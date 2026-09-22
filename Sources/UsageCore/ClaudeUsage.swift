import Foundation

/// Claude's own subscription usage — the numbers the desktop app shows under
/// "플랜 사용량 한도".
///
/// The opencodex proxy also reports an `anthropic` quota, but that is *its own*
/// configured Anthropic account, which is not the account the desktop app signs in
/// with (observed 2026-09-21: proxy said weekly 100 % / Fable 41 %, the desktop app
/// said 9 % / 4 % at the same moment). So this reads the account actually in use.
///
/// Source: the desktop app hands every Claude Code session it spawns a live OAuth
/// token in that process's environment. We read it from a running session, use it for
/// one GET, and drop it — never refreshed, written, cached or logged. Nothing here can
/// disturb an existing login.
public enum ClaudeUsage {
    /// Why the last fetch produced nothing — shown by `--dump`, never the token itself.
    public private(set) nonisolated(unsafe) static var lastDiagnosis = "not attempted"

    /// No request goes out again until this passes. Kept on disk as well: the app is
    /// reinstalled and relaunched often, and a back-off that only lived in memory meant
    /// every restart fired a request into a limit that was still in force.
    private static var backoffFile: String { Paths.root + "/claude-backoff" }
    private nonisolated(unsafe) static var backoffCache: Date?

    public static var backoffUntil: Date {
        get {
            if let d = backoffCache { return d }
            let stored = (try? String(contentsOfFile: backoffFile, encoding: .utf8))
                .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            backoffCache = stored
            return stored
        }
        set {
            backoffCache = newValue
            try? FileManager.default.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            try? String(Int(newValue.timeIntervalSince1970)).write(toFile: backoffFile, atomically: true, encoding: .utf8)
        }
    }

    /// The token that worked last time, tried first so a good one is not re-discovered
    /// on every poll. Never logged.
    private nonisolated(unsafe) static var knownGood: String?

    public static func fetch() async -> ProviderQuota? {
        guard !Paths.offline else { lastDiagnosis = "offline"; return nil }
        if Date() < backoffUntil {
            lastDiagnosis = "rate-limited, retrying in \(Int(backoffUntil.timeIntervalSinceNow))s"
            return nil
        }
        var tokens = sessionTokens()
        if let good = knownGood, let i = tokens.firstIndex(of: good) {
            tokens.remove(at: i); tokens.insert(good, at: 0)
        }
        guard !tokens.isEmpty else { lastDiagnosis = "no live session token"; return nil }

        // Several sessions may be running, each with its own token, and the older ones
        // expire. Try them newest first and stop at the one the endpoint accepts.
        var rejected = 0
        for token in tokens.prefix(3) {
            switch await ask(token: token) {
            case .ok(let q):
                knownGood = token
                backoffUntil = .distantPast
                lastDiagnosis = "ok"
                return q
            case .expired:
                rejected += 1
            case .limited(let wait, let reason):
                backoffUntil = Date().addingTimeInterval(wait)
                lastDiagnosis = "http 429, waiting \(Int(wait))s — \(reason)"
                return nil
            case .other(let why):
                lastDiagnosis = why
                return nil
            }
        }
        // Every token we can see is expired. Asking again in five minutes is what turned
        // this into a rate limit last time, so wait before looking for a fresher one.
        knownGood = nil
        backoffUntil = Date().addingTimeInterval(600)
        lastDiagnosis = "http 401 on \(rejected) token(s) — waiting 600s for a fresh session"
        return nil
    }

    private enum Answer {
        case ok(ProviderQuota)
        case expired
        case limited(Double, String)
        case other(String)
    }

    private static func ask(token: String) async -> Answer {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                             timeoutInterval: 8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .other("network error")
        }
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 401 || code == 403 { return .expired }
        if code == 429 {
            // Honour the server's own wait; asking again sooner is what keeps a 429 alive.
            let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 900
            let reason = (String(data: data.prefix(300), encoding: .utf8) ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            return .limited(wait, reason)
        }
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .other("http \(code)")
        }
        guard let q = parse(obj) else {
            return .other("unexpected fields: \(obj.keys.sorted().prefix(8).joined(separator: ","))")
        }
        return .ok(q)
    }

    /// `five_hour` / `seven_day` carry `utilization` + `resets_at`; the weekly figure is
    /// the all-models window, matching the desktop app's "주간 · 전체 모델" row.
    static func parse(_ r: [String: Any]) -> ProviderQuota? {
        func window(_ key: String) -> (Double, Date?)? {
            guard let o = r[key] as? [String: Any],
                  let u = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
            var reset: Date?
            if let s = o["resets_at"] as? String { reset = isoDate(s) }
            else if let n = (o["resets_at"] as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: n) }
            return (max(0, min(100, u)), reset)
        }
        let five = window("five_hour"), week = window("seven_day")
        guard five != nil || week != nil else { return nil }
        return ProviderQuota(provider: "anthropic", weeklyPercent: week?.0, fiveHourPercent: five?.0,
                             resetsAt: week?.1, updatedAt: Date())
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Pull the OAuth token out of a live `claude` process's environment (same user).
    /// `ps eww` prints the environment of our own processes only.
    static func sessionTokens() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        // BSD-style `e` (environment) must be given without a dash; `-e` means "all
        // processes" instead and prints no environment at all.
        p.arguments = ["eww", "-A", "-o", "command="]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let marker = "CLAUDE_CODE_OAUTH_TOKEN="
        // `ps` lists oldest first, so reversing puts the freshest session at the front —
        // and the older ones are the expired ones.
        var found: [String] = []
        for line in text.split(separator: "\n").reversed() where line.contains(marker) {
            guard let r = line.range(of: marker) else { continue }
            let token = String(line[r.upperBound...].prefix { !$0.isWhitespace })
            if token.count > 20, !found.contains(token) { found.append(token) }   // never logged
        }
        return found
    }
}
