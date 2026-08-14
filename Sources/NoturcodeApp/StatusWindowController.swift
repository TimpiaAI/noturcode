import AppKit
import ServiceManagement
import SwiftUI
import NoturcodeCore

@MainActor
final class StatusWindowController: NSWindowController, NSWindowDelegate {
    static let shared = StatusWindowController()
    private let shellSizingKey = "noturcode.full-app-shell-v2-sized"

    private var hostingController: NSHostingController<StatusOverviewView>?

    private init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1500, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Noturcode"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.047, green: 0.050, blue: 0.059, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = CGSize(width: 980, height: 640)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            window.setContentSize(CGSize(
                width: min(1_620, visible.width * 0.92),
                height: min(1_040, visible.height * 0.92)
            ))
            window.center()
        }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show(model: AppModel) {
        guard let window else { return }
        let rootView = StatusOverviewView(model: model)
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hosting = NSHostingController(rootView: rootView)
            hostingController = hosting
            window.contentViewController = hosting
        }
        if !UserDefaults.standard.bool(forKey: shellSizingKey),
           let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let target = CGSize(
                width: min(1_620, max(1_240, visible.width * 0.88)),
                height: min(1_040, max(760, visible.height * 0.88))
            )
            window.setContentSize(target)
            window.center()
            UserDefaults.standard.set(true, forKey: shellSizingKey)
        }
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }
}

private struct StatusOverviewView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store: SessionStore
    @ObservedObject private var loginItem: LoginItemController
    @ObservedObject private var completionReads: CompletionReadStore
    @State private var selectedSessionID: String?
    @State private var searchText = ""
    @State private var isSidebarVisible = true

    init(model: AppModel) {
        self.model = model
        _store = ObservedObject(wrappedValue: model.store)
        _loginItem = ObservedObject(wrappedValue: model.loginItem)
        _completionReads = ObservedObject(wrappedValue: model.completionReads)
    }

    private var sessions: [TrackedSession] { store.sortedSessions }
    private var filteredSessions: [TrackedSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.key.source.displayName.localizedCaseInsensitiveContains(searchText)
                || ($0.cwd?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    private var selectedSession: TrackedSession? {
        sessions.first(where: { $0.id == selectedSessionID }) ?? sessions.first
    }
    private var attentionSessions: [TrackedSession] {
        filteredSessions.filter { $0.state == .askingYou || $0.state == .failed || completionReads.isUnread($0) }
    }
    private var activeSessions: [TrackedSession] {
        filteredSessions.filter { $0.state == .working && !attentionSessions.contains($0) }
    }
    private var settledSessions: [TrackedSession] {
        filteredSessions.filter { !attentionSessions.contains($0) && !activeSessions.contains($0) }
    }
    private var shellMotion: Animation? {
        reduceMotion ? .easeOut(duration: 0.08) : .smooth(duration: 0.20)
    }

    var body: some View {
        HStack(spacing: -14) {
            if isSidebarVisible {
                sessionSidebar
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            applicationShell
        }
        .background(Color(red: 0.020, green: 0.022, blue: 0.028))
        .frame(minWidth: 980, minHeight: 640)
        .animation(shellMotion, value: isSidebarVisible)
        .onAppear { if selectedSessionID == nil { selectedSessionID = sessions.first?.id } }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if selectedSessionID == nil || !ids.contains(selectedSessionID ?? "") {
                selectedSessionID = ids.first
            }
        }
    }

    private var applicationShell: some View {
        workspace
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.061, green: 0.064, blue: 0.074))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.44), radius: 18, x: -4, y: 0)
            .padding(.vertical, 10)
            .padding(.trailing, 10)
            .zIndex(1)
    }

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                NoturcodeBrandMark(size: 21)
                Text("Noturcode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.91))
                Spacer()
                Menu {
                    Button("Start Codex") { model.createNativeSession(provider: .codex) }
                    Button("Start Gemini") { model.createNativeSession(provider: .gemini) }
                    Button("Start Grok") { model.createNativeSession(provider: .grok) }
                    Divider()
                    Button("Connect OpenCode") { model.connectOpenCodeServer() }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
                .clickableCursor()
                .help("Start or connect a native coding session")
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 12)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                TextField("Search sessions", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 10)
            .frame(height: 31)
            .background(.white.opacity(0.048), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.055), lineWidth: 0.7) }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    sessionSection("Needs attention", sessions: attentionSessions)
                    sessionSection("Working", sessions: activeSessions)
                    sessionSection("Recent", sessions: settledSessions)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.hidden)

            Rectangle().fill(.white.opacity(0.065)).frame(height: 1)
            HStack(spacing: 7) {
                Circle().fill(.green.opacity(0.68)).frame(width: 5, height: 5)
                Text("\(sessions.count) connected")
                Spacer()
                Toggle("", isOn: loginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Open at login")
                    .accessibilityIdentifier("open-at-login-toggle")
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.38))
            .padding(.horizontal, 14)
            .frame(height: 42)
        }
        .frame(width: 272)
        .frame(width: 286, alignment: .leading)
        .background(Color(red: 0.020, green: 0.022, blue: 0.028))
        .accessibilityIdentifier("desktop-session-sidebar")
    }

    @ViewBuilder
    private func sessionSection(_ title: String, sessions: [TrackedSession]) -> some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.27))
                    .padding(.horizontal, 8)
                ForEach(sessions) { session in sessionSidebarRow(session) }
            }
        }
    }

    private func sessionSidebarRow(_ session: TrackedSession) -> some View {
        let selected = selectedSession?.id == session.id
        return Button {
            withAnimation(shellMotion) {
                selectedSessionID = session.id
                completionReads.markSeen(session)
            }
        } label: {
            HStack(spacing: 9) {
                SessionMarble(session: session, size: 22, animate: selected)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(session.name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        ProviderMark(source: session.key.source, size: 9)
                        Spacer(minLength: 2)
                        if session.state == .askingYou {
                            Circle().fill(.orange.opacity(0.8)).frame(width: 5, height: 5)
                        }
                    }
                    Text(session.currentActivity ?? session.state.displayName)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? .white.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .foregroundStyle(.white.opacity(selected ? 0.94 : 0.72))
        .accessibilityIdentifier("desktop-session-row")
    }

    @ViewBuilder
    private var workspace: some View {
        if let session = selectedSession {
            VStack(spacing: 0) {
                workspaceHeader(session)
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                TerminalViewportContent(
                    session: session,
                    reader: model.transcriptReader,
                    sender: model.promptSender,
                    nativeSessions: model.nativeSessions,
                    onPreviewFile: { model.filePreviews.show(url: $0) },
                    presentation: .desktop
                )
                .id(session.id)
            }
            .accessibilityIdentifier("desktop-workspace")
        } else {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspaceHeader(_ session: TrackedSession) -> some View {
        HStack(spacing: 9) {
            DesktopHeaderControl(
                title: isSidebarVisible ? "Hide sessions" : "Show sessions",
                icon: "sidebar.leading",
                showsTitle: false,
                isActive: !isSidebarVisible,
                identifier: "toggle-desktop-session-sidebar"
            ) {
                withAnimation(shellMotion) { isSidebarVisible.toggle() }
            }

            SessionMarble(session: session, size: 20, animate: false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(session.name).font(.system(size: 12.5, weight: .semibold))
                    Text(session.key.source.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                }
                Text(session.cwd ?? "Location not reported")
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.27))
                    .lineLimit(1)
            }
            Spacer()
            Text(session.state.displayName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(session.state.needsAttention ? 0.82 : 0.42))
            headerAction("Open CLI", icon: "terminal") { model.jump(to: session) }
            headerAction("Full screen", icon: "arrow.up.left.and.arrow.down.right") {
                StatusWindowController.shared.toggleFullScreen()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .frame(minHeight: 58)
        .background(Color(red: 0.047, green: 0.050, blue: 0.059))
    }

    private func headerAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        let identifier = "header-action-" + title.lowercased().replacingOccurrences(of: " ", with: "-")
        return DesktopHeaderControl(
            title: title,
            icon: icon,
            showsTitle: true,
            isActive: false,
            identifier: identifier,
            action: action
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            NoturcodeBrandMark(size: 34)
            Text("No connected sessions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
            Text("Connect from Claude Code or Codex with /nc project-name.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.38))
        }
        .accessibilityElement(children: .combine)
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.status == .enabled || loginItem.status == .requiresApproval },
            set: { loginItem.setEnabled($0) }
        )
    }
}

private struct DesktopHeaderControl: View {
    let title: String
    let icon: String
    let showsTitle: Bool
    let isActive: Bool
    let identifier: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                if showsTitle {
                    Text(title)
                        .font(.system(size: 9.5, weight: .semibold))
                }
            }
            .padding(.horizontal, showsTitle ? 9 : 0)
            .frame(width: showsTitle ? nil : 28, height: 28)
            .foregroundStyle(.white.opacity(isActive ? 0.88 : (isHovered ? 0.78 : 0.52)))
            .background(
                .white.opacity(isActive ? 0.10 : (isHovered ? 0.075 : 0.035)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(isHovered || isActive ? 0.11 : 0.055), lineWidth: 0.7)
            }
        }
        .buttonStyle(ShellPressButtonStyle(reduceMotion: reduceMotion))
        .clickableCursor()
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct ShellPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
