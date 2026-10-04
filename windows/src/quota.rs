//! Live subscription limits: Claude's own usage endpoint for the account Claude Code is
//! signed in with, and the local opencodex proxy for everything else.
//!
//! Read-only: the credential is never refreshed, written or logged — only a short
//! fingerprint of it, so a back-off can tell which token earned it.

use crate::models::Quota;
use crate::paths;
use crate::timeutil::now_secs;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::Duration;

static DIAGNOSIS: Mutex<String> = Mutex::new(String::new());
static USER_AGENT: Mutex<Option<String>> = Mutex::new(None);

pub fn diagnosis() -> String {
    let d = DIAGNOSIS.lock().unwrap().clone();
    if d.is_empty() {
        "not attempted".into()
    } else {
        d
    }
}
fn diagnose(s: impl Into<String>) {
    *DIAGNOSIS.lock().unwrap() = s.into();
}

/// A short, non-reversible stand-in for a token (FNV-1a), the same as the macOS app's.
pub fn fingerprint(token: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in token.bytes() {
        h = (h ^ b as u64).wrapping_mul(0x100000001b3);
    }
    format!("{h:x}")
}

// ---- Back-off, kept on disk so a restart does not fire into a limit still in force ----

fn backoff_file() -> std::path::PathBuf {
    paths::root().join("claude-backoff")
}

pub fn backoff() -> (f64, String) {
    let text = std::fs::read_to_string(backoff_file()).unwrap_or_default();
    let mut parts = text.split_whitespace();
    let until = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0.0);
    (until, parts.next().unwrap_or("").to_string())
}

fn set_backoff(until: f64, fp: &str) {
    if until <= now_secs() {
        let _ = std::fs::remove_file(backoff_file());
        return;
    }
    let _ = std::fs::create_dir_all(paths::root());
    let _ = std::fs::write(backoff_file(), format!("{} {fp}", until as i64));
}

// ---- The credential --------------------------------------------------------------------

/// Claude Code on Windows keeps its login in `~/.claude/.credentials.json`. An expired
/// token is worse than none: it is what answers 401 in a loop.
pub fn credential_token() -> Option<String> {
    let d = std::fs::read(paths::home().join(".claude").join(".credentials.json")).ok()?;
    let v: Value = serde_json::from_slice(&d).ok()?;
    let o = &v["claudeAiOauth"];
    let token = o["accessToken"].as_str().filter(|t| t.len() > 20)?;
    if let Some(ms) = o["expiresAt"].as_f64() {
        if ms / 1000.0 <= now_secs() {
            return None;
        }
    }
    Some(token.to_string())
}

/// The account Claude Code is signed in as, from its own settings file.
pub fn signed_in_account() -> Option<String> {
    let v: Value = serde_json::from_slice(&std::fs::read(paths::home().join(".claude.json")).ok()?).ok()?;
    v["oauthAccount"]["accountUuid"].as_str().map(String::from)
}

// ---- The last reading, kept with the account it belongs to ---------------------------

fn last_file() -> std::path::PathBuf {
    paths::root().join("claude-last.json")
}

fn remember(q: &Quota) {
    let Some(account) = signed_in_account() else { return };
    let v = json!({"account": account, "updatedAt": q.updated_at, "weekly": q.weekly, "fiveHour": q.five_hour, "resetsAt": q.resets_at});
    let _ = std::fs::create_dir_all(paths::root());
    let _ = std::fs::write(last_file(), v.to_string());
}

/// The last live reading, or None when it was read for another account than the one
/// signed in now — a snapshot of someone else's quota must never stand in for yours.
pub fn last_known() -> Option<Quota> {
    let v: Value = serde_json::from_slice(&std::fs::read(last_file()).ok()?).ok()?;
    if v["account"].as_str()? != signed_in_account()? {
        return None;
    }
    Some(Quota {
        provider: "anthropic".into(),
        weekly: v["weekly"].as_f64(),
        five_hour: v["fiveHour"].as_f64(),
        resets_at: v["resetsAt"].as_f64(),
        updated_at: v["updatedAt"].as_f64()?,
    })
}

// ---- The lookup --------------------------------------------------------------------------

enum Answer {
    Ok(Quota),
    Expired,
    Limited(f64, String),
    Other(String),
}

fn agent(timeout: u64) -> ureq::Agent {
    let mut b = ureq::AgentBuilder::new().timeout(Duration::from_secs(timeout));
    if let Ok(tls) = native_tls::TlsConnector::new() {
        b = b.tls_connector(Arc::new(tls));
    }
    b.build()
}

/// `claude-code/<installed version>`: the endpoint is stricter with callers it does
/// not recognise.
fn user_agent() -> String {
    let mut ua = USER_AGENT.lock().unwrap();
    if let Some(u) = ua.as_ref() {
        return u.clone();
    }
    let mut c = std::process::Command::new(if cfg!(windows) { "cmd" } else { "sh" });
    if cfg!(windows) {
        c.args(["/C", "claude --version"]);
    } else {
        c.args(["-c", "claude --version"]);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    let out = c.output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let version = regex::Regex::new(r"\d+\.\d+\.\d+").unwrap().find(&out).map(|m| m.as_str().to_string()).unwrap_or_else(|| "2.1.260".into());
    let u = format!("claude-code/{version}");
    *ua = Some(u.clone());
    u
}

fn ask(token: &str) -> Answer {
    let r = agent(8)
        .get("https://api.anthropic.com/api/oauth/usage")
        .set("Authorization", &format!("Bearer {token}"))
        .set("anthropic-beta", "oauth-2025-04-20")
        .set("User-Agent", &user_agent())
        .call();
    match r {
        Ok(resp) => {
            let Ok(v) = resp.into_json::<Value>() else { return Answer::Other("unreadable body".into()) };
            match parse(&v) {
                Some(q) => Answer::Ok(q),
                None => Answer::Other("unexpected fields".into()),
            }
        }
        Err(ureq::Error::Status(401 | 403, _)) => Answer::Expired,
        Err(ureq::Error::Status(429, resp)) => {
            // Honour the server's own wait; asking sooner is what keeps a 429 alive.
            let wait = resp.header("retry-after").and_then(|s| s.parse().ok()).unwrap_or(900.0);
            let body: String = resp.into_string().unwrap_or_default().chars().take(300).collect();
            Answer::Limited(wait, body.replace('\n', " "))
        }
        Err(ureq::Error::Status(code, _)) => Answer::Other(format!("http {code}")),
        Err(_) => Answer::Other("network error".into()),
    }
}

/// `five_hour` / `seven_day` carry `utilization` and `resets_at`.
pub fn parse(v: &Value) -> Option<Quota> {
    let window = |key: &str| -> Option<(f64, Option<f64>)> {
        let o = &v[key];
        let u = o["utilization"].as_f64()?;
        let reset = o["resets_at"].as_f64().or_else(|| crate::timeutil::iso(&o["resets_at"]));
        Some((u.clamp(0.0, 100.0), reset))
    };
    let (five, week) = (window("five_hour"), window("seven_day"));
    if five.is_none() && week.is_none() {
        return None;
    }
    Some(Quota {
        provider: "anthropic".into(),
        weekly: week.map(|w| w.0),
        five_hour: five.map(|f| f.0),
        resets_at: week.and_then(|w| w.1),
        updated_at: now_secs(),
    })
}

pub fn fetch_claude() -> Option<Quota> {
    if paths::offline() {
        diagnose("offline");
        return None;
    }
    let Some(token) = credential_token() else {
        diagnose("no live session token");
        return None;
    };
    let fp = fingerprint(&token);
    let (until, held) = backoff();
    if now_secs() < until && held == fp {
        diagnose(format!("rate-limited, retrying in {}s", (until - now_secs()) as i64));
        return None;
    }
    match ask(&token) {
        Answer::Ok(q) => {
            set_backoff(0.0, "");
            diagnose("ok");
            remember(&q);
            Some(q)
        }
        Answer::Expired => {
            // Asking again in five minutes is what turned this into a rate limit before.
            set_backoff(now_secs() + 600.0, &fp);
            diagnose("http 401 — waiting 600s for a fresh session");
            None
        }
        Answer::Limited(wait, why) => {
            set_backoff(now_secs() + wait, &fp);
            diagnose(format!("http 429, waiting {}s — {why}", wait as i64));
            None
        }
        Answer::Other(why) => {
            diagnose(why);
            None
        }
    }
}

/// How long Claude's own limit still has to run.
pub fn claude_wait() -> f64 {
    let (until, held) = backoff();
    let current = credential_token().map(|t| fingerprint(&t)).unwrap_or_default();
    if held == current {
        (until - now_secs()).max(0.0)
    } else {
        0.0
    }
}

// ---- The local opencodex proxy -----------------------------------------------------------

fn admin_token() -> Option<String> {
    if let Ok(e) = std::env::var("OPENCODEX_ADMIN_AUTH_TOKEN") {
        if !e.trim().is_empty() {
            return Some(e.trim().to_string());
        }
    }
    let t = std::fs::read_to_string(paths::home().join(".opencodex").join("admin-api-token")).ok()?;
    let t = t.trim().to_string();
    (!t.is_empty()).then_some(t)
}

/// The port from Codex's `openai_base_url` (…127.0.0.1:PORT…), default 10100.
fn proxy_port() -> u16 {
    let toml = std::fs::read_to_string(paths::home().join(".codex").join("config.toml")).unwrap_or_default();
    let re = regex::Regex::new(r"127\.0\.0\.1:(\d+)").unwrap();
    toml.lines()
        .filter(|l| l.contains("openai_base_url"))
        .find_map(|l| re.captures(l).and_then(|c| c[1].parse().ok()))
        .unwrap_or(10100)
}

/// One localhost GET of cached JSON. The proxy's own Anthropic account is not the one
/// Claude Code signs in with, so its `anthropic` row is ignored.
pub fn fetch_proxy() -> Vec<Quota> {
    if paths::offline() {
        return vec![];
    }
    let Some(token) = admin_token() else { return vec![] };
    let url = format!("http://127.0.0.1:{}/api/provider-quotas", proxy_port());
    let Ok(resp) = agent(3).get(&url).set("x-opencodex-api-key", &token).call() else { return vec![] };
    let Ok(v) = resp.into_json::<Value>() else { return vec![] };
    let ms = |v: &Value| v.as_f64().filter(|m| *m > 0.0).map(|m| m / 1000.0);
    let pct = |v: &Value| v.as_f64().map(|p| p.clamp(0.0, 100.0));
    v["reports"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let provider = r["provider"].as_str()?;
            if provider == "anthropic" {
                return None;
            }
            let q = &r["quota"];
            let (weekly, five) = (pct(&q["weeklyPercent"]), pct(&q["fiveHourPercent"]));
            if weekly.is_none() && five.is_none() {
                return None;
            }
            Some(Quota {
                provider: provider.into(),
                weekly,
                five_hour: five,
                resets_at: ms(&q["weeklyResetAt"]),
                updated_at: ms(&r["updatedAt"]).or_else(|| ms(&q["updatedAt"])).unwrap_or_else(now_secs),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Home;

    #[test]
    fn the_last_reading_belongs_to_its_account() {
        let h = Home::new();
        let claude_json = h.dir.path().join(".claude.json");
        std::fs::write(&claude_json, r#"{"oauthAccount":{"accountUuid":"acct-in-use"}}"#).unwrap();
        remember(&Quota { provider: "anthropic".into(), weekly: Some(16.0), five_hour: Some(3.0), resets_at: None, updated_at: now_secs() });
        assert_eq!(last_known().unwrap().weekly, Some(16.0));
        std::fs::write(&claude_json, r#"{"oauthAccount":{"accountUuid":"someone-else"}}"#).unwrap();
        assert!(last_known().is_none(), "the previous account's reading was shown");
    }

    #[test]
    fn an_expired_token_is_not_used() {
        let h = Home::new();
        let f = h.dir.path().join(".claude").join(".credentials.json");
        let later = (now_secs() + 3600.0) * 1000.0;
        std::fs::write(&f, format!(r#"{{"claudeAiOauth":{{"accessToken":"{}","expiresAt":{later}}}}}"#, "t".repeat(30))).unwrap();
        assert!(credential_token().is_some());
        std::fs::write(&f, format!(r#"{{"claudeAiOauth":{{"accessToken":"{}","expiresAt":1000}}}}"#, "t".repeat(30))).unwrap();
        assert!(credential_token().is_none());
    }

    #[test]
    fn usage_fields_are_read() {
        let q = parse(&serde_json::json!({"five_hour":{"utilization":21.0,"resets_at":"2026-10-05T03:59:59Z"},
                                          "seven_day":{"utilization":5,"resets_at":"2026-10-05T03:59:59+00:00"}})).unwrap();
        assert_eq!((q.weekly, q.five_hour), (Some(5.0), Some(21.0)));
        assert!(q.resets_at.is_some());
        assert_eq!(fingerprint("abc"), "e71fa2190541574b");
    }
}
