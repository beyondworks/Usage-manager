import Foundation

/// Weekly subscription limit of one tool, read from local files only.
public struct Limit: Sendable, Equatable {
    public let tool: ToolKind
    public let percent: Double
    public let resetsAt: Date?
    public let updatedAt: Date        // when the tool last reported this number
}

/// Live state of one active session, carrying context-window occupancy.
/// (`windowSize == 0` marks a presence-only session with no known window.)
public struct SessionCtx: Sendable, Identifiable, Equatable {
    public var id: String { sessionId }
    public let tool: ToolKind
    public let sessionId: String
    public let project: String
    public let title: String?     // user-set session name (Claude "custom-title"), nil when unnamed
    public let model: String
    public let ctxTokens: Int
    public let windowSize: Int
    public let mtime: Date

    public var usedPercent: Double { windowSize > 0 ? Double(ctxTokens) / Double(windowSize) * 100 : 0 }
    public var hasContext: Bool { windowSize > 0 }
    /// No writes for a while — session is open but resting (shown dimmed, not dropped).
    public var isIdle: Bool { Date().timeIntervalSince(mtime) > 3 * 60 }
    public var shortId: String { String(sessionId.prefix(6)) }

    /// Whether a compaction notice is worth sending. Every Claude Code session counts,
    /// and so does a Codex thread running Kimi (measured window 996k). GPT-model Codex
    /// threads run in a 258k window and compact on their own, so they are left alone.
    /// Codex hosts both, so this keys on the model, not the tool.
    public var wantsCompactionAlert: Bool {
        tool == .claudeCode || model.lowercased().contains("kimi")
    }
    public var label: String { title ?? project }

    /// Claude Code reserves output headroom before measuring occupancy: it compacts at
    /// `min(effective × pct/100, effective − 13000)`, where `effective = window − 20000`
    /// (the reserve is `min(model max output, 20000)`, and every model we alert on is
    /// well above 20k). Measured: 120 past auto-compactions in a 1M window land at a
    /// median of 966,511 tokens, i.e. the `effective − 13000` arm of that formula.
    ///
    /// The app must act *before* this point or the compaction it wants to hold has
    /// already started, so the threshold the user picks is what Claude Code is told,
    /// and these are what the app itself watches.
    var effectiveWindow: Int { max(0, windowSize - 20_000) }
    public func compactionTokens(pct: Int) -> Int {
        min(effectiveWindow * max(1, min(100, pct)) / 100, effectiveWindow - 13_000)
    }
    /// Arm one step earlier, so the notice and the gate's arming both land first.
    public func armTokens(pct: Int) -> Int {
        compactionTokens(pct: pct) - min(30_000, effectiveWindow / 20)
    }
    public init(tool: ToolKind = .claudeCode, sessionId: String, project: String, title: String? = nil,
                model: String, ctxTokens: Int, windowSize: Int, mtime: Date) {
        self.tool = tool; self.sessionId = sessionId; self.project = project; self.title = title
        self.model = model; self.ctxTokens = ctxTokens; self.windowSize = windowSize; self.mtime = mtime
    }
}

public struct LiveSnapshot: Sendable {
    public let tools: [ToolKind]
    public let limits: [ToolKind: Limit]
    public let sessions: [SessionCtx]
}

/// Incremental reader of everything the app shows.
///
/// A full scan (launch, then every `fullEvery`) walks the session trees once to find
/// recently written logs. Between full scans only the paths FSEvents reports are
/// re-read, and a log whose size hasn't changed is never re-parsed — so a busy
/// session costs one 256 KB tail parse per write burst, not a walk of ~7k transcripts.
///
/// Not thread-safe: the caller confines it to one serial queue.
public final class LiveScanner: @unchecked Sendable {
    public let home: String
    public var windowMinutes: Double = 15
    public var defaultWindow = 1_000_000
    private let fullEvery: TimeInterval = 600

    private var recent: [String: Date] = [:]               // session log → mtime, within window
    private var parsed: [String: (size: UInt64, s: SessionCtx?)] = [:]
    private var human: [String: (offset: UInt64, yes: Bool)] = [:]
    private var claudeWeekly: Limit?
    private var codexWeekly: Limit?
    private var lastFull = Date.distantPast

    public init(home: String = Paths.home) { self.home = home }

    private var claudeRoot: String { home + "/.claude/projects" }
    private var codexRoot: String { home + "/.codex/sessions" }

    /// `changed == nil` → rescan what's known (and a full scan when due).
    public func scan(changed: [String]? = nil) -> LiveSnapshot {
        if Date().timeIntervalSince(lastFull) > fullEvery { fullScan() }
        for p in changed ?? [] { touch(p) }
        let cutoff = Date().addingTimeInterval(-windowMinutes * 60)
        var sessions: [SessionCtx] = []
        for (path, _) in recent {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff else {
                recent[path] = nil; parsed[path] = nil; continue
            }
            recent[path] = mtime
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let s: SessionCtx?
            if let hit = parsed[path], hit.size == size { s = hit.s } else { s = read(path); parsed[path] = (size, s) }
            if let s { sessions.append(s.with(mtime: mtime)) }
        }
        human = human.filter { recent[$0.key] != nil }
        var limits: [ToolKind: Limit] = [:]
        limits[.claudeCode] = claudeWeekly
        limits[.codex] = codexWeekly
        let tools = [(ToolKind.claudeCode, "/.claude"), (.codex, "/.codex")]
            .filter { FileManager.default.fileExists(atPath: home + $0.1) }.map { $0.0 }
        return LiveSnapshot(tools: tools, limits: limits, sessions: sessions.sorted { $0.usedPercent > $1.usedPercent })
    }

    // MARK: - Discovery

    private func fullScan() {
        lastFull = Date()
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-windowMinutes * 60)
        for dir in (try? fm.contentsOfDirectory(atPath: claudeRoot)) ?? [] {
            let dpath = claudeRoot + "/" + dir
            for name in (try? fm.contentsOfDirectory(atPath: dpath)) ?? [] where name.hasSuffix(".jsonl") {
                let p = dpath + "/" + name
                if let m = mtime(p), m >= cutoff { recent[p] = m }
            }
        }
        for p in CodexRollout.recentFiles(home: home) { if let m = mtime(p), m >= cutoff { recent[p] = m } }
        codexWeekly = newest(codexWeekly, CodexRollout.newestWeekly(home: home))
        claudeWeekly = newest(claudeWeekly, claudeWeeklyFromSnapshots())
    }

    /// A path FSEvents reported as written.
    private func touch(_ p: String) {
        if p.hasPrefix(Paths.claudeStatus + "/"), p.hasSuffix(".json") {
            claudeWeekly = newest(claudeWeekly, Self.claudeWeekly(snapshot: p))
        } else if p.hasPrefix(claudeRoot + "/"), p.hasSuffix(".jsonl"), !p.contains("/subagents/"),
                  p.dropFirst(claudeRoot.count + 1).split(separator: "/").count == 2 {
            if let m = mtime(p) { recent[p] = m }
        } else if p.hasPrefix(codexRoot + "/"), (p as NSString).lastPathComponent.hasPrefix("rollout-") {
            if let m = mtime(p) { recent[p] = m }
            codexWeekly = newest(codexWeekly, CodexRollout.tail(path: p)?.weekly)
        }
    }

    // MARK: - Weekly limits

    private func newest(_ a: Limit?, _ b: Limit?) -> Limit? {
        guard let a else { return b }
        guard let b else { return a }
        return b.updatedAt >= a.updatedAt ? b : a
    }

    /// Newest snapshot carrying `seven_day`; snapshots older than 8 days are pruned
    /// (one file per Claude session would otherwise accumulate forever).
    private func claudeWeeklyFromSnapshots() -> Limit? {
        let fm = FileManager.default
        let dir = Paths.claudeStatus
        var files: [(String, Date)] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".json") {
            let p = dir + "/" + name
            guard let m = mtime(p) else { continue }
            if Date().timeIntervalSince(m) > 8 * 86400 { try? fm.removeItem(atPath: p); continue }
            files.append((p, m))
        }
        for (p, _) in files.sorted(by: { $0.1 > $1.1 }) { if let l = Self.claudeWeekly(snapshot: p) { return l } }
        return nil
    }

    static func claudeWeekly(snapshot path: String) -> Limit? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let week = (obj["rate_limits"] as? [String: Any])?["seven_day"] as? [String: Any],
              let used = (week["used_percentage"] as? NSNumber)?.doubleValue,
              let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let reset = (week["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Limit(tool: .claudeCode, percent: used, resetsAt: reset, updatedAt: m)
    }

    // MARK: - Sessions

    private func read(_ path: String) -> SessionCtx? {
        if path.hasPrefix(codexRoot) {
            // Spawned subagent threads are skipped: nobody watches them, so an alert isn't actionable.
            guard let meta = CodexRollout.meta(path: path), !meta.isSubagent,
                  let t = CodexRollout.tail(path: path) else { return nil }
            codexWeekly = newest(codexWeekly, t.weekly)
            guard t.ctxTokens > 0 else { return nil }
            return SessionCtx(tool: .codex, sessionId: meta.sessionId, project: Self.projectLabel(meta.cwd),
                              model: t.model, ctxTokens: t.ctxTokens, windowSize: t.window, mtime: .distantPast)
        }
        guard let t = Self.claudeTail(path: path) else { return nil }
        let sid = String((path as NSString).lastPathComponent.dropLast(6))
        guard isHumanAttended(entrypoint: t.entrypoint, path: path) else { return nil }
        return SessionCtx(tool: .claudeCode, sessionId: sid, project: Self.projectLabel(t.cwd), title: t.title,
                          model: t.model, ctxTokens: t.ctxTokens,
                          windowSize: claudeWindow(sid: sid, model: t.model, ctx: t.ctxTokens), mtime: .distantPast)
    }

    /// Only human-attended sessions belong in the list. Transcript `entrypoint`:
    /// `sdk-*` (= `claude -p`) → headless; `cli` / absent → interactive; `claude-desktop`
    /// is written both for the human's session and agents it spawns, so for those we
    /// look for the typed-prompt marker `"origin":{"kind":"human"}`.
    private func isHumanAttended(entrypoint: String?, path: String) -> Bool {
        guard let ep = entrypoint else { return true }
        if ep.hasPrefix("sdk") { return false }
        if ep == "claude-desktop" { return hasHumanPrompt(path: path) }
        return true
    }

    private static let humanMarker = Data(#""origin":{"kind":"human""#.utf8)

    /// Scans forward from where the previous call stopped, 1 MB at a time.
    private func hasHumanPrompt(path: String) -> Bool {
        var st = human[path] ?? (0, false)
        if st.yes { return true }
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let chunkSize = 1 << 20
        let overlap = UInt64(Self.humanMarker.count)
        var offset = st.offset > overlap ? st.offset - overlap : 0
        while true {
            do { try fh.seek(toOffset: offset) } catch { break }
            guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            if chunk.range(of: Self.humanMarker) != nil { st.yes = true; break }
            offset += UInt64(chunk.count)
            if chunk.count < chunkSize { break }
            offset -= overlap
        }
        st.offset = max(st.offset, offset)
        human[path] = st
        return st.yes
    }

    /// Also read by the PreCompact gate, which needs the same two facts (size, and
    /// whether a human is attending) from a transcript it is handed by path.
    public struct ClaudeTail: Sendable {
        public let ctxTokens: Int; public let model: String
        let cwd: String; let title: String?; public let entrypoint: String?
        /// Characters of tool-result text queued since that `usage` was reported — what
        /// the next request will carry on top of it. The gate needs the size of the
        /// request about to go out, not the one that last came back: five parallel reads
        /// can queue 100 KB, which is how a session crosses its limit between two
        /// measurements. Parallel calls are logged as several assistant lines carrying
        /// the *same* usage, so this counts from the first of them, not the last.
        public let trailingChars: Int

        /// Two measured rounds came out at 4.0 and 2.7 characters per token, so no
        /// constant here is accurate — the ratio depends on what the tools returned.
        /// Three sits between them, and the ceiling this feeds is set wide enough that
        /// being wrong by half still errs towards releasing the compaction.
        public var nextRequestTokens: Int { ctxTokens + trailingChars / 3 }
    }

    /// Backward pass over the last 256 KB: latest assistant `usage`, cwd, entrypoint,
    /// and the newest user-set session name.
    public static func claudeTail(path: String) -> ClaudeTail? {
        guard let data = FileTail.read(path: path) else { return nil }
        var cwd = "", title: String?, entrypoint: String?
        var hit: (ctx: Int, model: String)?
        var trailing = 0, queued = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            queued += contentChars(obj)
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if entrypoint == nil, let ep = obj["entrypoint"] as? String { entrypoint = ep }
            if title == nil, obj["type"] as? String == "custom-title",
               let ct = obj["customTitle"] as? String, !ct.isEmpty { title = ct }
            if let msg = obj["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                let ctx = int(u["input_tokens"]) + int(u["cache_read_input_tokens"]) + int(u["cache_creation_input_tokens"])
                if ctx > 0 {
                    // A parallel round is logged as several assistant lines carrying the
                    // same usage, so keep walking back through them: everything between
                    // them is queued for the next request. An older, different usage ends
                    // the round.
                    if let h = hit, ctx != h.ctx { break }
                    hit = (ctx, (msg["model"] as? String) ?? "claude")
                    trailing = queued
                }
            }
        }
        guard let hit else { return nil }
        return ClaudeTail(ctxTokens: hit.ctx, model: hit.model, cwd: cwd, title: title,
                          entrypoint: entrypoint, trailingChars: trailing)
    }

    /// Text carried by one transcript line — tool results and message text. A line that
    /// reports its own `usage` is a response already counted in it, so it contributes
    /// nothing to what the next request adds.
    private static func contentChars(_ obj: [String: Any]) -> Int {
        guard let msg = obj["message"] as? [String: Any], msg["usage"] == nil else { return 0 }
        func chars(_ any: Any?) -> Int {
            if let s = any as? String { return s.count }
            if let list = any as? [Any] { return list.reduce(0) { $0 + chars($1) } }
            if let d = any as? [String: Any] { return chars(d["text"]) + chars(d["content"]) }
            return 0
        }
        return chars(msg["content"])
    }

    /// Context window: statusLine snapshot (authoritative) → `[1m]` model / observed
    /// tokens over 200k → default.
    private func claudeWindow(sid: String, model: String, ctx: Int) -> Int {
        if let data = FileManager.default.contents(atPath: Paths.claudeStatus + "/\(sid).json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cw = obj["context_window"] as? [String: Any], Self.int(cw["context_window_size"]) > 0 {
            return Self.int(cw["context_window_size"])
        }
        if model.contains("[1m]") || ctx > 200_000 { return 1_000_000 }
        return defaultWindow
    }

    private func mtime(_ p: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    private static func projectLabel(_ cwd: String) -> String {
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? (cwd.isEmpty ? "—" : cwd) : base
    }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
}

private extension SessionCtx {
    func with(mtime: Date) -> SessionCtx {
        SessionCtx(tool: tool, sessionId: sessionId, project: project, title: title, model: model,
                   ctxTokens: ctxTokens, windowSize: windowSize, mtime: mtime)
    }
}
