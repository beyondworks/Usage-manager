//! Codex rollout logs (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`), read for the
//! account's weekly limit. Every `token_count` event carries it.

use crate::models::Limit;
use crate::transcript::{read_tail, TAIL_BYTES};
use chrono::{Duration, Local};
use serde_json::Value;
use std::path::{Path, PathBuf};

pub fn root(home: &Path) -> PathBuf {
    home.join(".codex").join("sessions")
}

/// Rollouts from the last `days` day-folders; the tree is dated, so years of history
/// are never walked.
pub fn recent_files(home: &Path, days: i64) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for back in 0..=days.max(0) {
        let d = Local::now() - Duration::days(back);
        let dir = root(home).join(d.format("%Y").to_string()).join(d.format("%m").to_string()).join(d.format("%d").to_string());
        let Ok(items) = std::fs::read_dir(&dir) else { continue };
        for e in items.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with("rollout-") && name.ends_with(".jsonl") {
                out.push(e.path());
            }
        }
    }
    out
}

/// A spawned helper thread is not a session anybody watches.
pub fn is_subagent(path: &Path) -> bool {
    use std::io::Read;
    let mut head = Vec::new();
    let Ok(f) = std::fs::File::open(path) else { return false };
    if f.take(256 * 1024).read_to_end(&mut head).is_err() {
        return false;
    }
    for line in head.split(|b| *b == b'\n') {
        let Ok(obj) = serde_json::from_slice::<Value>(line) else { continue };
        if obj["type"].as_str() == Some("session_meta") {
            return obj["payload"]["thread_source"].as_str() == Some("subagent");
        }
    }
    false
}

/// The weekly limit in the newest `token_count` that carries one.
pub fn weekly(path: &Path) -> Option<Limit> {
    let data = read_tail(path, TAIL_BYTES)?;
    for line in data.split(|b| *b == b'\n').rev() {
        let Ok(obj) = serde_json::from_slice::<Value>(line) else { continue };
        let p = &obj["payload"];
        if p["type"].as_str() != Some("token_count") {
            continue;
        }
        if let Some(rl) = p.get("rate_limits").filter(|v| v.is_object()) {
            if let Some(l) = weekly_limit(rl, crate::timeutil::iso(&obj["timestamp"])) {
                return Some(l);
            }
        }
    }
    None
}

/// The ≥ 7-day window, from whichever slot the plan puts it in.
pub fn weekly_limit(rl: &Value, at: Option<f64>) -> Option<Limit> {
    for key in ["primary", "secondary"] {
        let w = &rl[key];
        let mins = w["window_minutes"].as_f64().unwrap_or(0.0);
        let Some(used) = w["used_percent"].as_f64() else { continue };
        if mins < 7.0 * 24.0 * 60.0 {
            continue;
        }
        return Some(Limit { percent: used, resets_at: w["resets_at"].as_f64(), updated_at: at.unwrap_or_else(crate::timeutil::now_secs) });
    }
    None
}

/// The account-wide limit from the newest rollout of the past week that logged one.
pub fn newest_weekly(home: &Path) -> Option<Limit> {
    let mut dated: Vec<(PathBuf, f64)> = recent_files(home, 7)
        .into_iter()
        .filter_map(|p| crate::paths::mtime(&p).map(|m| (p, crate::timeutil::secs(m))))
        .collect();
    dated.sort_by(|a, b| b.1.total_cmp(&a.1));
    dated.iter().take(20).find_map(|(p, _)| weekly(p))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn weekly_window_is_picked_from_either_slot() {
        let rl = serde_json::json!({"primary":{"window_minutes":300,"used_percent":5},
                                    "secondary":{"window_minutes":10080,"used_percent":42,"resets_at":4102444800u64}});
        let l = weekly_limit(&rl, Some(1.0)).unwrap();
        assert_eq!((l.percent, l.resets_at), (42.0, Some(4102444800.0)));
    }
}
