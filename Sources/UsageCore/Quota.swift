import Foundation

/// A subscription's weekly (and, when known, 5-hour) usage, as a percentage used.
public struct ProviderQuota: Sendable, Equatable, Identifiable {
    public let provider: String          // "anthropic" | "openai" | "kimi" | …
    public let weeklyPercent: Double?
    public let fiveHourPercent: Double?
    public let resetsAt: Date?           // weekly reset
    public let updatedAt: Date

    public var id: String { provider }

    public init(provider: String, weeklyPercent: Double?, fiveHourPercent: Double?,
                resetsAt: Date?, updatedAt: Date) {
        self.provider = provider; self.weeklyPercent = weeklyPercent
        self.fiveHourPercent = fiveHourPercent; self.resetsAt = resetsAt; self.updatedAt = updatedAt
    }
}

/// Display metadata for a provider id — name and sort order. The logo lives in the
/// UI layer (BrandLogos); this stays UI-free so it can live in the core module.
public enum ProviderMeta {
    private static let order = ["anthropic", "openai", "kimi"]
    public static func name(_ id: String) -> String {
        switch id {
        case "anthropic": return "Claude"
        case "openai":    return "Codex"
        case "kimi":      return "Kimi"
        default:          return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
    public static func rank(_ id: String) -> Int { order.firstIndex(of: id) ?? order.count }
    public static func sorted(_ q: [ProviderQuota]) -> [ProviderQuota] {
        q.sorted { (rank($0.provider), $0.provider) < (rank($1.provider), $1.provider) }
    }
}

/// Reads live subscription quotas from the local opencodex proxy, which already
/// aggregates every configured provider (Claude, ChatGPT/Codex, Kimi, …) and refreshes
/// them as it routes traffic. One localhost GET of cached JSON — no upstream call, no
/// tokens spent, no credentials of ours. Returns [] when the proxy isn't running.
public enum OpenCodex {
    public static func fetchQuotas(home: String = Paths.home) async -> [ProviderQuota] {
        guard !Paths.offline, let token = adminToken(home: home), let port = proxyPort(home: home),
              let url = URL(string: "http://127.0.0.1:\(port)/api/provider-quotas") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue(token, forHTTPHeaderField: "x-opencodex-api-key")   // never logged
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reports = obj["reports"] as? [[String: Any]] else { return [] }
        let now = Date()
        return reports.compactMap { r in
            guard let provider = r["provider"] as? String, let q = r["quota"] as? [String: Any] else { return nil }
            // The proxy's own Anthropic account is not the one Claude Code/desktop signs
            // in with, so its numbers describe a different subscription (observed
            // 2026-09-21: 100 % here vs 9 % in the app). ClaudeUsage reads the real one.
            guard provider != "anthropic" else { return nil }
            let weekly = num(q["weeklyPercent"])
            let five = num(q["fiveHourPercent"])
            guard weekly != nil || five != nil else { return nil }
            return ProviderQuota(provider: provider, weeklyPercent: weekly, fiveHourPercent: five,
                                 resetsAt: epochMillis(q["weeklyResetAt"]),
                                 updatedAt: epochMillis(r["updatedAt"]) ?? epochMillis(q["updatedAt"]) ?? now)
        }
    }

    /// The proxy's admin token: env override, else the owner-only token file.
    static func adminToken(home: String) -> String? {
        if let e = ProcessInfo.processInfo.environment["OPENCODEX_ADMIN_AUTH_TOKEN"],
           !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return e }
        guard let raw = try? String(contentsOfFile: home + "/.opencodex/admin-api-token", encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Proxy port from Codex's `openai_base_url` (…127.0.0.1:PORT…), default 10100.
    static func proxyPort(home: String) -> Int? {
        guard let toml = try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8) else { return 10100 }
        for line in toml.split(separator: "\n") where line.contains("openai_base_url") {
            if let m = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) {
                return Int(line[m].split(separator: ":")[1])
            }
        }
        return 10100
    }

    private static func num(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue else { return nil }
        return max(0, min(100, d))
    }
    private static func epochMillis(_ v: Any?) -> Date? {
        guard let ms = (v as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
