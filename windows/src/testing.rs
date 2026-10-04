//! A disposable home for tests. Paths are read from the environment, which is global
//! to the process, so one test at a time holds it.

use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};

static LOCK: Mutex<()> = Mutex::new(());

pub struct Home {
    pub dir: tempfile::TempDir,
    _guard: MutexGuard<'static, ()>,
}

impl Home {
    pub fn new() -> Self {
        let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_MANAGER_HOME", dir.path());
        std::env::set_var("USAGE_MANAGER_OFFLINE", "1");
        for d in [".claude", ".usage-manager/alerts", ".usage-manager/pressed", ".usage-manager/holds"] {
            std::fs::create_dir_all(dir.path().join(d)).unwrap();
        }
        Home { dir, _guard: guard }
    }
    pub fn transcript(&self) -> PathBuf {
        self.dir.path().join("gate-transcript.jsonl")
    }
}
