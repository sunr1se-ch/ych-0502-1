use crate::models::{BoilCurve, FloatEvent, UnderheatSegment};
use chrono::{DateTime, Duration, Utc};

pub fn detect_underheat_segments(
    curves: &[BoilCurve],
    target_temp: f64,
) -> Vec<UnderheatSegment> {
    let threshold = target_temp - 2.0;
    let mut segments = Vec::new();
    let mut sorted_curves: Vec<&BoilCurve> = curves.iter().collect();
    sorted_curves.sort_by_key(|c| c.recorded_at);

    let mut i = 0;
    while i + 2 < sorted_curves.len() {
        let c1 = sorted_curves[i];
        let c2 = sorted_curves[i + 1];
        let c3 = sorted_curves[i + 2];

        let within_3_min = (c3.recorded_at - c1.recorded_at) <= Duration::minutes(3);
        let all_below = c1.temp_c < threshold && c2.temp_c < threshold && c3.temp_c < threshold;

        if within_3_min && all_below {
            let min_temp = c1.temp_c.min(c2.temp_c).min(c3.temp_c);
            segments.push(UnderheatSegment {
                start_time: c1.recorded_at,
                end_time: c3.recorded_at,
                min_temp,
            });
            i += 3;
        } else {
            i += 1;
        }
    }

    segments
}

pub fn has_suspect_condition(
    underheat_segments: &[UnderheatSegment],
    float_events: &[FloatEvent],
) -> bool {
    if underheat_segments.is_empty() {
        return false;
    }

    let mut sorted_events: Vec<&FloatEvent> = float_events.iter().collect();
    sorted_events.sort_by_key(|e| e.recorded_at);

    for i in 4..sorted_events.len() {
        let window = &sorted_events[i - 4..=i];
        let all_low = window.iter().all(|e| e.float_ratio_pct < 40.0);
        if !all_low {
            continue;
        }

        let window_start = window[0].recorded_at;
        let window_end = window[4].recorded_at;

        let has_overlap = underheat_segments.iter().any(|seg| {
            segments_overlap(seg.start_time, seg.end_time, window_start, window_end)
        });

        if has_overlap {
            return true;
        }
    }

    false
}

fn segments_overlap(
    a_start: DateTime<Utc>,
    a_end: DateTime<Utc>,
    b_start: DateTime<Utc>,
    b_end: DateTime<Utc>,
) -> bool {
    a_start <= b_end && b_start <= a_end
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn create_boil(batch_id: i32, temp: f64, minutes_offset: i64) -> BoilCurve {
        BoilCurve {
            id: 0,
            batch_id,
            temp_c: temp,
            recorded_at: Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap()
                + Duration::minutes(minutes_offset),
        }
    }

    #[test]
    fn test_detect_underheat_single_segment() {
        let curves = vec![
            create_boil(1, 95.0, 0),
            create_boil(1, 95.5, 1),
            create_boil(1, 95.8, 2),
        ];
        let target = 98.0;
        let segments = detect_underheat_segments(&curves, target);
        assert_eq!(segments.len(), 1);
    }

    #[test]
    fn test_no_underheat_when_temps_ok() {
        let curves = vec![
            create_boil(1, 97.0, 0),
            create_boil(1, 97.5, 1),
            create_boil(1, 97.8, 2),
        ];
        let target = 98.0;
        let segments = detect_underheat_segments(&curves, target);
        assert!(segments.is_empty());
    }

    #[test]
    fn test_suspect_condition_met() {
        let underheat = vec![UnderheatSegment {
            start_time: Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap(),
            end_time: Utc.with_ymd_and_hms(2024, 1, 1, 0, 10, 0).unwrap(),
            min_temp: 95.0,
        }];

        let floats = (0..5)
            .map(|i| FloatEvent {
                id: 0,
                batch_id: 1,
                float_ratio_pct: 35.0,
                recorded_at: Utc.with_ymd_and_hms(2024, 1, 1, 0, 5 + i, 0).unwrap(),
            })
            .collect::<Vec<_>>();

        assert!(has_suspect_condition(&underheat, &floats));
    }

    #[test]
    fn test_not_suspect_without_underheat() {
        let floats = (0..5)
            .map(|i| FloatEvent {
                id: 0,
                batch_id: 1,
                float_ratio_pct: 35.0,
                recorded_at: Utc.with_ymd_and_hms(2024, 1, 1, 0, 5 + i, 0).unwrap(),
            })
            .collect::<Vec<_>>();

        assert!(!has_suspect_condition(&[], &floats));
    }
}
