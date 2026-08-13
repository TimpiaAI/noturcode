import SwiftUI
import NoturcodeCore

/// The always-available session dock. The AppKit envelope never changes size;
/// only lightweight SwiftUI hover feedback is drawn inside it.
struct NotchSurfaceView: View {
    let model: AppModel
    @ObservedObject var state: NotchPresentationState
    let metrics: NotchMetrics

    @ObservedObject private var store: SessionStore

    init(model: AppModel, state: NotchPresentationState, metrics: NotchMetrics) {
        self.model = model
        self.state = state
        self.metrics = metrics
        _store = ObservedObject(wrappedValue: model.store)
    }

    private var dockWidth: CGFloat {
        min(metrics.envelopeWidth - 12, max(390, metrics.dockWidth(sessionCount: store.sessions.count)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            if !store.sessions.isEmpty {
                SessionDock(
                    sessions: store.sortedSessions,
                    metrics: metrics,
                    width: dockWidth,
                    hoveredSessionID: state.hoveredSessionID,
                    completionReads: model.completionReads,
                    onHover: state.setHoveredSession,
                    onOpenWorkspace: model.showStatusWindow,
                    onSelect: { session in
                        state.select(session) { model.jump(to: session) }
                    }
                )
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
        .background {
            DockShelfShape(bottomRadius: 13)
                .fill(metrics.hasHardwareNotch ? AnyShapeStyle(Color(red: 0.025, green: 0.029, blue: 0.038)) : AnyShapeStyle(.ultraThinMaterial))
                .overlay {
                    DockShelfShape(bottomRadius: 13)
                        .fill(Color(red: 0.025, green: 0.029, blue: 0.038).opacity(metrics.hasHardwareNotch ? 0.98 : 0.88))
                }
                .overlay {
                    DockShelfShape(bottomRadius: 13)
                        .stroke(.white.opacity(0.075), lineWidth: 0.7)
                }
        }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .overlay(alignment: .top) {
            if let hovered = visibleSessions.first(where: { $0.id == hoveredSessionID }) {
                DockSessionLabel(session: hovered)
                    .offset(y: metrics.dockHeight + 5)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Noturcode session dock, \(sessions.count) connected sessions")
        .accessibilityIdentifier("session-dock")
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
