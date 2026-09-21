import Foundation

/// Reading Codex rollout logs (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
/// One rollout file is one thread, so a file *is* a session. Codex logs both the
/// context occupancy and the account rate limits in every `token_count` event, so
/// everything here is read straight from disk — no credentials, no network.
public enum CodexRollout {
    /// Rollout files from the last `days` day-directories (the tree is `YYYY/MM/DD/`,
    /// so this never walks years of history).
    public static func recentFiles(home: String = Paths.home, days: Int = 2) -> [String] {
        let root = home + "/.codex/sessions"
        let cal = Calendar.current
        var out: [String] = []
        for back in 0...max(0, days) {
            guard let d = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = String(format: "%@/%04d/%02d/%02d", root, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            out += items.filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
        }
        return out
    }

    public struct Meta: Sendable {
        public let sessionId: String
        public let cwd: String
        public let isSubagent: Bool     // spawned helper thread, not a session a human watches
    }

    /// `session_meta` is the first line; read only the head of the file.
    public static func meta(path: String) -> Meta? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 256 * 1024), !head.isEmpty else { return nil }
        for slice in head.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
                  obj["type"] as? String == "session_meta",
                  let p = obj["payload"] as? [String: Any] else { continue }
            let id = (p["session_id"] as? String) ?? (p["id"] as? String) ?? ""
            guard !id.isEmpty else { continue }
            return Meta(sessionId: id, cwd: (p["cwd"] as? String) ?? "",
                        isSubagent: (p["thread_source"] as? String) == "subagent")
        }
        return nil
    }

    public struct Tail: Sendable {
        public var ctxTokens = 0
        public var window = 0
        public var model = "codex"
        public var weekly: Limit?
    }

    /// One backward pass over the last 256 KB: latest context size + window, model,
    /// and the weekly rate limit (the `rate_limits` window of ≥ 7 days).
    public static func tail(path: String) -> Tail? {
        guard let data = FileTail.read(path: path) else { return nil }
        var t = Tail()
        var haveCtx = false, haveModel = false
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(slice)) as? [String: Any],
                  let p = obj["payload"] as? [String: Any] else { continue }
            if !haveModel, obj["type"] as? String == "turn_context", let m = p["model"] as? String, !m.isEmpty {
                t.model = m; haveModel = true
            }
            guard p["type"] as? String == "token_count" else { continue }
            if !haveCtx, let info = p["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any],
               let ctx = (last["total_tokens"] as? NSNumber)?.intValue, ctx > 0 {
                t.ctxTokens = ctx
                t.window = (info["model_context_window"] as? NSNumber)?.intValue ?? 0
                haveCtx = true
            }
            if t.weekly == nil, let rl = p["rate_limits"] as? [String: Any] {
                t.weekly = weeklyLimit(rl, at: TimeUtil.iso(obj["timestamp"]))
            }
            if haveCtx && haveModel && t.weekly != nil { break }
        }
        return haveCtx || t.weekly != nil ? t : nil
    }

    /// Weekly limit from the newest rollout (any thread — the limit is account-wide)
    /// that logged one in the past week.
    static func newestWeekly(home: String) -> Limit? {
        let dated = recentFiles(home: home, days: 7).compactMap { p -> (String, Date)? in
            guard let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { return nil }
            return (p, m)
        }
        for (p, _) in dated.sorted(by: { $0.1 > $1.1 }).prefix(20) {
            if let w = tail(path: p)?.weekly { return w }
        }
        return nil
    }

    /// Pick the ≥ 7-day window out of `primary` / `secondary` (plans differ in which
    /// slot carries it).
    static func weeklyLimit(_ rl: [String: Any], at: Date?) -> Limit? {
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any],
                  let mins = (w["window_minutes"] as? NSNumber)?.intValue, mins >= 7 * 24 * 60,
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Limit(tool: .codex, percent: used, resetsAt: reset, updatedAt: at ?? Date())
        }
        return nil
    }
}

/// Shared tail reader: the last `bytes` of a file (whole file when smaller).
enum FileTail {
    static func read(path: String, bytes: UInt64 = 256 * 1024) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        do { try fh.seek(toOffset: size > bytes ? size - bytes : 0) } catch { return nil }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        return data
    }
}

extension TimeUtil {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    static func iso(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
}
