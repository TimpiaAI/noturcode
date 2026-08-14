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
        return metrics.collapsedWidth(sessionCount: store.sessions.count)
    }

    private var surfaceHeight: CGFloat {
        if state.isExpanded {
            return min(
                520,
                metrics.expandedHeight(sessionCount: store.sessions.count)
                    + state.activityHeightAdjustment(in: store.sessions)
            )
        }
        return max(40, metrics.neckHeight)
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

                if state.isExpanded {
                    expandedSurface
                        .transition(coordinatedContentTransition)
                } else {
                    RestIndicatorView(
                        sessions: store.sortedSessions,
                        metrics: metrics,
                        completionReads: model.completionReads
                    )
                        .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
                        .transition(coordinatedContentTransition)
                }

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

    private var expandedSurface: some View {
        ExpandedSessionList(
            sessions: store.sortedSessions,
            staleMessage: store.lastStaleTargetMessage,
            model: model,
            state: state
        )
        .padding(.top, metrics.neckHeight + 9)
        .padding(.bottom, 12)
        .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
    }

    @ViewBuilder
    private func surfaceBackground(width: CGFloat, height: CGFloat) -> some View {
        if metrics.hasHardwareNotch {
            let shape = NotchSilhouette(
                neckWidth: min(metrics.neckWidth, width - 24),
                neckHeight: metrics.neckHeight,
                bottomRadius: state.isExpanded ? 18 : 14
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

struct NotchSilhouette: Shape {
    var neckWidth: CGFloat
    var neckHeight: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(neckWidth, neckHeight) }
        set {
            neckWidth = newValue.first
            neckHeight = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let midX = rect.midX
        let neckLeft = midX - neckWidth / 2
        let neckRight = midX + neckWidth / 2
        let shoulderY = min(rect.height - bottomRadius - 1, neckHeight + 13)
        let bottomY = rect.maxY
        let radius = min(bottomRadius, rect.width / 4, max(2, rect.height / 3))

        var path = Path()
        path.move(to: CGPoint(x: neckLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: neckRight, y: rect.minY))
        path.addLine(to: CGPoint(x: neckRight, y: max(rect.minY, neckHeight - 7)))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: shoulderY),
            control1: CGPoint(x: neckRight, y: neckHeight + 4),
            control2: CGPoint(x: rect.maxX - 18, y: shoulderY - 8)
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
            to: CGPoint(x: neckLeft, y: max(rect.minY, neckHeight - 7)),
            control1: CGPoint(x: rect.minX + 18, y: shoulderY - 8),
            control2: CGPoint(x: neckLeft, y: neckHeight + 4)
        )
        path.closeSubpath()
        return path
    }
}

private struct RestIndicatorView: View {
    let sessions: [TrackedSession]
    let metrics: NotchMetrics
    @ObservedObject var completionReads: CompletionReadStore

    private var working: [TrackedSession] {
        sessions.filter { !$0.state.needsAttention }
    }

    private var attention: [TrackedSession] {
        sessions.filter(\.state.needsAttention)
    }

    private var animatedSessionID: String? {
        attention.first?.id ?? working.first?.id
    }

    private var sessionIDs: [String] {
        sessions.map(\.id)
    }

    private var primarySession: TrackedSession? {
        sessions.first(where: { $0.state == .working })
            ?? attention.first
            ?? sessions.first
    }

    private var compactActivityText: String {
        guard let session = primarySession else { return "Connected" }
        let raw = session.currentActivity?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return session.state.displayName }

        // The compact surface describes the operation, never its command,
        // arguments, paths, or prompt contents.
        let firstLine = raw.components(separatedBy: .newlines).first ?? raw
        let operation = firstLine.components(separatedBy: " · ").first ?? firstLine
        return String(operation.prefix(32))
    }

    var body: some View {
        Group {
            if metrics.hasHardwareNotch {
                HStack(spacing: 8) {
                    NoturcodeBrandMark(size: 19)
                    sessionStrip(working)
                    Color.clear.frame(width: metrics.neckWidth, height: metrics.neckHeight)
                    sessionStrip(attention)
                }
            } else {
                HStack(spacing: 8) {
                    NoturcodeBrandMark(size: 19)
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1, height: 20)
                    sessionStrip(sessions)
                }
            }
        }
        .padding(.horizontal, metrics.hasHardwareNotch ? 9 : 14)
        .frame(maxHeight: metrics.neckHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Noturcode, \(sessions.count) connected sessions, \(primarySession?.name ?? "no session"), \(compactActivityText)"
        )
        .animation(.easeOut(duration: 0.14), value: compactActivityText)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: sessionIDs)
    }

    @ViewBuilder
    private func sessionStrip(_ values: [TrackedSession]) -> some View {
        if !values.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(values) { session in
                        sessionChip(session)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
            }
            .scrollClipDisabled()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sessionChip(_ session: TrackedSession) -> some View {
        let isPrimary = session.id == primarySession?.id
        return HStack(spacing: 5) {
            SessionMarble(
                session: session,
                size: 15,
                animate: session.id == animatedSessionID,
                completionIsUnread: completionReads.isUnread(session)
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(session.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isPrimary {
                    Text(compactActivityText)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
            }
        }
        .frame(maxWidth: isPrimary ? 116 : 88, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, isPrimary ? 4 : 6)
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
        .padding(.vertical, 12)
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
