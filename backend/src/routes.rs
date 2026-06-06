use crate::analysis::{detect_underheat_segments, has_suspect_condition};
use crate::models::*;
use crate::AppState;
use axum::{
    body::Body,
    extract::{Path, State},
    http::{HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{DateTime, Utc};
use http_body_util::Full;
use sqlx::PgPool;
use std::collections::BTreeMap;

async fn update_suspect_status(pool: &PgPool, batch_id: i32) -> Result<(), sqlx::Error> {
    let batch = sqlx::query_as::<_, CocoonBatch>(
        "SELECT * FROM cocoon_batches WHERE id = $1",
    )
    .bind(batch_id)
    .fetch_one(pool)
    .await?;

    let curves = sqlx::query_as::<_, BoilCurve>(
        "SELECT * FROM boil_curves WHERE batch_id = $1 ORDER BY recorded_at",
    )
    .bind(batch_id)
    .fetch_all(pool)
    .await?;

    let floats = sqlx::query_as::<_, FloatEvent>(
        "SELECT * FROM float_events WHERE batch_id = $1 ORDER BY recorded_at",
    )
    .bind(batch_id)
    .fetch_all(pool)
    .await?;

    let underheat_segments = detect_underheat_segments(&curves, batch.target_temp);
    let is_suspect = has_suspect_condition(&underheat_segments, &floats);

    sqlx::query(
        "UPDATE cocoon_batches SET is_suspect = $1 WHERE id = $2",
    )
    .bind(is_suspect)
    .bind(batch_id)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn list_batches(
    State(state): State<AppState>,
) -> Result<Json<Vec<CocoonBatch>>, (StatusCode, String)> {
    let batches = sqlx::query_as::<_, CocoonBatch>(
        "SELECT * FROM cocoon_batches ORDER BY created_at DESC",
    )
    .fetch_all(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(batches))
}

pub async fn create_batch(
    State(state): State<AppState>,
    Json(req): Json<CreateBatchRequest>,
) -> Result<Json<CocoonBatch>, (StatusCode, String)> {
    let batch = sqlx::query_as::<_, CocoonBatch>(
        "INSERT INTO cocoon_batches (cocoon_type, target_reeling_kg, target_temp)
         VALUES ($1, $2, $3)
         RETURNING *",
    )
    .bind(&req.cocoon_type)
    .bind(req.target_reeling_kg)
    .bind(req.target_temp)
    .fetch_one(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(batch))
}

pub async fn get_batch(
    State(state): State<AppState>,
    Path(id): Path<i32>,
) -> Result<Json<BatchDetail>, (StatusCode, String)> {
    let batch = sqlx::query_as::<_, CocoonBatch>(
        "SELECT * FROM cocoon_batches WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(|e| {
        if e.as_database_error()
            .and_then(|d| d.is_unique_violation())
            .is_some()
        {
            (StatusCode::CONFLICT, e.to_string())
        } else {
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        }
    })?;

    let boil_curves = sqlx::query_as::<_, BoilCurve>(
        "SELECT * FROM boil_curves WHERE batch_id = $1 ORDER BY recorded_at",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let float_events = sqlx::query_as::<_, FloatEvent>(
        "SELECT * FROM float_events WHERE batch_id = $1 ORDER BY recorded_at",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let underheat_segments = detect_underheat_segments(&boil_curves, batch.target_temp);

    Ok(Json(BatchDetail {
        batch,
        boil_curves,
        float_events,
        underheat_segments,
    }))
}

pub async fn record_boil(
    State(state): State<AppState>,
    Path(id): Path<i32>,
    Json(req): Json<RecordBoilRequest>,
) -> Result<Json<BoilCurve>, (StatusCode, String)> {
    let curve = sqlx::query_as::<_, BoilCurve>(
        "INSERT INTO boil_curves (batch_id, temp_c) VALUES ($1, $2) RETURNING *",
    )
    .bind(id)
    .bind(req.temp_c)
    .fetch_one(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    if let Err(e) = update_suspect_status(&state.db, id).await {
        tracing::warn!("Failed to update suspect status: {}", e);
    }

    Ok(Json(curve))
}

pub async fn record_float(
    State(state): State<AppState>,
    Path(id): Path<i32>,
    Json(req): Json<RecordFloatRequest>,
) -> Result<Json<FloatEvent>, (StatusCode, String)> {
    let event = sqlx::query_as::<_, FloatEvent>(
        "INSERT INTO float_events (batch_id, float_ratio_pct) VALUES ($1, $2) RETURNING *",
    )
    .bind(id)
    .bind(req.float_ratio_pct)
    .fetch_one(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    if let Err(e) = update_suspect_status(&state.db, id).await {
        tracing::warn!("Failed to update suspect status: {}", e);
    }

    Ok(Json(event))
}

pub async fn mark_outbound(
    State(state): State<AppState>,
    Path(id): Path<i32>,
) -> Result<Response, (StatusCode, String)> {
    let batch = sqlx::query_as::<_, CocoonBatch>(
        "SELECT * FROM cocoon_batches WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    if batch.is_suspect {
        return Ok((
            StatusCode::CONFLICT,
            Json(OutboundResponse {
                success: false,
                message: "批次存在质量问题（低温+低浮茧），禁止出库".to_string(),
            }),
        )
            .into_response());
    }

    let updated = sqlx::query_as::<_, CocoonBatch>(
        "UPDATE cocoon_batches SET status = 'outbound' WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok((
        StatusCode::OK,
        Json(OutboundResponse {
            success: true,
            message: format!("批次 {} 已出库", updated.id),
        }),
    )
        .into_response())
}

pub async fn export_report(
    State(state): State<AppState>,
    Path(id): Path<i32>,
) -> Result<Response, (StatusCode, String)> {
    let batch = sqlx::query_as::<_, CocoonBatch>(
        "SELECT * FROM cocoon_batches WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let boil_curves = sqlx::query_as::<_, BoilCurve>(
        "SELECT * FROM boil_curves WHERE batch_id = $1 ORDER BY recorded_at",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let float_events = sqlx::query_as::<_, FloatEvent>(
        "SELECT * FROM float_events WHERE batch_id = $1 ORDER BY recorded_at",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let underheat_segments = detect_underheat_segments(&boil_curves, batch.target_temp);

    let mut time_map: BTreeMap<DateTime<Utc>, (Option<f64>, Option<f64>)> = BTreeMap::new();

    for curve in &boil_curves {
        time_map
            .entry(curve.recorded_at)
            .or_insert((None, None))
            .0 = Some(curve.temp_c);
    }

    for event in &float_events {
        time_map
            .entry(event.recorded_at)
            .or_insert((None, None))
            .1 = Some(event.float_ratio_pct);
    }

    let is_underheat_time = |time: &DateTime<Utc>| -> bool {
        underheat_segments.iter().any(|seg| {
            *time >= seg.start_time && *time <= seg.end_time
        })
    };

    let mut wtr = csv::Writer::from_writer(vec![]);

    wtr.write_record([
        "时间",
        "温度(°C)",
        "浮茧率(%)",
        "目标温度(°C)",
        "低温段",
        "可疑批次",
    ])
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    for (time, (temp, float_ratio)) in &time_map {
        let underheat = is_underheat_time(time);
        wtr.write_record(&[
            time.format("%Y-%m-%d %H:%M:%S").to_string(),
            temp.map(|v| format!("{:.2}", v)).unwrap_or_default(),
            float_ratio.map(|v| format!("{:.2}", v)).unwrap_or_default(),
            format!("{:.2}", batch.target_temp),
            if underheat { "是" } else { "否" }.to_string(),
            if batch.is_suspect { "是" } else { "否" }.to_string(),
        ])
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    }

    let csv_data = wtr
        .into_inner()
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let filename = format!(
        "attachment; filename=\"batch_{}_report.csv\"",
        id
    );

    let body = Body::from(Full::from(csv_data));

    let mut response = Response::new(body);
    *response.status_mut() = StatusCode::OK;
    response.headers_mut().insert(
        "Content-Type",
        HeaderValue::from_str("text/csv; charset=utf-8")
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?,
    );
    response.headers_mut().insert(
        "Content-Disposition",
        HeaderValue::from_str(&filename)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?,
    );

    Ok(response)
}
