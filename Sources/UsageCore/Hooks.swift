import Foundation

/// Wiring between Usage Manager and the agents themselves.
///
/// - Claude Code statusLine → `statusline.sh` snapshots its input (the only local
///   place Claude exposes `rate_limits`) and then runs the previously configured
///   statusLine, so the user's own status bar keeps working.
/// - `UserPromptSubmit` (Claude Code + Codex) → `ctx-hook.sh` hands the agent a
///   pending compaction notice for its session, once, as `additionalContext`.
///
/// Every edit is reversible: the original statusLine command is kept in
/// `statusline.prev`, and a `.usage-manager.bak` copy is written before each change.
public enum Hooks {
    /// Both events carry the notice: a prompt (user is present) and every tool call
    /// (long autonomous runs, where no prompt may come before auto-compaction does).
    static let promptEvents = ["UserPromptSubmit", "PostToolUse"]
    static let statusScript = "statusline.sh"
    static let promptScript = "ctx-hook.sh"
    static var prevStatusLine: String { Paths.root + "/statusline.prev" }
    static var claudeSettings: String { Paths.home + "/.claude/settings.json" }
    static var codexHooks: String { Paths.home + "/.codex/hooks.json" }

    // Hook stdin carries `session_id`; everything else in it is ignored.
    private static let readSid = """
    in=$(cat | tr -d '\\n')
    sid=$(printf '%s' "$in" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9-]*\\)".*/\\1/p')
    """

    static let statusBody = """
    #!/bin/sh
    # Usage Manager: snapshot Claude Code statusLine input, then run the previous statusLine.
    \(readSid)
    if [ -n "$sid" ]; then
      d="$HOME/.usage-manager/claude-status"; mkdir -p "$d"
      printf '%s' "$in" > "$d/.$sid.tmp" && mv -f "$d/.$sid.tmp" "$d/$sid.json"
    fi
    prev="$HOME/.usage-manager/statusline.prev"
    [ -s "$prev" ] && printf '%s' "$in" | /bin/sh -c "$(cat "$prev")"
    exit 0

    """

    static let promptBody = """
    #!/bin/sh
    # Usage Manager: deliver this session's pending context notice to the agent (once).
    # Runs on UserPromptSubmit *and* PostToolUse, so a long autonomous run is told even
    # when the user sends no message. The alert file holds a bare JSON string; the event
    # name comes from stdin so the same file serves either hook.
    \(readSid)
    ev=$(printf '%s' "$in" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\\([A-Za-z]*\\)".*/\\1/p')
    [ -n "$ev" ] || ev=UserPromptSubmit
    f="$HOME/.usage-manager/alerts/$sid.txt"
    [ -n "$sid" ] && [ -f "$f" ] || exit 0
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\\n' "$ev" "$(cat "$f")"
    rm -f "$f"
    exit 0

    """

    // MARK: - State

    public struct Status: Sendable, Equatable {
        public var claude = false
        public var codex = false
        public var codexTrusted = false   // Codex skips a new hook until the user trusts it (`/hooks`)
        public init(claude: Bool = false, codex: Bool = false, codexTrusted: Bool = false) {
            self.claude = claude; self.codex = codex; self.codexTrusted = codexTrusted
        }
    }

    public static func status() -> Status {
        let claude = readJSON(claudeSettings)
        let codex = readJSON(codexHooks)
        let status = (claude?["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        return Status(claude: status == statusCommand && hasPromptHook(claude),
                      codex: hasPromptHook(codex), codexTrusted: codexTrusted(codex))
    }

    /// Codex records trust per hook as `[hooks.state."<hooks.json>:<event>:<group>:<hook>"]`
    /// in config.toml; our slot's key must be present for every event we registered.
    private static func codexTrusted(_ root: [String: Any]?) -> Bool {
        guard let toml = try? String(contentsOfFile: Paths.home + "/.codex/config.toml", encoding: .utf8) else { return false }
        return promptEvents.allSatisfy { event in
            let list = ((root?["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []
            guard let idx = list.firstIndex(where: isOurs) else { return false }
            return toml.contains("[hooks.state.\"\(codexHooks):\(snakeCase(event)):\(idx):0\"]")
        }
    }

    /// "PostToolUse" → "post_tool_use", the spelling Codex uses for trust keys.
    private static func snakeCase(_ event: String) -> String {
        event.reduce(into: "") { out, c in
            if c.isUppercase && !out.isEmpty { out += "_" }
            out.append(Character(c.lowercased()))
        }
    }

    // MARK: - Install / uninstall

    public static func install() throws {
        try writeScripts()
        if FileManager.default.fileExists(atPath: Paths.home + "/.claude") {
            var s = readJSON(claudeSettings) ?? [:]
            let current = s["statusLine"] as? [String: Any]
            let cmd = current?["command"] as? String ?? ""
            if cmd != statusCommand {
                try cmd.write(toFile: prevStatusLine, atomically: true, encoding: .utf8)
                var line = current ?? ["type": "command"]
                line["command"] = statusCommand
                s["statusLine"] = line
            }
            try writeJSON(addPromptHook(s), to: claudeSettings)
        }
        if FileManager.default.fileExists(atPath: Paths.home + "/.codex") {
            try writeJSON(addPromptHook(readJSON(codexHooks) ?? [:]), to: codexHooks)
        }
    }

    public static func uninstall() throws {
        if var s = readJSON(claudeSettings) {
            if var line = s["statusLine"] as? [String: Any], line["command"] as? String == statusCommand {
                let prev = (try? String(contentsOfFile: prevStatusLine, encoding: .utf8)) ?? ""
                if prev.isEmpty { s["statusLine"] = nil } else { line["command"] = prev; s["statusLine"] = line }
            }
            try writeJSON(removePromptHook(s), to: claudeSettings)
        }
        if let c = readJSON(codexHooks) { try writeJSON(removePromptHook(c), to: codexHooks) }
    }

    /// Queue a notice for `sessionId`; `ctx-hook.sh` hands it over on the session's next
    /// prompt *or* tool call, whichever comes first, then deletes it. Stored as a bare
    /// JSON string so the script can wrap it in whichever hook event fired.
    public static func queueNotice(sessionId: String, text: String) {
        guard sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let data = try? JSONSerialization.data(withJSONObject: text,
                                                     options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.alerts, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Paths.alerts + "/\(sessionId).txt"), options: .atomic)
    }

    // MARK: - Helpers

    static func writeScripts() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: Paths.bin, withIntermediateDirectories: true)
        for (name, body) in [(statusScript, statusBody), (promptScript, promptBody)] {
            let path = Paths.bin + "/" + name
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    // Exact-match identity: other tools' scripts can share our file names (e.g. `ponytail-statusline.sh`).
    private static var promptCommand: String { "/bin/sh " + Paths.bin + "/" + promptScript }
    private static var statusCommand: String { "/bin/sh " + Paths.bin + "/" + statusScript }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains { $0["command"] as? String == promptCommand }
    }

    private static func hasPromptHook(_ root: [String: Any]?) -> Bool {
        promptEvents.allSatisfy { event in
            (((root?["hooks"] as? [String: Any])?[event] as? [[String: Any]]) ?? []).contains(where: isOurs)
        }
    }

    private static func addPromptHook(_ root: [String: Any]) -> [String: Any] {
        var r = root
        var hooks = r["hooks"] as? [String: Any] ?? [:]
        for event in promptEvents {
            var list = hooks[event] as? [[String: Any]] ?? []
            guard !list.contains(where: isOurs) else { continue }
            list.append(["hooks": [["type": "command", "command": promptCommand, "timeout": 5]]])
            hooks[event] = list
        }
        r["hooks"] = hooks
        return r
    }

    private static func removePromptHook(_ root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        var r = root
        for event in promptEvents {
            guard let list = hooks[event] as? [[String: Any]] else { continue }
            let kept = list.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        r["hooks"] = hooks
        return r
    }

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// Back up, then write atomically. A file that exists but doesn't parse is never
    /// overwritten (`readJSON` returns nil → callers would start from `[:]`).
    static func writeJSON(_ obj: [String: Any], to path: String) throws {
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions]
        if fm.fileExists(atPath: path) {
            guard readJSON(path) != nil else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
            let bak = path + ".usage-manager.bak"
            try? fm.removeItem(atPath: bak)
            try fm.copyItem(atPath: path, toPath: bak)
        }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if let perms { try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: path) }   // hooks.json is 0600
    }
}
