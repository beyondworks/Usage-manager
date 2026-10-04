//! Time words, the same ones the macOS app uses.

use chrono::{DateTime, Utc};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn secs(t: SystemTime) -> f64 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn iso_now() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

/// ISO 8601 with or without fractional seconds, as Claude Code and Codex write it.
pub fn iso(v: &serde_json::Value) -> Option<f64> {
    let s = v.as_str()?;
    DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis() as f64 / 1000.0)
}

/// "2일 3시간 후" style countdown; empty when unknown or already past.
pub fn reset_text(at: Option<f64>, now: f64) -> String {
    let Some(at) = at else { return String::new() };
    let s = at - now;
    if s <= 0.0 {
        return String::new();
    }
    let h = (s / 3600.0) as i64;
    if h < 1 {
        return format!("{}분 후", ((s / 60.0) as i64).max(1));
    }
    if h < 24 {
        return format!("{h}시간 후");
    }
    format!("{}일 {}시간 후", h / 24, h % 24)
}

/// "42분", "1시간 12분" — short enough to sit inside a row.
pub fn short_span(sec: f64) -> String {
    let s = sec.round() as i64;
    if s < 60 {
        return format!("{s}초");
    }
    if s < 3600 {
        return format!("{}분", s / 60);
    }
    let m = (s % 3600) / 60;
    if m == 0 {
        format!("{}시간", s / 3600)
    } else {
        format!("{}시간 {}분", s / 3600, m)
    }
}

pub fn age_text(at: f64, now: f64) -> String {
    let age = now - at;
    if age < 60.0 {
        "방금".into()
    } else if age < 3600.0 {
        format!("{}분 전", (age / 60.0) as i64)
    } else {
        format!("{}시간 전", (age / 3600.0) as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_match_the_mac_app() {
        assert_eq!(reset_text(Some(100.0 + 30.0), 100.0), "1분 후");
        assert_eq!(reset_text(Some(100.0 + 5.0 * 3600.0), 100.0), "5시간 후");
        assert_eq!(reset_text(Some(100.0 + 50.0 * 3600.0), 100.0), "2일 2시간 후");
        assert_eq!(reset_text(Some(50.0), 100.0), "");
        assert_eq!(short_span(42.0 * 60.0), "42분");
        assert_eq!(short_span(72.0 * 60.0), "1시간 12분");
        assert_eq!(age_text(0.0, 30.0), "방금");
        assert_eq!(age_text(0.0, 7200.0), "2시간 전");
        assert!(iso(&serde_json::json!("2026-09-28T10:19:46.123Z")).is_some());
        assert!(iso(&serde_json::json!("2026-09-28T10:19:46Z")).is_some());
    }
}
