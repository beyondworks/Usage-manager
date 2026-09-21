import Foundation

/// Which AI coding tool a session or limit belongs to.
public enum ToolKind: String, CaseIterable, Sendable, Codable {
    case claudeCode = "claude_code"
    case codex

    public var display: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        }
    }

    /// The subscription provider this tool bills against (for matching quota reports).
    public var provider: String { self == .claudeCode ? "anthropic" : "openai" }
}

/// Single source for every path the app reads or writes. `HOME` is honoured so a
/// disposable home can drive the whole app (hook scripts, snapshots, sessions).
public enum Paths {
    public static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }
    /// App-owned state, kept outside `Application Support` so hook commands need no quoting.
    public static var root: String { home + "/.usage-manager" }
    public static var claudeStatus: String { root + "/claude-status" }   // statusLine snapshots, one per session
    public static var alerts: String { root + "/alerts" }                // pending compaction notices, one per session
    public static var bin: String { root + "/bin" }
    /// Set by the self-check so a disposable HOME exercises only the local file readers
    /// — otherwise the real account's live numbers would mask the fallback under test.
    public static var offline: Bool { ProcessInfo.processInfo.environment["USAGE_MANAGER_OFFLINE"] == "1" }
}
