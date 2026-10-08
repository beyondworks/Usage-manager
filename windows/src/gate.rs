//! The PreCompact(auto) decision, taken at the moment Claude Code is about to compact.
//!
//! A PreCompact with `trigger: auto` *is* the signal that a session reached its
//! compaction point, so nothing has to be armed in advance — the app learns a session's
//! size a second too late to win that race. This also covers sessions the app cannot
//! see, and works with the app closed.

use crate::paths::{self, mtime};
use crate::timeutil::{now_secs, secs};
use crate::transcript;
use serde_json::Value;
use std::path::PathBuf;

#[derive(Debug, PartialEq)]
pub enum Decision {
    Pass(String),
    Hold(String),
}

/// Long enough for a handover and no longer: the window keeps filling meanwhile.
pub const MAX_HOLDS: i64 = 40;
pub const MAX_SECONDS: f64 = 600.0;
/// Past `window − 20000` a request fails instead of compacting, and the reactive
/// compaction after that failure arrives as `auto` too; holding it strands the session.
/// The 10k step back is twice the estimator's measured error.
const OUTPUT_RESERVE: i64 = 20_000;
const ESTIMATE_MARGIN: i64 = 10_000;
/// How much a session may grow after writing its handover and still be described by it.
const DELTA_TOKENS: i64 = 5_000;
/// A marker written after a warning but never spent says nothing by the next day.
const STALE_MARKER: f64 = 6.0 * 3600.0;
pub const HANDOVER_REASON: &str = "handover written";

fn dir(name: &str) -> PathBuf {
    paths::root().join(name)
}
fn hold_file(sid: &str) -> PathBuf {
    dir("holds").join(sid)
}
fn pressed(sid: &str) -> PathBuf {
    dir("pressed").join(sid)
}
pub fn warning(sid: &str) -> PathBuf {
    dir("warned").join(sid)
}

pub fn decide(input: &[u8]) -> Decision {
    let (sid, d) = evaluate(input, now_secs());
    match &d {
        Decision::Pass(why) => {
            log(&format!("{sid} pass — {why}"));
            // Whether the compaction about to run had a handover behind it, so the app can
            // tell "saved, safe to clear" from "clearing would lose this" — written at the
            // gate or ahead of the warning alike.
            if sid != "?" {
                let _ = std::fs::create_dir_all(dir("lastpass"));
                let _ = std::fs::write(dir("lastpass").join(&sid), if why.starts_with(HANDOVER_REASON) { "handover" } else { "other" });
            }
        }
        Decision::Hold(why) => log(&format!("{sid} {why}")),
    }
    d
}

pub fn log(text: &str) {
    paths::append_log("gate.log", text);
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub struct Held {
    pub n: i64,
    pub first: f64,
    pub ctx: i64,
}

pub fn state(sid: &str) -> Option<Held> {
    let text = std::fs::read_to_string(hold_file(sid)).ok()?;
    let f: Vec<f64> = text.split_whitespace().filter_map(|x| x.parse().ok()).collect();
    (f.len() == 3).then(|| Held { n: f[0] as i64, first: f[1], ctx: f[2] as i64 })
}

pub fn write_state(sid: &str, s: Held) {
    let _ = std::fs::create_dir_all(dir("holds"));
    let _ = std::fs::write(hold_file(sid), format!("{} {} {}", s.n, s.first as i64, s.ctx));
}

/// End the cycle completely: a notice or marker left behind would be spent on the next.
pub fn clear(sid: &str) {
    for p in [hold_file(sid), pressed(sid), paths::alerts().join(format!("{sid}.txt")), warning(sid)] {
        let _ = std::fs::remove_file(p);
    }
}

fn evaluate(input: &[u8], now: f64) -> (String, Decision) {
    let obj: Value = serde_json::from_slice(input).unwrap_or(Value::Null);
    let sid = obj["session_id"].as_str().unwrap_or("").to_string();
    if !paths::safe_id(&sid) {
        return ("?".into(), Decision::Pass("no session id".into()));
    }
    // A subagent's compaction carries its parent's session id; anything done with it
    // would be spent on the parent's behalf.
    if obj.get("agent_id").is_some() {
        return (sid, Decision::Pass("subagent".into()));
    }
    if dir("gate-off").exists() {
        clear(&sid);
        return (sid, Decision::Pass("alerts off".into()));
    }
    let pressed_at = mtime(&pressed(&sid)).map(secs);
    let path = PathBuf::from(obj["transcript_path"].as_str().unwrap_or(""));
    let tail = transcript::claude_tail_deep(&path, pressed_at);
    if tail.as_ref().and_then(|t| t.entrypoint.as_deref()).map(|e| e.starts_with("sdk")).unwrap_or(false) {
        clear(&sid);
        return (sid, Decision::Pass("headless session".into()));
    }
    // No usage in reach means no idea how large the session is, and holding blind is
    // what strands one at its limit.
    let Some(tail) = tail.filter(|t| t.ctx_tokens > 0) else {
        clear(&sid);
        return (sid, Decision::Pass("no usage found in the transcript".into()));
    };
    let ctx = tail.next_request_tokens();
    let held = state(&sid);
    let mut stale = false;
    if let Some(at) = pressed_at {
        if held.is_some() {
            clear(&sid);
            return (sid, Decision::Pass(HANDOVER_REASON.into()));
        }
        if let Some(warned) = mtime(&warning(&sid)).map(secs) {
            if at >= warned && now - at < STALE_MARKER {
                let grew = tail.tokens_at.map(|t| ctx - t);
                if grew.is_some_and(|g| g < DELTA_TOKENS) {
                    clear(&sid);
                    return (sid, Decision::Pass(format!("{HANDOVER_REASON} ahead of the warning")));
                }
                stale = true;
                log(&format!(
                    "{sid} grew {} tokens after the marker — holding for the rest",
                    grew.map(|g| g.to_string()).unwrap_or_else(|| "an unknown amount".into())
                ));
            }
        }
        let _ = std::fs::remove_file(pressed(&sid));
    }
    let window = window_size(&sid, &tail);
    let ceiling = window - OUTPUT_RESERVE - ESTIMATE_MARGIN;
    if ctx >= ceiling {
        clear(&sid);
        return (sid, Decision::Pass(format!("at the hard limit ({ctx} tokens, ceiling {ceiling} in a {window} window)")));
    }
    let mut s = held.unwrap_or(Held { n: 0, first: now, ctx });
    s.n += 1;
    if s.n > MAX_HOLDS || now - s.first >= MAX_SECONDS {
        clear(&sid);
        return (sid, Decision::Pass(format!("budget spent after {} holds", s.n - 1)));
    }
    write_state(&sid, s);
    // Once per cycle; the prompt hook hands it over on the next tool call and restarts
    // the budget from there.
    if s.n == 1 {
        crate::hooks::queue_notice(&sid, &if stale { delta(&sid) } else { notice(&sid) });
    }
    (sid, Decision::Hold(format!("hold {} ({ctx} tokens)", s.n)))
}

/// The smaller guess (200k) when nothing says otherwise: it releases earlier, so it
/// never leaves a session stuck behind a hold it cannot clear.
fn window_size(sid: &str, tail: &transcript::Tail) -> i64 {
    crate::scanner::window_size(sid, &tail.model, tail.ctx_tokens, 200_000)
}

/// Called when the app tells a session its compaction point is near, so the gate can
/// tell a marker written in answer to it from one left over.
pub fn record_warning(sid: &str) {
    let _ = std::fs::create_dir_all(dir("warned"));
    let _ = std::fs::write(warning(sid), b"");
}

pub fn steps(sid: &str) -> String {
    format!(
        "① 작업 폴더의 SESSION_HANDOVER.md 를 갱신합니다(목표·결정·진행 상황·미검증 항목·다음 단계·처리 중인 요청).\n\
         ② obsidian-save 로 AI-Sessions-Vault 에 저장합니다(lint 와 push 까지 마칩니다).\n\
         ③ ②의 push 까지 끝난 것을 확인한 뒤, 마지막으로 `touch ~/.usage-manager/pressed/{sid}` 를 \
         실행하면 압축이 이어집니다. /compact 를 직접 실행하거나 사용자에게 안내하지 마세요."
    )
}

pub fn notice(sid: &str) -> String {
    format!(
        "[Usage Manager] 이 세션의 자동 압축이 보류되었습니다. 아래 ①②가 끝나면 압축이 이어집니다. \
         사용자에게 묻지 말고 지금 바로 진행하세요.\n{}\n\
         보류는 약 10분 뒤 자동으로 풀리므로, 다른 작업보다 먼저 처리하세요.",
        steps(sid)
    )
}

/// For a session that saved once at the warning and kept working: only the difference.
pub fn delta(sid: &str) -> String {
    format!(
        "[Usage Manager] 이 세션의 자동 압축이 보류되었습니다. 핸드오버를 저장한 뒤로도 작업이 이어져서, \
         그 사이 내용이 저장본에 빠져 있습니다. 사용자에게 묻지 말고 지금 바로 진행하세요.\n\
         ① 마지막 저장 이후에 한 일만 SESSION_HANDOVER.md 에 덧붙입니다(처음부터 다시 쓰지 않습니다).\n\
         ② obsidian-save 로 그 갱신본을 저장합니다.\n\
         ③ `touch ~/.usage-manager/pressed/{sid}` 를 실행하면 압축이 이어집니다. 이번에는 한 번만 \
         묻습니다 — 마커를 누르면 그대로 압축됩니다.\n\
         보류는 약 10분 뒤 자동으로 풀립니다."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Home;
    use crate::transcript::tests::usage_line;
    use std::path::Path;

    const SID: &str = "33333333-cccc-dddd-eeee-ffffffffffff";

    fn gate(h: &Home, sid: &str, extra: &str) -> bool {
        let input = format!(
            r#"{{"session_id":"{sid}","hook_event_name":"PreCompact","trigger":"auto","transcript_path":{}{extra}}}"#,
            serde_json::to_string(&h.transcript().to_string_lossy()).unwrap()
        );
        matches!(decide(input.as_bytes()), Decision::Hold(_))
    }
    fn tokens(h: &Home, n: i64) {
        std::fs::write(h.transcript(), usage_line(n, "2026-10-01T00:00:00Z") + "\n").unwrap();
    }
    fn alert(sid: &str) -> PathBuf {
        paths::alerts().join(format!("{sid}.txt"))
    }

    #[test]
    fn holds_until_the_marker_then_lets_one_through() {
        let h = Home::new();
        tokens(&h, 900_000);
        assert!(gate(&h, SID, ""), "an automatic compaction was not held");
        let n = std::fs::read_to_string(alert(SID)).unwrap();
        assert!(n.contains("SESSION_HANDOVER") && n.contains("obsidian-save") && n.contains("묻지 말고"));
        std::fs::write(pressed(SID), b"").unwrap();
        assert!(!gate(&h, SID, ""), "marker present but still held");
        assert!(!pressed(SID).exists(), "marker not consumed");
        assert!(state(SID).is_none(), "counter left after pass");
        assert_eq!(std::fs::read_to_string(dir("lastpass").join(SID)).unwrap(), "handover");
        assert!(gate(&h, SID, ""), "second cycle not held");
    }

    #[test]
    fn lets_go_at_the_hard_limit() {
        let h = Home::new();
        tokens(&h, 960_000);
        assert!(gate(&h, SID, ""), "released below the ceiling");
        tokens(&h, 985_000);
        assert!(!gate(&h, SID, ""), "still holding above the ceiling");
        assert!(state(SID).is_none() && !alert(SID).exists(), "state outlived the compaction");
        assert_eq!(std::fs::read_to_string(dir("lastpass").join(SID)).unwrap(), "other");
        tokens(&h, 985_000);
        assert!(!gate(&h, SID, ""), "first hold on an over-limit session");
        assert!(state(SID).is_none());
    }

    #[test]
    fn queued_results_count_toward_the_limit() {
        let h = Home::new();
        let result = format!(r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{}"}}]}}}}"#, "x".repeat(90_000));
        let u = usage_line(960_000, "2026-10-01T00:00:00Z");
        std::fs::write(h.transcript(), format!("{u}\n{result}\n{u}\n")).unwrap();
        assert!(!gate(&h, SID, ""), "queued tool results were not counted");
    }

    #[test]
    fn budget_is_forty_holds_or_ten_minutes() {
        let h = Home::new();
        tokens(&h, 900_000);
        let mut held = 0;
        while gate(&h, SID, "") {
            held += 1;
            if held > 45 {
                break;
            }
        }
        assert_eq!(held, 40);
        assert!(gate(&h, SID, ""), "new cycle not held");
        let mut s = state(SID).unwrap();
        s.first -= 1200.0;
        write_state(SID, s);
        assert!(!gate(&h, SID, ""), "holding past the time budget");
    }

    #[test]
    fn a_marker_without_a_cycle_means_nothing() {
        let h = Home::new();
        tokens(&h, 900_000);
        std::fs::create_dir_all(dir("pressed")).unwrap();
        std::fs::write(pressed(SID), b"").unwrap();
        assert!(gate(&h, SID, ""), "a stale marker waved the compaction through");
        assert!(!pressed(SID).exists(), "stale marker not discarded");
    }

    fn set_mtime(p: &Path, ago_secs: u64) {
        let f = std::fs::OpenOptions::new().create(true).write(true).open(p).unwrap();
        f.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(ago_secs)).unwrap();
    }
    fn grown(h: &Home, before: i64, now_tokens: i64) {
        let then = (chrono::Utc::now() - chrono::Duration::minutes(20)).to_rfc3339();
        let now = chrono::Utc::now().to_rfc3339();
        std::fs::write(h.transcript(), format!("{}\n{}\n", usage_line(before, &then), usage_line(now_tokens, &now))).unwrap();
    }

    /// What counts is how far the session ran past the marker, not past the warning.
    #[test]
    fn early_warning_marker_is_accepted_only_when_current() {
        let h = Home::new();
        for d in ["warned", "pressed"] {
            std::fs::create_dir_all(dir(d)).unwrap();
        }
        set_mtime(&warning(SID), 30 * 60);
        set_mtime(&pressed(SID), 15 * 60);
        grown(&h, 832_000, 832_900);
        assert!(!gate(&h, SID, ""), "a session that prepared after the warning was held");
        assert!(!warning(SID).exists(), "the warning outlived the compaction");
        // A compaction with a handover behind it; recorded otherwise, the app reported it
        // as compacted with nothing saved.
        assert_eq!(std::fs::read_to_string(dir("lastpass").join(SID)).unwrap(), "handover");

        set_mtime(&warning(SID), 30 * 60);
        set_mtime(&pressed(SID), 15 * 60);
        grown(&h, 809_000, 832_900);
        assert!(gate(&h, SID, ""), "22k of work after the handover was compacted away");
        assert!(std::fs::read_to_string(alert(SID)).unwrap().contains("마지막 저장 이후"));
        clear(SID);

        set_mtime(&pressed(SID), 40 * 60);
        set_mtime(&warning(SID), 30 * 60);
        grown(&h, 832_000, 832_900);
        assert!(gate(&h, SID, ""), "a marker older than the warning was accepted");
        clear(SID);

        set_mtime(&warning(SID), 8 * 3600);
        set_mtime(&pressed(SID), 8 * 3600);
        grown(&h, 832_000, 832_900);
        assert!(gate(&h, SID, ""), "an eight-hour-old marker was accepted");
        clear(SID);

        set_mtime(&warning(SID), 0);
        grown(&h, 809_000, 832_900);
        assert!(gate(&h, SID, ""));
        set_mtime(&pressed(SID), 0);
        assert!(!gate(&h, SID, ""), "held a second time after the marker was written");
    }

    #[test]
    fn leaves_subagents_headless_runs_and_switched_off_alone() {
        let h = Home::new();
        tokens(&h, 900_000);
        assert!(!gate(&h, SID, r#","agent_id":"agent-1""#), "a subagent compaction was held");
        assert!(state(SID).is_none() && !alert(SID).exists());
        std::fs::write(h.transcript(), usage_line(900_000, "2026-10-01T00:00:00Z").replace("\"cli\"", "\"sdk-cli\"") + "\n").unwrap();
        assert!(!gate(&h, SID, ""), "headless session was held");
        tokens(&h, 900_000);
        std::fs::write(dir("gate-off"), b"").unwrap();
        assert!(!gate(&h, SID, ""), "alerts off but still held");
        std::fs::remove_file(dir("gate-off")).unwrap();
        std::fs::write(h.transcript(), "{\"type\":\"user\",\"message\":{\"content\":\"nothing\"}}\n").unwrap();
        assert!(!gate(&h, SID, ""), "held a session it could not measure");
        assert!(!gate(&h, "../x", ""), "unsafe id");
    }

    #[test]
    fn measures_past_a_large_result() {
        let h = Home::new();
        let result = format!(r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{}"}}]}}}}"#, "x".repeat(300_000));
        std::fs::write(h.transcript(), format!("{}\n{result}\n", usage_line(700_000, "2026-10-01T00:00:00Z"))).unwrap();
        assert!(gate(&h, SID, ""));
        assert!(std::fs::read_to_string(dir("gate.log")).unwrap().contains("hold 1 (800010 tokens)"));
    }
}
