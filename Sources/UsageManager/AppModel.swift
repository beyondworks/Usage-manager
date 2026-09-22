import Foundation
import SwiftUI
import ServiceManagement
import UsageCore

@MainActor
final class AppModel: ObservableObject {
    @Published var tools: [ToolKind] = []
    /// Weekly (and 5-hour) subscription usage, one row per provider. opencodex is the
    /// primary source; the file-based readers fill any provider it doesn't cover.
    @Published var quotas: [ProviderQuota] = []
    @Published var sessions: [SessionCtx] = []

    private var fileLimits: [ToolKind: Limit] = [:]   // statusLine/rollout fallback
    // Kept per provider so one source failing (rate limit, proxy down) leaves the other
    // rows — and that provider's last good value — on screen instead of blanking it.
    private var liveQuotas: [String: ProviderQuota] = [:]
    private var lastQuotaFetch = Date.distantPast
    /// When the next automatic lookup is due, and the guard against hammering the
    /// button. The endpoint rate-limits a caller that asks too often, and the limit it
    /// applies lasts far longer than the time saved by asking early.
    @Published var nextQuotaFetch = Date().addingTimeInterval(quotaInterval)
    private var lastManualFetch = Date.distantPast
    static let quotaInterval: TimeInterval = 300
    static let manualInterval: TimeInterval = 60
    /// Demo snapshots must never be overwritten by a real scan (the view refreshes on
    /// appear), so both refresh paths become no-ops once sample data is loaded.
    private var demo = false
    @Published var hooks = Hooks.Status()
    @Published var hookError: String?
    @Published var launchAtLogin = false

    /// Alert threshold (% of context window) and on/off — persisted across launches.
    @Published var ctxThreshold: Int {
        didSet {
            UserDefaults.standard.set(ctxThreshold, forKey: "ctxThreshold")
            evaluateAlerts()
            // The threshold is also the auto-compaction point, so keep the two in step.
            if hooks.claude { try? Hooks.install(compactAt: ctxThreshold) }
        }
    }
    /// How many compactions a session is expected to last before it is worth starting a
    /// fresh one. Only a yardstick for the count shown on each row — nothing enforces it.
    @Published var compactLimit: Int {
        didSet { UserDefaults.standard.set(compactLimit, forKey: "compactLimit") }
    }
    @Published var alertsOn: Bool {
        didSet {
            UserDefaults.standard.set(alertsOn, forKey: "alertsOn")
            Hooks.setGateEnabled(alertsOn)
        }
    }

    private struct CtxState { var armed = true; var lastNotified = Date.distantPast; var clearPushed = false }
    private var ctxState: [String: CtxState] = [:]

    private var watcher: FileWatcher?
    private var timer: Timer?
    // The scanner keeps per-file caches; one serial queue owns it and orders the scans.
    private let scanner = LiveScanner()
    private let scanQueue = DispatchQueue(label: "usage-manager.scan", qos: .utility)
    private var changed: Set<String> = []
    private var scanPending = false

    init(live: Bool = true) {
        let d = UserDefaults.standard
        ctxThreshold = d.object(forKey: "ctxThreshold") as? Int ?? 80
        alertsOn = d.object(forKey: "alertsOn") as? Bool ?? true
        compactLimit = max(1, d.object(forKey: "compactLimit") as? Int ?? 3)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hooks = Hooks.status()
        // Command-line modes construct this too, and must not touch shared state — the
        // gate's own `--gate` run would otherwise clear the switch it is about to read.
        guard live else { return }
        Hooks.setGateEnabled(alertsOn)
        Notifier.shared.prepare()
        refresh()
        refreshQuotas(force: true)

        // Real time: FSEvents reports written paths (latency 1 s); they are batched
        // and only those files are re-read. The timer catches idle transitions,
        // reset countdowns, and runs the scanner's periodic full scan.
        let home = Paths.home
        try? FileManager.default.createDirectory(atPath: Paths.claudeStatus, withIntermediateDirectories: true)
        // The desktop app's session metadata is watched too, so a rename or a cleared
        // session shows up as soon as it happens rather than at the next full scan.
        watcher = FileWatcher(paths: [home + "/.claude/projects", home + "/.codex/sessions", Paths.claudeStatus]
                                + DesktopSessions.directories(home: home),
                              latency: 1.0) { [weak self] paths in
            MainActor.assumeIsolated { self?.refresh(changed: paths) }
        }
        watcher?.start()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(); self?.refreshQuotas(); self?.hooks = Hooks.status() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Coalesces requests: while a scan runs, new paths accumulate and one follow-up
    /// scan picks them all up.
    func refresh(changed paths: [String] = []) {
        guard !demo else { return }
        changed.formUnion(paths)
        guard !scanPending else { return }
        scanPending = true
        let batch = Array(changed)
        changed.removeAll()
        scanQueue.async { [scanner] in
            let snap = scanner.scan(changed: batch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tools = snap.tools
                    if self.fileLimits != snap.limits { self.fileLimits = snap.limits; self.rebuildQuotas() }
                    if self.sessions != snap.sessions { self.sessions = snap.sessions }
                    self.evaluateAlerts()
                    self.scanPending = false
                    if !self.changed.isEmpty { self.refresh() }
                }
            }
        }
    }

    /// Pull live quotas (throttled to once per 5 min unless forced), then merge. Limits
    /// move slowly, and the usage endpoint rate-limits a caller that asks too often.
    func refreshQuotas(force: Bool = false) {
        guard !demo else { return }
        guard force || Date().timeIntervalSince(lastQuotaFetch) > Self.quotaInterval else { return }
        lastQuotaFetch = Date()
        nextQuotaFetch = lastQuotaFetch.addingTimeInterval(Self.quotaInterval)
        Task.detached(priority: .utility) {
            async let proxy = OpenCodex.fetchQuotas()      // openai, kimi, …
            async let claude = ClaudeUsage.fetch()         // anthropic, from the live session
            let live = await proxy + [await claude].compactMap { $0 }
            let note = "quota fetch — " + (live.isEmpty ? "none" : live.map { "\($0.provider) \(Int($0.weeklyPercent ?? -1))%" }.joined(separator: " "))
                + " · claude: " + ClaudeUsage.lastDiagnosis
            await MainActor.run {
                for q in live { self.liveQuotas[q.provider] = q }   // keep the last good value per provider
                self.rebuildQuotas()
                Self.log(note)
            }
        }
    }

    /// A lookup asked for by hand. Rate-limited providers are skipped by their own
    /// back-off, so this never extends a limit that is already in force.
    func refreshNow() {
        guard Date().timeIntervalSince(lastManualFetch) > Self.manualInterval else { return }
        lastManualFetch = Date()
        refreshQuotas(force: true)
    }

    var manualReady: Bool { Date().timeIntervalSince(lastManualFetch) > Self.manualInterval }

    /// How long Claude's own limit still has to run, if it is in force.
    var claudeWait: TimeInterval {
        max(0, ClaudeUsage.backoffUntil.timeIntervalSinceNow)
    }

    /// Merge the file-based fallback with the live opencodex quotas (live wins per
    /// provider), and publish the ordered rows.
    private func rebuildQuotas() {
        var byId: [String: ProviderQuota] = [:]
        for (tool, l) in fileLimits {
            byId[tool.provider] = ProviderQuota(provider: tool.provider, weeklyPercent: l.percent,
                                                fiveHourPercent: nil, resetsAt: l.resetsAt, updatedAt: l.updatedAt)
        }
        for (id, q) in liveQuotas { byId[id] = q }
        let ordered = ProviderMeta.sorted(Array(byId.values))
        if quotas != ordered { quotas = ordered }
    }

    /// Per session: warn once on approaching the compaction point Claude Code itself
    /// will use, re-arm after a compaction drops the session well below it.
    ///
    /// This is an early warning, not the hold. A session can cross the point between two
    /// scans — a parallel tool call moves it 30k tokens at once — so what actually holds
    /// the compaction is the gate, which decides when Claude Code asks it. Getting the
    /// warning out first only buys the agent time to write the handover before then.
    func evaluateAlerts() {
        let now = Date()
        var pending: [SessionCtx] = []
        for s in sessions where s.hasContext && s.wantsCompactionAlert {
            var st = ctxState[s.sessionId] ?? CtxState()
            let arm = s.armTokens(pct: ctxThreshold)
            if s.ctxTokens >= arm, st.armed, alertsOn {
                st.armed = false
                Hooks.queueNotice(sessionId: s.sessionId, text: notice(for: s))
                if now.timeIntervalSince(st.lastNotified) > 600 { pending.append(s); st.lastNotified = now }
            } else if s.ctxTokens < arm - arm / 10 {
                st.armed = true
            }
            // Compacting again buys little and costs accuracy, so say so once per
            // session. The app only suggests it — clearing is the user's to do.
            if alertsOn, !st.clearPushed, s.needsClear(limit: compactLimit) {
                st.clearPushed = true
                Notifier.shared.fire(
                    title: "\(s.label) 압축 \(s.compactions)회",
                    body: {
                        switch s.handoverSaved {
                        case true: return "핸드오버 저장됨. clear 하거나 새 세션에서 핸드오버 문서와 옵시디언을 참조해 이어 가세요."
                        case false: return "핸드오버 없이 압축되었습니다. /raw-press 로 먼저 저장한 뒤 clear 하세요."
                        default: return "핸드오버 저장 여부를 알 수 없습니다. 확인한 뒤 clear 하세요."
                        }
                    }(),
                    id: "clear-\(s.sessionId)")
            }
            ctxState[s.sessionId] = st
        }
        let active = Set(sessions.map(\.sessionId))
        ctxState = ctxState.filter { active.contains($0.key) }
        guard !pending.isEmpty else { return }

        // The push tells the user what is already happening; the agent has been told to
        // write the handover, and the compaction resumes by itself once it has.
        if pending.count > 3 {
            let list = pending.prefix(6).map { "\($0.label) \(Int($0.usedPercent))%" }.joined(separator: ", ")
            Notifier.shared.fire(title: "\(pending.count)개 세션이 압축 직전입니다",
                                 body: "\(list) · 핸드오버 저장 후 자동 압축", id: "ctx-summary")
        } else {
            for s in pending {
                Notifier.shared.fire(title: "압축 직전 \(Int(s.usedPercent))% · \(s.label)",
                                     body: "\(s.tool.display) · 핸드오버 저장 후 자동 압축", id: "ctx-\(s.sessionId)")
            }
        }
    }

    /// What the agent is told ahead of time. Deliberately non-interactive: a step that
    /// asks the user anything, or hands the work back with "run /compact yourself", lets
    /// the turn end before the marker is written. Same procedure the gate states, so the
    /// agent reads one set of instructions whichever arrives first.
    private func notice(for s: SessionCtx) -> String {
        """
        [Usage Manager] 이 세션은 곧 자동 압축 지점(약 \(s.compactionTokens(pct: ctxThreshold) / 1000)k 토큰)에 닿습니다. \
        그 지점에서 압축은 아래 ①②가 끝날 때까지 보류됩니다. 지금 미리 해 두면 기다림 없이 이어집니다. \
        사용자에게 묻지 말고 진행하세요.
        \(Gate.steps(sid: s.sessionId))
        """
    }

    /// Fixed sample data for the README screenshot, so a published image never carries
    /// real account numbers or session names. Used only by `--snap` under
    /// USAGE_MANAGER_DEMO=1.
    func loadDemoData() {
        demo = true
        let now = Date()
        quotas = [
            ProviderQuota(provider: "anthropic", weeklyPercent: 38, fiveHourPercent: 21,
                          resetsAt: now.addingTimeInterval(4.2 * 86400), updatedAt: now),
            ProviderQuota(provider: "openai", weeklyPercent: 86, fiveHourPercent: nil,
                          resetsAt: now.addingTimeInterval(2.5 * 86400), updatedAt: now.addingTimeInterval(-180)),
            ProviderQuota(provider: "kimi", weeklyPercent: 64, fiveHourPercent: 55,
                          resetsAt: now.addingTimeInterval(5.1 * 86400), updatedAt: now),
        ]
        sessions = [
            SessionCtx(tool: .claudeCode, sessionId: "demo01", project: "storefront",
                       title: "결제 리팩터링", model: "claude-opus-5",
                       ctxTokens: 871_000, windowSize: 1_000_000, mtime: now, compactions: 3,
                       lastPostTokens: 38_000, handoverSaved: true,
                       cacheTTL: 3600, lastReplyAt: now.addingTimeInterval(-120), titleSource: "meta"),
            SessionCtx(tool: .claudeCode, sessionId: "demo02", project: "api-gateway",
                       title: "검색 색인 재구축", model: "claude-opus-5",
                       ctxTokens: 486_000, windowSize: 1_000_000, mtime: now, compactions: 1,
                       lastPostTokens: 31_000, handoverSaved: nil,
                       cacheTTL: 3600, lastReplyAt: now.addingTimeInterval(-3480), titleSource: "meta"),
            SessionCtx(tool: .codex, sessionId: "demo03", project: "infra",
                       model: "kimi/k3[1m]", ctxTokens: 274_000, windowSize: 996_147, mtime: now),
            SessionCtx(tool: .claudeCode, sessionId: "demo04", project: "docs",
                       title: "온보딩 문서", model: "claude-opus-5",
                       ctxTokens: 132_000, windowSize: 1_000_000, mtime: now.addingTimeInterval(-400),
                       cacheTTL: 3600, lastReplyAt: now.addingTimeInterval(-400), titleSource: "meta"),
        ]
        tools = [.claudeCode, .codex]
        hooks = Hooks.Status(claude: true)
    }

    /// One line per limit lookup in `~/.usage-manager/usage.log`, so the poll interval
    /// and any rate-limit back-off can be checked after the fact. Truncated at 64 KB.
    static func log(_ text: String) {
        let path = Paths.root + "/usage.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(text)\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 64_000 {
            try? fm.removeItem(atPath: path)
        }
        guard let fh = FileHandle(forWritingAtPath: path) else {
            try? fm.createDirectory(atPath: Paths.root, withIntermediateDirectories: true)
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
    }

    func setHooks(_ on: Bool) {
        do {
            if on { try Hooks.install(compactAt: ctxThreshold) } else { try Hooks.uninstall() }
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        hooks = Hooks.status()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
