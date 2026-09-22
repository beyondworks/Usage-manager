import SwiftUI
import AppKit
import UsageCore

/// Tool/provider marks: the official logos as plain white symbols (no app-icon plate);
/// a white letter disc for a provider with no bundled logo.
enum ToolLogo {
    static func view(_ tool: ToolKind, size: CGFloat) -> some View {
        provider(tool.provider, size: size)
    }

    @ViewBuilder static func provider(_ id: String, size: CGFloat) -> some View {
        if let logo = BrandLogos.forProvider(id) {
            Image(nsImage: logo).renderingMode(.template).resizable().interpolation(.high)
                .foregroundStyle(.white).frame(width: size, height: size)
        } else {
            Text(ProviderMeta.name(id).prefix(1))
                .font(.system(size: size * 0.55, weight: .bold, design: .rounded)).foregroundStyle(.black)
                .frame(width: size, height: size).background(.white, in: Circle())
        }
    }
}

extension Animation {
    /// Strong ease-out, under 300 ms — starts fast so every change feels immediate.
    static let ui = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
}

/// Press feedback: the control dips to 97 % while held.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.16), value: configuration.isPressed)
    }
}

/// MenuBarExtra grows its window with the content but never shrinks it back (the
/// content then floats centred between two empty bands). This keeps the window height
/// equal to the measured content height, top edge pinned under the menu bar, and paints
/// the window in the panel colour so nothing lighter shows mid-resize.
private struct WindowFitter: NSViewRepresentable {
    let height: CGFloat
    let animate: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = RootView.panelNS
            guard height > 0 else { return }
            let target = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w.frame.width, height: height)).height
            guard abs(w.frame.height - target) > 0.5 else { return }
            var f = w.frame
            f.origin.y = f.maxY - target
            f.size.height = target
            w.setFrame(f, display: true, animate: animate)
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Monochrome capsule row whose fill *is* the gauge: label left, value right.
/// `strong` (at/over the alert line) brightens the fill instead of adding colour.
private struct GaugeRow<Leading: View, Trailing: View>: View {
    let ratio: Double
    var strong = false
    var height: CGFloat = 44
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, height * 0.36)
        .frame(height: height)
        .background(alignment: .leading) {
            GeometryReader { g in
                Capsule().fill(Color.white.opacity(strong ? 0.42 : 0.2))
                    .frame(width: ratio > 0 ? max(g.size.height, g.size.width * min(1, ratio)) : 0)
                    .animation(.ui, value: ratio)
                    .animation(.ui, value: strong)
            }
        }
        .background(RootView.plate, in: Capsule())
        .clipShape(Capsule())
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    /// Row surface on the dark panel.
    static let plate = Color.white.opacity(0.08)
    static let panelNS = NSColor(white: 0.045, alpha: 1)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chip
    @State private var contentHeight: CGFloat = 0
    private static let thresholds = Array(stride(from: 50, through: 95, by: 5))

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            section("남은 한도") { limits }
            section("활성 세션 \(model.sessions.count)") { sessions }
            section("압축 알림") { alerts }
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(nsColor: Self.panelNS))
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .background(WindowFitter(height: contentHeight, animate: !reduceMotion))
        .animation(.ui, value: model.sessions.map(\.id))
        .animation(.ui, value: model.quotas)
        .animation(.ui, value: model.hooks)
        .transaction { if reduceMotion { $0.animation = nil } }
        .foregroundStyle(.white)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
        .onAppear { model.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: PillIcon.image(height: 20, template: false))
            Text("Usage Manager").font(.system(size: 15, weight: .bold))
            Spacer()
            circleButton(model.launchAtLogin ? "sunrise.fill" : "sunrise", on: model.launchAtLogin,
                         help: model.launchAtLogin ? "로그인 시 자동 실행: 켬" : "로그인 시 자동 실행: 끔") {
                model.setLaunchAtLogin(!model.launchAtLogin)
            }
            circleButton("power", help: "종료") { NSApplication.shared.terminate(nil) }
        }
    }

    private func circleButton(_ symbol: String, on: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background(on ? Color.white : Self.plate, in: Circle())
        }
        .buttonStyle(PressStyle()).help(help)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 6)
            content()
        }
    }

    // MARK: Weekly limits

    @ViewBuilder private var limits: some View {
        if model.quotas.isEmpty {
            Text(model.tools.isEmpty ? "구독 LLM을 찾지 못했습니다" : "한도 읽는 중…")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, minHeight: 36).background(Self.plate, in: Capsule())
        }
        ForEach(model.quotas) { q in
            // Shown as headroom, not consumption: the bar drains as the week is spent,
            // and a nearly empty bar is the warning. `strong` brightens the last fifth,
            // where the remaining budget is small enough to plan around.
            let left = q.weeklyPercent.map { 100 - $0 }
            GaugeRow(ratio: (left ?? 0) / 100, strong: (left ?? 100) <= 20) {
                ToolLogo.provider(q.provider, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ProviderMeta.name(q.provider)).font(.system(size: 13, weight: .semibold))
                    Text(limitNote(q)).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
            } trailing: {
                Text(left.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(left == nil ? 0.4 : 1))
                    .contentTransition(.numericText())
                    .animation(.ui, value: left)
            }
        }
    }

    /// Sub-line under a provider's weekly gauge: the 5-hour window, reset countdown,
    /// and staleness.
    private func limitNote(_ q: ProviderQuota) -> String {
        var parts: [String] = []
        if let five = q.fiveHourPercent { parts.append("5시간 \(Int((100 - five).rounded()))%") }
        let reset = TimeUtil.resetText(q.resetsAt)
        if !reset.isEmpty { parts.append("리셋 \(reset)") }
        let age = Date().timeIntervalSince(q.updatedAt)
        if age > 600 { parts.append(age >= 3600 ? "\(Int(age / 3600))시간 전" : "\(Int(age / 60))분 전") }
        return parts.isEmpty ? "주간 잔량" : parts.joined(separator: " · ")
    }

    // MARK: Active sessions

    @ViewBuilder private var sessions: some View {
        if model.sessions.isEmpty {
            Text("작업 중인 세션 없음").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 36).background(Self.plate, in: Capsule())
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.sessions) { s in
                        sessionRow(s).transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
            }
            .frame(height: min(CGFloat(model.sessions.count), 5) * 42 - 6)
        }
    }

    private func sessionRow(_ s: SessionCtx) -> some View {
        let over = s.usedPercent >= Double(model.ctxThreshold)
        return GaugeRow(ratio: s.usedPercent / 100, strong: over, height: 36) {
            ToolLogo.view(s.tool, size: 16)
            Text(s.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        } trailing: {
            // Compactions so far against the yardstick the user works to. Codex records
            // no compaction, so its rows carry no count.
            if s.needsClear(limit: model.compactLimit) {
                // Which of the two to suggest depends on whether the last compaction had
                // a handover behind it.
                Text(s.handoverSaved == true ? "clear 권장" : s.handoverSaved == false ? "저장 먼저" : "저장 확인")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .transition(.opacity)
            }
            if s.tool == .claudeCode {
                let spent = s.compactions >= model.compactLimit
                Text("\(s.compactions)/\(model.compactLimit)")
                    .font(.system(size: 11, weight: spent ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(spent ? 0.9 : 0.4))
                    .contentTransition(.numericText())
                    .animation(.ui, value: s.compactions)
            }
            Text("\(Int(s.usedPercent))%").font(.system(size: 12, weight: over ? .heavy : .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.ui, value: Int(s.usedPercent))
        }
        .opacity(s.isIdle ? 0.45 : 1)
        .animation(.ui, value: s.isIdle)
        .help("\(s.tool.display) · \(s.model) · \(s.ctxTokens.formatted())/\(s.windowSize.formatted()) tokens · 압축 \(s.compactions)회\(s.lastPostTokens > 0 ? " (직전 요약 \(s.lastPostTokens.formatted()) 토큰\(s.handoverSaved == true ? ", 핸드오버 저장됨" : s.handoverSaved == false ? ", 핸드오버 없이 압축됨" : ""))" : "") · \(s.shortId)\(s.isIdle ? " · 유휴" : "")")
    }

    // MARK: Compaction alerts

    private var alerts: some View {
        VStack(spacing: 6) {
            HStack {
                Label("푸시 알림", systemImage: model.alertsOn ? "bell.fill" : "bell.slash")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                pillSwitch(model.alertsOn) { model.alertsOn.toggle() }
            }
            .padding(.horizontal, 14).frame(height: 36).background(Self.plate, in: Capsule())

            // Threshold picker: one dot per step; the selected one becomes a white chip.
            HStack(spacing: 0) {
                Text("기준").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    .fixedSize().padding(.trailing, 6)
                ForEach(Self.thresholds, id: \.self) { t in
                    Button { withAnimation(.ui) { model.ctxThreshold = t } } label: {
                        ZStack {
                            Circle().fill(Color.white.opacity(t < model.ctxThreshold ? 0.6 : 0.22)).frame(width: 5, height: 5)
                                .opacity(t == model.ctxThreshold ? 0 : 1)
                            if t == model.ctxThreshold {
                                Capsule().fill(.white).frame(width: 32, height: 22)
                                    .matchedGeometryEffect(id: "chip", in: chip)
                                Text("\(t)").font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.black).transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle()).help("\(t)%")
                }
            }
            .padding(.horizontal, 14).frame(height: 36).background(Self.plate, in: Capsule())
            .opacity(model.alertsOn ? 1 : 0.4)
            .animation(.ui, value: model.alertsOn)

            hookRow
        }
    }

    private var hookRow: some View {
        let connected = model.hooks.claude || model.hooks.codex
        let needsTrust = model.hooks.codex && !model.hooks.codexTrusted
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("에이전트 훅", systemImage: "link").font(.system(size: 12, weight: .medium))
                    .help("Claude Code statusLine(주간 한도 수집)과 UserPromptSubmit 훅(Claude Code·Codex)을 설치합니다. 기준을 넘은 세션은 다음 프롬프트에서 에이전트가 압축 권고를 전달받습니다.")
                Spacer()
                hookChip(.claudeCode, model.hooks.claude)
                hookChip(.codex, model.hooks.codex && model.hooks.codexTrusted)
                pillSwitch(connected) { model.setHooks(!connected) }
            }
            .padding(.horizontal, 14).frame(height: 36)
            if needsTrust {
                Text("Codex에서 /hooks 로 Usage Manager 훅을 한 번 신뢰(trust)해 주세요")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            if let e = model.hookError {
                Text(e).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .background(Self.plate, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func hookChip(_ tool: ToolKind, _ on: Bool) -> some View {
        ToolLogo.view(tool, size: 16).opacity(on ? 1 : 0.3)
            .help("\(tool.display) 훅 \(on ? "연결됨" : "미연결 또는 신뢰 대기")")
    }

    /// Black-and-white switch (the system switch would bring the accent colour back).
    private func pillSwitch(_ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Capsule().fill(Color.white.opacity(on ? 1 : 0.18))
                .frame(width: 36, height: 20)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(on ? Color.black : Color.white).frame(width: 14, height: 14).padding(3)
                }
                .animation(.ui, value: on)
        }
        .buttonStyle(PressStyle())
    }
}
