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

    /// Where holding stops being safe. Claude Code keeps 20k of the window for output,
    /// so a request may grow to about `window - 20000`; past that it fails instead of
    /// compacting — and the reactive compaction that follows such a failure arrives as
    /// `auto` too, so blocking it leaves the session with no way forward at all. It just
    /// stops, and the gate is never called again to release it. Hence this check runs on
    /// the first hold as much as on later ones.
    ///
    /// Bracketed by measurement, in a 200k window (effective 180k): a compaction at
    /// 171,597 tokens succeeded, and a request of 186,464 failed. Replaying both moments
    /// through this estimator gave 166,338 and 182,250 — within 3% of each, and low in
    /// both cases. The 10k step back is twice that error, so a misjudgement releases a
    /// compaction that could have been held rather than blocking one that had to run.
    ///
    /// An earlier version compared against the session's own first measurement, to avoid
    /// guessing the window at all. That was wrong: the gap between the compaction point
    /// and the limit is `effective × (1 - pct)`, not a constant, so at 70% it let go with
    /// 40k still to spare — before the agent had taken a single turn.
    static let outputReserve = 20_000
    static let estimateMargin = 10_000

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

        // A subagent's compaction carries its parent's session_id, so anything this gate
        // did with it — a hold, a notice, the marker — would be spent on the parent's
        // behalf without the parent ever compacting. `agent_id` marks those, and they
        // are left entirely alone: no state touched, nothing cleared.
        if obj["agent_id"] != nil { return (sid, .pass("subagent")) }

        if FileManager.default.fileExists(atPath: Paths.root + "/gate-off") {
            clear(sid); return (sid, .pass("alerts off"))
        }

        // Nobody is watching a headless run, so a notice there is not actionable.
        // One big tool result can fill the usual tail on its own, so when no usage is
        // in reach, look further back before giving up on measuring the session.
        let path = (obj["transcript_path"] as? String) ?? ""
        var tail = LiveScanner.claudeTail(path: path)
        if tail == nil || tail!.ctxTokens == 0 { tail = LiveScanner.claudeTail(path: path, bytes: 8 << 20) }
        if let ep = tail?.entrypoint, ep.hasPrefix("sdk") { clear(sid); return (sid, .pass("headless session")) }

        // No usage in reach means no idea how large this session is, and holding blind
        // is what strands a session: if it is already at its limit, the reactive
        // compaction would be held too, and nothing would call this gate again.
        guard let tail, tail.ctxTokens > 0 else {
            clear(sid); return (sid, .pass("no usage found in the transcript"))
        }

        // The marker only means something inside a cycle this gate opened. Left over
        // from a cycle that ended some other way, it would wave through the next
        // compaction on the strength of the previous one's handover.
        let held = state(sid)
        let pressed = Paths.root + "/pressed/" + sid
        if FileManager.default.fileExists(atPath: pressed) {
            if held != nil { clear(sid); return (sid, .pass("handover written")) }
            try? FileManager.default.removeItem(atPath: pressed)
        }

        // The size of the request about to go out, not the one that last came back.
        let ctx = tail.nextRequestTokens
        let window = windowSize(sid: sid, tail: tail)
        let ceiling = window - outputReserve - estimateMargin
        if ctx >= ceiling {
            clear(sid)
            return (sid, .pass("at the hard limit (\(ctx) tokens, ceiling \(ceiling) in a \(window) window)"))
        }
        var s = held ?? Held(n: 0, first: now.timeIntervalSince1970, ctx: ctx)
        s.n += 1
        if s.n > maxHolds || now.timeIntervalSince1970 - s.first >= maxSeconds {
            clear(sid)
            return (sid, .pass("budget spent after \(s.n - 1) holds"))
        }
        write(sid, s)
        // Once per cycle: `ctx-hook.sh` hands it over on the session's next tool call,
        // and restarts the budget from that moment — the agent cannot act on a notice
        // it has not been given yet.
        if s.n == 1 { Hooks.queueNotice(sessionId: sid, text: notice(sid: sid)) }
        return (sid, .hold("hold \(s.n) (\(ctx) tokens)"))
    }

    /// Context window, best source first:
    /// 1. the statusLine snapshot, which carries the real number;
    /// 2. a model that names its own 1M window;
    /// 3. a session already past 200k, which a 200k window cannot be;
    /// 4. otherwise 200k — the smaller guess, which releases the gate earlier and so
    ///    never leaves a session stuck behind a hold it cannot clear.
    static func windowSize(sid: String, tail: LiveScanner.ClaudeTail?) -> Int {
        if let data = FileManager.default.contents(atPath: Paths.claudeStatus + "/\(sid).json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cw = obj["context_window"] as? [String: Any],
           let size = (cw["context_window_size"] as? NSNumber)?.intValue, size > 0 {
            return size
        }
        if tail?.model.contains("[1m]") == true { return 1_000_000 }
        if (tail?.ctxTokens ?? 0) > 200_000 { return 1_000_000 }
        return 200_000
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
        ③ ②의 push 까지 끝난 것을 확인한 뒤, 마지막으로 `touch ~/.usage-manager/pressed/\(sid)` 를 \
        실행하면 압축이 이어집니다. /compact 를 직접 실행하거나 사용자에게 안내하지 마세요.
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

    /// End the cycle completely. A notice or marker left behind outlives the compaction
    /// it belonged to and is then spent on the next one.
    static func clear(_ sid: String) {
        let fm = FileManager.default
        for p in [file(sid), Paths.root + "/pressed/" + sid, Paths.alerts + "/\(sid).txt"] {
            try? fm.removeItem(atPath: p)
        }
    }
}
