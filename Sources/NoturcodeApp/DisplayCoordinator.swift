import AppKit
import Combine
import Foundation
import NoturcodeCore
import SwiftUI

struct NotchMetrics: Equatable, Sendable {
    let displayID: UInt32
    let screenFrame: CGRect
    let envelopeWidth: CGFloat
    let envelopeHeight: CGFloat
    let hasHardwareNotch: Bool
    let neckWidth: CGFloat
    let neckHeight: CGFloat

    var surfaceTopInset: CGFloat { hasHardwareNotch ? 0 : 7 }
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
        displayID = screenNumber?.uint32Value ?? UInt32(abs(screen.localizedName.hashValue))
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
        min(96, max(50, ceil(CGFloat(name.count) * 5.7) + 34))
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
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            Task { @MainActor in self?.handleMouse(at: NSEvent.mouseLocation) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.handleMouse(at: NSEvent.mouseLocation) }
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
        let current = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { screen in
            let metrics = NotchMetrics(screen: screen)
            return (metrics.displayID, (screen, metrics))
        })

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
    private var hoverIntentTask: Task<Void, Never>?
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
        hoverIntentTask?.cancel()
        hoverIntentTask = nil
        hoverClearTask?.cancel()
        hoverClearTask = nil
        if let id {
            if isUITestSpotlight || hoveredSessionID == nil {
                hoveredSessionID = id
                return
            }
            guard hoveredSessionID != id else { return }
            hoverIntentTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(90))
                } catch {
                    return
                }
                self?.hoveredSessionID = id
                self?.hoverIntentTask = nil
            }
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
        Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(230))
            } catch {
                return
            }
            self?.collapseAndLatch()
            self?.pressedSessionID = nil
            // UI fixtures must never activate or manipulate a real iTerm2 window.
            if self?.isUITestForcedExpanded != true {
                action()
            }
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
        // Keep the surface above both the menu bar and status items. Native
        // notch overlays use mainMenu + 3; statusBar + 1 can still sit below
        // menu extras and makes the hardware surface appear recessed.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = !state.isUITestSpotlight
        panel.contentView = hostingView
        update(screen: screen, metrics: metrics)
        panel.orderFrontRegardless()
    }

    func update(screen: NSScreen, metrics: NotchMetrics) {
        self.metrics = metrics
        let origin = CGPoint(
            x: screen.frame.midX - metrics.envelopeWidth / 2,
            y: screen.frame.maxY - metrics.envelopeHeight
        )
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: metrics.envelopeWidth, height: metrics.envelopeHeight)), display: true)
        hostingView.rootView = NotchSurfaceView(model: model, state: state, metrics: metrics)
    }

    func refresh() {
        hostingView.rootView = NotchSurfaceView(model: model, state: state, metrics: metrics)
        panel.orderFrontRegardless()
    }

    func contains(screenPoint: CGPoint, sessionCount: Int, hasAnnouncement: Bool) -> Bool {
        guard sessionCount > 0 || hasAnnouncement else { return false }
        let width: CGFloat
        let height: CGFloat
        if state.isExpanded {
            width = min(420, metrics.envelopeWidth - 16)
            height = min(
                520,
                metrics.expandedHeight(sessionCount: sessionCount)
                    + state.activityHeightAdjustment(in: model.store.sessions)
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
        panel.ignoresMouseEvents = state.isUITestSpotlight ? false : !inside
        state.pointerMoved(inside: inside)
    }

    func dismiss() {
        state.dismiss()
    }

    func close() {
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

    @objc private func handleClick() {
        onClick?()
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
