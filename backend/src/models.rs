use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Debug, Serialize, Deserialize, FromRow, Clone)]
pub struct CocoonBatch {
    pub id: i32,
    pub cocoon_type: String,
    pub target_reeling_kg: f64,
    pub target_temp: f64,
    pub status: String,
    pub is_suspect: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct CreateBatchRequest {
    pub cocoon_type: String,
    pub target_reeling_kg: f64,
    pub target_temp: f64,
}

#[derive(Debug, Serialize, Deserialize, FromRow, Clone)]
pub struct BoilCurve {
    pub id: i32,
    pub batch_id: i32,
    pub temp_c: f64,
    pub recorded_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct RecordBoilRequest {
    pub temp_c: f64,
}

#[derive(Debug, Serialize, Deserialize, FromRow, Clone)]
pub struct FloatEvent {
    pub id: i32,
    pub batch_id: i32,
    pub float_ratio_pct: f64,
    pub recorded_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct RecordFloatRequest {
    pub float_ratio_pct: f64,
}

#[derive(Debug, Serialize)]
pub struct BatchDetail {
    pub batch: CocoonBatch,
    pub boil_curves: Vec<BoilCurve>,
    pub float_events: Vec<FloatEvent>,
    pub underheat_segments: Vec<UnderheatSegment>,
}

#[derive(Debug, Serialize, Clone)]
pub struct UnderheatSegment {
    pub start_time: DateTime<Utc>,
    pub end_time: DateTime<Utc>,
    pub min_temp: f64,
}

#[derive(Debug, Serialize)]
pub struct ReportRow {
    pub time: DateTime<Utc>,
    pub temp_c: Option<f64>,
    pub float_ratio_pct: Option<f64>,
    pub is_underheat: bool,
}

#[derive(Debug, Serialize)]
pub struct OutboundResponse {
    pub success: bool,
    pub message: String,
}
