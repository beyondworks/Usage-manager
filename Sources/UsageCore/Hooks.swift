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

    // Hook stdin carries `session_id`; everything else in it is ignored. `plutil` reads
    // the *top-level* key — a PostToolUse payload can carry another session's id nested
    // inside `tool_response` (an MCP session lookup), and a `.*` regex would take that
    // one. The regex stays as a fallback for a payload plutil won't parse.
    private static let readSid = """
    in=$(cat | tr -d '\\n')
    sid=$(printf '%s' "$in" | plutil -extract session_id raw -o - - 2>/dev/null)
    case "$sid" in
      ""|*[!A-Za-z0-9-]*)
        sid=$(printf '%s' "$in" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([A-Za-z0-9-]*\\)".*/\\1/p') ;;
    esac
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
    # A subagent's hooks carry its parent's session_id; the notice is the parent's to
    # receive, so leave it where it is rather than spending it inside a subagent.
    printf '%s' "$in" | plutil -extract agent_id raw -o - - >/dev/null 2>&1 && exit 0
    ev=$(printf '%s' "$in" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\\([A-Za-z]*\\)".*/\\1/p')
    [ -n "$ev" ] || ev=UserPromptSubmit
    f="$HOME/.usage-manager/alerts/$sid.txt"
    [ -n "$sid" ] && [ -f "$f" ] || exit 0
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\\n' "$ev" "$(cat "$f")"
    rm -f "$f"
    # The hold budget starts here, not when the gate first blocked: the agent cannot act
    # on a notice it had not been given, and a user who stepped away for ten minutes
    # would otherwise come back to an expired one.
    h="$HOME/.usage-manager/holds/$sid"
    if [ -f "$h" ]; then
      set -- $(cat "$h")
      [ -n "$3" ] && echo "$1 $(date +%s) $3" > "$h"
    fi
    exit 0

    """

    /// Holds an automatic compaction until the session has written its handover.
    ///
    /// The script is a thin shim: the decision lives in `Gate`, reached through the app
    /// binary's `--gate` mode, so it can parse the transcript with the same reader the
    /// app uses and keep working when the app is not running. A binary that has been
    /// moved or deleted must never block a compaction, hence the executable test.
    static let gateScript = "precompact-gate.sh"

    static var gateBody: String {
        """
        #!/bin/sh
        # Usage Manager: decide, at the moment of the compaction, whether to hold it.
        bin=\(Bundle.main.executablePath.map { "\"" + $0 + "\"" } ?? "")
        [ -n "$bin" ] && [ -x "$bin" ] || exit 0
        exec "$bin" --gate

        """
    }

    // MARK: - State

    public struct Status: Sendable, Equatable {
        public var claude = false
        public init(claude: Bool = false) { self.claude = claude }
    }

    public static func status() -> Status {
        let claude = readJSON(claudeSettings)
        let status = (claude?["statusLine"] as? [String: Any])?["command"] as? String ?? ""
        return Status(claude: status == statusCommand && hasPromptHook(claude) && hasGateHook(claude))
    }

    // MARK: - Install / uninstall

    public static func install(compactAt: Int? = nil) throws {
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
            s = addGateHook(addPromptHook(s))
            if let pct = compactAt { s = setCompactPercent(s, pct) }
            try writeJSON(s, to: claudeSettings)
        }
        try clearCodex()
    }

    /// Codex is no longer a target. Earlier versions installed the prompt hook there
    /// too, so both install and uninstall take it back out — whichever runs first
    /// leaves nothing of ours behind. Our entries were appended last in each event, so
    /// removing them leaves every other hook's index, and the trust keys Codex records
    /// against those indices, untouched.
    private static func clearCodex() throws {
        guard let c = readJSON(codexHooks), hasPromptHook(c) else { return }
        try writeJSON(removePromptHook(c), to: codexHooks)
    }

    public static func uninstall() throws {
        if var s = readJSON(claudeSettings) {
            if var line = s["statusLine"] as? [String: Any], line["command"] as? String == statusCommand {
                let prev = (try? String(contentsOfFile: prevStatusLine, encoding: .utf8)) ?? ""
                if prev.isEmpty { s["statusLine"] = nil } else { line["command"] = prev; s["statusLine"] = line }
            }
            try writeJSON(clearCompactPercent(removeGateHook(removePromptHook(s))), to: claudeSettings)
        }
        try clearCodex()
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
        for d in ["pressed", "holds"] {   // gate state
            try? fm.createDirectory(atPath: Paths.root + "/" + d, withIntermediateDirectories: true)
        }
        for (name, body) in [(statusScript, statusBody), (promptScript, promptBody), (gateScript, gateBody)] {
            let path = Paths.bin + "/" + name
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    // Exact-match identity: other tools' scripts can share our file names (e.g. `ponytail-statusline.sh`).
    private static var promptCommand: String { "/bin/sh " + Paths.bin + "/" + promptScript }
    private static var statusCommand: String { "/bin/sh " + Paths.bin + "/" + statusScript }

    static var gateCommand: String { "/bin/sh " + Paths.bin + "/" + gateScript }

    /// The auto-compaction point, as a share of the context window. Claude Code reads
    /// this when a session starts, so a change lands on the next session.
    private static let compactKey = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
    private static var prevCompactPct: String { Paths.root + "/compactpct.prev" }

    static func setCompactPercent(_ root: [String: Any], _ pct: Int) -> [String: Any] {
        var r = root
        var env = r["env"] as? [String: Any] ?? [:]
        // Record whatever the user had here before the first install, so uninstall can
        // restore it instead of deleting a setting we did not create. An empty file
        // means "there was none".
        if !FileManager.default.fileExists(atPath: prevCompactPct) {
            try? FileManager.default.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            try? (env[compactKey] as? String ?? "").write(toFile: prevCompactPct, atomically: true, encoding: .utf8)
        }
        env[compactKey] = String(max(1, min(100, pct)))
        r["env"] = env
        return r
    }

    static func clearCompactPercent(_ root: [String: Any]) -> [String: Any] {
        guard var env = root["env"] as? [String: Any], env[compactKey] != nil else { return root }
        var r = root
        let prev = (try? String(contentsOfFile: prevCompactPct, encoding: .utf8)) ?? ""
        env[compactKey] = prev.isEmpty ? nil : prev
        try? FileManager.default.removeItem(atPath: prevCompactPct)
        r["env"] = env.isEmpty ? nil : env
        return r
    }

    /// The gate guards *automatic* compactions only; a manual /compact is never held.
    private static func isOurGate(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? []).contains { $0["command"] as? String == gateCommand }
    }

    static func hasGateHook(_ root: [String: Any]?) -> Bool {
        (((root?["hooks"] as? [String: Any])?["PreCompact"] as? [[String: Any]]) ?? []).contains(where: isOurGate)
    }

    static func addGateHook(_ root: [String: Any]) -> [String: Any] {
        guard !hasGateHook(root) else { return root }
        var r = root
        var hooks = r["hooks"] as? [String: Any] ?? [:]
        var list = hooks["PreCompact"] as? [[String: Any]] ?? []
        list.append(["matcher": "auto",
                     "hooks": [["type": "command", "command": gateCommand, "timeout": 10]]])
        hooks["PreCompact"] = list
        r["hooks"] = hooks
        return r
    }

    static func removeGateHook(_ root: [String: Any]) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any],
              let list = hooks["PreCompact"] as? [[String: Any]] else { return root }
        var r = root
        let kept = list.filter { !isOurGate($0) }
        hooks["PreCompact"] = kept.isEmpty ? nil : kept
        r["hooks"] = hooks
        return r
    }

    /// The alerts switch, in a form the gate can read without the app running. Holding
    /// a compaction while alerts are off would block with nothing to explain why.
    public static func setGateEnabled(_ on: Bool) {
        let fm = FileManager.default
        let flag = Paths.root + "/gate-off"
        if on {
            try? fm.removeItem(atPath: flag)
        } else {
            try? fm.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            fm.createFile(atPath: flag, contents: nil)
            for f in (try? fm.contentsOfDirectory(atPath: Paths.root + "/holds")) ?? [] {
                try? fm.removeItem(atPath: Paths.root + "/holds/" + f)
            }
        }
    }

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
