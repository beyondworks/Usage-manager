//! Wiring between Usage Manager and Claude Code.
//!
//! - statusLine → `--status-line` snapshots its input (the only local place Claude Code
//!   exposes `rate_limits`), then runs the statusLine that was there before.
//! - UserPromptSubmit / PostToolUse → `--prompt-hook` hands the agent a pending notice
//!   for its session, once.
//! - PreCompact(auto) → `--gate` holds the compaction until the handover is written.
//!
//! On macOS these are shell scripts; Claude Code on Windows runs hook commands through
//! Git Bash, so the commands call this executable directly and need nothing else. Every
//! edit is reversible: the previous statusLine and compaction point are kept, and a
//! `.usage-manager.bak` copy is written before each change.

use crate::paths;
use serde_json::{json, Map, Value};
use std::io::Read;
use std::path::{Path, PathBuf};

const PROMPT_EVENTS: [&str; 2] = ["UserPromptSubmit", "PostToolUse"];
const COMPACT_KEY: &str = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE";

fn settings() -> PathBuf {
    paths::home().join(".claude").join("settings.json")
}
fn prev_status_line() -> PathBuf {
    paths::root().join("statusline.prev")
}
fn prev_compact_pct() -> PathBuf {
    paths::root().join("compactpct.prev")
}

/// The command Claude Code runs: the executable, quoted, forward slashes for Git Bash.
pub fn command(exe: &Path, flag: &str) -> String {
    format!("\"{}\" {flag}", exe.to_string_lossy().replace('\\', "/"))
}

/// Ours wherever the executable sits, so a moved install is replaced, not duplicated.
fn is_ours(cmd: &str, flag: &str) -> bool {
    cmd.contains("UsageManager") && cmd.trim_end().ends_with(flag)
}

fn group_is_ours(group: &Value, flag: &str) -> bool {
    group["hooks"].as_array().map(|hs| hs.iter().any(|h| is_ours(h["command"].as_str().unwrap_or(""), flag))).unwrap_or(false)
}

fn group_is(group: &Value, cmd: &str) -> bool {
    group["hooks"].as_array().map(|hs| hs.iter().any(|h| h["command"].as_str() == Some(cmd))).unwrap_or(false)
}

#[derive(Debug, Clone, Copy, PartialEq, Default, serde::Serialize)]
pub struct Status {
    pub claude: bool,
}

pub fn status(exe: &Path) -> Status {
    let Some(s) = read_json(&settings()) else { return Status::default() };
    let status_ok = s["statusLine"]["command"].as_str() == Some(&command(exe, "--status-line"));
    let prompt_ok = PROMPT_EVENTS.iter().all(|ev| {
        s["hooks"][ev].as_array().map(|l| l.iter().any(|g| group_is(g, &command(exe, "--prompt-hook")))).unwrap_or(false)
    });
    let gate_ok = s["hooks"]["PreCompact"].as_array().map(|l| l.iter().any(|g| group_is(g, &command(exe, "--gate")))).unwrap_or(false);
    Status { claude: status_ok && prompt_ok && gate_ok }
}

fn obj(v: &mut Value) -> &mut Map<String, Value> {
    if !v.is_object() {
        *v = json!({});
    }
    v.as_object_mut().unwrap()
}

/// Remove our groups from one event, dropping the event when nothing else is left.
/// Whether anything was removed.
fn remove_from(root: &mut Value, event: &str, flag: &str) -> bool {
    let Some(hooks) = root.get_mut("hooks").filter(|h| h.is_object()) else { return false };
    let Some(list) = hooks.get_mut(event).and_then(|l| l.as_array_mut()) else { return false };
    let n = list.len();
    list.retain(|g| !group_is_ours(g, flag));
    let removed = list.len() != n;
    if list.is_empty() {
        obj(hooks).remove(event);
    }
    removed
}

pub fn install(exe: &Path, compact_at: Option<i64>) -> Result<(), String> {
    for d in ["pressed", "holds", "claude-status"] {
        let _ = std::fs::create_dir_all(paths::root().join(d));
    }
    if !paths::home().join(".claude").exists() {
        return Ok(());
    }
    let path = settings();
    let mut s = if path.exists() { read_json(&path).ok_or_else(|| format!("{} 를 읽을 수 없어 바꾸지 않았습니다", path.display()))? } else { json!({}) };

    let current = s["statusLine"]["command"].as_str().unwrap_or("").to_string();
    if !is_ours(&current, "--status-line") {
        std::fs::write(prev_status_line(), &current).map_err(|e| e.to_string())?;
    }
    let mut line = s.get("statusLine").filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({"type": "command"}));
    obj(&mut line).insert("command".into(), json!(command(exe, "--status-line")));
    obj(&mut s).insert("statusLine".into(), line);

    for ev in PROMPT_EVENTS {
        remove_from(&mut s, ev, "--prompt-hook");
        let hooks = obj(&mut s).entry("hooks").or_insert_with(|| json!({}));
        let list = obj(hooks).entry(ev).or_insert_with(|| json!([]));
        if let Some(l) = list.as_array_mut() {
            l.push(json!({"hooks": [{"type": "command", "command": command(exe, "--prompt-hook"), "timeout": 5}]}));
        }
    }
    // The gate guards automatic compactions only; a manual /compact is never held.
    remove_from(&mut s, "PreCompact", "--gate");
    let hooks = obj(&mut s).entry("hooks").or_insert_with(|| json!({}));
    let list = obj(hooks).entry("PreCompact").or_insert_with(|| json!([]));
    if let Some(l) = list.as_array_mut() {
        l.push(json!({"matcher": "auto", "hooks": [{"type": "command", "command": command(exe, "--gate"), "timeout": 10}]}));
    }
    if let Some(pct) = compact_at {
        set_compact_percent(&mut s, pct);
    }
    write_json(&s, &path)
}

pub fn uninstall() -> Result<(), String> {
    let path = settings();
    let Some(mut s) = read_json(&path) else { return Ok(()) };
    let before = s.clone();
    if is_ours(s["statusLine"]["command"].as_str().unwrap_or(""), "--status-line") {
        let prev = std::fs::read_to_string(prev_status_line()).unwrap_or_default();
        if prev.is_empty() {
            obj(&mut s).remove("statusLine");
        } else {
            obj(&mut s["statusLine"]).insert("command".into(), json!(prev));
        }
    }
    let mut removed = false;
    for ev in PROMPT_EVENTS {
        removed |= remove_from(&mut s, ev, "--prompt-hook");
    }
    removed |= remove_from(&mut s, "PreCompact", "--gate");
    if removed && s["hooks"].as_object().map(|h| h.is_empty()).unwrap_or(false) {
        obj(&mut s).remove("hooks");
    }
    clear_compact_percent(&mut s);
    // Nothing of ours was there: leave the file exactly as it is, formatting included.
    if s == before {
        return Ok(());
    }
    write_json(&s, &path)
}

/// The auto-compaction point, as a share of the window. Whatever the user had before
/// the first install is recorded so uninstall restores it rather than deleting it.
fn set_compact_percent(s: &mut Value, pct: i64) {
    let env = obj(s).entry("env").or_insert_with(|| json!({}));
    if !prev_compact_pct().exists() {
        let _ = std::fs::write(prev_compact_pct(), env[COMPACT_KEY].as_str().unwrap_or(""));
    }
    obj(env).insert(COMPACT_KEY.into(), json!(pct.clamp(1, 100).to_string()));
}

fn clear_compact_percent(s: &mut Value) {
    if s["env"].get(COMPACT_KEY).is_none() {
        return;
    }
    let prev = std::fs::read_to_string(prev_compact_pct()).unwrap_or_default();
    let env = obj(&mut s["env"]);
    if prev.is_empty() {
        env.remove(COMPACT_KEY);
    } else {
        env.insert(COMPACT_KEY.into(), json!(prev));
    }
    let empty = env.is_empty();
    let _ = std::fs::remove_file(prev_compact_pct());
    if empty {
        obj(s).remove("env");
    }
}

/// The alerts switch, in a form the gate reads without the app running.
pub fn set_gate_enabled(on: bool) {
    let flag = paths::root().join("gate-off");
    if on {
        let _ = std::fs::remove_file(flag);
    } else {
        let _ = std::fs::create_dir_all(paths::root());
        let _ = std::fs::write(flag, b"");
        for e in std::fs::read_dir(paths::root().join("holds")).into_iter().flatten().flatten() {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

/// Queue a notice; the prompt hook hands it over on the session's next prompt or tool
/// call, then deletes it. Stored as a bare JSON string.
pub fn queue_notice(sid: &str, text: &str) {
    if !paths::safe_id(sid) {
        return;
    }
    let _ = std::fs::create_dir_all(paths::alerts());
    let _ = write_atomic(&paths::alerts().join(format!("{sid}.txt")), serde_json::to_string(text).unwrap_or_default().as_bytes());
}

// ---- What the hooks do when Claude Code calls them -----------------------------------

pub fn read_stdin() -> Vec<u8> {
    let mut v = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut v);
    v
}

/// `--prompt-hook`: the pending notice for this session, once, as additionalContext.
pub fn prompt_hook(input: &[u8]) -> Option<String> {
    let v: Value = serde_json::from_slice(input).ok()?;
    let sid = v["session_id"].as_str()?;
    // A subagent's hooks carry its parent's id; the notice is the parent's to receive.
    if v.get("agent_id").is_some() || !paths::safe_id(sid) {
        return None;
    }
    let ev = v["hook_event_name"].as_str().filter(|e| !e.is_empty()).unwrap_or("UserPromptSubmit");
    let f = paths::alerts().join(format!("{sid}.txt"));
    let text = std::fs::read_to_string(&f).ok()?;
    let context: Value = serde_json::from_str(&text).unwrap_or(Value::String(text));
    let _ = std::fs::remove_file(&f);
    // The hold budget starts here: the agent cannot act on a notice it had not been given.
    if let Some(mut h) = crate::gate::state(sid) {
        h.first = crate::timeutil::now_secs();
        crate::gate::write_state(sid, h);
    }
    Some(json!({"hookSpecificOutput": {"hookEventName": ev, "additionalContext": context}}).to_string())
}

/// `--status-line`: keep the snapshot, then print what the previous statusLine prints.
pub fn status_line(input: &[u8]) -> String {
    if let Ok(v) = serde_json::from_slice::<Value>(input) {
        if let Some(sid) = v["session_id"].as_str().filter(|s| paths::safe_id(s)) {
            let _ = std::fs::create_dir_all(paths::claude_status());
            let _ = write_atomic(&paths::claude_status().join(format!("{sid}.json")), input);
        }
    }
    let prev = std::fs::read_to_string(prev_status_line()).unwrap_or_default();
    if prev.trim().is_empty() {
        return String::new();
    }
    run_shell(&prev, input).unwrap_or_default()
}

/// The shell Claude Code itself runs hooks with on Windows: Git Bash.
fn bash() -> Option<PathBuf> {
    if cfg!(not(windows)) {
        return Some("/bin/sh".into());
    }
    let mut c: Vec<PathBuf> = std::env::var("CLAUDE_CODE_GIT_BASH_PATH").ok().map(PathBuf::from).into_iter().collect();
    c.push(r"C:\Program Files\Git\bin\bash.exe".into());
    c.push(r"C:\Program Files (x86)\Git\bin\bash.exe".into());
    c.into_iter().find(|p| p.exists())
}

fn run_shell(cmd: &str, input: &[u8]) -> Option<String> {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut c = Command::new(bash()?);
    c.arg("-c").arg(cmd).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = c.spawn().ok()?;
    let _ = child.stdin.take()?.write_all(input);
    let out = child.wait_with_output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

// ---- Files ---------------------------------------------------------------------------

pub fn read_json(path: &Path) -> Option<Value> {
    let d = std::fs::read(path).ok()?;
    serde_json::from_slice::<Value>(&d).ok().filter(|v| v.is_object())
}

fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("usage-manager.tmp");
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)
}

/// Back up, then write. A file that exists but does not parse is never overwritten.
fn write_json(v: &Value, path: &Path) -> Result<(), String> {
    if path.exists() {
        if read_json(path).is_none() {
            return Err(format!("{} 를 읽을 수 없어 바꾸지 않았습니다", path.display()));
        }
        let bak = PathBuf::from(format!("{}.usage-manager.bak", path.display()));
        std::fs::copy(path, bak).map_err(|e| e.to_string())?;
    }
    let text = serde_json::to_string_pretty(v).map_err(|e| e.to_string())?;
    write_atomic(path, text.as_bytes()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Home;

    fn exe(h: &Home) -> PathBuf {
        h.dir.path().join("Programs").join("Usage Manager").join("UsageManager.exe")
    }
    fn settings_text() -> String {
        std::fs::read_to_string(settings()).unwrap()
    }
    fn seed() {
        std::fs::write(
            settings(),
            r#"{"statusLine":{"type":"command","command":"cat >/dev/null; echo PREV-STATUS"},
                "env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"72","KEEP_ME":"1"},
                "hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}"#,
        )
        .unwrap();
    }

    #[test]
    fn install_keeps_the_users_own_and_uninstall_restores_it() {
        let h = Home::new();
        seed();
        install(&exe(&h), Some(85)).unwrap();
        assert!(status(&exe(&h)).claude);
        let t = settings_text();
        assert!(t.contains("echo user-hook"), "user hook dropped");
        assert!(t.contains(r#"Usage Manager/UsageManager.exe\" --gate"#), "gate command not quoted with forward slashes: {t}");
        install(&exe(&h), Some(85)).unwrap();
        assert_eq!(settings_text().matches("--prompt-hook").count(), 2, "one hook per event, no duplicates");
        let s = read_json(&settings()).unwrap();
        assert_eq!(s["env"][COMPACT_KEY], "85");

        // moved install: replaced, not added beside the old one
        let moved = h.dir.path().join("elsewhere").join("UsageManager.exe");
        install(&moved, Some(85)).unwrap();
        assert_eq!(settings_text().matches("--prompt-hook").count(), 2);
        assert!(status(&moved).claude && !status(&exe(&h)).claude);

        uninstall().unwrap();
        let s = read_json(&settings()).unwrap();
        assert_eq!(s["statusLine"]["command"], "cat >/dev/null; echo PREV-STATUS", "statusLine not restored");
        assert_eq!(s["env"][COMPACT_KEY], "72", "the user's compaction point not restored");
        assert_eq!(s["env"]["KEEP_ME"], "1");
        let t = settings_text();
        assert!(!t.contains("UsageManager") && t.contains("echo user-hook"));
        assert!(!status(&moved).claude);
    }

    /// The uninstaller runs this on every machine; where we never installed, the user's
    /// file must not be rewritten or backed up.
    #[test]
    fn uninstall_leaves_a_file_without_our_hooks_untouched() {
        let _h = Home::new();
        let original = "{\n    \"model\": \"opus\",\n  \"hooks\": {}\n}";
        std::fs::write(settings(), original).unwrap();
        uninstall().unwrap();
        assert_eq!(std::fs::read_to_string(settings()).unwrap(), original);
        assert!(!PathBuf::from(format!("{}.usage-manager.bak", settings().display())).exists());
    }

    #[test]
    fn an_unreadable_settings_file_is_left_alone() {
        let _h = Home::new();
        std::fs::write(settings(), "{ not json").unwrap();
        assert!(install(Path::new("C:/x/UsageManager.exe"), Some(80)).is_err());
        assert_eq!(std::fs::read_to_string(settings()).unwrap(), "{ not json");
    }

    #[test]
    fn notice_is_delivered_once_on_either_event() {
        let _h = Home::new();
        let sid = "11111111-2222-3333-4444-555555555555";
        queue_notice(sid, "컨텍스트 90% — SESSION_HANDOVER 갱신 후 마커");
        let out = prompt_hook(format!(r#"{{"session_id":"{sid}","hook_event_name":"PostToolUse"}}"#).as_bytes()).unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
        assert!(v["hookSpecificOutput"]["additionalContext"].as_str().unwrap().contains("SESSION_HANDOVER"));
        assert!(prompt_hook(format!(r#"{{"session_id":"{sid}","hook_event_name":"PostToolUse"}}"#).as_bytes()).is_none(), "delivered twice");
        queue_notice(sid, "두 번째");
        assert!(prompt_hook(format!(r#"{{"session_id":"{sid}","hook_event_name":"UserPromptSubmit"}}"#).as_bytes()).unwrap().contains("\"UserPromptSubmit\""));
        queue_notice(sid, "세 번째");
        assert!(prompt_hook(br#"{"session_id":"../x","hook_event_name":"PostToolUse"}"#).is_none(), "unsafe id accepted");
        // a subagent leaves the parent's notice where it is
        assert!(prompt_hook(format!(r#"{{"session_id":"{sid}","agent_id":"a","hook_event_name":"PostToolUse"}}"#).as_bytes()).is_none());
        assert!(paths::alerts().join(format!("{sid}.txt")).exists());
    }

    /// The budget runs from the moment the notice reaches the agent.
    #[test]
    fn delivering_the_notice_restarts_the_hold_budget() {
        let _h = Home::new();
        let sid = "33333333-cccc-dddd-eeee-ffffffffffff";
        crate::gate::write_state(sid, crate::gate::Held { n: 1, first: crate::timeutil::now_secs() - 540.0, ctx: 900_000 });
        queue_notice(sid, "SESSION_HANDOVER");
        prompt_hook(format!(r#"{{"session_id":"{sid}","hook_event_name":"PostToolUse"}}"#).as_bytes()).unwrap();
        assert!(crate::timeutil::now_secs() - crate::gate::state(sid).unwrap().first < 60.0);
    }

    #[test]
    fn status_line_snapshots_and_chains_the_previous_one() {
        let _h = Home::new();
        std::fs::write(prev_status_line(), "cat >/dev/null; echo PREV-STATUS").unwrap();
        let sid = "11111111-2222-3333-4444-555555555555";
        let input = format!(r#"{{"session_id":"{sid}","rate_limits":{{"seven_day":{{"used_percentage":42}}}}}}"#);
        assert_eq!(status_line(input.as_bytes()).trim(), "PREV-STATUS");
        let snap = paths::claude_status().join(format!("{sid}.json"));
        assert_eq!(crate::scanner::claude_weekly_from_snapshot(&snap).unwrap().percent, 42.0);
    }
}
