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
        if state.isExpanded { return min(420, metrics.envelopeWidth - 16) }
        return metrics.collapsedWidth(sessionNames: store.sessions.map(\.name))
    }

    private var surfaceHeight: CGFloat {
        if state.isExpanded {
            return min(
                520,
                metrics.expandedHeight(sessionCount: store.sessions.count)
                    + metrics.dockRailHeight(sessionCount: store.sessions.count)
                    + state.activityHeightAdjustment(in: store.sessions)
            )
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
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0),
            value: surfaceHeight
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
            height: metrics.collapsedHeight(sessionCount: store.sessions.count),
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

    var body: some View {
        Text("“\(Self.quotes[quoteIndex])” — Bill Gates")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: quoteIndex)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "Noturcode quote" : "Noturcode, \(sessions.count) connected sessions: \(sessionNames)")
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: sessionIDs)
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
                size: 15,
                animate: session.id == animatedSessionID,
                completionIsUnread: completionReads.isUnread(session)
            )
            Text(session.name)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .frame(width: width, height: 30, alignment: .leading)
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
                    size: 15,
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
            .frame(width: width, height: 30, alignment: .leading)
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
        .accessibilityLabel("Show \(count) more connected sessions, \(overflowState.displayName.lowercased())")
    }
}

struct AnnouncementView: View {
    let announcement: AttentionAnnouncement

    private var accent: Color {
        announcement.kind == .done ? .green : .orange
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
                    Label(
                        announcement.kind == .done ? "Finished — click to open" : "Needs your attention",
                        systemImage: announcement.kind == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.90))
                }
                Spacer(minLength: 0)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: announcement.isPaused)) { context in
                    ZStack {
                        Circle().stroke(.white.opacity(0.16), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: announcement.progress(at: context.date))
                            .stroke(.white.opacity(0.88), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 17, height: 17)
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
        }
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(announcement.name), \(announcement.kind.label)")
        .accessibilityHint("Focus this session in iTerm2")
    }
}
