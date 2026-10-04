//! The app's state and its judgements: which rows to show, when to warn a session, and
//! when to suggest clearing one. A port of the macOS `AppModel`, without the UI.

use crate::gate;
use crate::hooks;
use crate::models::{provider_name, sort_quotas, Limit, Quota, Session, Tool};
use crate::paths;
use crate::timeutil::{age_text, now_secs, reset_text};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;

pub const QUOTA_INTERVAL: f64 = 300.0;
pub const MANUAL_INTERVAL: f64 = 60.0;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub ctx_threshold: i64,
    pub alerts_on: bool,
    pub compact_limit: i64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { ctx_threshold: 80, alerts_on: true, compact_limit: 3 }
    }
}

impl Settings {
    fn file() -> std::path::PathBuf {
        paths::root().join("settings.json")
    }
    pub fn load() -> Self {
        let mut s: Settings = std::fs::read(Self::file()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        s.ctx_threshold = s.ctx_threshold.clamp(50, 95);
        s.compact_limit = s.compact_limit.max(1);
        s
    }
    pub fn save(&self) {
        let _ = std::fs::create_dir_all(paths::root());
        let _ = std::fs::write(Self::file(), serde_json::to_string_pretty(self).unwrap_or_default());
    }
}

#[derive(Default, Clone, Copy)]
struct CtxState {
    disarmed: bool,
    last_notified: f64,
    clear_pushed: bool,
}

/// A notification to show: title, body, and an id so repeats replace each other.
pub type Notice = (String, String, String);

pub struct App {
    pub settings: Settings,
    pub tools: Vec<Tool>,
    pub sessions: Vec<Session>,
    pub quotas: Vec<Quota>,
    file_limits: HashMap<Tool, Limit>,
    live: HashMap<String, Quota>,
    pub next_quota_fetch: f64,
    pub last_manual_fetch: f64,
    pub hooks_on: bool,
    pub hook_error: Option<String>,
    pub launch_at_login: bool,
    ctx_state: HashMap<String, CtxState>,
    pub demo: bool,
    /// Whether a lookup has finished, so an empty row can stop saying it is still reading.
    pub quotas_fetched: bool,
}

impl App {
    pub fn new(settings: Settings) -> Self {
        App {
            settings,
            tools: vec![],
            sessions: vec![],
            quotas: vec![],
            file_limits: HashMap::new(),
            live: HashMap::new(),
            next_quota_fetch: now_secs() + QUOTA_INTERVAL,
            last_manual_fetch: 0.0,
            hooks_on: false,
            hook_error: None,
            launch_at_login: false,
            ctx_state: HashMap::new(),
            demo: false,
            quotas_fetched: false,
        }
    }

    pub fn apply_scan(&mut self, snap: crate::scanner::Snapshot) -> Vec<Notice> {
        if self.demo {
            return vec![];
        }
        self.tools = snap.tools;
        self.file_limits = snap.limits;
        self.sessions = snap.sessions;
        self.rebuild_quotas();
        self.evaluate_alerts()
    }

    /// Keep each provider's last good value, so one source failing leaves its row.
    pub fn apply_live(&mut self, live: Vec<Quota>) {
        for q in live {
            self.live.insert(q.provider.clone(), q);
        }
        self.rebuild_quotas();
    }

    /// The file-based fallback, overlaid by live values. Claude comes from the reading
    /// kept with its account, so a fresh launch has it and another account's never shows.
    fn rebuild_quotas(&mut self) {
        let mut by_id: HashMap<String, Quota> = HashMap::new();
        for (tool, l) in &self.file_limits {
            by_id.insert(
                tool.provider().into(),
                Quota { provider: tool.provider().into(), weekly: Some(l.percent), five_hour: None, resets_at: l.resets_at, updated_at: l.updated_at },
            );
        }
        for (id, q) in &self.live {
            if id != "anthropic" {
                by_id.insert(id.clone(), q.clone());
            }
        }
        if let Some(q) = crate::quota::last_known() {
            by_id.insert("anthropic".into(), q);
        }
        let mut q: Vec<Quota> = by_id.into_values().collect();
        sort_quotas(&mut q);
        self.quotas = q;
    }

    /// Per session: warn once on approaching the compaction point Claude Code itself will
    /// use, and re-arm once a compaction drops the session well below it. What actually
    /// holds the compaction is the gate; this only buys the agent time to write first.
    pub fn evaluate_alerts(&mut self) -> Vec<Notice> {
        let now = now_secs();
        let mut pushes = Vec::new();
        let mut pending: Vec<Session> = Vec::new();
        let pct = self.settings.ctx_threshold;
        for s in self.sessions.iter().filter(|s| s.has_context() && s.wants_compaction_alert()) {
            let mut st = self.ctx_state.get(&s.session_id).copied().unwrap_or_default();
            let arm = s.arm_tokens(pct);
            if s.ctx_tokens >= arm && !st.disarmed && self.settings.alerts_on {
                st.disarmed = true;
                hooks::queue_notice(&s.session_id, &notice_for(s, pct));
                // So the gate accepts the marker this warning asks for.
                gate::record_warning(&s.session_id);
                if now - st.last_notified > 600.0 {
                    pending.push(s.clone());
                    st.last_notified = now;
                }
            } else if s.ctx_tokens < arm - arm / 10 {
                st.disarmed = false;
            }
            if self.settings.alerts_on && !st.clear_pushed && s.needs_clear(self.settings.compact_limit) {
                st.clear_pushed = true;
                let body = match s.handover_saved {
                    Some(true) => "핸드오버 저장됨. clear 하거나 새 세션에서 핸드오버 문서와 옵시디언을 참조해 이어 가세요.",
                    Some(false) => "핸드오버 없이 압축되었습니다. /raw-press 로 먼저 저장한 뒤 clear 하세요.",
                    None => "핸드오버 저장 여부를 알 수 없습니다. 확인한 뒤 clear 하세요.",
                };
                pushes.push((format!("{} 압축 {}회", s.label(), s.compactions), body.into(), format!("clear-{}", s.session_id)));
            }
            self.ctx_state.insert(s.session_id.clone(), st);
        }
        let active: std::collections::HashSet<_> = self.sessions.iter().map(|s| s.session_id.clone()).collect();
        self.ctx_state.retain(|k, _| active.contains(k));
        if pending.len() > 3 {
            let list: Vec<String> = pending.iter().take(6).map(|s| format!("{} {}%", s.label(), s.used_percent() as i64)).collect();
            pushes.push((format!("{}개 세션이 압축 직전입니다", pending.len()), format!("{} · 핸드오버 저장 후 자동 압축", list.join(", ")), "ctx-summary".into()));
        } else {
            for s in pending {
                pushes.push((
                    format!("압축 직전 {}% · {}", s.used_percent() as i64, s.label()),
                    format!("{} · 핸드오버 저장 후 자동 압축", s.tool.display()),
                    format!("ctx-{}", s.session_id),
                ));
            }
        }
        pushes
    }

    pub fn manual_ready(&self) -> bool {
        now_secs() - self.last_manual_fetch > MANUAL_INTERVAL
    }

    /// Everything the popover draws, already worded.
    pub fn view(&self) -> Value {
        let now = now_secs();
        let limit = self.settings.compact_limit;
        let quotas: Vec<Value> = self
            .quotas
            .iter()
            .map(|q| {
                // Shown as headroom: the bar drains as the week is spent.
                let left = q.weekly.map(|w| 100.0 - w);
                let mut note = vec![];
                if let Some(f) = q.five_hour {
                    note.push(format!("5시간 {}%", (100.0 - f).round() as i64));
                }
                let r = reset_text(q.resets_at, now);
                if !r.is_empty() {
                    note.push(format!("리셋 {r}"));
                }
                note.push(age_text(q.updated_at, now));
                json!({
                    "provider": q.provider, "name": provider_name(&q.provider),
                    "left": left.map(|l| l.round() as i64), "ratio": left.unwrap_or(0.0) / 100.0,
                    "strong": left.unwrap_or(100.0) <= 20.0, "note": note.join(" · "),
                    "stale": now - q.updated_at >= 3600.0,
                })
            })
            .collect();
        let sessions: Vec<Value> = self
            .sessions
            .iter()
            .map(|s| {
                let clear = s.needs_clear(limit);
                json!({
                    "id": s.session_id, "label": s.label(), "provider": s.tool.provider(),
                    "pct": s.used_percent() as i64, "ratio": s.used_percent() / 100.0,
                    "over": s.used_percent() >= self.settings.ctx_threshold as f64,
                    "idle": s.is_idle(now),
                    "clear": clear.then(|| match s.handover_saved { Some(true) => "clear 권장", Some(false) => "저장 먼저", None => "저장 확인" }),
                    "count": (s.tool == Tool::ClaudeCode).then(|| format!("{}/{}", s.compactions, limit)),
                    "countSpent": s.compactions >= limit,
                    // The cache badge ticks in the page; it needs when and how long.
                    "cache": (!clear && s.cache_left(now).is_some()).then(|| json!({"at": s.last_reply_at, "ttl": s.cache_ttl, "tokens": s.ctx_tokens})),
                    "help": tooltip(s, now),
                })
            })
            .collect();
        json!({
            "tools": self.tools, "quotas": quotas, "sessions": sessions,
            "ctxThreshold": self.settings.ctx_threshold, "alertsOn": self.settings.alerts_on,
            "compactLimit": limit, "hooksOn": self.hooks_on, "hookError": self.hook_error,
            "launchAtLogin": self.launch_at_login, "nextQuotaFetch": self.next_quota_fetch,
            "quotaInterval": QUOTA_INTERVAL, "claudeWait": if self.demo { 0.0 } else { crate::quota::claude_wait() },
            "manualReady": self.manual_ready(), "now": now,
            "quotasFetched": self.quotas_fetched || self.demo, "claudeDiagnosis": crate::quota::diagnosis(),
        })
    }

    /// Fixed sample data for screenshots, so a published image never carries real
    /// account numbers or session names.
    pub fn load_demo(&mut self) {
        self.demo = true;
        let now = now_secs();
        self.quotas = vec![
            Quota { provider: "anthropic".into(), weekly: Some(38.0), five_hour: Some(21.0), resets_at: Some(now + 4.2 * 86400.0), updated_at: now },
            Quota { provider: "openai".into(), weekly: Some(86.0), five_hour: None, resets_at: Some(now + 2.5 * 86400.0), updated_at: now - 180.0 },
            Quota { provider: "kimi".into(), weekly: Some(64.0), five_hour: Some(55.0), resets_at: Some(now + 5.1 * 86400.0), updated_at: now },
        ];
        let mk = |sid: &str, title: &str, ctx: i64, comp: i64, post: i64, saved: Option<bool>, reply_ago: f64, idle: bool| Session {
            tool: Tool::ClaudeCode,
            session_id: sid.into(),
            project: "proj".into(),
            title: Some(title.into()),
            model: "claude-opus-5".into(),
            ctx_tokens: ctx,
            window_size: 1_000_000,
            mtime: if idle { now - 400.0 } else { now },
            compactions: comp,
            title_source: "meta".into(),
            cache_ttl: 3600.0,
            last_reply_at: Some(now - reply_ago),
            last_post_tokens: post,
            handover_saved: saved,
            compacted_at: 0,
        };
        self.sessions = vec![
            mk("demo01", "결제 리팩터링", 871_000, 3, 38_000, Some(true), 120.0, false),
            mk("demo02", "검색 색인 재구축", 486_000, 1, 31_000, None, 3480.0, false),
            mk("demo04", "온보딩 문서", 132_000, 0, 0, None, 400.0, true),
        ];
        self.tools = vec![Tool::ClaudeCode, Tool::Codex];
        self.hooks_on = true;
    }
}

fn tooltip(s: &Session, now: f64) -> String {
    let ttl = match s.cache_ttl as i64 {
        3600 => "1시간",
        300 => "5분",
        _ => "?",
    };
    let left = s.cache_left(now).map(|l| if l > 0.0 { format!(" · 남음 {}", crate::timeutil::short_span(l)) } else { " · 만료".into() }).unwrap_or_default();
    let post = if s.last_post_tokens > 0 {
        let h = match s.handover_saved {
            Some(true) => ", 핸드오버 저장됨",
            Some(false) => ", 핸드오버 없이 압축됨",
            None => "",
        };
        format!(" (직전 요약 {} 토큰{h})", s.last_post_tokens)
    } else {
        String::new()
    };
    format!(
        "{} · {} · {}/{} tokens · 캐시 {ttl}{left} · 압축 {}회{post} · {}{}",
        s.tool.display(),
        s.model,
        s.ctx_tokens,
        s.window_size,
        s.compactions,
        s.short_id(),
        if s.is_idle(now) { " · 유휴" } else { "" }
    )
}

/// What the agent is told ahead of time — the same procedure the gate states, so it
/// reads one set of instructions whichever arrives first. Non-interactive on purpose.
fn notice_for(s: &Session, pct: i64) -> String {
    format!(
        "[Usage Manager] 이 세션은 곧 자동 압축 지점(약 {}k 토큰)에 닿습니다. \
         그 지점에서 압축은 아래 ①②가 끝날 때까지 보류됩니다. 지금 미리 해 두면 기다림 없이 이어집니다. \
         사용자에게 묻지 말고 진행하세요.\n{}",
        s.compaction_tokens(pct) / 1000,
        gate::steps(&s.session_id)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::sample;
    use crate::testing::Home;

    /// A session near its compaction point gets the notice, the gate's warning mark and
    /// one push; Codex threads get nothing.
    #[test]
    fn warns_a_claude_session_near_its_compaction_point_once() {
        let _h = Home::new();
        let mut app = App::new(Settings::default());
        let sid = "99999999-8888-7777-6666-555555555555";
        app.sessions = vec![sample(sid, 950_010, 1_000_000)];
        let pushes = app.evaluate_alerts();
        let n = std::fs::read_to_string(paths::alerts().join(format!("{sid}.txt"))).unwrap();
        assert!(n.contains("SESSION_HANDOVER") && n.contains("obsidian-save") && n.contains("묻지 말고"));
        assert!(gate::warning(sid).exists());
        assert_eq!(pushes.len(), 1);
        assert!(app.evaluate_alerts().is_empty(), "warned twice");

        let mut codex = sample("22222222-aaaa-bbbb-cccc-dddddddddddd", 950_000, 1_000_000);
        codex.tool = Tool::Codex;
        app.sessions = vec![codex];
        assert!(app.evaluate_alerts().is_empty());
        assert!(!paths::alerts().join("22222222-aaaa-bbbb-cccc-dddddddddddd.txt").exists());
    }

    #[test]
    fn alerts_off_sends_nothing() {
        let _h = Home::new();
        let mut app = App::new(Settings { alerts_on: false, ..Default::default() });
        app.sessions = vec![sample("aa", 950_000, 1_000_000)];
        assert!(app.evaluate_alerts().is_empty());
        assert!(!paths::alerts().join("aa.txt").exists());
    }

    #[test]
    fn clear_is_pushed_once_with_the_right_words() {
        let _h = Home::new();
        let mut app = App::new(Settings::default());
        let mut s = sample("bb", 100_000, 1_000_000);
        s.compactions = 3;
        s.handover_saved = Some(false);
        app.sessions = vec![s];
        let p = app.evaluate_alerts();
        assert!(p[0].1.contains("/raw-press"));
        assert!(app.evaluate_alerts().is_empty());
        assert_eq!(app.view()["sessions"][0]["clear"], "저장 먼저");
    }
}
