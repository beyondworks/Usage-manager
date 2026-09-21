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
    @Published var alertsOn: Bool { didSet { UserDefaults.standard.set(alertsOn, forKey: "alertsOn") } }

    private struct CtxState { var armed = true; var lastNotified = Date.distantPast }
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
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hooks = Hooks.status()
        guard live else { return }
        Notifier.shared.prepare()
        refresh()
        refreshQuotas(force: true)

        // Real time: FSEvents reports written paths (latency 1 s); they are batched
        // and only those files are re-read. The timer catches idle transitions,
        // reset countdowns, and runs the scanner's periodic full scan.
        let home = Paths.home
        try? FileManager.default.createDirectory(atPath: Paths.claudeStatus, withIntermediateDirectories: true)
        watcher = FileWatcher(paths: [home + "/.claude/projects", home + "/.codex/sessions", Paths.claudeStatus],
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
        guard force || Date().timeIntervalSince(lastQuotaFetch) > 300 else { return }
        lastQuotaFetch = Date()
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

    /// Per session: fire once when crossing the threshold, re-arm after it drops
    /// 10 points below (i.e. after a compaction), at most once per 10 minutes.
    private func evaluateAlerts() {
        let now = Date()
        var pending: [SessionCtx] = []
        for s in sessions where s.hasContext && s.wantsCompactionAlert {
            var st = ctxState[s.sessionId] ?? CtxState()
            if s.usedPercent >= Double(ctxThreshold) {
                if alertsOn, st.armed, now.timeIntervalSince(st.lastNotified) > 600 {
                    pending.append(s); st.armed = false; st.lastNotified = now
                }
            } else if s.usedPercent < Double(ctxThreshold) - 10 {
                st.armed = true
            }
            ctxState[s.sessionId] = st
        }
        let active = Set(sessions.map(\.sessionId))
        ctxState = ctxState.filter { active.contains($0.key) }
        guard !pending.isEmpty else { return }

        for s in pending {
            // Arm first: the gate holds this session's automatic compaction until the
            // marker below appears, so the handover is never overtaken by a compaction.
            if s.tool == .claudeCode { Hooks.arm(sessionId: s.sessionId) }
            Hooks.queueNotice(sessionId: s.sessionId, text: """
                [Usage Manager] 이 세션의 컨텍스트가 \(Int(s.usedPercent))%로 기준(\(ctxThreshold)%)을 넘었습니다. \
                자동 압축은 아래 절차가 끝날 때까지 보류됩니다. 진행 중인 작업 단위를 마무리한 뒤 \
                /raw-press 스킬로 핸드오버 문서와 옵시디언을 갱신하고, 끝나면 바로 \
                `touch ~/.usage-manager/pressed/\(s.sessionId)` 를 실행하세요. \
                그 순간부터 압축이 진행됩니다. 오래 미루면 보류가 자동 해제되니 먼저 처리하세요.
                """)
        }
        if pending.count > 3 {
            let list = pending.prefix(6).map { "\($0.label) \(Int($0.usedPercent))%" }.joined(separator: ", ")
            Notifier.shared.fire(title: "\(pending.count)개 세션 컨텍스트 \(ctxThreshold)% 초과",
                                 body: "\(list) · /compact 권장", id: "ctx-summary")
        } else {
            for s in pending {
                Notifier.shared.fire(title: "컨텍스트 \(Int(s.usedPercent))% · \(s.label)",
                                     body: "\(s.tool.display) · /compact 권장", id: "ctx-\(s.sessionId)")
            }
        }
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
                          resetsAt: now.addingTimeInterval(2.5 * 86400), updatedAt: now),
            ProviderQuota(provider: "kimi", weeklyPercent: 64, fiveHourPercent: 55,
                          resetsAt: now.addingTimeInterval(5.1 * 86400), updatedAt: now),
        ]
        sessions = [
            SessionCtx(tool: .claudeCode, sessionId: "demo01", project: "storefront",
                       title: "결제 리팩터링", model: "claude-opus-5",
                       ctxTokens: 871_000, windowSize: 1_000_000, mtime: now),
            SessionCtx(tool: .claudeCode, sessionId: "demo02", project: "api-gateway",
                       model: "claude-opus-5", ctxTokens: 486_000, windowSize: 1_000_000, mtime: now),
            SessionCtx(tool: .codex, sessionId: "demo03", project: "infra",
                       model: "kimi/k3[1m]", ctxTokens: 274_000, windowSize: 996_147, mtime: now),
            SessionCtx(tool: .claudeCode, sessionId: "demo04", project: "docs",
                       title: "온보딩 문서", model: "claude-opus-5",
                       ctxTokens: 132_000, windowSize: 1_000_000, mtime: now.addingTimeInterval(-400)),
        ]
        tools = [.claudeCode, .codex]
        hooks = Hooks.Status(claude: true, codex: true, codexTrusted: true)
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
