import AppKit
import NoturcodeCore
import SwiftUI

@MainActor
final class RecentAppsStore: ObservableObject {
    struct Item: Identifiable {
        let record: RecentApplicationRecord
        let icon: NSImage

        var id: String { record.id }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selectedAppID: String?
    @Published private(set) var browserTabs: [BrowserTabRecord] = []
    @Published private(set) var browserTabIcons: [String: NSImage] = [:]
    @Published private(set) var browserTabMessage: String?
    @Published private(set) var isLoadingBrowserTabs = false

    // Keep a small reserve so the fourth app can move into the visible top
    // three immediately when one of the visible apps quits.
    private var history = RecentApplicationHistory(limit: 12)
    private let workspace = NSWorkspace.shared
    private var observers: [NSObjectProtocol] = []
    private var browserTabTask: Task<Void, Never>?

    var selectedAppName: String {
        items.first(where: { $0.id == selectedAppID })?.record.name ?? "Application"
    }

    var selectedAppSupportsBrowserTabs: Bool {
        guard let bundleIdentifier = items.first(where: { $0.id == selectedAppID })?.record.bundleIdentifier else {
            return false
        }
        return ChromeBrowserTabs.supports(bundleIdentifier)
    }

    func start() {
        seedFromVisibleWindowOrder()
        let center = workspace.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                Task { @MainActor in self?.record(application) }
            },
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                Task { @MainActor in self?.record(application) }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
                Task { @MainActor in self?.remove(application) }
            }
        ]
    }

    func stop() {
        browserTabTask?.cancel()
        browserTabTask = nil
        let center = workspace.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    func open(_ item: Item) {
        guard let application = NSRunningApplication(processIdentifier: item.record.processIdentifier),
              !application.isTerminated else {
            history.terminate(processIdentifier: item.record.processIdentifier)
            rebuildItems()
            return
        }
        application.unhide()
        // Do not use activateAllWindows. A normal activation returns to the
        // app's last active window and keeps its last selected browser tab.
        if application.activate(options: []) {
            record(application)
        }
    }

    func inspect(_ item: Item) {
        selectedAppID = item.id
        browserTabTask?.cancel()
        browserTabs = []
        browserTabIcons = [:]
        browserTabMessage = nil

        guard ChromeBrowserTabs.supports(item.record.bundleIdentifier) else {
            isLoadingBrowserTabs = false
            browserTabMessage = "Click to return to the last active window."
            return
        }

        isLoadingBrowserTabs = true
        let selectedID = item.id
        let bundleIdentifier = item.record.bundleIdentifier
        browserTabTask = Task { [weak self] in
            let payload = await Task.detached(priority: .userInitiated) {
                let snapshot = ChromeBrowserTabs.read(bundleIdentifier: bundleIdentifier)
                let tabs = Array(snapshot.tabs.prefix(5))
                return (snapshot, ChromeFaviconLoader.load(for: tabs))
            }.value
            guard !Task.isCancelled, let self, self.selectedAppID == selectedID else { return }
            self.browserTabs = Array(payload.0.tabs.prefix(5))
            self.browserTabIcons = payload.1.compactMapValues(NSImage.init(data:))
            self.browserTabMessage = payload.0.message
            self.isLoadingBrowserTabs = false
        }
    }

    func open(_ tab: BrowserTabRecord) {
        let selectedID = selectedAppID
        Task { [weak self] in
            let didOpen = await Task.detached(priority: .userInitiated) {
                ChromeBrowserTabs.open(tab)
            }.value
            guard let self else { return }
            if didOpen,
               let item = self.items.first(where: { $0.id == selectedID }),
               let application = NSRunningApplication(processIdentifier: item.record.processIdentifier) {
                self.record(application)
            } else if !didOpen {
                self.browserTabMessage = "Chrome could not open this tab."
            }
        }
    }

    private func seedFromVisibleWindowOrder() {
        var seeded = Set<pid_t>()
        var visibleApplications: [RecentApplicationRecord] = []
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for window in windowInfo {
            guard let number = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let processIdentifier = pid_t(number.int32Value)
            guard seeded.insert(processIdentifier).inserted,
                  let application = NSRunningApplication(processIdentifier: processIdentifier),
                  isEligible(application) else { continue }
            visibleApplications.append(record(for: application))
            if visibleApplications.count == history.limit { break }
        }
        for application in visibleApplications.reversed() {
            history.activate(application)
        }

        if let frontmost = workspace.frontmostApplication {
            record(frontmost)
        } else {
            rebuildItems()
        }
    }

    private func record(_ application: NSRunningApplication) {
        guard isEligible(application) else { return }
        history.activate(record(for: application))
        rebuildItems()
    }

    private func remove(_ application: NSRunningApplication) {
        history.terminate(processIdentifier: application.processIdentifier)
        rebuildItems()
    }

    private func isEligible(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && application.activationPolicy == .regular
            && !application.isTerminated
            && application.bundleIdentifier?.isEmpty == false
    }

    private func record(for application: NSRunningApplication) -> RecentApplicationRecord {
        RecentApplicationRecord(
            bundleIdentifier: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            name: application.localizedName ?? "Application",
            processIdentifier: application.processIdentifier
        )
    }

    private func rebuildItems() {
        let refreshed: [Item] = history.items.compactMap { record -> Item? in
            guard let application = NSRunningApplication(processIdentifier: record.processIdentifier),
                  !application.isTerminated else { return nil }
            let icon = application.bundleURL.map { workspace.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: record.name)
                ?? NSImage()
            return Item(record: record, icon: icon)
        }
        items = refreshed
    }
}

private struct BrowserTabSnapshot: Sendable {
    let tabs: [BrowserTabRecord]
    let message: String?
}

enum ChromeBrowserTabs {
    private static let supportedBundleIdentifiers = Set([
        "com.google.Chrome",
        "com.google.Chrome.canary"
    ])

    static func supports(_ bundleIdentifier: String) -> Bool {
        supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    static func selfTest() -> String {
        let snapshot = read(bundleIdentifier: "com.google.Chrome")
        guard snapshot.message == nil else { return "FAIL:\(snapshot.message ?? "unknown")" }
        let iconCount = ChromeFaviconLoader.load(for: snapshot.tabs).count
        return "PASS:tabs=\(snapshot.tabs.count):icons=\(iconCount)"
    }

    fileprivate static func read(bundleIdentifier: String) -> BrowserTabSnapshot {
        guard supports(bundleIdentifier) else {
            return BrowserTabSnapshot(tabs: [], message: "This app does not expose browser tabs.")
        }
        let script = """
        set fieldSeparator to ASCII character 31
        set rowSeparator to ASCII character 30
        set outputText to ""
        tell application id "\(bundleIdentifier)"
            if (count of windows) is greater than 0 then
                set browserWindow to front window
                set windowIdentifier to id of browserWindow
                set selectedTabIndex to active tab index of browserWindow
                set tabCount to count of tabs of browserWindow
                set candidateIndexes to {selectedTabIndex}
                set offsetValue to 1
                repeat while (count of candidateIndexes) is less than 5 and offsetValue is less than tabCount
                    if (selectedTabIndex - offsetValue) is greater than 0 then
                        set end of candidateIndexes to (selectedTabIndex - offsetValue)
                    end if
                    if (count of candidateIndexes) is less than 5 and (selectedTabIndex + offsetValue) is less than or equal to tabCount then
                        set end of candidateIndexes to (selectedTabIndex + offsetValue)
                    end if
                    set offsetValue to offsetValue + 1
                end repeat
                repeat with currentTabIndex in candidateIndexes
                    set browserTab to tab currentTabIndex of browserWindow
                    set selectedFlag to "0"
                    if currentTabIndex is selectedTabIndex then set selectedFlag to "1"
                    set outputText to outputText & windowIdentifier & fieldSeparator & currentTabIndex & fieldSeparator & title of browserTab & fieldSeparator & URL of browserTab & fieldSeparator & selectedFlag & rowSeparator
                end repeat
            end if
        end tell
        return outputText
        """
        var errorInfo: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo) else {
            let errorNumber = errorInfo?[NSAppleScript.errorNumber] as? Int
            let message = errorNumber == -1743
                ? "Allow Noturcode to control Chrome in Privacy & Security."
                : "Chrome did not return its tab list."
            return BrowserTabSnapshot(tabs: [], message: message)
        }
        let payload = descriptor.stringValue ?? ""
        let tabs = BrowserTabWireParser.parse(payload, bundleIdentifier: bundleIdentifier)
        return BrowserTabSnapshot(
            tabs: tabs,
            message: tabs.isEmpty ? "Chrome has no open tabs." : nil
        )
    }

    static func open(_ tab: BrowserTabRecord) -> Bool {
        guard supports(tab.bundleIdentifier) else { return false }
        let script = """
        tell application id "\(tab.bundleIdentifier)"
            set targetWindowID to \(tab.windowIdentifier)
            set targetTabIndex to \(tab.tabIndex)
            set targetWindow to first window whose id is targetWindowID
            set active tab index of targetWindow to targetTabIndex
            set index of targetWindow to 1
            activate
        end tell
        """
        guard let result = try? BoundedProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 2.5
        ) else { return false }
        return result.status == 0
    }
}

private enum ChromeFaviconLoader {
    static func load(for tabs: [BrowserTabRecord]) -> [String: Data] {
        guard !tabs.isEmpty else { return [:] }
        let fileManager = FileManager.default
        let chromeRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        guard let profileURLs = try? fileManager.contentsOfDirectory(
            at: chromeRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let databases = profileURLs
            .map { $0.appendingPathComponent("Favicons") }
            .filter { fileManager.fileExists(atPath: $0.path) }
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("noturcode-favicons-\(UUID().uuidString)", isDirectory: true)
        guard (try? fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)) != nil else {
            return [:]
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let tabsByURL = Dictionary(grouping: tabs, by: \.url)
        var remainingURLs = Set(tabsByURL.keys)
        var dataByURL: [String: Data] = [:]

        for (databaseIndex, databaseURL) in databases.enumerated() where !remainingURLs.isEmpty {
            let snapshotURL = temporaryRoot.appendingPathComponent("Favicons-\(databaseIndex)")
            guard copyDatabaseSnapshot(from: databaseURL, to: snapshotURL, fileManager: fileManager) else {
                continue
            }
            for url in remainingURLs {
                guard let data = faviconData(pageURL: url, databaseURL: snapshotURL) else { continue }
                dataByURL[url] = data
            }
            remainingURLs.subtract(dataByURL.keys)
        }

        var icons: [String: Data] = [:]
        for tab in tabs {
            if let data = dataByURL[tab.url] { icons[tab.id] = data }
        }
        return icons
    }

    private static func copyDatabaseSnapshot(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: sourceURL.path + suffix)
                guard fileManager.fileExists(atPath: sidecar.path) else { continue }
                try? fileManager.copyItem(
                    at: sidecar,
                    to: URL(fileURLWithPath: destinationURL.path + suffix)
                )
            }
            return true
        } catch {
            return false
        }
    }

    private static func faviconData(pageURL: String, databaseURL: URL) -> Data? {
        let escapedURL = pageURL.replacingOccurrences(of: "'", with: "''")
        let query = """
        SELECT hex(favicon_bitmaps.image_data)
        FROM icon_mapping
        JOIN favicon_bitmaps ON favicon_bitmaps.icon_id = icon_mapping.icon_id
        WHERE icon_mapping.page_url = '\(escapedURL)'
          AND length(favicon_bitmaps.image_data) > 0
        ORDER BY favicon_bitmaps.width DESC
        LIMIT 1;
        """
        guard let result = try? BoundedProcessRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: ["-readonly", databaseURL.path, query],
            timeout: 0.8
        ), result.status == 0 else { return nil }
        let hex = String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hex.isEmpty else { return nil }
        return Data(hexadecimal: hex)
    }
}

private extension Data {
    init?(hexadecimal value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

@MainActor
final class RecentAppsPresentationState: ObservableObject {
    @Published private(set) var isExpanded = false

    func pointerMoved(inside: Bool) {
        guard isExpanded != inside else { return }
        isExpanded = inside
    }
}

@MainActor
final class RecentAppsCoordinator {
    private let store = RecentAppsStore()
    private var panels: [UInt32: RecentAppsPanelController] = [:]
    private var screenObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    func start() {
        store.start()
        refreshScreens()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshScreens() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            self?.handleMouse(NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            Task { @MainActor in self?.handleMouse(NSEvent.mouseLocation) }
        }
        handleMouse(NSEvent.mouseLocation)
    }

    func stop() {
        store.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    private func refreshScreens() {
        var screens: [UInt32: NSScreen] = [:]
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            var displayID = number?.uint32Value
                ?? UInt32(truncatingIfNeeded: ObjectIdentifier(screen).hashValue)
            while screens[displayID] != nil { displayID &+= 1 }
            screens[displayID] = screen
        }

        for (displayID, panel) in panels where screens[displayID] == nil {
            panel.close()
            panels[displayID] = nil
        }
        for (displayID, screen) in screens {
            if let panel = panels[displayID] {
                panel.update(screen: screen)
            } else {
                panels[displayID] = RecentAppsPanelController(screen: screen, store: store)
            }
        }
    }

    private func handleMouse(_ point: CGPoint) {
        panels.values.forEach { panel in
            panel.pointerMoved(inside: panel.contains(screenPoint: point))
        }
    }
}

@MainActor
private final class RecentAppsPanelController {
    private static let envelopeSize = CGSize(width: 536, height: 174)
    private static let collapsedWidth: CGFloat = 52
    private static let expandedWidth: CGFloat = 520

    private let panel: NotchPanel
    private let state = RecentAppsPresentationState()
    private let hostingView: NSHostingView<RecentAppsShelfView>
    private var screenFrame: CGRect
    private var surfaceMadeKeyForCursor = false

    init(screen: NSScreen, store: RecentAppsStore) {
        screenFrame = screen.frame
        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: Self.envelopeSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        hostingView = NSHostingView(rootView: RecentAppsShelfView(store: store, state: state))
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.becomesKeyOnlyIfNeeded = true
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        update(screen: screen)
        panel.orderFrontRegardless()
    }

    func update(screen: NSScreen) {
        screenFrame = screen.frame
        let origin = CGPoint(
            x: screen.frame.minX,
            y: screen.frame.midY - Self.envelopeSize.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: Self.envelopeSize), display: true)
    }

    func contains(screenPoint: CGPoint) -> Bool {
        let width = state.isExpanded ? Self.expandedWidth : Self.collapsedWidth
        let surface = CGRect(
            x: screenFrame.minX,
            y: screenFrame.midY - Self.envelopeSize.height / 2,
            width: width,
            height: Self.envelopeSize.height
        )
        return surface.insetBy(dx: -3, dy: -3).contains(screenPoint)
    }

    func pointerMoved(inside: Bool) {
        let ignoresMouseEvents = !inside
        let interactionChanged = panel.ignoresMouseEvents != ignoresMouseEvents
        panel.ignoresMouseEvents = ignoresMouseEvents
        if interactionChanged, !ignoresMouseEvents {
            panel.enableCursorRects()
            panel.resetCursorRects()
        }
        updatePanelKeyForCursor(inside: inside)
        state.pointerMoved(inside: inside)
    }

    private func updatePanelKeyForCursor(inside: Bool) {
        if inside, !surfaceMadeKeyForCursor {
            panel.makeKey()
            surfaceMadeKeyForCursor = panel.isKeyWindow
            return
        }
        guard !inside, surfaceMadeKeyForCursor else { return }
        surfaceMadeKeyForCursor = false
        if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    func close() {
        updatePanelKeyForCursor(inside: false)
        panel.orderOut(nil)
        panel.close()
    }
}

private struct RecentAppsShelfView: View {
    @ObservedObject var store: RecentAppsStore
    @ObservedObject var state: RecentAppsPresentationState
    @State private var hoveredID: String?

    private var width: CGFloat { state.isExpanded ? 520 : 52 }

    var body: some View {
        ZStack(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 22,
                topTrailingRadius: 22,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 22,
                    topTrailingRadius: 22,
                    style: .continuous
                )
                .fill(Color(red: 0.025, green: 0.029, blue: 0.038).opacity(0.90))
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 22,
                    topTrailingRadius: 22,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.075), lineWidth: 0.75)
            }

            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(store.items.prefix(3)) { item in
                        Button {
                            store.open(item)
                        } label: {
                            if state.isExpanded {
                                expandedAppRow(item)
                            } else {
                                collapsedAppIcon(item)
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            hoveredID = inside ? item.id : nil
                            if inside { store.inspect(item) }
                        }
                        .clickableCursor()
                        .accessibilityLabel("Open \(item.record.name), last active window")
                    }
                }
                .padding(.leading, 4)
                .frame(width: state.isExpanded ? 236 : 52, height: 174, alignment: .leading)

                if state.isExpanded {
                    Rectangle()
                        .fill(.white.opacity(0.07))
                        .frame(width: 1, height: 136)
                        .transition(.opacity)
                    browserTabDetails
                        .frame(width: 283, height: 174, alignment: .topLeading)
                        .transition(.opacity)
                }
            }
            .frame(width: width, height: 174, alignment: .leading)
        }
        .frame(width: width, height: 174, alignment: .leading)
        .frame(width: 536, height: 174, alignment: .leading)
        .animation(.spring(response: 0.22, dampingFraction: 0.90), value: state.isExpanded)
        .animation(.easeOut(duration: 0.08), value: hoveredID)
        .onChange(of: state.isExpanded) { _, isExpanded in
            if isExpanded, store.selectedAppID == nil, let first = store.items.first {
                store.inspect(first)
            }
        }
        .accessibilityIdentifier("recent-apps-left-shelf")
    }

    private func collapsedAppIcon(_ item: RecentAppsStore.Item) -> some View {
        Image(nsImage: item.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 30, height: 30)
            .frame(width: 44, height: 46, alignment: .center)
            .contentShape(Rectangle())
    }

    private func expandedAppRow(_ item: RecentAppsStore.Item) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.record.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(
                    item.id == store.selectedAppID && store.selectedAppSupportsBrowserTabs
                        ? "Recent tabs"
                        : "Last active window"
                )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 228, height: 46, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(hoveredID == item.id || store.selectedAppID == item.id ? 0.095 : 0))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var browserTabDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 11, weight: .semibold))
                Text(store.selectedAppSupportsBrowserTabs ? "Chrome tabs" : store.selectedAppName)
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                if store.isLoadingBrowserTabs {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .foregroundStyle(.white.opacity(0.52))
            .padding(.horizontal, 12)

            if !store.browserTabs.isEmpty {
                VStack(spacing: 3) {
                    ForEach(store.browserTabs.prefix(3)) { tab in
                        Button {
                            store.open(tab)
                        } label: {
                            HStack(spacing: 8) {
                                Group {
                                    if let icon = store.browserTabIcons[tab.id] {
                                        Image(nsImage: icon)
                                            .resizable()
                                            .interpolation(.high)
                                    } else {
                                        Image(systemName: "globe")
                                            .resizable()
                                            .scaledToFit()
                                            .foregroundStyle(.white.opacity(0.42))
                                    }
                                }
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tab.title.isEmpty ? "Untitled tab" : tab.title)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.86))
                                        .lineLimit(1)
                                    Text(tabHost(tab.url))
                                        .font(.system(size: 9.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.38))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.34))
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 37)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(.white.opacity(0.055))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .accessibilityLabel("Open Chrome tab \(tab.title)")
                    }
                }
                .padding(.horizontal, 7)
            } else if let message = store.browserTabMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
            }
        }
        .padding(.top, 13)
    }

    private func tabHost(_ value: String) -> String {
        URL(string: value)?.host() ?? value
    }
}
