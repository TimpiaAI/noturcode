import SwiftUI
import NoturcodeCore

/// A fixed AppKit envelope hosts both the compact dock and its hover-opened
/// notch surface. Only SwiftUI content morphs, so WindowServer geometry stays
/// stable while the visible surface grows down from the display edge.
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

    private var dockWidth: CGFloat {
        min(metrics.envelopeWidth - 12, max(390, metrics.dockWidth(sessionCount: store.sessions.count)))
    }

    private var surfaceWidth: CGFloat {
        if state.isExpanded { return min(520, metrics.envelopeWidth - 12) }
        return min(metrics.envelopeWidth - 12, dockWidth + (state.isPrehover ? 8 : 0))
    }

    private var surfaceHeight: CGFloat {
        guard state.isExpanded else { return metrics.dockHeight }
        return metrics.expandedDockHeight(sessionCount: store.sessions.count)
    }

    private var morphAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .timingCurve(0.16, 1, 0.3, 1, duration: state.isExpanded ? 0.24 : 0.18)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if !store.sessions.isEmpty {
                VStack(spacing: 0) {
                    SessionDock(
                        sessions: store.sortedSessions,
                        metrics: metrics,
                        width: surfaceWidth,
                        showsHoverLabel: !state.isExpanded,
                        hoveredSessionID: state.hoveredSessionID,
                        completionReads: model.completionReads,
                        onHover: state.setHoveredSession,
                        onOpenWorkspace: model.showStatusWindow,
                        onSelect: { session in
                            state.select(session) { model.jump(to: session) }
                        }
                    )

                    if state.isExpanded {
                        Rectangle()
                            .fill(.white.opacity(0.08))
                            .frame(height: 0.5)
                            .padding(.horizontal, 14)

                        ExpandedSessionList(
                            sessions: store.sortedSessions,
                            staleMessage: store.lastStaleTargetMessage,
                            model: model,
                            state: state
                        )
                        .padding(.top, 7)
                        .padding(.bottom, 10)
                        .frame(height: max(0, surfaceHeight - metrics.dockHeight - 0.5))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
                .background {
                    DockShelfShape(bottomRadius: state.isExpanded ? 19 : 13)
                        .fill(metrics.hasHardwareNotch ? AnyShapeStyle(Color(red: 0.025, green: 0.029, blue: 0.038)) : AnyShapeStyle(.ultraThinMaterial))
                        .overlay {
                            DockShelfShape(bottomRadius: state.isExpanded ? 19 : 13)
                                .fill(Color(red: 0.025, green: 0.029, blue: 0.038).opacity(metrics.hasHardwareNotch ? 0.98 : 0.90))
                        }
                        .overlay {
                            DockShelfShape(bottomRadius: state.isExpanded ? 19 : 13)
                                .stroke(.white.opacity(state.isExpanded ? 0.09 : 0.075), lineWidth: 0.7)
                        }
                }
                .clipShape(DockShelfShape(bottomRadius: state.isExpanded ? 19 : 13))
                .shadow(color: .black.opacity(state.isExpanded ? 0.30 : 0.22), radius: state.isExpanded ? 18 : 10, y: state.isExpanded ? 9 : 5)
                .scaleEffect(state.isPrehover ? 1.006 : 1, anchor: .top)
                .animation(morphAnimation, value: state.isExpanded)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.isPrehover)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("session-dock")
            }
        }
        .offset(y: metrics.surfaceTopInset)
        .frame(width: metrics.envelopeWidth, height: metrics.envelopeHeight, alignment: .top)
    }
}

private struct SessionDock: View {
    let sessions: [TrackedSession]
    let metrics: NotchMetrics
    let width: CGFloat
    let showsHoverLabel: Bool
    let hoveredSessionID: String?
    @ObservedObject var completionReads: CompletionReadStore
    let onHover: (String?) -> Void
    let onOpenWorkspace: () -> Void
    let onSelect: (TrackedSession) -> Void

    private var visibleSessions: [TrackedSession] { Array(sessions.prefix(12)) }
    private var overflowCount: Int { max(0, sessions.count - visibleSessions.count) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpenWorkspace) {
                NoturcodeBrandMark(size: 19)
                    .frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(DockButtonStyle())
            .help("Open Noturcode workspace")
            .accessibilityLabel("Open Noturcode workspace")

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1, height: 20)

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(visibleSessions) { session in
                        DockSessionButton(
                            session: session,
                            isHovered: hoveredSessionID == session.id,
                            isUnread: completionReads.isUnread(session),
                            onHover: onHover,
                            onSelect: onSelect
                        )
                    }

                    if overflowCount > 0 {
                        Text("+\(overflowCount)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.54))
                            .frame(height: 28)
                            .accessibilityLabel("\(overflowCount) more sessions")
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 10)
        .padding(.top, metrics.hasHardwareNotch ? metrics.neckHeight : 0)
        .frame(width: width, height: metrics.dockHeight)
        .overlay(alignment: .top) {
            if showsHoverLabel,
               let hovered = visibleSessions.first(where: { $0.id == hoveredSessionID }) {
                DockSessionLabel(session: hovered)
                    .offset(y: metrics.dockHeight + 5)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Noturcode session dock, \(sessions.count) connected sessions")
    }
}

private struct DockSessionButton: View {
    let session: TrackedSession
    let isHovered: Bool
    let isUnread: Bool
    let onHover: (String?) -> Void
    let onSelect: (TrackedSession) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { onSelect(session) } label: {
            SessionMarble(
                session: session,
                size: 20,
                animate: session.state == .working || isHovered,
                completionIsUnread: isUnread
            )
            .scaleEffect(isHovered ? 1.12 : 1)
            .offset(y: isHovered ? -2 : 0)
            .frame(width: 28, height: 28, alignment: .top)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(DockButtonStyle())
        .onHover { hovering in onHover(hovering ? session.id : nil) }
        .help("\(session.name), \(session.state.displayName). Click to show in iTerm2.")
        .accessibilityLabel("\(session.name), \(session.key.source.displayName), \(session.state.displayName)")
        .accessibilityHint("Show this session in iTerm2")
        .accessibilityIdentifier("dock-session-\(session.id)")
        .animation(reduceMotion ? nil : .snappy(duration: 0.13, extraBounce: 0), value: isHovered)
        .zIndex(isHovered ? 2 : 0)
    }
}

private struct DockSessionLabel: View {
    let session: TrackedSession

    var body: some View {
        HStack(spacing: 5) {
            ProviderMark(source: session.key.source, size: 11)
            Text(session.name)
                .font(.system(size: 11, weight: .semibold))
            Text(session.state.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(Color(red: 0.045, green: 0.049, blue: 0.058), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.30), radius: 8, y: 4)
    }
}

private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct DockShelfShape: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomRadius, rect.height / 2, rect.width / 4)
        var path = Path()
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct AnnouncementView: View {
    let announcement: AttentionAnnouncement

    private var accent: Color { announcement.kind == .done ? .green : .orange }

    var body: some View {
        HStack(spacing: 11) {
            SessionMarble(name: announcement.name, state: announcement.kind == .done ? .done : .askingYou, source: nil, size: 24, animate: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(announcement.name).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                Label(announcement.kind == .done ? "Finished, click to open" : "Needs your attention", systemImage: announcement.kind == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.90))
            }
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: announcement.isPaused)) { context in
                ZStack {
                    Circle().stroke(.white.opacity(0.16), lineWidth: 1.5)
                    Circle().trim(from: 0, to: announcement.progress(at: context.date)).stroke(.white.opacity(0.88), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 17, height: 17)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .foregroundStyle(.white.opacity(0.97))
        .contentShape(Rectangle())
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 0.75))
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(announcement.name), \(announcement.kind.label)")
        .accessibilityHint("Focus this session in iTerm2")
    }
}
