//! Single source for every path the app reads or writes.
//!
//! Claude Code on Windows keeps its files under `%USERPROFILE%` (`os.homedir()`), so
//! that is home. `USAGE_MANAGER_HOME` overrides it so a disposable folder can drive the
//! whole app — the self-check never touches the real one.

use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    for key in ["USAGE_MANAGER_HOME", "USERPROFILE", "HOME"] {
        if let Ok(v) = std::env::var(key) {
            if !v.trim().is_empty() {
                return PathBuf::from(v);
            }
        }
    }
    PathBuf::from(".")
}

/// App-owned state. Same layout as the macOS app, so the instructions handed to the
/// agent (`touch ~/.usage-manager/pressed/<id>`) read the same in Git Bash.
pub fn root() -> PathBuf {
    home().join(".usage-manager")
}
pub fn claude_status() -> PathBuf {
    root().join("claude-status")
}
pub fn alerts() -> PathBuf {
    root().join("alerts")
}

/// Set by the self-check so a disposable home exercises only the local file readers.
pub fn offline() -> bool {
    std::env::var("USAGE_MANAGER_OFFLINE").map(|v| v == "1").unwrap_or(false)
}

pub fn mtime(p: &Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// A session id is used as a file name, so only ids that cannot climb out of the
/// folder are accepted.
pub fn safe_id(sid: &str) -> bool {
    !sid.is_empty() && sid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Append one stamped line, starting over past 64 KB.
pub fn append_log(name: &str, text: &str) {
    use std::io::Write;
    let path = root().join(name);
    if std::fs::metadata(&path).map(|m| m.len() > 64_000).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    let _ = std::fs::create_dir_all(root());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{} {}", crate::timeutil::iso_now(), text);
    }
}
