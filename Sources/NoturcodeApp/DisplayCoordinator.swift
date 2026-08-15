import AppKit
import Combine
import Foundation
import NoturcodeCore
import SwiftUI

private final class MouseLocationCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGPoint?
    private var isScheduled = false
    private let deliver: @MainActor (CGPoint) -> Void

    init(deliver: @escaping @MainActor (CGPoint) -> Void) {
        self.deliver = deliver
    }

    func submit(_ location: CGPoint) {
        lock.lock()
        latest = location
        let shouldSchedule = !isScheduled
        if shouldSchedule { isScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            guard let self, let location = self.takeLatest() else { return }
            self.deliver(location)
        }
    }

    private func takeLatest() -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        let location = latest
        latest = nil
        isScheduled = false
        return location
    }
}

struct NotchMetrics: Equatable, Sendable {
    let displayID: UInt32
    let screenFrame: CGRect
    let envelopeWidth: CGFloat
    let envelopeHeight: CGFloat
    let hasHardwareNotch: Bool
    let neckWidth: CGFloat
    let neckHeight: CGFloat

    // The panel frame already starts at screen.maxY. A second visual inset
    // creates a gap and also moves the hit region away from the visible dock.
    var surfaceTopInset: CGFloat { 0 }
    var minimumDockRailHeight: CGFloat { hasHardwareNotch ? 50 : 42 }
    var notchShoulderClearance: CGFloat { hasHardwareNotch ? 4 : 0 }
    var dockContentTopInset: CGFloat { hasHardwareNotch ? neckHeight + notchShoulderClearance : 0 }

    func dockRailHeight(sessionCount: Int) -> CGFloat {
        return minimumDockRailHeight
    }

    func compactItemCount(sessionCount: Int) -> Int {
        min(3, sessionCount) + (sessionCount > 3 ? 1 : 0)
    }

    func collapsedHeight(sessionCount: Int) -> CGFloat {
        dockContentTopInset + dockRailHeight(sessionCount: sessionCount)
    }

    init(screen: NSScreen) {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = screenNumber?.uint32Value
            ?? UInt32(truncatingIfNeeded: ObjectIdentifier(screen).hashValue)
        screenFrame = screen.frame
        envelopeWidth = min(540, max(360, screen.frame.width))
        envelopeHeight = min(570, max(300, screen.frame.height))

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let gap = max(0, right.minX - left.maxX)
            hasHardwareNotch = gap >= 80 && screen.safeAreaInsets.top >= 20
            neckWidth = hasHardwareNotch ? min(240, gap + 2) : 94
            neckHeight = hasHardwareNotch ? max(30, screen.safeAreaInsets.top) : 28
        } else {
            hasHardwareNotch = false
            neckWidth = 94
            neckHeight = 28
        }
    }

    func sessionChipWidth(for name: String) -> CGFloat {
        min(108, max(62, ceil(CGFloat(name.count) * 5.7) + 46))
    }

    func collapsedWidth(sessionNames: [String]) -> CGFloat {
        guard !sessionNames.isEmpty else { return 0 }
        let widestChip = sessionNames.map(sessionChipWidth(for:)).max() ?? 0
        let chipWidths = CGFloat(compactItemCount(sessionCount: sessionNames.count)) * widestChip
        let chipSpacing = CGFloat(max(0, compactItemCount(sessionCount: sessionNames.count) - 1)) * 6
        let fixedContent: CGFloat = 28 + 19 + 16 + 1
        let contentWidth = fixedContent + chipWidths + chipSpacing
        let minimumWidth = hasHardwareNotch ? neckWidth + 28 : 120
        return min(envelopeWidth - 12, max(minimumWidth, contentWidth))
    }

    func expandedHeight(sessionCount: Int) -> CGFloat {
        let topInset = hasHardwareNotch ? neckHeight + 18 : 18
        return min(520, max(180, topInset + CGFloat(sessionCount) * 92 + 12))
    }

    func expandedSurfaceHeight(sessionCount: Int, activityAdjustment: CGFloat) -> CGFloat {
        min(
            520,
            expandedHeight(sessionCount: sessionCount)
                + dockRailHeight(sessionCount: sessionCount)
                + activityAdjustment
        )
    }

}

@MainActor
final class DisplayCoordinator {
    private weak var model: AppModel?
    private var panels: [UInt32: NotchPanelController] = [:]
    private var announcementPanel: AttentionAnnouncementPanelController?
    private var announcementCancellable: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var mouseCoalescer: MouseLocationCoalescer?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        refreshScreens()
        if let model {
            let announcementPanel = AttentionAnnouncementPanelController { [weak model] sessionKey in
                guard let model,
                      let session = model.store.sessions.first(where: { $0.key == sessionKey }) else { return }
                model.announcements.dismiss(sessionKey: sessionKey)
                model.jump(to: session)
            }
            self.announcementPanel = announcementPanel
            announcementCancellable = model.announcements.$current
                .receive(on: RunLoop.main)
                .sink { announcement in
                    Task { @MainActor in
                        announcementPanel.present(announcement, cursor: NSEvent.mouseLocation)
                    }
                }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshScreens() }
        }
        let mouseCoalescer = MouseLocationCoalescer { [weak self] location in
            self?.handleMouse(at: location)
        }
        self.mouseCoalescer = mouseCoalescer
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            mouseCoalescer.submit(NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            mouseCoalescer.submit(NSEvent.mouseLocation)
        }
        handleMouse(at: NSEvent.mouseLocation)
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        localMouseMonitor = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
        mouseCoalescer = nil
        announcementCancellable?.cancel()
        announcementCancellable = nil
        announcementPanel?.close()
        announcementPanel = nil
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    func dismissAll() {
        panels.values.forEach { $0.dismiss() }
    }

    func sessionStateDidChange() {
        panels.values.forEach { $0.refresh() }
        handleMouse(at: NSEvent.mouseLocation)
    }

    private func refreshScreens() {
        guard let model else { return }
        var current: [UInt32: (NSScreen, NotchMetrics)] = [:]
        for screen in NSScreen.screens {
            let metrics = NotchMetrics(screen: screen)
            var displayID = metrics.displayID
            while current[displayID] != nil { displayID &+= 1 }
            current[displayID] = (screen, metrics)
        }

        for (displayID, controller) in panels where current[displayID] == nil {
            controller.close()
            panels[displayID] = nil
        }
        for (displayID, pair) in current {
            if let controller = panels[displayID] {
                controller.update(screen: pair.0, metrics: pair.1)
            } else {
                panels[displayID] = NotchPanelController(screen: pair.0, metrics: pair.1, model: model)
            }
        }
        handleMouse(at: NSEvent.mouseLocation)
    }

    private func handleMouse(at location: CGPoint) {
        guard let model else { return }
        for controller in panels.values {
            let inside = controller.contains(
                screenPoint: location,
                sessionCount: model.store.sessions.count,
                hasAnnouncement: false
            )
            controller.pointerMoved(inside: inside)
        }
        model.announcements.setHovered(announcementPanel?.contains(location) == true)
    }
}

@MainActor
private final class AttentionAnnouncementPanelController {
    private let panel: NSPanel
    private let hostingView: AnnouncementHostingView
    private let onSelect: (SessionKey) -> Void
    private var presentedID: UUID?
    private let size = CGSize(width: 408, height: 106)

    init(onSelect: @escaping (SessionKey) -> Void) {
        self.onSelect = onSelect
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hostingView = AnnouncementHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
    }

    func present(_ announcement: AttentionAnnouncement?, cursor: CGPoint) {
        guard let announcement else {
            presentedID = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.presentedID == nil else { return }
                    self.panel.orderOut(nil)
                }
            }
            return
        }

        hostingView.onClick = { [weak self] in
            self?.onSelect(announcement.sessionKey)
        }
        hostingView.rootView = AnyView(
            AnnouncementView(announcement: announcement)
                .frame(width: size.width, height: size.height)
        )
        guard presentedID != announcement.id else { return }
        presentedID = announcement.id

        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let edge = AnnouncementPlacement.edge(cursor: cursor, screenFrame: screen.frame)
        let origin = AnnouncementPlacement.origin(
            cursor: cursor,
            screenFrame: screen.frame,
            visibleFrame: visibleFrame,
            size: size
        )
        let finalFrame = CGRect(origin: origin, size: size)
        let isTopHalf = edge == .top
        let entranceOffset: CGFloat = isTopHalf ? 14 : -14
        let entranceFrame = finalFrame
            .insetBy(dx: 6, dy: 3)
            .offsetBy(dx: 0, dy: entranceOffset)
        let overshootFrame = finalFrame.insetBy(dx: -2, dy: -1)

        panel.setFrame(entranceFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(finalFrame, display: true)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(overshootFrame, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentedID == announcement.id else { return }
                NSAnimationContext.runAnimationGroup { settleContext in
                    settleContext.duration = 0.10
                    settleContext.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.panel.animator().setFrame(finalFrame, display: true)
                }
            }
        }
    }

    func contains(_ point: CGPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor
final class NotchPresentationState: ObservableObject {
    @Published private(set) var isExpanded: Bool
    @Published private(set) var hoveredSessionID: String?
    @Published private(set) var pressedSessionID: String?
    let isUITestSpotlight: Bool
    let isUITestRapidHover: Bool

    private var isArmed = true
    private var pointerInside = false
    private let isUITestForcedExpanded: Bool
    private var dwellTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var hoverClearTask: Task<Void, Never>?

    init() {
        isUITestForcedExpanded = CommandLine.arguments.contains("--ui-test-expanded")
        isUITestSpotlight = CommandLine.arguments.contains("--ui-test-hover-first")
            || CommandLine.arguments.contains("--ui-test-live-transcript")
        isUITestRapidHover = CommandLine.arguments.contains("--ui-test-rapid-hover")
        isExpanded = isUITestForcedExpanded
        isArmed = !isExpanded
    }

    func pointerMoved(inside: Bool) {
        guard !isUITestForcedExpanded else { return }
        pointerInside = inside
        if inside {
            exitTask?.cancel()
            exitTask = nil
            guard !isExpanded, isArmed, dwellTask == nil else { return }
            dwellTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(70))
                } catch {
                    return
                }
                guard let self, self.pointerInside, self.isArmed else { return }
                self.isExpanded = true
                self.dwellTask = nil
            }
        } else {
            dwellTask?.cancel()
            dwellTask = nil
            if isExpanded, exitTask == nil {
                exitTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(140))
                    } catch {
                        return
                    }
                    self?.collapseAndLatch()
                }
            } else if !isExpanded, !isArmed {
                isArmed = true
            }
        }
    }

    func setHoveredSession(_ id: String?) {
        hoverClearTask?.cancel()
        hoverClearTask = nil
        if let id {
            // Row feedback must follow the pointer on the same frame. The old
            // 90 ms intent timer made the gray selection lag behind the mouse.
            hoveredSessionID = id
            return
        }
        hoverClearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            self?.hoveredSessionID = nil
            self?.hoverClearTask = nil
        }
    }

    func expand() {
        dwellTask?.cancel()
        dwellTask = nil
        exitTask?.cancel()
        exitTask = nil
        isExpanded = true
        isArmed = false
    }

    func activityHeightAdjustment(in sessions: [TrackedSession]) -> CGFloat {
        guard !sessions.isEmpty else { return 0 }
        let summaryCount = sessions.filter {
            $0.state.showsCompletionSummary && NoturcodeSummaryContract.isDisplayable($0.lastAgentMessage)
        }.count
        let summaryAllowance = min(42, CGFloat(summaryCount) * 14)
        return summaryAllowance
    }

    func select(_ session: TrackedSession, action: @escaping @MainActor () -> Void) {
        pressedSessionID = session.id
        dwellTask?.cancel()
        exitTask?.cancel()
        collapseAndLatch()
        // UI fixtures must never activate or manipulate a real terminal window.
        if !isUITestForcedExpanded {
            action()
        }
        Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            self?.pressedSessionID = nil
        }
    }

    func dismiss() {
        collapseAndLatch()
    }

    private func collapseAndLatch() {
        dwellTask?.cancel()
        dwellTask = nil
        exitTask?.cancel()
        exitTask = nil
        hoverClearTask?.cancel()
        hoverClearTask = nil
        isExpanded = false
        hoveredSessionID = nil
        isArmed = false
    }
}

@MainActor
final class NotchPanelController {
    private let panel: NotchPanel
    private let hostingView: NSHostingView<NotchSurfaceView>
    private let state: NotchPresentationState
    private let model: AppModel
    private var metrics: NotchMetrics
    private var surfaceMadeKeyForCursor = false

    init(screen: NSScreen, metrics: NotchMetrics, model: AppModel) {
        self.metrics = metrics
        self.model = model
        state = NotchPresentationState()
        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: metrics.envelopeWidth, height: metrics.envelopeHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        hostingView = NSHostingView(rootView: NotchSurfaceView(model: model, state: state, metrics: metrics))

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // isFloatingPanel resets the AppKit level to .floating. Apply the
        // notch level after it so the surface stays above the menu bar.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.becomesKeyOnlyIfNeeded = true
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = !state.isUITestSpotlight
        panel.contentView = hostingView
        update(screen: screen, metrics: metrics)
        panel.orderFrontRegardless()
        panel.enableCursorRects()
        panel.resetCursorRects()
    }

    func update(screen: NSScreen, metrics: NotchMetrics) {
        self.metrics = metrics
        let origin = CGPoint(
            x: screen.frame.midX - metrics.envelopeWidth / 2,
            y: screen.frame.maxY - metrics.envelopeHeight
        )
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: metrics.envelopeWidth, height: metrics.envelopeHeight)), display: true)
        hostingView.rootView = NotchSurfaceView(model: model, state: state, metrics: metrics)
        panel.resetCursorRects()
    }

    func refresh() {
        // The root already observes AppModel and NotchPresentationState. Replacing
        // it for every hook event destroys SwiftUI identity and restarts motion.
        panel.orderFrontRegardless()
    }

    func contains(screenPoint: CGPoint, sessionCount: Int, hasAnnouncement: Bool) -> Bool {
        guard sessionCount > 0 || hasAnnouncement else { return false }
        let width: CGFloat
        let height: CGFloat
        if state.isExpanded {
            width = min(420, metrics.envelopeWidth - 16)
            height = metrics.expandedSurfaceHeight(
                sessionCount: sessionCount,
                activityAdjustment: state.activityHeightAdjustment(in: model.store.sessions)
            )
        } else if hasAnnouncement {
            width = min(286, metrics.envelopeWidth - 16)
            height = metrics.neckHeight + 20
        } else {
            width = metrics.collapsedWidth(sessionNames: model.store.sessions.map(\.name))
            height = metrics.collapsedHeight(sessionCount: sessionCount)
        }
        let frame = CGRect(
            x: metrics.screenFrame.midX - width / 2,
            y: metrics.screenFrame.maxY - metrics.surfaceTopInset - height,
            width: width,
            height: height
        )
        return frame.insetBy(dx: -3, dy: -3).contains(screenPoint)
    }

    func pointerMoved(inside: Bool) {
        let ignoresMouseEvents = state.isUITestSpotlight ? false : !inside
        let interactionChanged = panel.ignoresMouseEvents != ignoresMouseEvents
        panel.ignoresMouseEvents = ignoresMouseEvents
        if interactionChanged, !ignoresMouseEvents {
            // The panel is non-activating and never becomes key. Invalidation
            // can wait for a key transition that never occurs, so rebuild now.
            panel.enableCursorRects()
            panel.resetCursorRects()
        }
        updatePanelKeyForCursor(inside: inside)
        state.pointerMoved(inside: inside)
    }

    private func updatePanelKeyForCursor(inside: Bool) {
        if inside, !surfaceMadeKeyForCursor {
            // A non-activating panel can become key without activating the app.
            // This gives AppKit ownership of its cursor rects, matching the
            // transition that previously happened only after the first click.
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

    func dismiss() {
        state.dismiss()
    }

    func close() {
        updatePanelKeyForCursor(inside: false)
        panel.orderOut(nil)
        panel.close()
    }
}

@MainActor
private final class AnnouncementHostingView: NSHostingView<AnyView> {
    var onClick: (() -> Void)?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
    }

    @available(*, unavailable)
    required init(rootView: AnyView, ignoreSafeArea: Bool) {
        fatalError("init(rootView:ignoreSafeArea:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func handleClick() {
        onClick?()
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // This panel must occupy the menu-bar/notch area. AppKit otherwise clamps
    // a borderless window below the menu bar after launch or display changes.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
