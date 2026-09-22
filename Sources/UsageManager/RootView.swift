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

    /// The bar runs the whole row, so at high occupancy it passes under the badges and
    /// the number on the right and its edge cuts across them. Darkening just behind
    /// those keeps them legible without stopping the bar short, which would make a full
    /// row look unfinished.
    private var shade: some View {
        LinearGradient(colors: [RootView.panel.opacity(0), RootView.panel.opacity(0.78)],
                       startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 6)
            // One shade behind the whole group, not one behind each: the trailing views
            // are a ViewBuilder, so a background applied to them lands on every one.
            HStack(spacing: 10) { trailing }
                .padding(.leading, 14)
                // Reach the row's own edge and full height, so the shade ends where the
                // capsule does instead of leaving a lit rim around it. The negative
                // padding puts the layout back where it was.
                .padding(.trailing, height * 0.36)
                .frame(maxHeight: .infinity)
                .background(shade)
                .padding(.trailing, -height * 0.36)
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
    static let panel = Color(nsColor: panelNS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chip
    @State private var contentHeight: CGFloat = 0
    @State private var scrollY: CGFloat = 0
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
            refreshRing
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

    /// Time to the next automatic lookup, as a ring that empties — and the button that
    /// asks now. A provider already rate-limited is skipped by its own back-off, so
    /// pressing this cannot extend a limit; the ring says so instead of hiding it.
    private var refreshRing: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let wait = model.claudeWait
            let limited = wait > 0
            let left = max(0, model.nextQuotaFetch.timeIntervalSince(ctx.date))
            let ratio = limited ? 1 : min(1, left / AppModel.quotaInterval)
            Button { model.refreshNow() } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.14), lineWidth: 2)
                    Circle().trim(from: 0, to: ratio)
                        .stroke(.white.opacity(limited ? 0.3 : 0.7),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if limited {
                        Image(systemName: "exclamationmark").font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(model.manualReady ? 1 : 0.45)
            .help(limited
                  ? "Claude 조회 제한 — 약 \(Int((wait / 60).rounded()))분 뒤 재시도. 지금 누르면 나머지만 조회합니다"
                  : "다음 조회까지 \(Int((left / 60).rounded()))분 · 눌러서 지금 조회")
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
            // An hour-old number is still shown, but dimmed: it is the age that matters
            // once a provider stops answering, not the number.
            .opacity(Date().timeIntervalSince(q.updatedAt) >= 3600 ? 0.5 : 1)
        }
    }

    /// Sub-line under a provider's weekly gauge: the 5-hour window, reset countdown,
    /// and staleness.
    private func limitNote(_ q: ProviderQuota) -> String {
        var parts: [String] = []
        if let five = q.fiveHourPercent { parts.append("5시간 \(Int((100 - five).rounded()))%") }
        let reset = TimeUtil.resetText(q.resetsAt)
        if !reset.isEmpty { parts.append("리셋 \(reset)") }
        parts.append(TimeUtil.ageText(q.updatedAt))
        return parts.joined(separator: " · ")
    }

    // MARK: Active sessions

    /// Row geometry, shared by the height and the fade so the two cannot drift apart.
    private static let rowHeight: CGFloat = 36
    private static let rowGap: CGFloat = 6
    private static var rowPitch: CGFloat { rowHeight + rowGap }
    private static let visibleRows = 5
    /// How much of the sixth row shows. Enough to read as "there is more below" without
    /// looking like a row that failed to render.
    private static var peek: CGFloat { rowHeight * 0.55 }
    /// Shorter than the peek, so the top of the sixth row is solid before it fades.
    private static let fadeHeight: CGFloat = 14

    private struct ScrollOffset: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    @ViewBuilder private var sessions: some View {
        if model.sessions.isEmpty {
            Text("작업 중인 세션 없음").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 36).background(Self.plate, in: Capsule())
        } else {
            let count = CGFloat(model.sessions.count)
            let content = count * Self.rowPitch - Self.rowGap
            // Past five sessions the list keeps its height and shows part of the next
            // row, so the list itself says there is more rather than a counter saying it.
            let height = model.sessions.count <= Self.visibleRows
                ? content
                : CGFloat(Self.visibleRows) * Self.rowPitch - Self.rowGap + Self.peek
            let atTop = scrollY > -2
            let atBottom = content + scrollY <= height + 2

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Self.rowGap) {
                    ForEach(model.sessions) { s in
                        sessionRow(s).transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ScrollOffset.self,
                                           value: g.frame(in: .named("sessionList")).minY)
                })
            }
            .coordinateSpace(name: "sessionList")
            .onPreferenceChange(ScrollOffset.self) { y in
                withAnimation(.ui) { scrollY = y }
            }
            .frame(height: height)
            // An alpha mask rather than a colour overlay: the rows themselves fade, so
            // it reads the same whatever is behind the panel. Each edge appears only
            // when there is something in that direction.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: atTop ? 0 : Self.fadeHeight)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: atBottom ? 0 : Self.fadeHeight)
                }
            )
            .animation(.ui, value: height)
            .animation(.ui, value: atTop)
            .animation(.ui, value: atBottom)
        }
    }

    private func sessionRow(_ s: SessionCtx) -> some View {
        let over = s.usedPercent >= Double(model.ctxThreshold)
        return GaugeRow(ratio: s.usedPercent / 100, strong: over, height: 36) {
            ToolLogo.view(s.tool, size: 16)
            Text(s.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        } trailing: {
            // Prompt cache: cheap to re-read while it lasts, and the whole context is
            // written again once it lapses. Stood down when there is a louder signal.
            if !s.needsClear(limit: model.compactLimit) { cacheBadge(s) }
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
        .help("\(s.tool.display) · \(s.model) · \(s.ctxTokens.formatted())/\(s.windowSize.formatted()) tokens · 캐시 \(s.cacheTTL == 3600 ? "1시간" : s.cacheTTL == 300 ? "5분" : "?")\(s.cacheLeft.map { $0 > 0 ? " · 남음 \(TimeUtil.shortSpan($0))" : " · 만료" } ?? "") · 압축 \(s.compactions)회\(s.lastPostTokens > 0 ? " (직전 요약 \(s.lastPostTokens.formatted()) 토큰\(s.handoverSaved == true ? ", 핸드오버 저장됨" : s.handoverSaved == false ? ", 핸드오버 없이 압축됨" : ""))" : "") · \(s.shortId)\(s.isIdle ? " · 유휴" : "")")
    }

    /// "캐시 42분" while it holds, "재작성 60만" once it has lapsed — the tokens the next
    /// message would have to write again. Ticks on its own so the number keeps moving
    /// between scans.
    @ViewBuilder private func cacheBadge(_ s: SessionCtx) -> some View {
        if s.cacheLeft != nil, let at = s.lastReplyAt {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remain = max(0, at.addingTimeInterval(s.cacheTTL).timeIntervalSince(ctx.date))
                let quiet = remain > 300
                Text(remain > 0 ? "캐시 \(TimeUtil.shortSpan(remain))" : "재작성 \(TimeUtil.manCount(s.ctxTokens))")
                    .font(.system(size: 10, weight: quiet ? .regular : .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(quiet ? 0.35 : 0.8))
            }
        }
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
        // Claude Code only. Codex threads are still listed and their quota still read,
        // but nothing is written into their prompts and no hook is installed there.
        let connected = model.hooks.claude
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("에이전트 훅", systemImage: "link").font(.system(size: 12, weight: .medium))
                    .help("Claude Code의 statusLine(주간 한도 수집), 프롬프트·도구 호출 훅(압축 알림), 압축 직전 훅(핸드오버 보류)을 설치합니다.")
                Spacer()
                hookChip(.claudeCode, model.hooks.claude)
                pillSwitch(connected) { model.setHooks(!connected) }
            }
            .padding(.horizontal, 14).frame(height: 36)
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
