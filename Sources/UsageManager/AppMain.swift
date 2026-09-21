import SwiftUI
import AppKit
import UsageCore

/// The app mark: a white pill with "LLM" in it. As a menu-bar template image the
/// letters are cut out, so macOS tints the pill like every other status icon.
enum PillIcon {
    static func image(height h: CGFloat, template: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: h * 0.62, weight: .heavy)
        let text = NSAttributedString(string: "LLM", attributes: [.font: font, .kern: h * 0.02,
                                                                  .foregroundColor: NSColor.black])
        let ts = text.size()
        let size = NSSize(width: (ts.width + h * 0.9).rounded(), height: h)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            let origin = NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2)
            if template {
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            text.draw(at: origin)
            return true
        }
        img.isTemplate = template
        return img
    }
}

@main
struct UsageManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(live: !CommandLine.arguments.contains { $0.hasPrefix("--") })

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model)
        } label: {
            Image(nsImage: PillIcon.image(height: 16, template: true))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar only (no Dock icon). Command-line modes, all exit when done:
///   `--dump`          print what the app reads (limits + sessions) as text
///   `--hooks on|off`  install / remove the agent hooks (same as the popover checkbox)
///   `--snap out.png`  render the real popover view into a PNG
///   `--arm-check`     report where the app arms the gate vs. where Claude Code compacts
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var snapWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--dump") { dump(); exit(0) }
        if args.contains("--arm-check") { armCheck(); exit(0) }
        if let i = args.firstIndex(of: "--hooks"), i + 1 < args.count {   // --hooks on|off
            do { try args[i + 1] == "on" ? Hooks.install(compactAt: 85) : Hooks.uninstall() } catch { print("error:", error); exit(1) }
            print("hooks:", Hooks.status()); exit(0)
        }
        if let i = args.firstIndex(of: "--snap"), i + 1 < args.count { snap(to: args[i + 1]); return }
        NSApp.appearance = NSAppearance(named: .darkAqua)   // whole window dark, not just the SwiftUI content
        NSApp.setActivationPolicy(.accessory)
    }

    private func dump() {
        let t0 = Date()
        let scanner = LiveScanner()
        let snap = scanner.scan()
        let t1 = Date()
        _ = scanner.scan()   // steady state: nothing changed → cache hits only
        print(String(format: "scan: first %.0f ms, cached %.0f ms", t1.timeIntervalSince(t0) * 1000, Date().timeIntervalSince(t1) * 1000))
        print("tools:", snap.tools.map(\.display))
        let sema = DispatchSemaphore(value: 0)
        var live: [ProviderQuota] = []
        Task {
            live = await OpenCodex.fetchQuotas()
            if let c = await ClaudeUsage.fetch() { live.append(c) }
            sema.signal()
        }
        sema.wait()
        // Same merge the app publishes: file-based fallback (statusLine/rollout) overlaid by opencodex.
        var byId: [String: ProviderQuota] = [:]
        for (tool, l) in snap.limits {
            byId[tool.provider] = ProviderQuota(provider: tool.provider, weeklyPercent: l.percent,
                                                fiveHourPercent: nil, resetsAt: l.resetsAt, updatedAt: l.updatedAt)
        }
        for q in live { byId[q.provider] = q }
        print("claude fetch:", ClaudeUsage.lastDiagnosis)
        for q in ProviderMeta.sorted(Array(byId.values)) {
            print("quota \(ProviderMeta.name(q.provider)) [\(q.provider)]: weekly=\(q.weeklyPercent.map{String(Int($0))} ?? "-")% 5h=\(q.fiveHourPercent.map{String(Int($0))} ?? "-")% resets=\(q.resetsAt.map{"\($0)"} ?? "-")")
        }
        for s in snap.sessions {
            print("session \(s.tool.display) \(s.label) \(Int(s.usedPercent))% \(s.ctxTokens)/\(s.windowSize) \(s.model) idle=\(s.isIdle)")
        }
        print("hooks:", Hooks.status())
    }

    /// Real pixels (glass, vibrancy) need a real window capture: host the view on the
    /// same popover material as the menu-bar window, then `screencapture -l` it.
    /// Walks a synthetic session up through its window and reports the first token
    /// count at which the app actually arms the gate — through `evaluateAlerts`, not a
    /// hand-made marker file. It must land below Claude Code's own compaction point, or
    /// the compaction starts before anything has been armed to hold it.
    /// Nothing should stay held once the app is gone: the gate would keep blocking
    /// compactions with no notice explaining why (a kill leaves the time budget to it).
    func applicationWillTerminate(_ notification: Notification) { Hooks.disarmAll() }

    @MainActor private func armCheck() {
        let d = UserDefaults.standard
        let savedPct = d.object(forKey: "ctxThreshold"), savedOn = d.object(forKey: "alertsOn")
        defer { d.set(savedPct, forKey: "ctxThreshold"); d.set(savedOn, forKey: "alertsOn") }
        var failed = false
        for (window, pct) in [(1_000_000, 80), (1_000_000, 85), (200_000, 85), (100_000, 85)] {
            d.set(pct, forKey: "ctxThreshold"); d.set(true, forKey: "alertsOn")
            let model = AppModel(live: false)   // init reads the defaults; no didSet, so nothing installs
            let sid = "armcheck-\(window)-\(pct)"
            Hooks.disarm(sessionId: sid)
            let probe = SessionCtx(sessionId: sid, project: "arm-check", model: "claude-opus-5",
                                   ctxTokens: 0, windowSize: window, mtime: Date())
            let compactAt = probe.compactionTokens(pct: pct)
            var armedAt = 0, t = window / 4
            while t < window, armedAt == 0 {
                model.sessions = [SessionCtx(sessionId: sid, project: "arm-check", model: "claude-opus-5",
                                             ctxTokens: t, windowSize: window, mtime: Date())]
                model.evaluateAlerts()
                if FileManager.default.fileExists(atPath: Paths.root + "/armed/" + sid) { armedAt = t }
                t += 500
            }
            Hooks.disarm(sessionId: sid)
            let ok = armedAt > 0 && armedAt < compactAt
            if !ok { failed = true }
            print("\(ok ? "OK  " : "FAIL") window \(window) pct \(pct): armed at \(armedAt), claude compacts at \(compactAt)")
        }
        exit(failed ? 1 : 0)
    }

    @MainActor private func snap(to path: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let model = AppModel(live: false)
        if ProcessInfo.processInfo.environment["USAGE_MANAGER_DEMO"] == "1" {
            model.loadDemoData()           // published screenshots carry no real data
        } else {
            model.refresh()
            model.refreshQuotas(force: true)   // snapshots show the same numbers the app does
        }
        let host = NSHostingView(rootView: RootView(model: model))
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.addSubview(host)
        let win = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = fx
        // Capture on a 2x display when one is attached; win.center() alone can land the
        // window on a 1x external screen and halve the screenshot's resolution.
        let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main
        if let f = screen?.frame { win.setFrameOrigin(NSPoint(x: f.midX - 180, y: f.midY - 300)) }
        win.orderFrontRegardless()
        snapWindow = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let size = host.fittingSize
            win.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(win.windowNumber), path]
                try? p.run(); p.waitUntilExit()
                exit(p.terminationStatus)
            }
        }
    }
}
