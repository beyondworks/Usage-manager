import Foundation

/// The PreCompact(auto) decision, taken at the moment Claude Code is about to compact.
///
/// Arming this from the app was a race the app could not win. It learns a session's size
/// only after the response reaches the transcript (FSEvents latency, then a scan), while
/// Claude Code decides right after that same response — measured one second apart, with
/// a parallel tool call moving the session 30k tokens in a single step. So the gate no
/// longer asks whether the app armed anything: a PreCompact with `trigger: auto` *is* the
/// signal that this session reached its compaction point.
///
/// It also means the gate covers sessions the app cannot see — a window it guessed wrong,
/// or the app not running at all.
public enum Gate {
    public enum Decision: Equatable {
        case pass(String)
        case hold(String)
    }

    /// Long enough for a handover (session file, vault save, lint, push) and no longer:
    /// the window keeps filling while the compaction waits. The gate is retried on every
    /// tool call, so the count is a backstop and the elapsed time is the real budget.
    static let maxHolds = 40
    static let maxSeconds: Double = 600

    /// Claude Code compacts at least 13k tokens below the hard limit. A session that has
    /// grown by that much since the first hold is therefore at the limit itself, where
    /// holding would produce an error instead of a compaction — including the reactive
    /// compaction that follows such an error, which arrives as `auto` too. Comparing
    /// against the session's own first measurement needs no guess at the window size.
    static let headroom = 13_000

    public static func decide(input: Data, now: Date = Date()) -> Decision {
        let (sid, d) = evaluate(input: input, now: now)
        switch d {
        case .pass(let why): log("\(sid) pass — \(why)")
        case .hold(let why): log("\(sid) \(why)")
        }
        return d
    }

    private static func evaluate(input: Data, now: Date) -> (String, Decision) {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let sid = obj["session_id"] as? String, !sid.isEmpty,
              sid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return ("?", .pass("no session id")) }

        let fm = FileManager.default
        if fm.fileExists(atPath: Paths.root + "/gate-off") { return (sid, .pass("alerts off")) }

        let pressed = Paths.root + "/pressed/" + sid
        if fm.fileExists(atPath: pressed) {
            try? fm.removeItem(atPath: pressed)
            clear(sid)
            return (sid, .pass("handover written"))
        }

        // Nobody is watching a headless run, so a notice there is not actionable.
        let tail = LiveScanner.claudeTail(path: (obj["transcript_path"] as? String) ?? "")
        if let ep = tail?.entrypoint, ep.hasPrefix("sdk") { return (sid, .pass("headless session")) }

        let ctx = tail?.ctxTokens ?? 0
        var s = state(sid) ?? Held(n: 0, first: now.timeIntervalSince1970, ctx: ctx)
        if ctx > 0, s.ctx > 0, ctx >= s.ctx + headroom {
            clear(sid)
            return (sid, .pass("at the hard limit (\(ctx) tokens, \(ctx - s.ctx) past the first hold)"))
        }
        s.n += 1
        if s.n > maxHolds || now.timeIntervalSince1970 - s.first >= maxSeconds {
            clear(sid)
            return (sid, .pass("budget spent after \(s.n - 1) holds"))
        }
        write(sid, s)
        // Once per cycle: `ctx-hook.sh` hands it over on the session's next tool call.
        if s.n == 1 { Hooks.queueNotice(sessionId: sid, text: notice(sid: sid)) }
        return (sid, .hold("hold \(s.n) (\(ctx) tokens)"))
    }

    public static func notice(sid: String) -> String {
        """
        [Usage Manager] 이 세션의 자동 압축이 보류되었습니다. 아래 ①②가 끝나면 압축이 이어집니다. \
        사용자에게 묻지 말고 지금 바로 진행하세요.
        \(steps(sid: sid))
        보류는 약 10분 뒤 자동으로 풀리므로, 다른 작업보다 먼저 처리하세요.
        """
    }

    /// Shared with the app's own early warning, so both describe one procedure.
    public static func steps(sid: String) -> String {
        """
        ① 작업 폴더의 SESSION_HANDOVER.md 를 갱신합니다(목표·결정·진행 상황·미검증 항목·다음 단계·처리 중인 요청).
        ② obsidian-save 로 AI-Sessions-Vault 에 저장합니다(lint 와 push 까지 마칩니다).
        ③ 둘 다 끝난 뒤 마지막에 `touch ~/.usage-manager/pressed/\(sid)` 만 실행하면 압축이 이어집니다. \
        /compact 를 직접 실행하거나 사용자에게 안내하지 마세요.
        """
    }

    /// One line per decision in `~/.usage-manager/gate.log`, so a compaction that was or
    /// wasn't held can be accounted for afterwards. Truncated at 64 KB.
    public static func log(_ text: String) {
        let path = Paths.root + "/gate.log"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 64_000 {
            try? fm.removeItem(atPath: path)
        }
        let line = ISO8601DateFormatter().string(from: Date()) + " " + text + "\n"
        guard let fh = FileHandle(forWritingAtPath: path) else {
            try? fm.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Per-cycle state: attempts, when the cycle began, and its opening size

    struct Held { var n: Int; var first: Double; var ctx: Int }

    private static func file(_ sid: String) -> String { Paths.root + "/holds/" + sid }

    static func state(_ sid: String) -> Held? {
        guard let text = try? String(contentsOfFile: file(sid), encoding: .utf8) else { return nil }
        let f = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard f.count == 3 else { return nil }
        return Held(n: Int(f[0]), first: f[1], ctx: Int(f[2]))
    }

    static func write(_ sid: String, _ s: Held) {
        try? FileManager.default.createDirectory(atPath: Paths.root + "/holds", withIntermediateDirectories: true)
        try? "\(s.n) \(Int(s.first)) \(s.ctx)".write(toFile: file(sid), atomically: true, encoding: .utf8)
    }

    static func clear(_ sid: String) { try? FileManager.default.removeItem(atPath: file(sid)) }
}
