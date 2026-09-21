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

    public static func fetch() async -> ProviderQuota? {
        guard !Paths.offline else { lastDiagnosis = "offline"; return nil }
        guard let token = sessionToken() else { lastDiagnosis = "no live session token"; return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                             timeoutInterval: 8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            lastDiagnosis = "network error"; return nil
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastDiagnosis = "http \(code)"; return nil
        }
        guard let q = parse(obj) else {
            lastDiagnosis = "unexpected fields: \(obj.keys.sorted().prefix(8).joined(separator: ","))"
            return nil
        }
        lastDiagnosis = "ok"
        return q
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
    static func sessionToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        // BSD-style `e` (environment) must be given without a dash; `-e` means "all
        // processes" instead and prints no environment at all.
        p.arguments = ["eww", "-A", "-o", "command="]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let marker = "CLAUDE_CODE_OAUTH_TOKEN="
        for line in text.split(separator: "\n") where line.contains(marker) {
            guard let r = line.range(of: marker) else { continue }
            let token = line[r.upperBound...].prefix { !$0.isWhitespace }
            if token.count > 20 { return String(token) }   // value only; never logged
        }
        return nil
    }
}
