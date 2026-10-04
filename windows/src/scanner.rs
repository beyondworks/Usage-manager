//! Incremental reader of everything the app shows.
//!
//! A full scan (launch, then every ten minutes) walks the session folders once to find
//! recently written logs. Between full scans only the paths the file watcher reports are
//! re-read, and a log whose size has not changed is never parsed again.

use crate::desktop::Desktop;
use crate::models::{Limit, Session, Tool};
use crate::paths;
use crate::timeutil::{now_secs, secs};
use crate::transcript::{self, Compactions};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct Snapshot {
    pub tools: Vec<Tool>,
    pub limits: HashMap<Tool, Limit>,
    pub sessions: Vec<Session>,
}

pub struct Scanner {
    pub home: PathBuf,
    pub window_minutes: f64,
    pub default_window: i64,
    recent: HashMap<PathBuf, f64>,
    parsed: HashMap<PathBuf, (u64, Option<Session>)>,
    human: HashMap<PathBuf, (u64, bool)>,
    compacted: HashMap<PathBuf, Compactions>,
    desktop: Desktop,
    claude_weekly: Option<Limit>,
    codex_weekly: Option<Limit>,
    last_full: f64,
}

fn newest(a: Option<Limit>, b: Option<Limit>) -> Option<Limit> {
    match (a, b) {
        (None, b) => b,
        (a, None) => a,
        (Some(a), Some(b)) => Some(if b.updated_at >= a.updated_at { b } else { a }),
    }
}

/// The last folder of a working directory, written with either separator.
pub fn project_label(cwd: &str) -> String {
    let base = cwd.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or("");
    if !base.is_empty() {
        base.to_string()
    } else if cwd.is_empty() {
        "—".into()
    } else {
        cwd.to_string()
    }
}

/// The weekly limit Claude Code hands its statusLine — the only local place it does.
pub fn claude_weekly_from_snapshot(path: &Path) -> Option<Limit> {
    let obj: Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let week = &obj["rate_limits"]["seven_day"];
    let used = week["used_percentage"].as_f64()?;
    Some(Limit { percent: used, resets_at: week["resets_at"].as_f64(), updated_at: secs(paths::mtime(path)?) })
}

/// Did the gate let this session's last compaction through *because* the handover had
/// been written? None when there is no record either way.
pub fn handover_saved(sid: &str) -> Option<bool> {
    let s = std::fs::read_to_string(paths::root().join("lastpass").join(sid)).ok()?;
    Some(s.trim() == "handover")
}

/// The real window from the statusLine snapshot; a 1M model, or a session already past
/// 200k; otherwise `fallback`.
pub fn window_size(sid: &str, model: &str, ctx: i64, fallback: i64) -> i64 {
    if let Ok(d) = std::fs::read(paths::claude_status().join(format!("{sid}.json"))) {
        if let Ok(obj) = serde_json::from_slice::<Value>(&d) {
            let n = transcript::int(obj["context_window"].get("context_window_size"));
            if n > 0 {
                return n;
            }
        }
    }
    if model.contains("[1m]") || ctx > 200_000 {
        return 1_000_000;
    }
    fallback
}

impl Scanner {
    pub fn new(home: PathBuf) -> Self {
        Scanner {
            desktop: Desktop::new(&home),
            home,
            window_minutes: 15.0,
            default_window: 1_000_000,
            recent: HashMap::new(),
            parsed: HashMap::new(),
            human: HashMap::new(),
            compacted: HashMap::new(),
            claude_weekly: None,
            codex_weekly: None,
            last_full: 0.0,
        }
    }

    fn claude_root(&self) -> PathBuf {
        self.home.join(".claude").join("projects")
    }

    /// Folders the file watcher should report on.
    pub fn watch_paths(&self) -> Vec<PathBuf> {
        let mut v = vec![self.claude_root(), crate::codex::root(&self.home), paths::claude_status()];
        v.extend(crate::desktop::directories(&self.home));
        v
    }

    /// `changed` empty → rescan what is known (and a full scan when due).
    pub fn scan(&mut self, changed: &[PathBuf]) -> Snapshot {
        let now = now_secs();
        if now - self.last_full > 600.0 {
            self.full_scan();
        }
        self.desktop.refresh();
        for p in changed {
            self.touch(p);
        }
        let cutoff = now - self.window_minutes * 60.0;
        let mut sessions = Vec::new();
        let paths_now: Vec<PathBuf> = self.recent.keys().cloned().collect();
        for path in paths_now {
            let meta = std::fs::metadata(&path).ok();
            let mtime = meta.as_ref().and_then(|m| m.modified().ok()).map(secs);
            let Some(mtime) = mtime.filter(|m| *m >= cutoff) else {
                self.recent.remove(&path);
                self.parsed.remove(&path);
                continue;
            };
            self.recent.insert(path.clone(), mtime);
            let size = meta.map(|m| m.len()).unwrap_or(0);
            let s = match self.parsed.get(&path) {
                Some((sz, s)) if *sz == size => s.clone(),
                _ => {
                    let s = self.read(&path);
                    self.parsed.insert(path.clone(), (size, s.clone()));
                    s
                }
            };
            if let Some(mut s) = s {
                s.mtime = mtime;
                sessions.push(s);
            }
        }
        let recent = &self.recent;
        self.human.retain(|k, _| recent.contains_key(k));
        self.compacted.retain(|k, _| recent.contains_key(k));
        let mut limits = HashMap::new();
        if let Some(l) = &self.claude_weekly {
            limits.insert(Tool::ClaudeCode, l.clone());
        }
        if let Some(l) = &self.codex_weekly {
            limits.insert(Tool::Codex, l.clone());
        }
        let tools = [(Tool::ClaudeCode, ".claude"), (Tool::Codex, ".codex")]
            .into_iter()
            .filter(|(_, d)| self.home.join(d).exists())
            .map(|(t, _)| t)
            .collect();
        sessions.sort_by(|a, b| b.used_percent().total_cmp(&a.used_percent()));
        Snapshot { tools, limits, sessions }
    }

    fn full_scan(&mut self) {
        let now = now_secs();
        self.last_full = now;
        let cutoff = now - self.window_minutes * 60.0;
        if let Ok(dirs) = std::fs::read_dir(self.claude_root()) {
            for d in dirs.flatten() {
                let Ok(files) = std::fs::read_dir(d.path()) else { continue };
                for f in files.flatten() {
                    let p = f.path();
                    if p.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                        continue;
                    }
                    if let Some(m) = paths::mtime(&p).map(secs).filter(|m| *m >= cutoff) {
                        self.recent.insert(p, m);
                    }
                }
            }
        }
        for p in crate::codex::recent_files(&self.home, 2) {
            if let Some(m) = paths::mtime(&p).map(secs).filter(|m| *m >= cutoff) {
                self.recent.insert(p, m);
            }
        }
        self.codex_weekly = newest(self.codex_weekly.take(), crate::codex::newest_weekly(&self.home));
        self.claude_weekly = newest(self.claude_weekly.take(), self.claude_weekly_from_snapshots());
    }

    /// A path the watcher reported as written.
    fn touch(&mut self, p: &Path) {
        let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("");
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if p.parent() == Some(paths::claude_status().as_path()) && ext == "json" {
            self.claude_weekly = newest(self.claude_weekly.take(), claude_weekly_from_snapshot(p));
        } else if let Ok(rel) = p.strip_prefix(self.claude_root()) {
            // `<project>/<session>.jsonl` only: subagent transcripts sit deeper.
            if ext == "jsonl" && rel.components().count() == 2 {
                if let Some(m) = paths::mtime(p) {
                    self.recent.insert(p.to_path_buf(), secs(m));
                }
            }
        } else if p.starts_with(crate::codex::root(&self.home)) && name.starts_with("rollout-") {
            if let Some(m) = paths::mtime(p) {
                self.recent.insert(p.to_path_buf(), secs(m));
            }
            self.codex_weekly = newest(self.codex_weekly.take(), crate::codex::weekly(p));
        }
    }

    /// Newest snapshot carrying `seven_day`; ones older than eight days are removed
    /// (one file per Claude session would otherwise pile up forever).
    fn claude_weekly_from_snapshots(&self) -> Option<Limit> {
        let mut files: Vec<(PathBuf, f64)> = Vec::new();
        let now = now_secs();
        for e in std::fs::read_dir(paths::claude_status()).into_iter().flatten().flatten() {
            let p = e.path();
            if p.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let Some(m) = paths::mtime(&p).map(secs) else { continue };
            if now - m > 8.0 * 86400.0 {
                let _ = std::fs::remove_file(&p);
                continue;
            }
            files.push((p, m));
        }
        files.sort_by(|a, b| b.1.total_cmp(&a.1));
        files.iter().find_map(|(p, _)| claude_weekly_from_snapshot(p))
    }

    fn read(&mut self, path: &Path) -> Option<Session> {
        if path.starts_with(crate::codex::root(&self.home)) {
            // Codex threads are read for the weekly quota only, and not listed: nothing is
            // written into their prompts and their names cannot be recovered.
            if !crate::codex::is_subagent(path) {
                self.codex_weekly = newest(self.codex_weekly.take(), crate::codex::weekly(path));
            }
            return None;
        }
        let t = transcript::claude_tail_deep(path, None)?;
        let sid = path.file_stem()?.to_str()?.to_string();
        let c = transcript::scan_compactions(path, self.compacted.get(path).copied().unwrap_or_default());
        self.compacted.insert(path.to_path_buf(), c);
        if !self.is_human_attended(t.entrypoint.as_deref(), path) {
            return None;
        }
        let mut title = t.title.clone();
        let mut source = if t.title.is_none() { "folder" } else { "custom-title" }.to_string();
        if t.entrypoint.as_deref() == Some("claude-desktop") && self.desktop.usable() {
            let m = self.desktop.meta(&sid).filter(|m| !m.archived)?;
            if !m.title.is_empty() {
                title = Some(m.title.clone());
                source = "meta".into();
            }
        }
        Some(Session {
            tool: Tool::ClaudeCode,
            window_size: window_size(&sid, &t.model, t.ctx_tokens, self.default_window),
            handover_saved: handover_saved(&sid),
            session_id: sid,
            project: project_label(&t.cwd),
            title,
            model: t.model,
            ctx_tokens: t.ctx_tokens,
            mtime: 0.0,
            compactions: c.count,
            title_source: source,
            cache_ttl: t.cache_ttl,
            last_reply_at: t.replied_at,
            last_post_tokens: c.post,
            compacted_at: c.auto_pre,
        })
    }

    /// Only sessions a person watches belong in the list. `sdk-*` is `claude -p`;
    /// `claude-desktop` is written for agents it spawns too, so those need the
    /// typed-prompt marker.
    fn is_human_attended(&mut self, entrypoint: Option<&str>, path: &Path) -> bool {
        match entrypoint {
            None => true,
            Some(e) if e.starts_with("sdk") => false,
            Some("claude-desktop") => {
                let st = self.human.get(path).copied().unwrap_or((0, false));
                if st.1 {
                    return true;
                }
                let st = transcript::scan_human(path, st.0);
                self.human.insert(path.to_path_buf(), st);
                st.1
            }
            _ => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Home;

    fn desk_session(h: &Home, sid: &str, tokens: i64) {
        let d = h.dir.path().join(".claude").join("projects").join("-tmp-desk");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join(format!("{sid}.jsonl")),
            format!(
                "{{\"type\":\"assistant\",\"entrypoint\":\"claude-desktop\",\"cwd\":\"C:\\\\tmp\\\\desk\",\"message\":{{\"model\":\"claude-opus-5\",\"usage\":{{\"input_tokens\":0,\"cache_read_input_tokens\":{tokens}}}}}}}\n\
                 {{\"type\":\"user\",\"message\":{{\"content\":[{{\"type\":\"text\",\"text\":\"x\"}}]}},\"origin\":{{\"kind\":\"human\"}}}}\n"
            ),
        )
        .unwrap();
    }
    fn meta_dir(h: &Home) -> PathBuf {
        h.dir.path().join("AppData").join("Roaming").join("Claude Second").join("claude-code-sessions").join("acct").join("org")
    }
    fn desk_meta(h: &Home, file: &str, sid: &str, title: &str, archived: bool) {
        std::fs::create_dir_all(meta_dir(h)).unwrap();
        std::fs::write(
            meta_dir(h).join(format!("local_{file}.json")),
            format!(r#"{{"cliSessionId":"{sid}","title":"{title}","isArchived":{archived},"lastActivityAt":{}000}}"#, now_secs() as i64),
        )
        .unwrap();
    }

    /// Desktop sessions take their name, and their right to be listed, from the app's
    /// own metadata; with no metadata at all nothing is hidden.
    #[test]
    fn desktop_metadata_names_and_filters_sessions() {
        let h = Home::new();
        let (new, old, gone) = ("aaaaaaaa-1111", "bbbbbbbb-1111", "cccccccc-1111");
        desk_session(&h, new, 300_000);
        desk_session(&h, old, 400_000);
        desk_session(&h, gone, 500_000);
        desk_meta(&h, "one", new, "작업 중인 세션", false);
        desk_meta(&h, "two", old, "보관된 세션", true);
        let snap = Scanner::new(paths::home()).scan(&[]);
        let ids: Vec<_> = snap.sessions.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, vec![new], "archived or replaced transcripts were listed");
        assert_eq!(snap.sessions[0].label(), "작업 중인 세션");
        assert_eq!(snap.sessions[0].title_source, "meta");

        std::fs::remove_dir_all(h.dir.path().join("AppData")).unwrap();
        let snap = Scanner::new(paths::home()).scan(&[]);
        assert_eq!(snap.sessions.len(), 3, "no metadata: everything stays listed");
        assert!(snap.sessions.iter().all(|s| s.title_source == "folder" && s.project == "desk"));
    }

    /// Codex threads feed the weekly row and are not listed; headless runs are not listed.
    #[test]
    fn codex_threads_and_headless_runs_are_not_listed() {
        let h = Home::new();
        let d = crate::codex::root(&h.dir.path().to_path_buf()).join(chrono::Local::now().format("%Y/%m/%d").to_string());
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(
            d.join("rollout-x.jsonl"),
            "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"x\",\"cwd\":\"C:\\\\tmp\"}}\n\
             {\"timestamp\":\"2026-10-01T00:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":950000},\"model_context_window\":1000000},\
             \"rate_limits\":{\"secondary\":{\"window_minutes\":10080,\"used_percent\":33}}}}\n",
        )
        .unwrap();
        let p = h.dir.path().join(".claude").join("projects").join("-p");
        std::fs::create_dir_all(&p).unwrap();
        std::fs::write(p.join("headless.jsonl"), crate::transcript::tests::usage_line(500_000, "2026-10-01T00:00:00Z").replace("\"cli\"", "\"sdk-cli\"") + "\n").unwrap();
        let snap = Scanner::new(paths::home()).scan(&[]);
        assert!(snap.sessions.is_empty());
        assert_eq!(snap.limits[&Tool::Codex].percent, 33.0);
    }

    #[test]
    fn the_gates_handover_record_is_read() {
        let _h = Home::new();
        assert_eq!(handover_saved("s1"), None);
        std::fs::create_dir_all(paths::root().join("lastpass")).unwrap();
        std::fs::write(paths::root().join("lastpass").join("s1"), "handover").unwrap();
        assert_eq!(handover_saved("s1"), Some(true));
        std::fs::write(paths::root().join("lastpass").join("s1"), "other").unwrap();
        assert_eq!(handover_saved("s1"), Some(false));
        assert_eq!(project_label(r"C:\Users\me\work\shop"), "shop");
        assert_eq!(project_label("/tmp/demo/"), "demo");
    }
}
