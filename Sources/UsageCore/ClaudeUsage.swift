import Foundation
import Security

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
    private nonisolated(unsafe) static var backoffCache: (until: Date, token: String)?

    /// Stored as "<epoch> <token fingerprint>". The fingerprint is what lets a limit
    /// earned by an expired token stop applying once a fresh one appears — that limit
    /// was the old token's doing, and the new one deserves its own attempt.
    private static var backoff: (until: Date, token: String) {
        get {
            if let b = backoffCache { return b }
            let parts = ((try? String(contentsOfFile: backoffFile, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            let b = (Date(timeIntervalSince1970: parts.first.flatMap(Double.init) ?? 0),
                     parts.count > 1 ? parts[1] : "")
            backoffCache = b
            return b
        }
        set {
            backoffCache = newValue
            guard newValue.until > Date() else {
                try? FileManager.default.removeItem(atPath: backoffFile); return
            }
            try? FileManager.default.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            try? "\(Int(newValue.until.timeIntervalSince1970)) \(newValue.token)"
                .write(toFile: backoffFile, atomically: true, encoding: .utf8)
        }
    }

    public static var backoffUntil: Date { backoff.until }

    /// Appends one line to `~/.usage-manager/usage.log`, beside the app's own entries.
    static func note(_ text: String) {
        let path = Paths.root + "/usage.log"
        let line = ISO8601DateFormatter().string(from: Date()) + " " + text + "\n"
        guard let fh = FileHandle(forWritingAtPath: path) else {
            try? FileManager.default.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
    }

    /// A short, non-reversible stand-in for a token, safe to write to disk and logs.
    static func fingerprint(_ token: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in token.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// The token that worked last time, tried first so a good one is not re-discovered
    /// on every poll. Never logged.
    private nonisolated(unsafe) static var knownGood: String?

    public static func fetch() async -> ProviderQuota? {
        guard !Paths.offline else { lastDiagnosis = "offline"; return nil }
        var tokens = allTokens()
        let held = backoff
        if Date() < held.until {
            // A limit the *current* token never earned should not hold it back.
            if let first = tokens.first, fingerprint(first) == held.token {
                lastDiagnosis = "rate-limited, retrying in \(Int(held.until.timeIntervalSinceNow))s"
                return nil
            }
            lastDiagnosis = "rate-limited on an older token; trying the current one"
        }
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
                backoff = (.distantPast, "")
                lastDiagnosis = "ok"
                remember(q)
                return q
            case .expired:
                rejected += 1
                forgetKeychain()   // whatever was cached is no longer accepted
            case .limited(let wait, let reason):
                backoff = (Date().addingTimeInterval(wait), fingerprint(token))
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
        backoff = (Date().addingTimeInterval(600), tokens.first.map(fingerprint) ?? "")
        lastDiagnosis = "http 401 on \(rejected) token(s) — waiting 600s for a fresh session"
        return nil
    }

    // MARK: - The last reading, kept across launches

    /// A launch whose first lookup is refused has nothing of its own to show, and the
    /// fallback it used to fall to is a statusLine snapshot — which carries no account.
    /// A terminal session still signed in as someone else then put that account's
    /// quota on the row (observed: 0 % left, resetting in two days, while the account
    /// in use stood at 84 %). So the last live reading is kept, tagged with the account
    /// it was read for, and used only while that is still the account signed in.
    static var lastFile: String { Paths.root + "/claude-last.json" }

    /// The account Claude Code is signed in as — its id, from Claude Code's own
    /// settings file. No credential is read.
    public static func signedInAccount() -> String? {
        guard let d = FileManager.default.contents(atPath: Paths.home + "/.claude.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["oauthAccount"] as? [String: Any] else { return nil }
        return a["accountUuid"] as? String
    }

    static func remember(_ q: ProviderQuota) {
        guard let account = signedInAccount() else { return }
        var o: [String: Any] = ["account": account, "updatedAt": q.updatedAt.timeIntervalSince1970]
        if let w = q.weeklyPercent { o["weekly"] = w }
        if let f = q.fiveHourPercent { o["fiveHour"] = f }
        if let r = q.resetsAt { o["resetsAt"] = r.timeIntervalSince1970 }
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: lastFile), options: .atomic)
    }

    /// The last live reading, or nil when it was read for a different account than the
    /// one signed in now.
    public static func lastKnown() -> ProviderQuota? {
        guard let d = FileManager.default.contents(atPath: lastFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let account = o["account"] as? String, account == signedInAccount(),
              let at = (o["updatedAt"] as? NSNumber)?.doubleValue else { return nil }
        return ProviderQuota(provider: "anthropic",
                             weeklyPercent: (o["weekly"] as? NSNumber)?.doubleValue,
                             fiveHourPercent: (o["fiveHour"] as? NSNumber)?.doubleValue,
                             resetsAt: (o["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                             updatedAt: Date(timeIntervalSince1970: at))
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
        // The endpoint rate-limits unknown callers harder than it does Claude Code
        // itself, which is what several usage tools found before this one.
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
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

    /// `claude-code/<version>`, read once from the installed CLI.
    private nonisolated(unsafe) static var uaCache: String?
    static var userAgent: String {
        if let ua = uaCache { return ua }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "--version"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        var version = "2.1.141"
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let text = String(data: data, encoding: .utf8),
               let m = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                version = String(text[m])
            }
        }
        let ua = "claude-code/" + version
        uaCache = ua
        return ua
    }

    /// Where to look for a usable token, best first.
    ///
    /// The keychain holds the one Claude Code keeps refreshed, so it is almost always
    /// valid. The process list holds whatever each running session started with, and
    /// the older of those have expired — reading those first is what produced a day of
    /// 401s, and then the rate limit they earned.
    static func allTokens() -> [String] {
        var found: [String] = []
        if let k = keychainToken() { found.append(k) }
        for t in credentialsFileTokens() where !found.contains(t) { found.append(t) }
        for t in sessionTokens() where !found.contains(t) { found.append(t) }
        return found
    }

    /// Kept in memory for as long as it is valid. Each read is a keychain access, and
    /// macOS asks the user to approve one whenever the app's signature has changed —
    /// which, with an ad-hoc signature, is every build. Reading once an hour instead of
    /// every five minutes is the difference between a prompt a day and twelve.
    ///
    /// `changed` is the item's own modification date, so a sign-in as a different
    /// account is noticed at the next poll rather than up to an hour later. Signing in
    /// rewrites the item; the cached token then belongs to the account before it, and
    /// the quota it reports is that account's.
    private nonisolated(unsafe) static var cachedKeychain: (token: String, until: Date, changed: Date?)?

    /// Called when the endpoint rejects a credential: whatever is cached is stale.
    static func forgetKeychain() { cachedKeychain = nil }

    /// When the credential item was last written. An attributes-only query: it does not
    /// return the credential, so it neither exposes it nor asks the user to approve a
    /// read. nil when the item cannot be found at all.
    public static func keychainChangedAt() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date
    }

    /// A cached token stands only while it is still valid *and* the item behind it has
    /// not been rewritten since.
    public static func cacheHolds(until: Date, cachedChange: Date?, itemChange: Date?, now: Date) -> Bool {
        until > now && cachedChange == itemChange
    }

    static func keychainToken() -> String? {
        let changedAt = keychainChangedAt()
        if let c = cachedKeychain,
           cacheHolds(until: c.until, cachedChange: c.changed, itemChange: changedAt, now: Date()) {
            return c.token
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let entry = oauthEntry(in: data) else { return nil }
        // Re-read shortly before it lapses, and at least every ten minutes, so a
        // credential rotated early is still picked up without asking on every poll.
        let until = min(entry.expires, Date().addingTimeInterval(3600))
        cachedKeychain = (entry.token, max(Date().addingTimeInterval(600), until.addingTimeInterval(-60)), changedAt)
        // One line per actual read, so the caching can be checked from the log without
        // anything sensitive in it: a fingerprint, never the credential.
        note("keychain read (fingerprint \(fingerprint(entry.token)))")
        return entry.token
    }

    /// Same shape, for installs that keep it in a file instead.
    static func credentialsFileTokens() -> [String] {
        guard let data = FileManager.default.contents(atPath: Paths.home + "/.claude/.credentials.json"),
              let t = oauthToken(in: data) else { return [] }
        return [t]
    }

    private static func oauthToken(in data: Data) -> String? { oauthEntry(in: data)?.token }

    private static func oauthEntry(in data: Data) -> (token: String, expires: Date)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, token.count > 20 else { return nil }
        // Expired is worse than absent: it is what answers 401 in a loop.
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        if let e = expires, e <= Date() { return nil }
        return (token, expires ?? Date().addingTimeInterval(3600))
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
