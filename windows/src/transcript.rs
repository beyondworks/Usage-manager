//! Reading a Claude Code transcript: its current size, and the compactions it records.
//! Shared by the scanner and the PreCompact gate, which need the same facts.

use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// The last `bytes` of a file (the whole file when smaller).
pub fn read_tail(path: &Path, bytes: u64) -> Option<Vec<u8>> {
    let mut f = std::fs::File::open(path).ok()?;
    let size = f.seek(SeekFrom::End(0)).ok()?;
    f.seek(SeekFrom::Start(size.saturating_sub(bytes))).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    (!buf.is_empty()).then_some(buf)
}

pub fn int(v: Option<&Value>) -> i64 {
    v.and_then(|v| v.as_f64()).map(|f| f as i64).unwrap_or(0)
}

pub struct Tail {
    pub ctx_tokens: i64,
    pub model: String,
    pub cwd: String,
    pub title: Option<String>,
    pub entrypoint: Option<String>,
    /// 3600 or 300, from the kind of cache write the last reply reported; 0 for none.
    pub cache_ttl: f64,
    pub replied_at: Option<f64>,
    /// Characters of tool-result text queued since that usage — what the next request
    /// carries on top of it. Parallel calls log several assistant lines with the same
    /// usage, so this counts from the first of them.
    pub trailing_chars: i64,
    /// How large the session was when `since` happened; None when the tail did not reach.
    pub tokens_at: Option<i64>,
}

impl Tail {
    /// 4.0 and 2.7 characters per token were measured; three sits between them, and
    /// non-ASCII is already weighted up in `content_chars`.
    pub fn next_request_tokens(&self) -> i64 {
        self.ctx_tokens + self.trailing_chars / 3
    }
}

pub const TAIL_BYTES: u64 = 256 * 1024;
pub const DEEP_BYTES: u64 = 8 << 20;

/// Backward pass over the tail: latest usage, cwd, entrypoint, newest user-set name.
pub fn claude_tail(path: &Path, bytes: u64, since: Option<f64>) -> Option<Tail> {
    let data = read_tail(path, bytes)?;
    let mut cwd = String::new();
    let mut title: Option<String> = None;
    let mut entrypoint: Option<String> = None;
    let mut hit: Option<(i64, String)> = None;
    let mut ttl = 0.0;
    let mut replied_at: Option<f64> = None;
    let (mut trailing, mut queued) = (0i64, 0i64);
    let mut earlier: Option<i64> = None;
    let mut past = false;
    // Between a compaction and the first reply after it there is no usage to read, and
    // walking past the boundary reports the session as it was *before* it (9,500 tokens
    // read as 135,937). What the compaction left is the size until the next reply.
    let mut after_compaction: Option<i64> = None;
    let mut queued_after = 0i64;

    for line in data.split(|b| *b == b'\n').rev() {
        if line.is_empty() {
            continue;
        }
        let Ok(obj) = serde_json::from_slice::<Value>(line) else { continue };
        queued += content_chars(&obj);
        if hit.is_none() && after_compaction.is_none() && obj["subtype"].as_str() == Some("compact_boundary") {
            let post = int(obj["compactMetadata"].get("postTokens"));
            after_compaction = Some(post);
            queued_after = queued;
            if post <= 0 {
                break;
            }
        }
        if cwd.is_empty() {
            if let Some(c) = obj["cwd"].as_str() {
                cwd = c.to_string();
            }
        }
        if entrypoint.is_none() {
            if let Some(e) = obj["entrypoint"].as_str() {
                entrypoint = Some(e.to_string());
            }
        }
        if title.is_none() && obj["type"].as_str() == Some("custom-title") {
            if let Some(t) = obj["customTitle"].as_str().filter(|t| !t.is_empty()) {
                title = Some(t.to_string());
            }
        }
        let msg = &obj["message"];
        let Some(u) = msg.get("usage").filter(|u| u.is_object()) else { continue };
        let ctx = int(u.get("input_tokens")) + int(u.get("cache_read_input_tokens")) + int(u.get("cache_creation_input_tokens"));
        if ctx <= 0 {
            continue;
        }
        let model = msg["model"].as_str().unwrap_or("claude").to_string();
        if let Some(post) = after_compaction {
            // The first usage above the boundary is the session before it: its model only.
            hit = Some((post, model));
            trailing = queued_after;
            break;
        }
        if let Some((h, _)) = &hit {
            if ctx != *h {
                if since.is_none() {
                    break;
                }
                past = true;
            }
        }
        if past {
            if let (Some(s), Some(ts)) = (since, crate::timeutil::iso(&obj["timestamp"])) {
                if ts <= s {
                    earlier = Some(ctx);
                    break;
                }
            }
            continue;
        }
        hit = Some((ctx, model));
        trailing = queued;
        if let Some(cc) = u.get("cache_creation") {
            if int(cc.get("ephemeral_1h_input_tokens")) > 0 {
                ttl = 3600.0;
            } else if int(cc.get("ephemeral_5m_input_tokens")) > 0 {
                ttl = 300.0;
            }
        }
        if replied_at.is_none() {
            replied_at = crate::timeutil::iso(&obj["timestamp"]);
        }
    }
    let (ctx_tokens, model) = hit?;
    Some(Tail { ctx_tokens, model, cwd, title, entrypoint, cache_ttl: ttl, replied_at, trailing_chars: trailing, tokens_at: earlier })
}

/// Text one line adds to the next request. A line reporting its own usage is a
/// response already counted in it.
fn content_chars(obj: &Value) -> i64 {
    let msg = &obj["message"];
    if !msg.is_object() || msg.get("usage").is_some() {
        return 0;
    }
    fn chars(v: &Value) -> i64 {
        match v {
            // Korean runs close to a token per character, so non-ASCII weighs three.
            Value::String(s) => s.chars().map(|c| if c.is_ascii() { 1 } else { 3 }).sum(),
            Value::Array(a) => a.iter().map(chars).sum(),
            Value::Object(o) => o.get("text").map(chars).unwrap_or(0) + o.get("content").map(chars).unwrap_or(0),
            _ => 0,
        }
    }
    chars(&msg["content"])
}

/// The tail as the scanner and the gate both read it: the usual tail first, and much
/// further back when one large tool result filled it.
pub fn claude_tail_deep(path: &Path, since: Option<f64>) -> Option<Tail> {
    match claude_tail(path, TAIL_BYTES, since) {
        Some(t) if t.ctx_tokens > 0 && !(since.is_some() && t.tokens_at.is_none()) => Some(t),
        _ => claude_tail(path, DEEP_BYTES, since),
    }
}

// ---- Compactions -------------------------------------------------------------------

const COMPACT_MARKER: &[u8] = br#""subtype":"compact_boundary""#;
const HUMAN_MARKER: &[u8] = br#""origin":{"kind":"human""#;

fn find(hay: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if from >= hay.len() || needle.len() > hay.len() - from {
        return None;
    }
    hay[from..].windows(needle.len()).position(|w| w == needle).map(|i| i + from)
}

#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct Compactions {
    pub offset: u64,
    pub count: i64,
    pub post: i64,
    pub auto_pre: i64,
}

/// Compaction boundaries in one run of whole lines: how many, what the last left
/// behind, and how large the session was when it last compacted by itself. Only `auto`
/// counts for the last: a hand-run /compact says nothing about where Claude Code would.
fn markers(hay: &[u8]) -> (i64, i64, i64) {
    let (mut n, mut post, mut pre, mut from) = (0, 0, 0, 0);
    while let Some(at) = find(hay, COMPACT_MARKER, from) {
        n += 1;
        from = at + COMPACT_MARKER.len();
        let start = hay[..at].iter().rposition(|b| *b == b'\n').map(|i| i + 1).unwrap_or(0);
        let end = hay[from..].iter().position(|b| *b == b'\n').map(|i| i + from).unwrap_or(hay.len());
        if let Ok(obj) = serde_json::from_slice::<Value>(&hay[start..end]) {
            if let Some(meta) = obj.get("compactMetadata") {
                post = int(meta.get("postTokens"));
                if meta["trigger"].as_str() == Some("auto") {
                    pre = int(meta.get("preTokens"));
                }
            }
        }
    }
    (n, post, pre)
}

/// Counted incrementally: Claude Code never truncates a transcript, so the file is read
/// once and then only what was appended. A partial last line is held back so a marker
/// split across two reads is seen whole, and counted once.
pub fn scan_compactions(path: &Path, mut st: Compactions) -> Compactions {
    let Ok(mut f) = std::fs::File::open(path) else { return st };
    let size = f.seek(SeekFrom::End(0)).unwrap_or(0);
    if size < st.offset {
        st = Compactions::default(); // replaced or truncated: count again
    }
    if st.offset >= size || f.seek(SeekFrom::Start(st.offset)).is_err() {
        return st;
    }
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        let n = match f.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        let Some(nl) = buf.iter().rposition(|b| *b == b'\n') else { continue };
        let (count, post, pre) = markers(&buf[..=nl]);
        st.count += count;
        if count > 0 {
            st.post = post;
        }
        if pre > 0 {
            st.auto_pre = pre;
        }
        st.offset += (nl + 1) as u64;
        buf.drain(..=nl);
    }
    st
}

/// Scans forward from where the previous call stopped, a megabyte at a time.
pub fn scan_human(path: &Path, offset: u64) -> (u64, bool) {
    let Ok(mut f) = std::fs::File::open(path) else { return (offset, false) };
    let overlap = HUMAN_MARKER.len() as u64;
    let mut at = offset.saturating_sub(overlap);
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        if f.seek(SeekFrom::Start(at)).is_err() {
            break;
        }
        let n = match f.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if find(&chunk[..n], HUMAN_MARKER, 0).is_some() {
            return (offset.max(at), true);
        }
        at += n as u64;
        if n < chunk.len() {
            break;
        }
        at -= overlap;
    }
    (offset.max(at), false)
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::io::Write;

    pub fn usage_line(tokens: i64, ts: &str) -> String {
        format!(
            r#"{{"type":"assistant","entrypoint":"cli","cwd":"C:\\work\\demo","timestamp":"{ts}","message":{{"model":"claude-opus-5","usage":{{"input_tokens":10,"cache_read_input_tokens":{tokens}}}}}}}"#
        )
    }
    pub fn boundary(trigger: &str, pre: i64, post: i64) -> String {
        format!(r#"{{"type":"system","subtype":"compact_boundary","compactMetadata":{{"trigger":"{trigger}","preTokens":{pre},"postTokens":{post}}}}}"#)
    }
    fn append(p: &Path, s: &str) {
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(p).unwrap();
        f.write_all(s.as_bytes()).unwrap();
    }

    #[test]
    fn size_is_the_latest_usage_and_its_folder() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        append(&p, &(usage_line(100_000, "2026-10-01T00:00:00Z") + "\n" + &usage_line(250_000, "2026-10-01T00:01:00Z") + "\n"));
        let t = claude_tail(&p, TAIL_BYTES, None).unwrap();
        assert_eq!(t.ctx_tokens, 250_010);
        assert_eq!(t.cwd, r"C:\work\demo");
    }

    /// Right after a compaction the size is what it left, not what came before it.
    #[test]
    fn just_compacted_reads_what_the_compaction_left() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        append(&p, &(usage_line(135_927, "2026-10-01T00:00:00Z") + "\n" + &boundary("auto", 135_937, 9_500) + "\n"));
        assert_eq!(claude_tail(&p, TAIL_BYTES, None).unwrap().ctx_tokens, 9_500);
    }

    /// Parallel calls: results queued between lines sharing one usage count toward the
    /// next request.
    #[test]
    fn queued_results_count_toward_the_next_request() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        let result = format!(r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{}"}}]}}}}"#, "x".repeat(90_000));
        append(&p, &format!("{}\n{}\n{}\n", usage_line(960_000, "2026-10-01T00:00:00Z"), result, usage_line(960_000, "2026-10-01T00:00:00Z")));
        let t = claude_tail(&p, TAIL_BYTES, None).unwrap();
        assert_eq!(t.next_request_tokens(), 960_010 + 30_000);
    }

    /// One big result can push the usage out of the usual tail; it is still found.
    #[test]
    fn deep_usage_is_found_past_a_large_result() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        let result = format!(r#"{{"type":"user","message":{{"content":[{{"type":"tool_result","content":"{}"}}]}}}}"#, "x".repeat(300_000));
        append(&p, &format!("{}\n{}\n", usage_line(700_000, "2026-10-01T00:00:00Z"), result));
        assert!(claude_tail(&p, TAIL_BYTES, None).is_none());
        let t = claude_tail_deep(&p, None).unwrap();
        assert_eq!(t.next_request_tokens(), 700_010 + 100_000);
    }

    /// The incremental count, step by step as a file grows (the macOS `--scan-replay`).
    #[test]
    fn incremental_count_follows_a_growing_file() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        let b = boundary("auto", 0, 30_000) + "\n";
        let mut st = Compactions::default();
        let step = |p: &Path, st: &mut Compactions| {
            *st = scan_compactions(p, *st);
            st.count
        };
        append(&p, &(usage_line(500_000, "2026-10-01T00:00:00Z") + "\n"));
        assert_eq!(step(&p, &mut st), 0, "none");
        append(&p, &b);
        assert_eq!(step(&p, &mut st), 1, "one");
        append(&p, &b[..40]);
        assert_eq!(step(&p, &mut st), 1, "partial");
        append(&p, &b[40..]);
        assert_eq!(step(&p, &mut st), 2, "completed");
        append(&p, "{\"type\":\"user\",\"message\":{\"content\":\"the subtype compact_boundary was mentioned\"}}\n");
        assert_eq!(step(&p, &mut st), 2, "mention");
        append(&p, &format!("{{\"type\":\"user\",\"message\":{{\"content\":\"{}\"}}}}\n", "x".repeat(1 << 20)));
        append(&p, &b);
        assert_eq!(step(&p, &mut st), 3, "across-reads");
        std::fs::write(&p, usage_line(500_000, "2026-10-01T00:00:00Z") + "\n").unwrap();
        assert_eq!(step(&p, &mut st), 0, "truncated");
    }

    #[test]
    fn auto_compaction_point_ignores_manual_ones() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        append(&p, &(boundary("auto", 832_917, 30_000) + "\n" + &boundary("manual", 500_000, 30_000) + "\n"));
        let st = scan_compactions(&p, Compactions::default());
        assert_eq!((st.count, st.auto_pre), (2, 832_917));
    }

    #[test]
    fn human_marker_is_found_once_and_remembered() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("s.jsonl");
        append(&p, "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}\n");
        let (off, yes) = scan_human(&p, 0);
        assert!(!yes);
        append(&p, "{\"type\":\"user\",\"message\":{\"content\":[]},\"origin\":{\"kind\":\"human\"}}\n");
        assert!(scan_human(&p, off).1);
    }
}
