//! What the app shows: limits per provider and the live state of each session.
//! A line-by-line port of the macOS `SessionCtx`, so the two apps judge alike.

use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
pub enum Tool {
    #[serde(rename = "claude_code")]
    ClaudeCode,
    #[serde(rename = "codex")]
    Codex,
}

impl Tool {
    pub fn display(self) -> &'static str {
        match self {
            Tool::ClaudeCode => "Claude Code",
            Tool::Codex => "Codex",
        }
    }
    /// The subscription this tool bills against.
    pub fn provider(self) -> &'static str {
        match self {
            Tool::ClaudeCode => "anthropic",
            Tool::Codex => "openai",
        }
    }
}

/// A weekly limit read from local files.
#[derive(Clone, Debug, PartialEq)]
pub struct Limit {
    pub percent: f64,
    pub resets_at: Option<f64>,
    pub updated_at: f64,
}

/// A subscription's weekly (and, when known, 5-hour) usage, as a percentage used.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Quota {
    pub provider: String,
    pub weekly: Option<f64>,
    pub five_hour: Option<f64>,
    pub resets_at: Option<f64>,
    pub updated_at: f64,
}

pub fn provider_name(id: &str) -> String {
    match id {
        "anthropic" => "Claude".into(),
        "openai" => "Codex".into(),
        "kimi" => "Kimi".into(),
        _ => {
            let mut c = id.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

pub fn sort_quotas(q: &mut [Quota]) {
    let rank = |id: &str| ["anthropic", "openai", "kimi"].iter().position(|x| *x == id).unwrap_or(3);
    q.sort_by(|a, b| (rank(&a.provider), &a.provider).cmp(&(rank(&b.provider), &b.provider)));
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Session {
    pub tool: Tool,
    pub session_id: String,
    pub project: String,
    /// The user-set name; None when unnamed.
    pub title: Option<String>,
    pub model: String,
    pub ctx_tokens: i64,
    pub window_size: i64,
    pub mtime: f64,
    pub compactions: i64,
    /// Where the title came from: the desktop app's metadata, the transcript's rename
    /// line, or nothing (the folder name is then used).
    pub title_source: String,
    pub cache_ttl: f64,
    pub last_reply_at: Option<f64>,
    /// What the last compaction left, and whether a handover was written before it.
    /// None means no record either way — not "nothing was saved".
    pub last_post_tokens: i64,
    pub handover_saved: Option<bool>,
    /// How large this session was at its last automatic compaction; 0 when never.
    pub compacted_at: i64,
}

/// Compacting again buys almost nothing past a few rounds (142 compactions of 1M
/// sessions: 31,233 tokens left after the first, 39,891 after the fifth), and each one
/// summarises a summary. A summary this large says the same early.
pub const SWOLLEN_SUMMARY: i64 = 45_000;

impl Session {
    pub fn used_percent(&self) -> f64 {
        if self.window_size > 0 {
            self.ctx_tokens as f64 / self.window_size as f64 * 100.0
        } else {
            0.0
        }
    }
    pub fn has_context(&self) -> bool {
        self.window_size > 0
    }
    pub fn is_idle(&self, now: f64) -> bool {
        now - self.mtime > 180.0
    }
    pub fn short_id(&self) -> String {
        self.session_id.chars().take(6).collect()
    }
    /// Codex threads are read for their quota only; nothing is written into their prompts.
    pub fn wants_compaction_alert(&self) -> bool {
        self.tool == Tool::ClaudeCode
    }
    pub fn needs_clear(&self, limit: i64) -> bool {
        self.compactions > 0 && (self.compactions >= limit || self.last_post_tokens >= SWOLLEN_SUMMARY)
    }
    pub fn cache_left(&self, now: f64) -> Option<f64> {
        let at = self.last_reply_at?;
        if self.cache_ttl <= 0.0 {
            return None;
        }
        Some((at + self.cache_ttl - now).max(0.0))
    }

    /// The tally once written into session names by hand ("Argo - 총괄 (0/3)") is
    /// dropped from what is shown; the session's own title is never modified.
    pub fn label(&self) -> String {
        let raw = self.title.clone().unwrap_or_else(|| self.project.clone());
        let re = regex::Regex::new(r"\s*\(\s*\d+\s*/\s*\d+\s*\)\s*$").unwrap();
        match re.find(&raw) {
            Some(m) => {
                let trimmed = raw[..m.start()].trim();
                if trimmed.is_empty() {
                    raw.clone()
                } else {
                    trimmed.to_string()
                }
            }
            None => raw,
        }
    }

    /// Claude Code compacts at `min(effective × pct/100, effective − 13000)` with
    /// `effective = window − 20000`.
    fn effective_window(&self) -> i64 {
        (self.window_size - 20_000).max(0)
    }

    /// Where this session actually compacted last time, when the slider (50–95%) or the
    /// formula's other arm could have produced it.
    pub fn measured_compaction_point(&self) -> Option<i64> {
        if self.compacted_at <= 0 || self.window_size <= 0 {
            return None;
        }
        let lo = self.effective_window() * 2 / 5;
        (lo..=self.window_size).contains(&self.compacted_at).then_some(self.compacted_at)
    }

    pub fn compaction_tokens(&self, pct: i64) -> i64 {
        self.measured_compaction_point().unwrap_or_else(|| {
            let e = self.effective_window();
            (e * pct.clamp(1, 100) / 100).min(e - 13_000)
        })
    }

    /// One step earlier, so the notice and the gate's arming both land first.
    pub fn arm_tokens(&self, pct: i64) -> i64 {
        self.compaction_tokens(pct) - 30_000.min(self.effective_window() / 20)
    }
}

#[cfg(test)]
pub fn sample(sid: &str, ctx: i64, window: i64) -> Session {
    Session {
        tool: Tool::ClaudeCode,
        session_id: sid.into(),
        project: "proj".into(),
        title: None,
        model: "claude-opus-5".into(),
        ctx_tokens: ctx,
        window_size: window,
        mtime: crate::timeutil::now_secs(),
        compactions: 0,
        title_source: "folder".into(),
        cache_ttl: 0.0,
        last_reply_at: None,
        last_post_tokens: 0,
        handover_saved: None,
        compacted_at: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tally_is_dropped_from_the_label_only() {
        let mut s = sample("a", 1, 1);
        s.title = Some("데모 세션 (2/3)".into());
        assert_eq!(s.label(), "데모 세션");
        assert_eq!(s.title.as_deref(), Some("데모 세션 (2/3)"));
        s.title = Some("(1/3)".into());
        assert_eq!(s.label(), "(1/3)");
    }

    #[test]
    fn clear_at_the_limit_or_a_swollen_summary() {
        let mut s = sample("a", 1, 1);
        s.compactions = 3;
        s.last_post_tokens = 30_000;
        assert!(!s.needs_clear(4));
        assert!(s.needs_clear(3));
        assert!(s.needs_clear(2));
        s.last_post_tokens = 50_000;
        assert!(s.needs_clear(9));
        s.compactions = 0;
        assert!(!s.needs_clear(1), "no compaction, nothing to suggest");
    }

    /// Only an automatic compaction inside the believable range moves the point.
    #[test]
    fn compaction_point_is_measured_when_believable() {
        let mut s = sample("a", 900_000, 1_000_000);
        assert_eq!(s.measured_compaction_point(), None);
        s.compacted_at = 832_917;
        assert_eq!(s.compaction_tokens(80), 832_917);
        s.compacted_at = 100_000;
        assert_eq!(s.measured_compaction_point(), None);
        assert_eq!(s.compaction_tokens(80), 784_000);
    }

    /// The app must warn before Claude Code compacts, at every threshold the slider allows.
    #[test]
    fn arms_before_claude_code_compacts() {
        for (window, pct) in [(1_000_000, 80), (1_000_000, 85), (200_000, 85), (100_000, 85)] {
            let s = sample("a", 0, window);
            assert!(s.arm_tokens(pct) < s.compaction_tokens(pct), "{window} {pct}");
            assert!(s.arm_tokens(pct) > 0);
        }
    }
}
