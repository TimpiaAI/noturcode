import AppKit
import SwiftUI
import NoturcodeCore
import UniformTypeIdentifiers

@MainActor
private final class PointingHandCursorCoordinator {
    static let shared = PointingHandCursorCoordinator()

    private var activeRegions: Set<UUID> = []
    private var eventMonitor: Any?
    private var cursorIsPushed = false

    func setActive(_ active: Bool, regionID: UUID) {
        let wasActive = !activeRegions.isEmpty
        if active {
            activeRegions.insert(regionID)
            installMonitorIfNeeded()
        } else {
            activeRegions.remove(regionID)
            if activeRegions.isEmpty {
                removeMonitor()
            }
        }
        let isActive = !activeRegions.isEmpty
        if !wasActive && isActive {
            NSCursor.pointingHand.push()
            cursorIsPushed = true
        } else if wasActive && !isActive {
            restoreCursor()
        } else if isActive {
            scheduleCursorRefresh()
        }
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.cursorUpdate, .mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.scheduleCursorRefresh()
            return event
        }
    }

    private func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func restoreCursor() {
        guard cursorIsPushed else { return }
        NSCursor.pop()
        cursorIsPushed = false
    }

    private func scheduleCursorRefresh() {
        // Local monitors run before AppKit applies the window cursor rect.
        // Apply on the next main-loop turn so the clickable cursor wins.
        DispatchQueue.main.async { [weak self] in
            self?.applyCursor()
        }
    }

    func refreshPointingHandIfActive() {
        guard !activeRegions.isEmpty else { return }
        scheduleCursorRefresh()
    }

    private func applyCursor() {
        if !activeRegions.isEmpty {
            NSCursor.pointingHand.set()
        }
    }
}

private final class PointingHandCursorRegionView: NSView {
    private var cursorTrackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let clippedBounds = bounds.intersection(visibleRect)
        if !clippedBounds.isEmpty {
            addCursorRect(clippedBounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        PointingHandCursorCoordinator.shared.refreshPointingHandIfActive()
    }

    override func mouseMoved(with event: NSEvent) {
        PointingHandCursorCoordinator.shared.refreshPointingHandIfActive()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // NSWindow invalidation waits for a key-window transition. The notch
        // panel is non-activating, so rebuild after SwiftUI inserts this view.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            window.enableCursorRects()
            window.resetCursorRects()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let window else { return }
        window.enableCursorRects()
        window.resetCursorRects()
    }
}

private struct PointingHandCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> PointingHandCursorRegionView {
        PointingHandCursorRegionView(frame: .zero)
    }

    func updateNSView(_ nsView: PointingHandCursorRegionView, context: Context) {}
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var regionID = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(PointingHandCursorRegion())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    PointingHandCursorCoordinator.shared.setActive(true, regionID: regionID)
                case .ended:
                    PointingHandCursorCoordinator.shared.setActive(false, regionID: regionID)
                }
            }
            .onDisappear {
                PointingHandCursorCoordinator.shared.setActive(false, regionID: regionID)
            }
    }
}

extension View {
    func clickableCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

struct NoturcodeBrandMark: View {
    let size: CGFloat

    private var appIcon: NSImage {
        NSApplication.shared.applicationIconImage
    }

    var body: some View {
        Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum TerminalViewportPresentation {
    case floating
    case desktop
}

struct SessionMarble: View {
    let name: String
    let state: SessionState
    let source: AgentSource?
    let size: CGFloat
    let animate: Bool
    let completionIsUnread: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: TrackedSession, size: CGFloat, animate: Bool, completionIsUnread: Bool? = nil) {
        name = session.name
        state = session.state
        source = session.key.source
        self.size = size
        self.animate = animate
        self.completionIsUnread = completionIsUnread
    }

    init(name: String, state: SessionState, source: AgentSource?, size: CGFloat, animate: Bool, completionIsUnread: Bool? = nil) {
        self.name = name
        self.state = state
        self.source = source
        self.size = size
        self.animate = animate
        self.completionIsUnread = completionIsUnread
    }

    private var identity: AvatarIdentity { AvatarIdentity(name: name) }

    private var animatesAttention: Bool {
        animate && !reduceMotion && state == .askingYou
    }

    private var orbMotion: ColoredThinkingOrb.Motion {
        switch state {
        case .working, .askingYou: .composing
        case .done: .breathing
        case .failed, .idle: .breathing
        }
    }

    private var animatesOrb: Bool {
        !reduceMotion
            && animate
            && size >= 12
            && (state == .working || state == .askingYou || state == .done)
    }

    var body: some View {
        ZStack {
            ColoredThinkingOrb(
                motion: orbMotion,
                size: size,
                primaryHue: identity.hue,
                secondaryHue: identity.secondaryHue,
                saturation: identity.saturation,
                isAnimated: animatesOrb
            )

            if animatesAttention {
                AskingAttentionRing(size: size, isAnimated: true)
                    .padding(-2.5)
            } else if state == .working {
                WorkingSpinnerRing(size: size, isAnimated: !reduceMotion)
                    .padding(-2.2)
                    .accessibilityHidden(true)
            } else {
                stateRing(time: 0)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: completionIsUnread)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(source?.displayName ?? "session"), \(state.displayName)")
    }

    @ViewBuilder
    private func stateRing(time: TimeInterval) -> some View {
        switch state {
        case .working:
            ZStack {
                Circle().stroke(.white.opacity(0.20), lineWidth: max(1, size * 0.065))
                Circle()
                    .trim(from: 0, to: 0.16)
                    .stroke(.white.opacity(0.98), style: StrokeStyle(lineWidth: max(1.1, size * 0.075), lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(-2.2)
        case .askingYou:
            let phase = reduceMotion ? 1.0 : (sin(time * 4.8) + 1) / 2
            Circle()
                .stroke(.white.opacity(0.42 + phase * 0.55), lineWidth: max(1.3, size * 0.09))
            .padding(-2.5)
        case .done:
            Circle()
                .stroke(
                    completionIsUnread == true
                        ? Color(red: 0.60, green: 1.0, blue: 0.22)
                        : .white.opacity(completionIsUnread == false ? 0.30 : 0.88),
                    lineWidth: max(1.15, size * 0.075)
                )
                .padding(-2.1)
        case .failed:
            Circle()
                .stroke(.white.opacity(0.78), style: StrokeStyle(lineWidth: max(1.1, size * 0.07), lineCap: .round, dash: [2.2, 2.4]))
                .padding(-2.1)
        case .idle:
            Circle()
                .stroke(.white.opacity(0.24), lineWidth: 1)
                .padding(-1.8)
        }
    }
}

private struct AskingAttentionRing: NSViewRepresentable {
    let size: CGFloat
    let isAnimated: Bool

    func makeNSView(context: Context) -> AskingAttentionRingView {
        AskingAttentionRingView()
    }

    func updateNSView(_ view: AskingAttentionRingView, context: Context) {
        view.configure(size: size, animated: isAnimated)
    }

    static func dismantleNSView(_ view: AskingAttentionRingView, coordinator: ()) {
        view.stopAnimating()
    }
}

private final class AskingAttentionRingView: NSView {
    private let ringLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        layer?.addSublayer(ringLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let lineWidth = ringLayer.lineWidth
        ringLayer.frame = bounds
        ringLayer.path = CGPath(
            ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            transform: nil
        )
    }

    func configure(size: CGFloat, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.lineWidth = max(1.3, size * 0.09)
        CATransaction.commit()
        needsLayout = true
        animated ? startAnimating() : stopAnimating()
    }

    private func startAnimating() {
        guard ringLayer.animation(forKey: "noturcode.asking-pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.42
        pulse.toValue = 0.97
        pulse.duration = 0.66
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ringLayer.add(pulse, forKey: "noturcode.asking-pulse")
    }

    func stopAnimating() {
        ringLayer.removeAnimation(forKey: "noturcode.asking-pulse")
        ringLayer.opacity = 0.95
    }
}

private struct WorkingSpinnerRing: NSViewRepresentable {
    let size: CGFloat
    let isAnimated: Bool

    func makeNSView(context: Context) -> WorkingSpinnerRingView {
        WorkingSpinnerRingView()
    }

    func updateNSView(_ view: WorkingSpinnerRingView, context: Context) {
        view.configure(size: size, animated: isAnimated)
    }

    static func dismantleNSView(_ view: WorkingSpinnerRingView, coordinator: ()) {
        view.stopAnimating()
    }
}

private final class WorkingSpinnerRingView: NSView {
    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(arcLayer)
        trackLayer.fillColor = NSColor.clear.cgColor
        trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.20).cgColor
        arcLayer.fillColor = NSColor.clear.cgColor
        arcLayer.strokeColor = NSColor.white.withAlphaComponent(0.98).cgColor
        arcLayer.lineCap = .round
        arcLayer.strokeStart = 0
        arcLayer.strokeEnd = 0.16
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updatePaths()
    }

    func configure(size: CGFloat, animated: Bool) {
        let lineWidth = max(1.1, size * 0.075)
        trackLayer.lineWidth = max(1, size * 0.065)
        arcLayer.lineWidth = lineWidth
        updatePaths()
        animated ? startAnimating() : stopAnimating()
    }

    private func updatePaths() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        arcLayer.frame = bounds
        let inset = max(trackLayer.lineWidth, arcLayer.lineWidth) / 2
        let path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        trackLayer.path = path
        arcLayer.path = path
        CATransaction.commit()
    }

    private func startAnimating() {
        guard arcLayer.animation(forKey: "noturcode.rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = -Double.pi / 2
        // AppKit's flipped view coordinates make decreasing Z rotation read
        // clockwise on screen. Keep a full negative turn to avoid reversal.
        rotation.toValue = -Double.pi * 5 / 2
        rotation.duration = 1.05
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        arcLayer.add(rotation, forKey: "noturcode.rotation")
    }

    func stopAnimating() {
        arcLayer.removeAnimation(forKey: "noturcode.rotation")
    }
}

struct ProviderMark: View {
    let source: AgentSource
    let size: CGFloat

    private var assetName: String {
        switch source {
        case .claude: "ClaudeMark"
        case .codex: "CodexMark"
        case .gemini: "GeminiMark"
        case .opencode: "HarnessMark"
        case .grok: "GrokMark"
        case .harness: "HarnessMark"
        }
    }

    private var isMulticolor: Bool {
        source == .claude || source == .harness
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .renderingMode(isMulticolor ? .original : .template)
            .foregroundStyle(.white.opacity(0.95))
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.34), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

struct ExpandedSessionList: View {
    let sessions: [TrackedSession]
    let staleMessage: String?
    let model: AppModel
    @ObservedObject var state: NotchPresentationState
    @ObservedObject private var completionReads: CompletionReadStore

    init(sessions: [TrackedSession], staleMessage: String?, model: AppModel, state: NotchPresentationState) {
        self.sessions = sessions
        self.staleMessage = staleMessage
        self.model = model
        self.state = state
        _completionReads = ObservedObject(wrappedValue: model.completionReads)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(sessions) { session in
                            SessionRow(
                                session: session,
                                now: .now,
                                isHovered: state.hoveredSessionID == session.id,
                                isPressed: state.pressedSessionID == session.id,
                                isUnreadFinished: completionReads.isUnread(session),
                                onHover: { hovering in
                                    state.setHoveredSession(hovering ? session.id : nil)
                                },
                                onViewTerminal: {
                                    model.showTerminalWindow(for: session)
                                },
                                onDisconnect: {
                                    model.disconnectFromNoturcode(session)
                                },
                                onSelect: {
                                    state.select(session) {
                                        model.jump(to: session)
                                    }
                                }
                            )
                            if session.id != sessions.last?.id {
                                Rectangle()
                                    .fill(.white.opacity(0.07))
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 15)
                            }
                        }
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            .mask {
                if sessions.count > 4 {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.045),
                            .init(color: .black, location: 0.90),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Rectangle().fill(.black)
                }
            }

            if let staleMessage {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                    Text(staleMessage).lineLimit(2)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 15)
                .padding(.top, 9)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Noturcode sessions")
        .onAppear {
            if state.isUITestSpotlight, state.hoveredSessionID == nil, let first = sessions.first {
                state.setHoveredSession(first.id)
            }
        }
        .task(id: sessions.map(\.id)) {
            guard state.isUITestRapidHover, sessions.count >= 2 else { return }
            try? await Task.sleep(for: .milliseconds(2500))
            let first = sessions[0].id
            let second = sessions[1].id
            for id in [first, second, first, second] {
                state.setHoveredSession(id)
                try? await Task.sleep(for: .milliseconds(28))
                if id != second { state.setHoveredSession(nil) }
            }
        }
    }

}

private struct DoneSummaryPreview: View {
    let session: TrackedSession
    let done: String
    let needs: String

    @State private var isPresented = false
    @State private var isAnchorHovered = false
    @State private var isPopoverHovered = false

    private var doneBody: String { value(after: "Done:", in: done) }
    private var needsBody: String { value(after: "Needs you:", in: needs) }
    private var completionMap: String? { NoturcodeSummaryContract.completionMap(in: session.lastAgentMessage) }
    private var completionMapWidth: CGFloat {
        guard let completionMap else { return 322 }
        let longestLine = completionMap.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0
        let contentWidth = CGFloat(longestLine) * 6.7 + 48
        let screenLimit = max(322, (NSScreen.main?.visibleFrame.width ?? 900) - 80)
        return min(screenLimit, max(322, contentWidth))
    }

    var body: some View {
        Text(done)
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(2, reservesSpace: true)
            .contentShape(Rectangle())
            .onHover { hovering in
                isAnchorHovered = hovering
                if hovering { isPresented = true } else { scheduleDismissal() }
            }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                popoverContent
                    .onHover { hovering in
                        isPopoverHovered = hovering
                        if !hovering { scheduleDismissal() }
                    }
            }
            .accessibilityIdentifier("done-summary-\(session.id)")
            .accessibilityHint("Hover to see the complete response summary and its steps")
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.78))
                Text("THIS RESPONSE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.42))
                Spacer(minLength: 0)
                Text(session.key.source.displayName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.36))
            }

            Text(markdown(doneBody))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.90))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if let completionMap {
                Text(completionMap)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 0.7)
                }
                .accessibilityLabel("Completion map")
                .accessibilityIdentifier("done-summary-ascii-map-\(session.id)")
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("NEEDS YOU")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.30))
                Text(markdown(needsBody))
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(14)
        .frame(width: completionMapWidth, alignment: .leading)
        .background(Color(red: 0.055, green: 0.061, blue: 0.072))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("done-summary-popover-\(session.id)")
    }

    private func value(after prefix: String, in value: String) -> String {
        guard value.lowercased().hasPrefix(prefix.lowercased()) else { return value }
        return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func markdown(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .full))) ?? AttributedString(value)
    }

    private func scheduleDismissal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !isAnchorHovered, !isPopoverHovered else { return }
            isPresented = false
        }
    }
}

private struct SessionRow: View {
    let session: TrackedSession
    let now: Date
    let isHovered: Bool
    let isPressed: Bool
    let isUnreadFinished: Bool
    let onHover: (Bool) -> Void
    let onViewTerminal: () -> Void
    let onDisconnect: () -> Void
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var subject: String {
        if session.state == .working {
            if let activity = session.currentActivity?.trimmingCharacters(in: .whitespacesAndNewlines),
               !activity.isEmpty {
                return activity
            }
            return "Working on the current prompt"
        }
        if let message = session.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message.replacingOccurrences(of: "\n", with: " ")
        }
        if let cwd = session.cwd {
            return "Connected in \(URL(fileURLWithPath: cwd).lastPathComponent)"
        }
        return "Connected session"
    }

    private var accessibilityDescription: String {
        var parts = [
            session.name,
            session.key.source.displayName,
            session.state.displayName,
            DurationFormatting.compact(from: session.stateChangedAt, to: now),
            subject
        ]
        if let activity = session.currentActivity { parts.append(activity) }
        if !session.activeSubagents.isEmpty { parts.append("\(session.activeSubagents.count) active agents") }
        return parts.joined(separator: ", ")
    }

    private var structuredSummary: (done: String, needs: String)? {
        guard session.state.showsCompletionSummary else { return nil }
        guard NoturcodeSummaryContract.isDisplayable(session.lastAgentMessage) else { return nil }
        let lines = session.lastAgentMessage?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        guard let done = lines.first(where: { $0.lowercased().hasPrefix("done:") }),
              let needs = lines.first(where: { $0.lowercased().hasPrefix("needs you:") }) else { return nil }
        return (done, needs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    SessionMarble(session: session, size: 22, animate: isHovered)
                    HStack(spacing: 5) {
                        if session.key.source != .codex {
                            ProviderMark(source: session.key.source, size: 13)
                        }
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 6)
                    if !session.activeSubagents.isEmpty {
                        Text("\(session.activeSubagents.count) agent\(session.activeSubagents.count == 1 ? "" : "s")")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(session.state.displayName) · \(DurationFormatting.relative(from: session.stateChangedAt, to: context.date))")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(session.state.needsAttention ? 0.9 : 0.58))
                            .lineLimit(1)
                    }
                }

                if let summary = structuredSummary {
                    VStack(alignment: .leading, spacing: 2) {
                        DoneSummaryPreview(
                            session: session,
                            done: summary.done,
                            needs: summary.needs
                        )
                        Text(summary.needs)
                            .foregroundStyle(.white.opacity(0.56))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .regular))
                    .padding(.leading, 31)
                    .contentTransition(.opacity)
                } else {
                    Text("“\(subject)”")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .padding(.leading, 31)
                        .contentTransition(.opacity)
                }

                HStack(spacing: 7) {
                    if let activity = session.currentActivity {
                        HStack(spacing: 5) {
                            Text(activity)
                            if let started = session.activityStartedAt {
                                Text("· \(DurationFormatting.compact(from: started, to: now))")
                                    .monospacedDigit()
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(action: onDisconnect) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.50))
                            .frame(width: 21, height: 21)
                            .background(.white.opacity(0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help("Disconnect from Noturcode — keeps the terminal and agent running")
                    .accessibilityLabel("Disconnect from Noturcode")
                    .accessibilityHint("Removes this card without stopping the terminal session")
                    .accessibilityIdentifier("disconnect-noturcode-\(session.id)")
                    Button(action: onViewTerminal) {
                        HStack(spacing: 4) {
                            Image(systemName: "bubble.left.and.bubble.right")
                            Text("View chat")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .accessibilityIdentifier("view-terminal-\(session.id)")
                }
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.43))
                    .padding(.leading, 31)

        }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isUnreadFinished ? Color(red: 0.60, green: 1.0, blue: 0.22).opacity(0.055) : .white.opacity(isPressed ? 0.12 : (isHovered ? 0.07 : 0)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        }
        .overlay {
            if isUnreadFinished {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 0.60, green: 1.0, blue: 0.22).opacity(0.78), lineWidth: 1.15)
                    .shadow(color: Color(red: 0.60, green: 1.0, blue: 0.22).opacity(0.16), radius: 5)
                    .accessibilityElement()
                    .accessibilityLabel("Finished session, unread")
                    .accessibilityIdentifier("unread-completion-\(session.id)")
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(isPressed ? 0.987 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture(perform: onSelect)
        .frame(maxWidth: .infinity)
        .onHover(perform: onHover)
        .clickableCursor()
        .animation(reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isUnreadFinished)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session: \(accessibilityDescription)")
        .accessibilityIdentifier("session-row-\(session.id)")
    }
}

private struct ConversationSidebarToggle: View {
    let isExpanded: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Workflow", systemImage: "sidebar.trailing")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isExpanded ? 0.72 : (isHovered ? 0.62 : 0.42)))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    .white.opacity(isExpanded ? 0.075 : (isHovered ? 0.060 : 0.025)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(isHovered || isExpanded ? 0.09 : 0.04), lineWidth: 0.7)
                }
        }
        .buttonStyle(ConversationControlButtonStyle(reduceMotion: reduceMotion))
        .clickableCursor()
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
        .help(isExpanded ? "Hide workflow" : "Show workflow")
        .accessibilityLabel(isExpanded ? "Hide workflow" : "Show workflow")
    }
}

private struct ConversationControlButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct TerminalViewportContent: View {
    let session: TrackedSession
    let reader: AgentTranscriptReader
    let sender: SessionPromptRouter
    let nativeSessions: NativeSessionCoordinator
    let onPreviewFile: (URL) -> Void
    let onClose: (() -> Void)?
    let presentation: TerminalViewportPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transcriptEntries: [ChatTranscriptEntry] = []
    @State private var optimisticEntries: [ChatTranscriptEntry] = []
    @State private var selectedAgentConversationEntries: [ChatTranscriptEntry] = []
    @State private var selectedAgentConversationMessage = "Loading agent conversation…"
    @State private var transcriptMessage = "Loading conversation…"
    @State private var didInitialScroll = false
    @State private var draft = ""
    @State private var attachments: [PromptImageAttachment] = []
    @State private var delivery: PromptDeliveryState = .idle
    @State private var selectedWorkflowNodeID = "session"
    @State private var selectedToolEntryID: String?
    @State private var chatIsNearBottom = true
    @State private var isSidebarVisible = true
    @State private var deliveryResetGeneration = 0
    @State private var composerHeight: CGFloat = 22
    @State private var nativeApprovals: [NativeSessionCoordinator.PendingApproval] = []
    @State private var nativeApprovalError: String?

    private var visibleTranscriptEntries: [ChatTranscriptEntry] {
        let merged = transcriptEntries + optimisticEntries.filter { optimistic in
            !transcriptEntries.contains { entry in
                entry.kind == .user && entry.text == optimistic.text
            }
        }
        if merged.isEmpty, let summary = session.lastAgentMessage, !summary.isEmpty {
            return [ChatTranscriptEntry(
                id: "session-summary-loading",
                kind: .assistant,
                text: summary,
                model: session.key.source.displayName
            )]
        }
        return merged
    }

    private var selectedSubagent: SubagentSnapshot? {
        guard selectedWorkflowNodeID.hasPrefix("subagent-") else { return nil }
        let id = String(selectedWorkflowNodeID.dropFirst("subagent-".count))
        return session.subagents.first(where: { $0.id == id })
    }

    private var displayedTranscriptEntries: [ChatTranscriptEntry] {
        guard let agent = selectedSubagent else { return visibleTranscriptEntries }
        if !selectedAgentConversationEntries.isEmpty { return selectedAgentConversationEntries }
        var entries = [ChatTranscriptEntry(
            id: "subagent-\(agent.id)-task",
            kind: .user,
            text: agent.activity,
            model: nil
        )]
        if let message = agent.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            entries.append(ChatTranscriptEntry(
                id: "subagent-\(agent.id)-result",
                kind: .assistant,
                text: message,
                model: nil
            ))
        }
        return entries
    }

    init(
        session: TrackedSession,
        reader: AgentTranscriptReader,
        sender: SessionPromptRouter,
        nativeSessions: NativeSessionCoordinator,
        onPreviewFile: @escaping (URL) -> Void = { _ in },
        onClose: (() -> Void)? = nil,
        presentation: TerminalViewportPresentation = .floating
    ) {
        self.session = session
        self.reader = reader
        self.sender = sender
        self.nativeSessions = nativeSessions
        self.onPreviewFile = onPreviewFile
        self.onClose = onClose
        self.presentation = presentation
        _isSidebarVisible = State(
            initialValue: presentation == .floating
                || CommandLine.arguments.contains("--ui-test-agent-conversation")
        )
    }

    private var projectPath: String {
        session.cwd ?? "Location not reported"
    }

    private var activity: String {
        if let currentActivity = session.currentActivity { return currentActivity }
        if let providerFailure { return providerFailure.title }
        return session.lastAgentMessage?.firstNonemptyLine ?? session.state.displayName
    }

    private var providerFailure: ProviderFailurePresentation? {
        guard let raw = session.lastAgentMessage else { return nil }
        return ProviderFailurePresentation.parse(raw)
    }

    private var providerFailureEventID: String? {
        providerFailure == nil ? nil : session.lastAgentMessage
    }

    private var sessionLabel: String {
        guard let terminal = session.terminal else {
            return session.nativeSession.map { "Native session · \($0.transport.rawValue)" } ?? "Native session"
        }
        let id = terminal.uniqueID
        guard id.count > 8 else { return "Local session · \(id)" }
        return "Local session · …\(id.suffix(8))"
    }

    private var conversationTitle: String {
        selectedSubagent.map { "\($0.type) conversation" } ?? "Conversation"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if onClose != nil && presentation == .floating {
                ZStack {
                    WindowDragHandle(identifier: "terminal-drag-handle", label: "Drag session chat")
                    Capsule()
                        .fill(.white.opacity(0.24))
                        .frame(width: 38, height: 3)
                        .allowsHitTesting(false)
                }
                .frame(height: 10)
            }
            if presentation == .floating {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    NoturcodeBrandMark(size: 21)
                    SessionMarble(session: session, size: 8, animate: false)
                        .offset(x: 2, y: 2)
                }
                .frame(width: 23, height: 23)
                ProviderMark(source: session.key.source, size: 12)
                Text(session.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text(session.key.source.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer(minLength: 8)
                Text(session.state.displayName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(session.state.needsAttention ? 0.92 : 0.62))
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isSidebarVisible.toggle()
                        if !isSidebarVisible { selectedToolEntryID = nil }
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(isSidebarVisible ? 0.66 : 0.38))
                        .frame(width: 20, height: 20)
                        .background(.white.opacity(0.055), in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
                .accessibilityLabel(isSidebarVisible ? "Hide sidebar" : "Show sidebar")
                .accessibilityIdentifier("toggle-chat-sidebar")
                if session.key.source == .claude || session.key.source == .codex {
                    Button(action: compactSession) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                            Text("Compact")
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.54))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help("Compact this \(session.key.source.displayName) session")
                    .accessibilityIdentifier("compact-session")
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(width: 20, height: 20)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .accessibilityLabel("Close session chat")
                    .accessibilityIdentifier("close-terminal-preview")
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("›")
                        .foregroundStyle(.white.opacity(0.38))
                    Text(activity.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let started = session.activityStartedAt {
                        Text(DurationFormatting.compact(from: started, to: context.date))
                            .monospacedDigit()
                    }
                    if !session.activeSubagents.isEmpty {
                        Text("· \(session.activeSubagents.count) active")
                    }
                }
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.73))
            }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(displayedTranscriptEntries.isEmpty ? Color.white.opacity(0.28) : Color.green.opacity(0.75))
                        .frame(width: 5, height: 5)
                    Label(conversationTitle, systemImage: "bubble.left.and.bubble.right")
                    Spacer(minLength: 8)
                    Text(displayedTranscriptEntries.isEmpty ? "waiting for transcript" : "local · live")
                        .foregroundStyle(.white.opacity(0.30))
                    if presentation == .desktop {
                        ConversationSidebarToggle(isExpanded: isSidebarVisible) {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.20)) {
                                isSidebarVisible.toggle()
                                if !isSidebarVisible { selectedToolEntryID = nil }
                            }
                        }
                        .accessibilityIdentifier("toggle-desktop-workflow")
                    }
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, presentation == .desktop ? 8 : 0)
                .frame(height: presentation == .desktop ? 30 : nil)
                .background(
                    presentation == .desktop ? Color.white.opacity(0.026) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(presentation == .desktop ? 0.045 : 0), lineWidth: 0.7)
                }

                ScrollViewReader { proxy in
                    HStack(spacing: 3) {
                        if !promptEntries.isEmpty {
                            PromptTimeline(entries: promptEntries, fallbackModel: transcriptModels.last) { prompt in
                                withAnimation(.easeOut(duration: 0.14)) {
                                    proxy.scrollTo(prompt.id, anchor: .center)
                                }
                            }
                        }

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .accessibilityElement()
                                    .accessibilityIdentifier("chat-transcript")
                                if displayedTranscriptEntries.isEmpty {
                                    ContentUnavailableView(
                                        selectedSubagent == nil ? "Conversation unavailable" : "Agent conversation unavailable",
                                        systemImage: "text.bubble",
                                        description: Text(selectedSubagent == nil ? transcriptMessage : selectedAgentConversationMessage)
                                    )
                                    .foregroundStyle(.white.opacity(0.42))
                                    .frame(maxWidth: .infinity, minHeight: 180)
                                } else {
                                    if shouldShowSummaryCard,
                                       let summary = session.lastAgentMessage {
                                        SessionSummaryCard(text: summary)
                                    }
                                    ForEach(conversationItems) { item in
                                        switch item.content {
                                        case let .message(entry):
                                            ChatTranscriptRow(
                                                entry: entry,
                                                source: session.key.source,
                                                cwd: session.cwd,
                                                onPreviewFile: onPreviewFile,
                                                onSelectTool: openTool
                                            )
                                            .id(entry.id)
                                        case let .tools(entries):
                                            ToolBatchRow(entries: entries, onSelectTool: openTool)
                                                .id(item.id)
                                        }
                                    }
                                    if let providerFailure {
                                        ProviderFailureCard(presentation: providerFailure)
                                            .id("provider-failure")
                                    }
                                    if let systemMessage = unifiedSystemMessage {
                                        UnifiedSystemMessage(text: systemMessage)
                                    }
                                }
                                Color.clear.frame(height: 24).id("chat-bottom")
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, presentation == .desktop ? 22 : 0)
                            .frame(maxWidth: presentation == .desktop ? 880 : .infinity)
                            .frame(maxWidth: .infinity)
                            .padding(.trailing, presentation == .desktop ? 0 : 9)
                            .padding(.leading, presentation == .desktop ? 0 : (promptEntries.isEmpty ? 9 : 3))
                        }
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentOffset.y + geometry.containerSize.height
                                >= geometry.contentSize.height - 140
                        } action: { _, nearBottom in
                            chatIsNearBottom = nearBottom
                        }
                        .onChange(of: displayedTranscriptEntries.map(\.id)) { _, ids in
                            guard !ids.isEmpty else { return }
                            if !didInitialScroll {
                                didInitialScroll = true
                                proxy.scrollTo("chat-bottom", anchor: .bottom)
                            } else if chatIsNearBottom {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: providerFailureEventID) { _, eventID in
                            guard eventID != nil else { return }
                            if delivery == .compacting {
                                delivery = .error(providerFailure?.title ?? "Compaction failed")
                            }
                            if chatIsNearBottom {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo("provider-failure", anchor: .bottom)
                                }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !chatIsNearBottom {
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                                    }
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .frame(width: 24, height: 24)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .clickableCursor()
                                .padding(8)
                                .help("Jump to latest message")
                                .accessibilityIdentifier("chat-jump-to-latest")
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    presentation == .desktop ? Color.clear : Color.black.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(presentation == .desktop ? 0 : 0.055), lineWidth: 0.7)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isSidebarVisible {
                    Group {
                        if let selectedToolEntryID,
                           let selectedTool = displayedTranscriptEntries.first(where: { $0.id == selectedToolEntryID }) {
                            ToolDetailInspector(
                                entry: selectedTool,
                                onClose: { self.selectedToolEntryID = nil }
                            )
                        } else {
                            workflowOverview
                        }
                    }
                    .frame(width: presentation == .desktop ? 300 : 230)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if presentation == .floating {
                    collapsedSidebarRail
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.14), value: selectedToolEntryID)
            .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: isSidebarVisible)

            if selectedSubagent == nil {
                if let approval = nativeApprovals.first {
                    NativeApprovalCard(
                        approval: approval,
                        errorMessage: nativeApprovalError,
                        onRespond: respondToNativeApproval
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composerSurface
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selectedWorkflowNodeID = "session" }
                } label: {
                    Label("Back to main session to send a message", systemImage: "arrow.turn.up.left")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityIdentifier("return-to-session-chat")
            }
        }
        .padding(.horizontal, presentation == .floating ? 14 : 0)
        .padding(.vertical, presentation == .floating ? 12 : 0)
        .background {
            if presentation == .floating {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 0.7)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-preview-surface")
        .accessibilityLabel("\(session.name) chat, \(session.key.source.displayName), \(sessionLabel), \(activity)")
        .task(id: "\(session.key.description)|\(session.transcriptPath ?? "")") {
            while !Task.isCancelled {
                switch await reader.snapshot(session) {
                case let .found(entries):
                    if entries != transcriptEntries,
                       !entries.isEmpty || transcriptEntries.isEmpty {
                        transcriptEntries = entries
                    }
                    optimisticEntries.removeAll { optimistic in
                        entries.contains { entry in
                            entry.kind == .user && entry.text == optimistic.text
                        }
                    }
                    let nextMessage = visibleTranscriptEntries.isEmpty
                        ? "No messages have been written to the local transcript yet."
                        : ""
                    if transcriptMessage != nextMessage { transcriptMessage = nextMessage }
                case .missing:
                    if transcriptEntries.isEmpty {
                        let nextMessage = "The local \(session.key.source.displayName) transcript has not been reported yet."
                        if transcriptMessage != nextMessage { transcriptMessage = nextMessage }
                    }
                case let .failed(message):
                    if transcriptEntries.isEmpty, transcriptMessage != message {
                        transcriptMessage = message
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
            }
        }
        .task(id: selectedWorkflowNodeID) {
            guard let subagentID = selectedSubagent?.id else {
                selectedAgentConversationEntries = []
                selectedAgentConversationMessage = "Loading agent conversation…"
                return
            }
            selectedAgentConversationEntries = []
            selectedAgentConversationMessage = "Loading agent conversation…"
            while !Task.isCancelled {
                switch await reader.snapshot(session, subagentID: subagentID) {
                case let .found(entries):
                    if entries != selectedAgentConversationEntries,
                       !entries.isEmpty || selectedAgentConversationEntries.isEmpty {
                        selectedAgentConversationEntries = entries
                    }
                    let nextMessage = entries.isEmpty
                        ? "This agent has not written to its local transcript yet."
                        : ""
                    if selectedAgentConversationMessage != nextMessage {
                        selectedAgentConversationMessage = nextMessage
                    }
                case .missing:
                    let nextMessage = "No separate transcript was reported for this agent."
                    if selectedAgentConversationMessage != nextMessage {
                        selectedAgentConversationMessage = nextMessage
                    }
                case let .failed(message):
                    if selectedAgentConversationMessage != message {
                        selectedAgentConversationMessage = message
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
            }
        }
        .task(id: "\(session.key.description)|\(session.state.rawValue)") {
            guard session.state == .askingYou else {
                nativeApprovals = []
                nativeApprovalError = nil
                return
            }
            while !Task.isCancelled {
                let next = await nativeSessions.approvals(for: session.key)
                if next != nativeApprovals {
                    nativeApprovals = next
                    if next.isEmpty { nativeApprovalError = nil }
                }
                do {
                    try await Task.sleep(for: .milliseconds(160))
                } catch {
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var composerSurface: some View {
        if presentation == .desktop {
            promptComposer
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(Color(red: 0.047, green: 0.050, blue: 0.059))
        } else {
            promptComposer
        }
    }

    private var collapsedSidebarRail: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isSidebarVisible = true
            }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 10, weight: .semibold))
                Text("Workflow")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .fixedSize()
            }
            .foregroundStyle(.white.opacity(0.48))
            .frame(width: 25)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel("Show workflow sidebar")
        .accessibilityIdentifier("show-chat-sidebar-rail")
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var transcriptModels: [String] {
        displayedTranscriptEntries.compactMap(\.model).reduce(into: [String]()) { values, model in
            if !values.contains(model) { values.append(model) }
        }
    }

    private var shouldShowSummaryCard: Bool {
        guard selectedSubagent == nil,
              session.state.showsCompletionSummary,
              let summary = session.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty,
              !transcriptEntries.isEmpty else { return false }
        let normalizedSummary = summary.replacingOccurrences(of: "\n", with: " ")
        return !transcriptEntries.contains { entry in
            entry.kind == .assistant
                && entry.text.replacingOccurrences(of: "\n", with: " ") == normalizedSummary
        }
    }

    private var promptEntries: [ChatTranscriptEntry] {
        Array(displayedTranscriptEntries.filter { $0.kind == .user }.suffix(12))
    }

    private var unifiedSystemMessage: String? {
        let messages = displayedTranscriptEntries
            .filter { $0.kind == .system }
            .map(\.text)
            .filter { !$0.isEmpty }
        guard !messages.isEmpty else { return nil }
        return messages.suffix(3).joined(separator: " · ")
    }

    private func openTool(_ entry: ChatTranscriptEntry) {
        selectedToolEntryID = entry.id
        isSidebarVisible = true
    }

    private var conversationItems: [ConversationItem] {
        var result: [ConversationItem] = []
        var tools: [ChatTranscriptEntry] = []
        func flushTools() {
            guard !tools.isEmpty else { return }
            result.append(ConversationItem(content: .tools(tools)))
            tools.removeAll(keepingCapacity: true)
        }
        for entry in displayedTranscriptEntries where entry.kind != .system {
            if entry.kind == .tool {
                tools.append(entry)
            } else {
                flushTools()
                result.append(ConversationItem(content: .message(entry)))
            }
        }
        flushTools()
        return result
    }

    private var workflowNodes: [WorkflowNode] {
        var nodes = [WorkflowNode(
            id: "session",
            title: session.name,
            subtitle: "session chat",
            detail: activity,
            model: transcriptModels.last,
            icon: "circle.hexagongrid",
            depth: 0,
            isLive: session.state == .working || session.state == .askingYou
        )]
        nodes += session.subagents.map { agent in
            WorkflowNode(
                id: "subagent-\(agent.id)",
                title: agent.type,
                subtitle: agent.state.displayName,
                detail: agent.lastMessage ?? agent.activity,
                model: nil,
                icon: "person.crop.circle.badge.gearshape",
                depth: 1,
                isLive: agent.state == .working || agent.state == .askingYou
            )
        }
        var seenWorkflowCalls = Set<String>()
        let uniqueWorkflowCalls = transcriptEntries.reversed().filter { entry in
            guard entry.kind == .tool else { return false }
            let title = (entry.title ?? "").lowercased()
            guard title.contains("agent") || title.contains("team") || title.contains("task") || title.contains("workflow") else {
                return false
            }
            let key = "\(title)|\(entry.model ?? "")"
            return seenWorkflowCalls.insert(key).inserted
        }.prefix(8).reversed()
        nodes += uniqueWorkflowCalls.map { entry in
            WorkflowNode(
                id: "transcript-\(entry.id)",
                title: entry.title ?? "Agent",
                subtitle: "workflow call",
                detail: entry.detail ?? entry.text,
                model: entry.model ?? modelName(in: entry.text),
                icon: (entry.title ?? "").lowercased().contains("team") ? "person.3" : "point.3.connected.trianglepath.dotted",
                depth: 1,
                isLive: entry.detail == nil
            )
        }
        return nodes
    }

    private var workflowOverview: some View {
        let nodes = workflowNodes
        let selection = nodes.first(where: { $0.id == selectedWorkflowNodeID }) ?? nodes[0]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("ORCHESTRATION")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.30))
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { isSidebarVisible = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.06), in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help("Hide sidebar")
                .accessibilityLabel("Close workflow sidebar")
                .accessibilityIdentifier("close-chat-sidebar")
            }
            if !transcriptModels.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                ForEach(transcriptModels, id: \.self) { model in
                    Text(model)
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.62))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(.cyan.opacity(0.07), in: Capsule())
                }
                    }
                }
                .scrollIndicators(.hidden)
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(sessionLabel, systemImage: "terminal")
                Text(projectPath)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.34))
            .padding(.horizontal, 2)
            .accessibilityIdentifier("local-session-metadata")
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(nodes) { node in
                        Button {
                            selectedToolEntryID = nil
                            selectedWorkflowNodeID = node.id
                        } label: {
                            HStack(spacing: 7) {
                                if node.depth > 0 {
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(.white.opacity(0.10))
                                            .frame(width: 1, height: 31)
                                        Rectangle()
                                            .fill(.white.opacity(0.10))
                                            .frame(width: 9, height: 1)
                                    }
                                    .frame(width: 15)
                                }
                                ZStack(alignment: .bottomTrailing) {
                                    Image(systemName: node.icon)
                                    Circle()
                                        .fill(node.isLive ? Color.green.opacity(0.86) : Color.white.opacity(0.24))
                                        .frame(width: 4, height: 4)
                                        .offset(x: 2, y: 2)
                                }
                                .frame(width: 14)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(node.title).lineLimit(1)
                                    Text(node.model ?? node.subtitle)
                                        .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                        .opacity(0.52)
                                }
                            }
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(selectedWorkflowNodeID == node.id ? 0.82 : 0.48))
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .background(.white.opacity(selectedWorkflowNodeID == node.id ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .accessibilityLabel("Open \(node.title) workflow details")
                        .accessibilityIdentifier("workflow-node-\(node.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: selection.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.58))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(selection.title)
                            .fontWeight(.semibold)
                        Text("chat / activity")
                            .opacity(0.48)
                        Spacer(minLength: 4)
                        if let model = selection.model { Text(model).monospaced() }
                    }
                    Text(selection.detail)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 9.5, weight: .regular))
            .foregroundStyle(.white.opacity(0.44))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("workflow-detail")
        }
        .padding(9)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.7)
        }
        .accessibilityIdentifier("workflow-sidebar")
    }

    private func modelName(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\"model\"\s*:\s*\"([^\"]+)\""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private var promptComposer: some View {
        IsolatedPromptComposer(
            session: session,
            sender: sender,
            onOptimisticAdd: { optimisticEntries.append($0) },
            onOptimisticRemove: { payload in
                optimisticEntries.removeAll { $0.text == payload }
            }
        )
    }

    private func respondToNativeApproval(
        _ approval: NativeSessionCoordinator.PendingApproval,
        _ response: NativeSessionCoordinator.ApprovalResponse
    ) {
        nativeApprovalError = nil
        Task {
            do {
                try await nativeSessions.respond(to: approval, with: response)
                nativeApprovals = await nativeSessions.approvals(for: session.key)
            } catch {
                nativeApprovalError = error.localizedDescription
            }
        }
    }

    private var legacyPromptComposer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(attachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: attachment.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 46, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(.white.opacity(0.13), lineWidth: 0.7)
                                    }
                                    .accessibilityIdentifier("prompt-image-attachment")
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.72))
                                }
                                .buttonStyle(.plain)
                                .clickableCursor()
                                .offset(x: 4, y: -4)
                                .accessibilityLabel("Remove \(attachment.url.lastPathComponent)")
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)
                .frame(height: 34)
            }

            HStack(alignment: .bottom, spacing: 3) {
                Button(action: chooseImages) {
                    Image(systemName: "paperclip")
                        .frame(width: 20, height: 20)
                }
                .help("Attach reference images")
                .accessibilityLabel("Attach reference images")
                .accessibilityIdentifier("attach-images")

                PasteAwarePromptEditor(
                    text: $draft,
                    height: $composerHeight,
                    placeholder: "Message \(session.name)…",
                    onSubmit: sendPrompt,
                    onPasteImage: pasteImages
                )
                    .frame(height: composerHeight)
                    .padding(.horizontal, 5)
                    .accessibilityLabel("Prompt for \(session.name)")
                    .accessibilityIdentifier("prompt-composer")

                Button(action: sendPrompt) {
                    Image(systemName: delivery == .sent ? "checkmark" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.black.opacity(0.82) : .white.opacity(0.24))
                        .frame(width: 24, height: 24)
                        .background(canSend ? Color.white.opacity(0.92) : .white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send to this session (Return or ⌘↩)")
                .accessibilityLabel("Send prompt to \(session.name)")
                .accessibilityIdentifier("send-prompt")
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .foregroundStyle(.white.opacity(0.46))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(minHeight: 30)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.7)
            }

            if delivery != .idle {
                HStack(spacing: 5) {
                    Image(systemName: delivery.icon)
                    Text(delivery.message).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(delivery.isError ? 0.72 : 0.38))
                .padding(.leading, 29)
                .accessibilityIdentifier("composer-system-status")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var canSend: Bool {
        delivery != .sending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Attach reference images"
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            addImageURLs(panel.urls)
        }
    }

    @discardableResult
    private func pasteImages() -> Bool {
        let pasteboard = NSPasteboard.general
        var images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        if images.isEmpty {
            let imageTypes: [NSPasteboard.PasteboardType] = [
                .png,
                .tiff,
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.heic")
            ]
            for item in pasteboard.pasteboardItems ?? [] {
                if let data = imageTypes.lazy.compactMap({ item.data(forType: $0) }).first,
                   let image = NSImage(data: data) {
                    images.append(image)
                }
                if let urlString = item.string(forType: .fileURL),
                   let url = URL(string: urlString),
                   let image = NSImage(contentsOf: url) {
                    images.append(image)
                }
            }
        }
        guard !images.isEmpty else {
            return false
        }
        for image in images.prefix(max(0, 8 - attachments.count)) {
            guard let url = PromptAttachmentStorage.persist(image: image) else { continue }
            attachments.append(PromptImageAttachment(url: url, image: image))
        }
        delivery = .idle
        return true
    }

    private func addImageURLs(_ urls: [URL]) {
        for url in urls.prefix(max(0, 8 - attachments.count)) {
            guard let image = NSImage(contentsOf: url) else { continue }
            attachments.append(PromptImageAttachment(url: url, image: image))
        }
        delivery = .idle
    }

    private func sendPrompt() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePaths = attachments.map(\.url.path)
        let references = attachments.map { "- \($0.url.path)" }.joined(separator: "\n")
        let payload = references.isEmpty
            ? message
            : [message, "Reference images available at these local paths:\n\(references)"]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        guard !payload.isEmpty else { return }
        let originalDraft = draft
        let originalAttachments = attachments
        optimisticEntries.append(ChatTranscriptEntry(
            id: "optimistic-\(UUID().uuidString)",
            kind: .user,
            text: payload
        ))
        draft = ""
        attachments.removeAll()
        delivery = .sending
        Task {
            switch await sender.send(payload, imagePaths: imagePaths, to: session) {
            case .sent:
                NoturcodeSoundPlayer.shared.play(.send)
                delivery = .sent
                scheduleDeliveryReset()
            case .missing:
                optimisticEntries.removeAll { $0.text == payload }
                if draft.isEmpty { draft = originalDraft }
                if attachments.isEmpty { attachments = originalAttachments }
                delivery = .error("Session is no longer open")
            case let .failed(message):
                optimisticEntries.removeAll { $0.text == payload }
                if draft.isEmpty { draft = originalDraft }
                if attachments.isEmpty { attachments = originalAttachments }
                delivery = .error(message)
            }
        }
    }

    private func scheduleDeliveryReset() {
        deliveryResetGeneration &+= 1
        let generation = deliveryResetGeneration
        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.25))
            } catch {
                return
            }
            guard deliveryResetGeneration == generation, delivery == .sent else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                delivery = .idle
            }
        }
    }

    private func compactSession() {
        delivery = .sending
        Task {
            switch await sender.compact(session) {
            case .sent:
                delivery = .compacting
            case .missing:
                delivery = .error("Session is no longer open")
            case let .failed(message):
                delivery = .error(message)
            }
        }
    }
}

private struct WorkflowNode: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let model: String?
    let icon: String
    let depth: Int
    let isLive: Bool
}

private struct ConversationItem: Identifiable {
    enum Content {
        case message(ChatTranscriptEntry)
        case tools([ChatTranscriptEntry])
    }

    let id: String
    let content: Content

    init(content: Content) {
        self.content = content
        switch content {
        case let .message(entry): id = entry.id
        case let .tools(entries): id = "tool-batch-\(entries.first?.id ?? UUID().uuidString)"
        }
    }
}

private struct PromptTimeline: View {
    let entries: [ChatTranscriptEntry]
    let fallbackModel: String?
    let onSelect: (ChatTranscriptEntry) -> Void

    var body: some View {
        GeometryReader { geometry in
            let markerDiameter: CGFloat = 26
            let railInset = markerDiameter / 2
            let usableHeight = max(0, geometry.size.height - markerDiameter)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.105))
                    .frame(width: 1, height: usableHeight)
                    .offset(y: railInset)

                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let progress = entries.count <= 1 ? 1 : CGFloat(index) / CGFloat(entries.count - 1)
                    PromptTimelineMarker(
                        entry: entry,
                        index: index,
                        isLatest: index == entries.count - 1,
                        fallbackModel: fallbackModel,
                        onSelect: onSelect
                    )
                    .offset(y: railInset + progress * usableHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 28)
        .padding(.vertical, 5)
        .accessibilityIdentifier("prompt-timeline")
    }
}

private struct PromptTimelineMarker: View {
    let entry: ChatTranscriptEntry
    let index: Int
    let isLatest: Bool
    let fallbackModel: String?
    let onSelect: (ChatTranscriptEntry) -> Void
    @State private var isPreviewPresented = false
    @State private var isPointerOverPreview = false
    @State private var previewDismissalTask: Task<Void, Never>?

    var body: some View {
        Button {
            onSelect(entry)
        } label: {
            Circle()
                .fill(.white.opacity(isLatest ? 0.82 : 0.30))
                .frame(width: isLatest ? 8 : 6, height: isLatest ? 8 : 6)
                .overlay(Circle().stroke(.black.opacity(0.70), lineWidth: 2))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { hovering in
            if hovering {
                previewDismissalTask?.cancel()
                isPreviewPresented = true
            } else {
                schedulePreviewDismissal()
            }
        }
        .popover(isPresented: $isPreviewPresented, arrowEdge: .leading) {
            PromptRailPreview(entry: entry, fallbackModel: fallbackModel)
                .onHover { hovering in
                    isPointerOverPreview = hovering
                    if hovering {
                        previewDismissalTask?.cancel()
                    } else {
                        schedulePreviewDismissal()
                    }
                }
        }
        .accessibilityLabel("Jump to prompt \(index + 1)")
        .accessibilityHint("Hover to preview the prompt")
        .accessibilityIdentifier("prompt-rail-marker")
    }

    private func schedulePreviewDismissal() {
        previewDismissalTask?.cancel()
        previewDismissalTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(280))
            } catch { return }
            guard !isPointerOverPreview else { return }
            isPreviewPresented = false
        }
    }
}

private struct PromptRailPreview: View {
    let entry: ChatTranscriptEntry
    let fallbackModel: String?

    private var prompt: String {
        let cleaned = entry.text.withoutInlineImagePath
        return cleaned.isEmpty ? entry.text : cleaned
    }

    private var sentAt: String {
        guard let timestamp = entry.timestamp else { return "Time unavailable" }
        return timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Label("Prompt", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.cyan.opacity(0.84))
                Spacer(minLength: 12)
                Text(entry.model ?? fallbackModel ?? "Model unavailable")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 9.5, weight: .semibold))

            Text(prompt)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)

            Text("Sent \(sentAt)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(11)
        .frame(width: 280, alignment: .leading)
        .background(Color(red: 0.070, green: 0.075, blue: 0.087), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("prompt-rail-preview")
    }
}

private struct SessionSummaryCard: View {
    let text: String

    private var cleanText: String {
        text.replacingOccurrences(of: "Noturcode summary", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.66))
                .frame(width: 17, height: 17)
                .background(.cyan.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Session summary")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.46))
                Text(cleanText)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.cyan.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.cyan.opacity(0.10), lineWidth: 0.7)
        }
        .accessibilityIdentifier("session-summary-card")
    }
}

private struct ProviderFailureCard: View {
    let presentation: ProviderFailurePresentation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange.opacity(0.78))
                .frame(width: 18, height: 18)
                .background(.orange.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(presentation.message)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.60))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(.orange.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.orange.opacity(0.11), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("provider-failure-card")
    }
}

private struct UnifiedSystemMessage: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "clock")
                .font(.system(size: 9))
            Text(text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.38))
        .padding(.horizontal, 4)
        .accessibilityIdentifier("unified-system-message")
    }
}

private struct ToolBatchRow: View {
    let entries: [ChatTranscriptEntry]
    let onSelectTool: (ChatTranscriptEntry) -> Void
    @State private var isExpanded = false

    private var summary: String {
        guard let first = entries.first else { return "Tool activity" }
        if entries.count == 1 { return first.title ?? "Tool completed" }
        return "\(first.title ?? "Tool activity") + \(entries.count - 1) more"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green.opacity(0.68))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary).lineLimit(1)
                        Text("\(entries.count) step\(entries.count == 1 ? "" : "s")")
                            .font(.system(size: 8.5, weight: .medium))
                            .opacity(0.48)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .padding(.horizontal, 9)
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") tool batch: \(summary)")
            .accessibilityIdentifier("chat-tool-batch")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        Button { onSelectTool(entry) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(spacing: 0) {
                                    Circle()
                                        .fill(.white.opacity(0.30))
                                        .frame(width: 5, height: 5)
                                    Rectangle()
                                        .fill(.white.opacity(0.08))
                                        .frame(width: 0.7, height: 22)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title ?? "Tool")
                                        .fontWeight(.semibold)
                                    Text(entry.detail == nil ? "Running" : "Done")
                                        .font(.system(size: 8.5, weight: .medium))
                                        .opacity(0.42)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .opacity(0.42)
                            }
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.54))
                            .padding(.horizontal, 10)
                            .padding(.top, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .accessibilityLabel("Show tool detail: \(entry.title ?? "Tool")")
                        .accessibilityIdentifier("chat-tool-call")
                    }
                }
                .padding(.bottom, 7)
                .transition(.opacity)
            }
        }
        .clipped()
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.7)
        }
    }
}

private struct ToolDetailInspector: View {
    let entry: ChatTranscriptEntry
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(.cyan.opacity(0.62))
                Text(entry.title ?? "Tool detail")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel("Close tool details")
            }
            .foregroundStyle(.white.opacity(0.68))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if !entry.text.isEmpty {
                        inspectorBlock(entry.text, opacity: 0.78)
                    }
                    if let detail = entry.detail, !detail.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("OUTPUT")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(.white.opacity(0.28))
                            inspectorBlock(detail, opacity: 0.58)
                                .accessibilityIdentifier("chat-tool-result")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-detail-inspector")
    }

    private func inspectorBlock(_ text: String, opacity: Double) -> some View {
        Text(SyntaxHighlighter.attributed(text, languageHint: entry.title))
            .font(.system(size: 9.5, design: .monospaced))
            .opacity(opacity)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ChatTranscriptRow: View {
    let entry: ChatTranscriptEntry
    let source: AgentSource
    let cwd: String?
    let onPreviewFile: (URL) -> Void
    let onSelectTool: (ChatTranscriptEntry) -> Void

    @State private var isHovered = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 42)
                VStack(alignment: .trailing, spacing: 6) {
                    messageText(entry.text.withoutInlineImagePath)
                    imageStrip
                    fileStrip
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(isHovered ? 0.12 : 0.085), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.10)) { isHovered = hovering }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.text)
            .accessibilityIdentifier("chat-message-user")

        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                ProviderMark(source: source, size: 14)
                    .opacity(0.54)
                VStack(alignment: .leading, spacing: 6) {
                    messageText(entry.text.withoutInlineImagePath)
                    imageStrip
                    fileStrip
                }
                Spacer(minLength: 30)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.text)
            .accessibilityIdentifier("chat-message-assistant")

        case .tool:
            toolRow

        case .system:
            Text(entry.text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity)
        }
    }

    private func messageText(_ text: String) -> some View {
        ConversationMarkdownView(source: text)
    }

    @ViewBuilder
    private var imageStrip: some View {
        if !entry.imagePaths.isEmpty {
            HStack(spacing: 6) {
                ForEach(entry.imagePaths, id: \.self) { path in
                    ChatImagePreview(path: path)
                }
            }
        }
    }

    private var toolRow: some View {
        Button {
            onSelectTool(entry)
        } label: {
                HStack(spacing: 7) {
                    Image(systemName: toolIcon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(entry.title ?? "Tool")
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if entry.detail != nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.green.opacity(0.72))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.54))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .accessibilityLabel("Show \(entry.title ?? "tool") details")
            .accessibilityIdentifier("chat-tool-call")
        .background(.white.opacity(isHovered ? 0.065 : 0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(isHovered ? 0.10 : 0.055), lineWidth: 0.7)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var fileStrip: some View {
        let references = LocalFileReferenceDetector.urls(
            in: [entry.text, entry.detail].compactMap { $0 }.joined(separator: "\n"),
            cwd: cwd
        )
        if !references.isEmpty {
            HStack(spacing: 5) {
                ForEach(references.prefix(3), id: \.path) { url in
                    Button { onPreviewFile(url) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text(url.lastPathComponent).lineLimit(1)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 7, weight: .bold))
                                .opacity(0.5)
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.horizontal, 7)
                        .frame(height: 23)
                        .background(.white.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help("Preview \(url.path)")
                    .accessibilityLabel("Preview \(url.lastPathComponent)")
                    .accessibilityIdentifier("chat-file-reference")
                }
                if references.count > 3 {
                    Text("+\(references.count - 3)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.36))
                }
            }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(SyntaxHighlighter.attributed(text, languageHint: entry.title))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(8)
        }
        .frame(maxHeight: 124)
        .accessibilityIdentifier("syntax-highlighted-tool")
        .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var toolIcon: String {
        let value = (entry.title ?? "").lowercased()
        if value.contains("edit") || value.contains("patch") || value.contains("write file") { return "square.and.pencil" }
        if value.contains("continue") { return "arrow.clockwise" }
        if value.contains("run") || value.contains("bash") || value.contains("command") || value.contains("exec") { return "terminal" }
        if value.contains("read") || value.contains("open") || value.contains("resource") { return "doc.text.magnifyingglass" }
        if value.contains("image") || value.contains("photo") { return "photo" }
        if value.contains("web") || value.contains("search") { return "globe" }
        if value.contains("start agent") { return "person.badge.plus" }
        if value.contains("message agent") { return "paperplane" }
        if value.contains("wait") { return "clock" }
        if value.contains("plan") { return "list.bullet.clipboard" }
        if value.contains("ask") { return "questionmark.bubble" }
        return "wrench.and.screwdriver"
    }
}

private struct ConversationMarkdownView: View {
    let source: String

    private var blocks: [ConversationMarkupBlock] {
        ConversationRenderCache.shared.blocks(for: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .markdown(text):
                    Text(renderedMarkdown(text))
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat-markdown-block")

                case let .code(language, content):
                    sourceBlock(content, language: language)

                case let .table(content):
                    fixedWidthBlock(content, label: "Markdown table", identifier: "chat-markdown-table")

                case let .diagram(content):
                    fixedWidthBlock(content, label: "ASCII diagram", identifier: "chat-ascii-diagram")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-markdown-message")
    }

    private func renderedMarkdown(_ text: String) -> AttributedString {
        ConversationRenderCache.shared.markdown(for: text)
    }

    private func sourceBlock(_ content: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.36))
                    .padding(.horizontal, 9)
                    .padding(.top, 7)
                    .padding(.bottom, 4)
            }
            ScrollView(.horizontal) {
                Text(SyntaxHighlighter.attributed(content, languageHint: language))
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code block \(language ?? "plain text")")
        .accessibilityIdentifier("chat-code-block")
    }

    private func fixedWidthBlock(_ content: String, label: String, identifier: String) -> some View {
        ScrollView(.horizontal) {
            Text(content)
                .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.80))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(9)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private final class ConversationRenderCache {
    static let shared = ConversationRenderCache()

    private var parsedBlocks: [String: [ConversationMarkupBlock]] = [:]
    private var renderedMarkdown: [String: AttributedString] = [:]
    private let limit = 160

    func blocks(for source: String) -> [ConversationMarkupBlock] {
        if let cached = parsedBlocks[source] { return cached }
        let value = ConversationMarkupParser.parse(source)
        trimIfNeeded(&parsedBlocks)
        parsedBlocks[source] = value
        return value
    }

    func markdown(for source: String) -> AttributedString {
        if let cached = renderedMarkdown[source] { return cached }
        let value = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(source)
        trimIfNeeded(&renderedMarkdown)
        renderedMarkdown[source] = value
        return value
    }

    private func trimIfNeeded<Value>(_ values: inout [String: Value]) {
        guard values.count >= limit else { return }
        let keysToRemove = Array(values.keys.prefix(limit / 2))
        for key in keysToRemove { values[key] = nil }
    }
}

private enum LocalFileReferenceDetector {
    static func urls(in text: String, cwd: String?) -> [URL] {
        let trimming = CharacterSet(charactersIn: "\"'`:,;()[]{}<>")
        let tokens = text.components(separatedBy: .whitespacesAndNewlines)
        var seen = Set<String>()
        var result: [URL] = []

        for rawToken in tokens {
            var token = rawToken.trimmingCharacters(in: trimming)
            while token.hasSuffix(".") { token.removeLast() }
            guard token.contains("/"), !token.contains("://") else { continue }
            token = token.replacingOccurrences(of: "\\ ", with: " ")
            let url: URL
            if token.hasPrefix("/") {
                url = URL(fileURLWithPath: token)
            } else if let cwd {
                url = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(token)
            } else {
                continue
            }
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  seen.insert(standardized.path).inserted else { continue }
            result.append(standardized)
            if result.count == 6 { break }
        }
        return result
    }
}

private struct ChatImagePreview: View {
    let path: String
    @State private var isHovered = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .frame(width: 64, height: 46)
        .background(.black.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(isHovered ? 0.22 : 0.09), lineWidth: 0.8)
        }
        .overlay {
            if isHovered {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.90))
                    .padding(6)
                    .background(.black.opacity(0.50), in: Circle())
            }
        }
        .scaleEffect(isHovered ? 1.035 : 1)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.11)) { isHovered = hovering }
        }
        .popover(isPresented: $isHovered, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(minWidth: 280, maxWidth: 560, minHeight: 180, maxHeight: 420)
                    .padding(8)
            }
        }
        .help(URL(fileURLWithPath: path).lastPathComponent)
        .accessibilityLabel("Preview \(URL(fileURLWithPath: path).lastPathComponent)")
        .accessibilityIdentifier("chat-image-preview")
        .task(id: path) {
            let imageData = await Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
            }.value
            image = imageData.flatMap(NSImage.init(data:))
        }
    }
}

private extension String {
    var withoutInlineImagePath: String {
        replacingOccurrences(
            of: #"\s*\[Image[^\]]*\]\s*path=[\"']?[^\n\"']+[\"']?"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?ms)\n*Reference images available at these local paths:\s*(?:\n-\s+[^\n]+)+"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PasteAwarePromptEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let onSubmit: () -> Void
    let onPasteImage: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = ImagePasteTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor.white.withAlphaComponent(0.90)
        textView.insertionPointColor = .white
        textView.string = text
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onPasteImage = onPasteImage
        scrollView.documentView = textView
        context.coordinator.updateHeight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ImagePasteTextView else { return }
        if textView.string != text { textView.string = text }
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onPasteImage = onPasteImage
        context.coordinator.parent = self
        context.coordinator.updateHeight(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteAwarePromptEditor

        init(parent: PasteAwarePromptEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updateHeight(textView)
        }

        func updateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let measured = ceil(layoutManager.usedRect(for: textContainer).height + 6)
            let next = min(96, max(22, measured))
            guard abs(parent.height - next) > 0.5 else { return }
            Task { @MainActor [weak self] in self?.parent.height = next }
        }
    }
}

private final class ImagePasteTextView: NSTextView {
    var placeholder = ""
    var onSubmit: (() -> Void)?
    var onPasteImage: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if onPasteImage?() == true { return }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isImagePasteShortcut(event), onPasteImage?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isImagePasteShortcut(event), onPasteImage?() == true {
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    private func isImagePasteShortcut(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers?.lowercased() == "v" else { return false }
        return event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.34)
        ]
        placeholder.draw(at: NSPoint(x: 0, y: textContainerInset.height + 1), withAttributes: attributes)
    }
}

private struct NativeApprovalCard: View {
    let approval: NativeSessionCoordinator.PendingApproval
    let errorMessage: String?
    let onRespond: (
        NativeSessionCoordinator.PendingApproval,
        NativeSessionCoordinator.ApprovalResponse
    ) -> Void

    @State private var answers: [String: String] = [:]

    private var questions: [NativeSessionCoordinator.ApprovalQuestion] {
        guard case let .codexUserInput(questions) = approval.kind else { return [] }
        return questions
    }

    private var canSubmitAnswers: Bool {
        !questions.isEmpty && questions.allSatisfy {
            !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(approval.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(approval.sessionKey.source.displayName)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
            }

            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if questions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(approval.options) { option in
                        Button(option.label) {
                            onRespond(approval, .option(option.id))
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(option.isDestructive ? .white.opacity(0.56) : .black.opacity(0.84))
                        .padding(.horizontal, 10)
                        .frame(height: 25)
                        .background(
                            option.isDestructive ? .white.opacity(0.055) : .white.opacity(0.88),
                            in: Capsule()
                        )
                        .accessibilityIdentifier(accessibilityID(for: option))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(question.prompt)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.74))
                                .fixedSize(horizontal: false, vertical: true)

                            if !question.options.isEmpty {
                                HStack(spacing: 5) {
                                    ForEach(question.options, id: \.self) { option in
                                        Button(option) { answers[question.id] = option }
                                            .buttonStyle(.plain)
                                            .clickableCursor()
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.76))
                                            .padding(.horizontal, 8)
                                            .frame(height: 23)
                                            .background(
                                                answers[question.id] == option
                                                    ? .white.opacity(0.14)
                                                    : .white.opacity(0.05),
                                                in: Capsule()
                                            )
                                    }
                                }
                            }

                            if question.options.isEmpty || question.allowsOther {
                                Group {
                                    if question.isSecret {
                                        SecureField("Answer", text: answerBinding(for: question.id))
                                    } else {
                                        TextField("Answer", text: answerBinding(for: question.id))
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.86))
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }

                    Button("Send answer") {
                        let values = answers.mapValues { [$0.trimmingCharacters(in: .whitespacesAndNewlines)] }
                        onRespond(approval, .answers(values))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .disabled(!canSubmitAnswers)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(canSubmitAnswers ? .black.opacity(0.84) : .white.opacity(0.26))
                    .padding(.horizontal, 10)
                    .frame(height: 25)
                    .background(canSubmitAnswers ? .white.opacity(0.88) : .white.opacity(0.05), in: Capsule())
                    .accessibilityIdentifier("native-approval-send-answer")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.red.opacity(0.78))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-approval-card")
    }

    private func answerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? "" },
            set: { answers[id] = $0 }
        )
    }

    private func accessibilityID(for option: NativeSessionCoordinator.ApprovalOption) -> String {
        switch option.id {
        case "accept", "once": "native-approval-approve-once"
        case "acceptForSession", "always": "native-approval-approve-session"
        case "decline", "reject", "cancel": "native-approval-reject"
        default: "native-approval-option-\(option.id)"
        }
    }
}

private struct IsolatedPromptComposer: View {
    let session: TrackedSession
    let sender: SessionPromptRouter
    let onOptimisticAdd: (ChatTranscriptEntry) -> Void
    let onOptimisticRemove: (String) -> Void

    @State private var draft = ""
    @State private var attachments: [PromptImageAttachment] = []
    @State private var delivery: PromptDeliveryState = .idle
    @State private var composerHeight: CGFloat = 22
    @State private var deliveryResetGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(attachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: attachment.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 46, height: 30)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .stroke(.white.opacity(0.13), lineWidth: 0.7)
                                    }
                                    .accessibilityIdentifier("prompt-image-attachment")
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.72))
                                }
                                .buttonStyle(.plain)
                                .clickableCursor()
                                .offset(x: 4, y: -4)
                                .accessibilityLabel("Remove \(attachment.url.lastPathComponent)")
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)
                .frame(height: 34)
            }

            HStack(alignment: .bottom, spacing: 3) {
                Button(action: chooseImages) {
                    Image(systemName: "paperclip")
                        .frame(width: 20, height: 20)
                }
                .help("Attach reference images")
                .accessibilityLabel("Attach reference images")
                .accessibilityIdentifier("attach-images")

                PasteAwarePromptEditor(
                    text: $draft,
                    height: $composerHeight,
                    placeholder: "Message \(session.name)…",
                    onSubmit: sendPrompt,
                    onPasteImage: pasteImages
                )
                .frame(height: composerHeight)
                .padding(.horizontal, 5)
                .accessibilityLabel("Prompt for \(session.name)")
                .accessibilityIdentifier("prompt-composer")

                Button(action: sendPrompt) {
                    Image(systemName: delivery == .sent ? "checkmark" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.black.opacity(0.82) : .white.opacity(0.24))
                        .frame(width: 24, height: 24)
                        .background(canSend ? Color.white.opacity(0.92) : .white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send to this session (Return or ⌘↩)")
                .accessibilityLabel("Send prompt to \(session.name)")
                .accessibilityIdentifier("send-prompt")
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .foregroundStyle(.white.opacity(0.46))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(minHeight: 30)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.7)
            }

            if delivery != .idle {
                HStack(spacing: 5) {
                    Image(systemName: delivery.icon)
                    Text(delivery.message).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(delivery.isError ? 0.72 : 0.38))
                .padding(.leading, 29)
                .accessibilityIdentifier("composer-system-status")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var canSend: Bool {
        delivery != .sending
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Attach reference images"
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addImageURLs(panel.urls) }
    }

    @discardableResult
    private func pasteImages() -> Bool {
        let pasteboard = NSPasteboard.general
        var images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []
        if images.isEmpty {
            let imageTypes: [NSPasteboard.PasteboardType] = [
                .png, .tiff, .init("public.jpeg"), .init("public.heic")
            ]
            for item in pasteboard.pasteboardItems ?? [] {
                if let data = imageTypes.lazy.compactMap({ item.data(forType: $0) }).first,
                   let image = NSImage(data: data) {
                    images.append(image)
                }
                if let urlString = item.string(forType: .fileURL),
                   let url = URL(string: urlString),
                   let image = NSImage(contentsOf: url) {
                    images.append(image)
                }
            }
        }
        guard !images.isEmpty else { return false }
        for image in images.prefix(max(0, 8 - attachments.count)) {
            guard let url = PromptAttachmentStorage.persist(image: image) else { continue }
            attachments.append(PromptImageAttachment(url: url, image: image))
        }
        delivery = .idle
        return true
    }

    private func addImageURLs(_ urls: [URL]) {
        for url in urls.prefix(max(0, 8 - attachments.count)) {
            guard let image = NSImage(contentsOf: url) else { continue }
            attachments.append(PromptImageAttachment(url: url, image: image))
        }
        delivery = .idle
    }

    private func sendPrompt() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePaths = attachments.map(\.url.path)
        let references = attachments.map { "- \($0.url.path)" }.joined(separator: "\n")
        let payload = references.isEmpty
            ? message
            : [message, "Reference images available at these local paths:\n\(references)"]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        guard !payload.isEmpty else { return }
        let originalDraft = draft
        let originalAttachments = attachments
        onOptimisticAdd(ChatTranscriptEntry(
            id: "optimistic-\(UUID().uuidString)",
            kind: .user,
            text: payload
        ))
        draft = ""
        attachments.removeAll()
        delivery = .sending
        Task {
            switch await sender.send(payload, imagePaths: imagePaths, to: session) {
            case .sent:
                NoturcodeSoundPlayer.shared.play(.send)
                delivery = .sent
                scheduleDeliveryReset()
            case .missing:
                restore(payload: payload, draft: originalDraft, attachments: originalAttachments)
                delivery = .error("Session is no longer open")
            case let .failed(message):
                restore(payload: payload, draft: originalDraft, attachments: originalAttachments)
                delivery = .error(message)
            }
        }
    }

    private func restore(payload: String, draft originalDraft: String, attachments originalAttachments: [PromptImageAttachment]) {
        onOptimisticRemove(payload)
        if draft.isEmpty { draft = originalDraft }
        if attachments.isEmpty { attachments = originalAttachments }
    }

    private func scheduleDeliveryReset() {
        deliveryResetGeneration &+= 1
        let generation = deliveryResetGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.25))
            guard deliveryResetGeneration == generation, delivery == .sent else { return }
            withAnimation(.easeOut(duration: 0.12)) { delivery = .idle }
        }
    }
}

private struct PromptImageAttachment: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
}

private enum PromptDeliveryState: Equatable {
    case idle
    case sending
    case sent
    case compacting
    case error(String)

    var icon: String {
        switch self {
        case .idle: "lock.shield"
        case .sending: "arrow.up.circle"
        case .sent: "checkmark.circle.fill"
        case .compacting: "arrow.down.right.and.arrow.up.left.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    var message: String {
        switch self {
        case .idle: "Local only"
        case .sending: "Sending"
        case .sent: "Sent"
        case .compacting: "Compaction requested"
        case let .error(message): message
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

private enum PromptAttachmentStorage {
    @MainActor
    static func persist(image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appendingPathComponent("Noturcode/Attachments", isDirectory: true)
            try SecureLocalStorage.ensurePrivateDirectory(at: directory)
            let url = directory.appendingPathComponent("reference-\(UUID().uuidString).png")
            try SecureLocalStorage.writePrivate(png, to: url)
            return url
        } catch {
            return nil
        }
    }
}

private extension String {
    var firstNonemptyLine: String? {
        components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
