import AppKit
import QuartzCore
import SwiftUI
import NoturcodeCore

struct NotchSurfaceView: View {
    let model: AppModel
    @ObservedObject var state: NotchPresentationState
    let metrics: NotchMetrics

    @ObservedObject private var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, state: NotchPresentationState, metrics: NotchMetrics) {
        self.model = model
        self.state = state
        self.metrics = metrics
        _store = ObservedObject(wrappedValue: model.store)
    }

    private var surfaceWidth: CGFloat {
        if state.isExpanded {
            return metrics.expandedSurfaceWidth(sessionNames: store.sessions.map(\.name))
        }
        return metrics.collapsedWidth(sessionNames: store.sessions.map(\.name))
    }

    private var surfaceHeight: CGFloat {
        if state.isExpanded {
            return metrics.expandedSurfaceHeight(
                sessionCount: store.sessions.count,
                activityAdjustment: state.activityHeightAdjustment(in: store.sessions)
            )
        }
        return metrics.collapsedHeight(sessionCount: store.sessions.count)
    }

    private var dockHeaderHeight: CGFloat {
        if state.isExpanded, metrics.hasHardwareNotch {
            return metrics.neckHeight + 30
        }
        return metrics.collapsedHeight(sessionCount: store.sessions.count)
    }

    private var coordinatedContentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.10).delay(0.04)),
            removal: .opacity.animation(.easeOut(duration: 0.05))
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if !store.sessions.isEmpty {
                // One persistent layer owns every state. Its geometry morphs
                // while content changes above it, avoiding a panel crossfade
                // that reads as a second card replacing the pill.
                surfaceBackground(width: surfaceWidth, height: surfaceHeight)
                    .shadow(
                        color: .black.opacity(state.isExpanded ? 0.32 : 0.14),
                        radius: state.isExpanded ? 16 : 7,
                        y: state.isExpanded ? 8 : 3
                    )

                VStack(spacing: 0) {
                    dockHeader
                    if state.isExpanded {
                        expandedDetails
                            .transition(coordinatedContentTransition)
                    }
                }
                .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)

            }
        }
        .offset(y: metrics.surfaceTopInset)
        .frame(width: metrics.envelopeWidth, height: metrics.envelopeHeight, alignment: .top)
        .animation(
            reduceMotion
                ? nil
                : (state.isExpanded
                    ? .spring(response: 0.24, dampingFraction: 0.90)
                    : .spring(response: 0.20, dampingFraction: 1.0)),
            value: state.isExpanded
        )
    }

    private var dockHeader: some View {
        AdaptiveDockHeader(
            sessions: store.sortedSessions,
            isExpanded: state.isExpanded,
            metrics: metrics,
            completionReads: model.completionReads,
            onShowAll: { state.expand() }
        )
        .frame(
            width: surfaceWidth,
            height: dockHeaderHeight,
            alignment: .top
        )
    }

    private var expandedDetails: some View {
        ExpandedSessionList(
            sessions: store.sortedSessions,
            staleMessage: store.lastStaleTargetMessage,
            model: model,
            state: state
        )
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func surfaceBackground(width: CGFloat, height: CGFloat) -> some View {
        if metrics.hasHardwareNotch {
            let shape = NotchSilhouette(
                neckWidth: min(metrics.neckWidth, width - 24),
                neckHeight: metrics.neckHeight,
                bottomRadius: state.isExpanded ? 18 : 14,
                topShoulderFill: 1
            )
            shape
                .fill(Color.black)
                .overlay {
                    shape.stroke(Color.white.opacity(0.055), lineWidth: 0.65)
                }
                .frame(width: width, height: height)
        } else {
            styledSurface(
                RoundedRectangle(cornerRadius: state.isExpanded ? 18 : 20, style: .continuous),
                width: width,
                height: height
            )
        }
    }

    private func styledSurface<S: Shape>(_ shape: S, width: CGFloat, height: CGFloat) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay {
                shape.fill(Color(red: 0.025, green: 0.029, blue: 0.038).opacity(0.88))
            }
            .overlay {
                shape.stroke(Color.white.opacity(0.075), lineWidth: 0.75)
            }
            .frame(width: width, height: height)
    }
}

private struct BillGatesQuoteRotator: View {
    private static let quotes = [
        "I have always been an optimist.",
        "The key will be, as always, innovation.",
        "The world can get better.",
        "The acceleration of innovation is just starting.",
        "The risks are real, but I am optimistic that they can be managed.",
        "We’ve done it before.",
        "We cannot merely hope for the best.",
        "We need to design for it, together."
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var quoteIndex = 0
    let alignment: Alignment

    init(alignment: Alignment = .leading) {
        self.alignment = alignment
    }

    var body: some View {
        Text("“\(Self.quotes[quoteIndex])” — Bill Gates")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: quoteIndex)
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityIdentifier("bill-gates-quote")
            .task {
                quoteIndex = Int.random(in: Self.quotes.indices)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { break }
                    let step = Int.random(in: 1..<Self.quotes.count)
                    quoteIndex = (quoteIndex + step) % Self.quotes.count
                }
            }
    }
}

struct NotchSilhouette: Shape {
    var neckWidth: CGFloat
    var neckHeight: CGFloat
    var bottomRadius: CGFloat
    var topShoulderFill: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(neckWidth, neckHeight), topShoulderFill) }
        set {
            neckWidth = newValue.first.first
            neckHeight = newValue.first.second
            topShoulderFill = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let neckLeft = midX - neckWidth / 2
        let neckRight = midX + neckWidth / 2
        let shoulderY = min(rect.height - bottomRadius - 1, neckHeight + 8)
        let bottomY = rect.maxY
        let radius = min(bottomRadius, rect.width / 4, max(2, rect.height / 3))
        let topShoulderFill = min(1, max(0, topShoulderFill))
        let topLeft = neckLeft + (rect.minX - neckLeft) * topShoulderFill
        let topRight = neckRight + (rect.maxX - neckRight) * topShoulderFill
        let shoulderControlInset = 18 * (1 - topShoulderFill)
        let shoulderControlRise = 8 * (1 - topShoulderFill)
        let topSideBottomY = max(rect.minY, neckHeight - 7) * (1 - topShoulderFill)

        var path = Path()
        path.move(to: CGPoint(x: topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: topRight, y: rect.minY))
        path.addLine(to: CGPoint(x: topRight, y: topSideBottomY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: shoulderY),
            control1: CGPoint(x: topRight, y: neckHeight + 4),
            control2: CGPoint(x: rect.maxX - shoulderControlInset, y: shoulderY - shoulderControlRise)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bottomY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: bottomY),
            control: CGPoint(x: rect.maxX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bottomY - radius),
            control: CGPoint(x: rect.minX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: shoulderY))
        path.addCurve(
            to: CGPoint(x: topLeft, y: topSideBottomY),
            control1: CGPoint(x: rect.minX + shoulderControlInset, y: shoulderY - shoulderControlRise),
            control2: CGPoint(x: topLeft, y: neckHeight + 4)
        )
        path.addLine(to: CGPoint(x: topLeft, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct AdaptiveDockHeader: View {
    let sessions: [TrackedSession]
    let isExpanded: Bool
    let metrics: NotchMetrics
    @ObservedObject var completionReads: CompletionReadStore
    let onShowAll: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animatedSessionID: String? {
        sessions.first(where: { $0.state.needsAttention })?.id ?? sessions.first?.id
    }

    private var sessionIDs: [String] {
        sessions.map(\.id)
    }

    private var primarySession: TrackedSession? {
        sessions.first(where: { $0.state == .working })
            ?? sessions.first(where: { $0.state.needsAttention })
            ?? sessions.first
    }

    private var sessionNames: String {
        sessions.map(\.name).joined(separator: ", ")
    }

    // Keep the shell mounted. Swap only its content in two stages.
    // See docs/NOTCH-MOTION.md.
    private var compactContentAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return isExpanded
            ? .easeOut(duration: 0.06)
            : .easeOut(duration: 0.10).delay(0.06)
    }

    private var quoteContentAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return isExpanded
            ? .easeOut(duration: 0.10).delay(0.06)
            : .easeOut(duration: 0.06)
    }

    var body: some View {
        Group {
            if metrics.hasHardwareNotch {
                hardwareNotchHeader
            } else {
                floatingPillHeader
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "Noturcode quote" : "Noturcode, \(sessions.count) connected sessions: \(sessionNames)")
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: sessionIDs)
    }

    private var floatingPillHeader: some View {
        HStack(spacing: 8) {
            NoturcodeBrandMark(size: 19)
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 20)
            ZStack(alignment: .leading) {
                sessionStrip(sessions)
                    .opacity(isExpanded ? 0 : 1)
                    .animation(compactContentAnimation, value: isExpanded)
                    .allowsHitTesting(!isExpanded)
                    .accessibilityHidden(isExpanded)

                BillGatesQuoteRotator()
                    .opacity(isExpanded ? 1 : 0)
                    .animation(quoteContentAnimation, value: isExpanded)
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: metrics.dockRailHeight(sessionCount: sessions.count))
        .padding(.top, metrics.dockContentTopInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var hardwareNotchHeader: some View {
        let primarySession = sessions.first
        let additionalSessions = Array(sessions.dropFirst())
        let primaryChipWidth = primarySession.map { metrics.sessionChipWidth(for: $0.name) } ?? 62

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    NoturcodeBrandMark(size: 19)
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 1, height: 20)
                        if let primarySession {
                            sessionChip(primarySession, width: primaryChipWidth)
                        }
                    }
                    .opacity(isExpanded ? 0 : 1)
                    .animation(compactContentAnimation, value: isExpanded)
                    .allowsHitTesting(!isExpanded)
                }
                .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .trailing)

                Color.clear.frame(width: metrics.neckWidth, height: metrics.neckHeight)

                HStack(spacing: 0) {
                    if !additionalSessions.isEmpty {
                        overflowChip(sessions: additionalSessions, width: 78)
                    }
                }
                .opacity(isExpanded ? 0 : 1)
                .animation(compactContentAnimation, value: isExpanded)
                .allowsHitTesting(!isExpanded)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: metrics.neckHeight)

            BillGatesQuoteRotator(alignment: .center)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .opacity(isExpanded ? 1 : 0)
                .animation(quoteContentAnimation, value: isExpanded)
                .accessibilityHidden(!isExpanded)
        }
    }

    @ViewBuilder
    private func sessionStrip(_ values: [TrackedSession]) -> some View {
        if !values.isEmpty {
            let visibleSessions = Array(values.prefix(3))
            let hiddenSessions = Array(values.dropFirst(3))
            let overflowCount = max(0, values.count - 3)
            let chipWidth = values.map { metrics.sessionChipWidth(for: $0.name) }.max() ?? 50
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(visibleSessions) { session in
                        sessionChip(session, width: chipWidth)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                    if overflowCount > 0 {
                        overflowChip(sessions: hiddenSessions, width: chipWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionChip(_ session: TrackedSession, width: CGFloat) -> some View {
        let isPrimary = session.id == primarySession?.id
        return HStack(spacing: 5) {
            SessionMarble(
                session: session,
                size: 26,
                animate: true,
                completionIsUnread: completionReads.isUnread(session)
            )
            ProviderMark(source: session.key.source, size: 9)
            Text(session.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .frame(width: width, height: 36, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(isPrimary ? 0.075 : 0.035))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(isPrimary ? 0.11 : 0.055), lineWidth: 0.6)
                )
        )
        .accessibilityElement(children: .combine)
    }

    private func overflowState(for sessions: [TrackedSession]) -> SessionState {
        if sessions.contains(where: { $0.state == .askingYou }) { return .askingYou }
        if sessions.contains(where: { $0.state == .failed }) { return .failed }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        if sessions.contains(where: { $0.state == .done }) { return .done }
        return .idle
    }

    private func overflowChip(sessions: [TrackedSession], width: CGFloat) -> some View {
        let count = sessions.count
        let overflowState = overflowState(for: sessions)
        let completionIsUnread = sessions.contains(where: { completionReads.isUnread($0) })
        return Button(action: onShowAll) {
            HStack(spacing: 5) {
                SessionMarble(
                    name: "More sessions",
                    state: overflowState,
                    source: nil,
                    size: 26,
                    animate: true,
                    completionIsUnread: completionIsUnread
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text("+\(count)")
                        .font(.system(size: 10, weight: .semibold))
                    Text(overflowState.displayName.lowercased())
                        .font(.system(size: 7, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white.opacity(0.66))
            .padding(.horizontal, 7)
            .frame(width: width, height: 36, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.035))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(0.055), lineWidth: 0.6)
                    }
            )
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel("Show \(count) more connected sessions, \(overflowState.displayName.lowercased())")
    }
}

@MainActor
final class AnnouncementHoverState: ObservableObject {
    @Published var isHovered = false
}

struct AnnouncementView: View {
    let announcement: AttentionAnnouncement
    @ObservedObject var hoverState: AnnouncementHoverState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        switch announcement.kind {
        case .done: .green
        case .asking: .orange
        case .remotePaste:
            switch announcement.remotePasteStage {
            case .sent: .green
            case .failed: .red
            case .preparing, .uploading, .inserting, .none: .cyan
            }
        }
    }

    private var statusText: String {
        switch announcement.kind {
        case .done: "Finished — click to open"
        case .asking: "Needs your attention"
        case .remotePaste:
            switch announcement.remotePasteStage {
            case .preparing: "Preparing image"
            case let .uploading(host): "Uploading image to \(host)"
            case .inserting: "Sending image to the session"
            case .sent: "Image sent"
            case .failed: "Upload failed"
            case .none: "Preparing image"
            }
        }
    }

    private var statusSymbol: String {
        switch announcement.kind {
        case .done: "checkmark.circle.fill"
        case .asking: "exclamationmark.circle.fill"
        case .remotePaste:
            switch announcement.remotePasteStage {
            case .sent: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            case .preparing, .uploading, .inserting, .none: "arrow.up.circle.fill"
            }
        }
    }

    private var detailText: String? {
        switch announcement.remotePasteStage {
        case let .inserting(remotePath), let .sent(remotePath):
            URL(fileURLWithPath: remotePath).lastPathComponent
        case let .failed(message): message
        case .preparing, .uploading, .none: nil
        }
    }

    private var isRemotePasteActive: Bool {
        announcement.kind == .remotePaste && announcement.remotePasteStage?.isTerminal == false
    }

    var body: some View {
        HStack(spacing: 11) {
                SessionMarble(
                    name: announcement.name,
                    state: announcement.kind == .done ? .done : .askingYou,
                    source: nil,
                    size: 24,
                    animate: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(announcement.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.97))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Label(statusText, systemImage: statusSymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.90))
                    if let detailText {
                        Text(detailText)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if isRemotePasteActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                        .frame(width: 17, height: 17)
                } else {
                    AnnouncementProgressRing(announcement: announcement)
                        .frame(width: 17, height: 17)
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.025, green: 0.029, blue: 0.038).opacity(0.90))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.75)
                }
                .overlay {
                    NodaConicGlow(
                        isActive: hoverState.isHovered,
                        reduceMotion: reduceMotion,
                        color: NSColor(red: 0.776, green: 0.910, blue: 0.235, alpha: 1),
                        cornerRadius: 18
                    )
                }
        }
        .padding(10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: hoverState.isHovered)
        .clickableCursor()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(announcement.name), \(announcement.kind.label)")
        .accessibilityHint("Focus this session in iTerm2")
    }
}

struct NodaConicGlow: NSViewRepresentable {
    let isActive: Bool
    let reduceMotion: Bool
    let color: NSColor
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NodaConicGlowView {
        NodaConicGlowView()
    }

    func updateNSView(_ view: NodaConicGlowView, context: Context) {
        view.configure(
            isActive: isActive,
            reduceMotion: reduceMotion,
            color: color,
            cornerRadius: cornerRadius
        )
    }

    static func dismantleNSView(_ view: NodaConicGlowView, coordinator: ()) {
        view.stopAnimating()
    }
}

final class NodaConicGlowView: NSView {
    private let effectLayer = CALayer()
    private let ringContainer = CALayer()
    private let haloContainer = CALayer()
    private let ringGradient = CAGradientLayer()
    private let haloGradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let haloMask = CAShapeLayer()
    private var configuredActive: Bool?
    private var configuredReduceMotion: Bool?
    private var configuredColor: NSColor?
    private var configuredCornerRadius: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        layer?.addSublayer(effectLayer)
        effectLayer.addSublayer(haloContainer)
        effectLayer.addSublayer(ringContainer)

        configureGradient(ringGradient)
        configureGradient(haloGradient)
        ringContainer.addSublayer(ringGradient)
        haloContainer.addSublayer(haloGradient)

        configureMask(ringMask, lineWidth: 1.5)
        configureMask(haloMask, lineWidth: 4.8)
        ringContainer.mask = ringMask
        haloContainer.mask = haloMask
        haloContainer.opacity = 0.23
        effectLayer.opacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.frame = bounds
        ringContainer.frame = bounds
        haloContainer.frame = bounds
        updateMask(ringMask, lineWidth: 1.5, cornerRadius: configuredCornerRadius)
        updateMask(haloMask, lineWidth: 4.8, cornerRadius: configuredCornerRadius)

        let side = max(bounds.width, bounds.height) * 2.4
        let gradientFrame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        ringGradient.frame = gradientFrame
        haloGradient.frame = gradientFrame
        CATransaction.commit()
    }

    func configure(isActive: Bool, reduceMotion: Bool, color: NSColor, cornerRadius: CGFloat) {
        let colorChanged = configuredColor?.isEqual(color) != true
        let radiusChanged = configuredCornerRadius != cornerRadius
        guard configuredActive != isActive || configuredReduceMotion != reduceMotion || colorChanged || radiusChanged else { return }
        configuredActive = isActive
        configuredReduceMotion = reduceMotion
        configuredColor = color
        configuredCornerRadius = cornerRadius
        if colorChanged {
            let colors = gradientColors(for: color)
            ringGradient.colors = colors
            haloGradient.colors = colors
        }
        if radiusChanged {
            needsLayout = true
        }
        setVisible(isActive, animated: !reduceMotion)
        reduceMotion ? stopAnimating() : startAnimating()
    }

    private func configureGradient(_ gradient: CAGradientLayer) {
        gradient.type = .conic
        gradient.locations = [0.00, 0.19, 0.39, 0.61, 0.83, 1.00]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.0)
    }

    private func gradientColors(for color: NSColor) -> [CGColor] {
        [
            NSColor.clear.cgColor,
            color.withAlphaComponent(0.60).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.black.withAlphaComponent(0.55).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor,
        ]
    }

    private func configureMask(_ mask: CAShapeLayer, lineWidth: CGFloat) {
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = lineWidth
    }

    private func updateMask(_ mask: CAShapeLayer, lineWidth: CGFloat, cornerRadius: CGFloat) {
        mask.frame = bounds
        mask.path = CGPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        let current = effectLayer.presentation()?.opacity ?? effectLayer.opacity
        effectLayer.removeAnimation(forKey: "noturcode.noda-glow-fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.opacity = target
        CATransaction.commit()
        guard animated, current != target else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = target
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        effectLayer.add(fade, forKey: "noturcode.noda-glow-fade")
    }

    private func startAnimating() {
        guard ringGradient.animation(forKey: "noturcode.noda-glow-spin") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = 5
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        ringGradient.add(rotation, forKey: "noturcode.noda-glow-spin")
        haloGradient.add(rotation.copy() as! CAAnimation, forKey: "noturcode.noda-glow-spin")
    }

    func stopAnimating() {
        ringGradient.removeAnimation(forKey: "noturcode.noda-glow-spin")
        haloGradient.removeAnimation(forKey: "noturcode.noda-glow-spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringGradient.transform = CATransform3DIdentity
        haloGradient.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}

private struct AnnouncementProgressRing: NSViewRepresentable {
    let announcement: AttentionAnnouncement

    func makeNSView(context: Context) -> AnnouncementProgressRingView {
        AnnouncementProgressRingView()
    }

    func updateNSView(_ view: AnnouncementProgressRingView, context: Context) {
        view.configure(announcement)
    }
}

private final class AnnouncementProgressRingView: NSView {
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private var configuredID: UUID?
    private var configuredPaused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [trackLayer, progressLayer] {
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = 1.5
            layer?.addSublayer(shape)
        }
        trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
        progressLayer.strokeColor = NSColor.white.withAlphaComponent(0.88).cgColor
        progressLayer.lineCap = .round
        progressLayer.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [trackLayer, progressLayer] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    func configure(_ announcement: AttentionAnnouncement) {
        guard configuredID != announcement.id || configuredPaused != announcement.isPaused else { return }
        configuredID = announcement.id
        configuredPaused = announcement.isPaused
        progressLayer.removeAnimation(forKey: "noturcode.announcement-progress")

        let remainingFraction = announcement.progress(at: Date())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.strokeEnd = remainingFraction
        CATransaction.commit()
        guard !announcement.isPaused, announcement.remaining > 0 else { return }

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = remainingFraction
        animation.toValue = 0
        animation.duration = max(0.05, announcement.remaining)
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        progressLayer.add(animation, forKey: "noturcode.announcement-progress")
    }
}
