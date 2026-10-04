//! What the Claude desktop app knows about its own sessions: the name the user sees,
//! and whether a transcript is still that session's own (clearing starts a new one and
//! repoints the metadata). Read-only, four fields, lifted from the bytes because the
//! files are large and there are hundreds.
//!
//! On macOS these live under `~/Library/Application Support/<profile>/`; the Windows
//! app keeps its profile under `%APPDATA%\<profile>\`.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq)]
pub struct Meta {
    pub title: String,
    pub archived: bool,
    pub active_at: f64,
}

pub fn directories(home: &Path) -> Vec<PathBuf> {
    // The disposable home of the self-check carries its own AppData.
    let appdata = match (std::env::var("USAGE_MANAGER_HOME"), std::env::var("APPDATA")) {
        (Err(_), Ok(a)) if !a.is_empty() => PathBuf::from(a),
        _ => home.join("AppData").join("Roaming"),
    };
    ["Claude Second", "Claude"].iter().map(|p| appdata.join(p).join("claude-code-sessions")).collect()
}

#[derive(Default)]
pub struct Desktop {
    roots: Vec<PathBuf>,
    seen: HashMap<PathBuf, (f64, String, Meta)>,
    by_id: HashMap<String, Meta>,
    loaded: bool,
}

fn value<'a>(data: &'a [u8], key: &str) -> Option<&'a [u8]> {
    let needle = format!("\"{key}\":");
    let n = needle.as_bytes();
    data.windows(n.len()).position(|w| w == n).map(|i| &data[i + n.len()..])
}

fn text(data: &[u8], key: &str) -> Option<String> {
    let rest = value(data, key)?;
    if rest.first() != Some(&b'"') {
        return None;
    }
    let mut out = Vec::new();
    let mut escaped = false;
    for &b in &rest[1..] {
        if escaped {
            out.push(if b == b'n' { b'\n' } else { b });
            escaped = false;
            continue;
        }
        if b == b'\\' {
            escaped = true;
            continue;
        }
        if b == b'"' {
            break;
        }
        out.push(b);
    }
    Some(String::from_utf8_lossy(&out).into_owned())
}

fn flag(data: &[u8], key: &str) -> bool {
    value(data, key).map(|r| r.starts_with(b"true")).unwrap_or(false)
}

fn number(data: &[u8], key: &str) -> Option<f64> {
    let r = value(data, key)?;
    let digits: Vec<u8> = r.iter().take_while(|b| b.is_ascii_digit() || **b == b'.' || **b == b'-').copied().collect();
    String::from_utf8(digits).ok()?.parse().ok()
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(items) = std::fs::read_dir(dir) else { return };
    for e in items.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out);
        } else if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
            if name.starts_with("local_") && name.ends_with(".json") {
                out.push(p);
            }
        }
    }
}

impl Desktop {
    pub fn new(home: &Path) -> Self {
        Desktop { roots: directories(home), ..Default::default() }
    }

    pub fn meta(&self, sid: &str) -> Option<&Meta> {
        self.by_id.get(sid)
    }

    /// Until metadata has been found at all, a missing entry may simply be unreadable
    /// here and must not be read as "this session was replaced".
    pub fn usable(&self) -> bool {
        self.loaded && !self.by_id.is_empty()
    }

    pub fn refresh(&mut self) {
        let mut files = Vec::new();
        for r in &self.roots {
            walk(r, &mut files);
        }
        let current: HashSet<PathBuf> = files.iter().cloned().collect();
        for path in files {
            let m = crate::paths::mtime(&path).map(crate::timeutil::secs).unwrap_or(0.0);
            if self.seen.get(&path).map(|h| h.0 == m).unwrap_or(false) {
                continue;
            }
            let Ok(data) = std::fs::read(&path) else { continue };
            let Some(sid) = text(&data, "cliSessionId").filter(|s| !s.is_empty()) else { continue };
            let meta = Meta {
                title: text(&data, "title").unwrap_or_default(),
                archived: flag(&data, "isArchived"),
                active_at: number(&data, "lastActivityAt").unwrap_or(0.0) / 1000.0,
            };
            self.seen.insert(path, (m, sid, meta));
        }
        self.seen.retain(|k, _| current.contains(k));
        // One entry per session, from the profile that saw it most recently.
        let mut merged: HashMap<String, Meta> = HashMap::new();
        for (_, (_, sid, meta)) in &self.seen {
            if merged.get(sid).map(|p| p.active_at >= meta.active_at).unwrap_or(false) {
                continue;
            }
            merged.insert(sid.clone(), meta.clone());
        }
        self.by_id = merged;
        self.loaded = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fields_are_lifted_from_the_bytes() {
        let d = r#"{"cliSessionId":"abc","title":"작업 \"중\"","isArchived":true,"lastActivityAt":1700000000000,"tools":[]}"#.as_bytes();
        assert_eq!(text(d, "cliSessionId").as_deref(), Some("abc"));
        assert_eq!(text(d, "title").as_deref(), Some("작업 \"중\""));
        assert!(flag(d, "isArchived"));
        assert_eq!(number(d, "lastActivityAt"), Some(1_700_000_000_000.0));
    }
}
