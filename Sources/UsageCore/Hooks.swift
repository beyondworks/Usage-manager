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

    /// Holds an automatic compaction until the session has written its handover, then
    /// lets it through. The session is told to `touch` the marker when it finishes; the
    /// gate deletes the marker and passes.
    ///
    /// Blocking is only safe because Claude Code treats a blocked *pre-emptive* compaction
    /// as "skip it and carry on uncompacted" — but that headroom is finite, so the gate
    /// gives up after `maxHolds` attempts or `maxHoldSeconds`, whichever comes first, and
    /// lets the compaction proceed. A session that was never alerted (small window, or
    /// alerts off) is never held.
    static let gateScript = "precompact-gate.sh"
    static let maxHolds = 8
    static let maxHoldSeconds = 600

    static let gateBody = """
    #!/bin/sh
    # Usage Manager: hold one automatic compaction until the handover is written.
    \(readSid)
    root="$HOME/.usage-manager"
    [ -n "$sid" ] || exit 0
    # Only hold sessions this app actually asked to press (armed on alert).
    [ -f "$root/armed/$sid" ] || exit 0
    if [ -f "$root/pressed/$sid" ]; then
      rm -f "$root/pressed/$sid" "$root/armed/$sid" "$root/holds/$sid"
      echo "$(date -u +%FT%TZ) $sid pass" >> "$root/gate.log"
      exit 0
    fi
    # Give up rather than let the window fill to a hard limit error.
    mkdir -p "$root/holds"
    n=$(cat "$root/holds/$sid" 2>/dev/null || echo 0)
    first=$(cat "$root/holds/$sid.since" 2>/dev/null || echo "")
    now=$(date +%s)
    [ -n "$first" ] || { first=$now; echo "$first" > "$root/holds/$sid.since"; }
    n=$((n + 1)); echo "$n" > "$root/holds/$sid"
    if [ "$n" -ge \(maxHolds) ] || [ $((now - first)) -ge \(maxHoldSeconds) ]; then
      rm -f "$root/holds/$sid" "$root/holds/$sid.since" "$root/armed/$sid"
      echo "$(date -u +%FT%TZ) $sid give-up after $n holds" >> "$root/gate.log"
      exit 0
    fi
    echo "$(date -u +%FT%TZ) $sid hold $n" >> "$root/gate.log"
    echo "Usage Manager: 핸드오버 갱신(/raw-press)이 끝나지 않아 압축을 잠시 미룹니다." >&2
    exit 2

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
        return Status(claude: status == statusCommand && hasPromptHook(claude) && hasGateHook(claude),
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
            try writeJSON(clearCompactPercent(removeGateHook(removePromptHook(s))), to: claudeSettings)
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
        for d in ["armed", "pressed", "holds"] {   // gate state
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

    static func setCompactPercent(_ root: [String: Any], _ pct: Int) -> [String: Any] {
        var r = root
        var env = r["env"] as? [String: Any] ?? [:]
        env[compactKey] = String(max(1, min(100, pct)))
        r["env"] = env
        return r
    }

    static func clearCompactPercent(_ root: [String: Any]) -> [String: Any] {
        guard var env = root["env"] as? [String: Any], env[compactKey] != nil else { return root }
        var r = root
        env[compactKey] = nil
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

    /// Arm the gate for a session: its next automatic compaction is held until the
    /// handover marker appears. Only sessions the app actually alerted are armed.
    public static func arm(sessionId: String) {
        guard sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
        try? FileManager.default.createDirectory(atPath: Paths.root + "/armed", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Paths.root + "/armed/" + sessionId, contents: nil)
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
