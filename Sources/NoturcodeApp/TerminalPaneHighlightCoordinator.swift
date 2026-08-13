import AppKit
import SwiftUI
import NoturcodeCore

@MainActor
final class TerminalPaneHighlightCoordinator {
    private var panel: NSPanel?
    private var backdropPanels: [NSPanel] = []
    private var dismissalTask: Task<Void, Never>?

    func show(frame: CGRect, session: TrackedSession) {
        dismissalTask?.cancel()
        panel?.close()
        backdropPanels.forEach { $0.close() }
        backdropPanels.removeAll()

        backdropPanels = NSScreen.screens.map { screen in
            makeBackdropPanel(screen: screen, focusedFrame: frame)
        }
        backdropPanels.forEach { backdrop in
            backdrop.alphaValue = 0
            backdrop.orderFrontRegardless()
        }

        let highlightFrame = frame.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(
            contentRect: highlightFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: TerminalPaneHighlightView(session: session))
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdropPanels.forEach { $0.animator().alphaValue = 1 }
        }

        dismissalTask = Task { [weak self, weak panel] in
            do {
                try await Task.sleep(for: .milliseconds(1800))
            } catch { return }
            guard let self, self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel?.animator().alphaValue = 0
                self.backdropPanels.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, self.panel === panel else { return }
                    panel?.orderOut(nil)
                    panel?.close()
                    self.backdropPanels.forEach { $0.close() }
                    self.backdropPanels.removeAll()
                    self.panel = nil
                    self.dismissalTask = nil
                }
            })
        }
    }

    private func makeBackdropPanel(screen: NSScreen, focusedFrame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let cutout = focusedFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        panel.contentView = SpotlightBackdropView(frame: CGRect(origin: .zero, size: screen.frame.size), cutout: cutout)
        return panel
    }
}

private final class SpotlightBackdropView: NSView {
    private let cutout: CGRect
    private let dimLayer = CALayer()

    init(frame frameRect: NSRect, cutout: CGRect) {
        self.cutout = cutout
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        layer?.addSublayer(dimLayer)
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dimLayer.frame = bounds
        updateMask()
    }

    private func updateMask() {
        guard let layer else { return }
        let path = CGMutablePath()
        path.addRect(bounds)
        if cutout.intersects(bounds) {
            path.addRoundedRect(in: cutout.insetBy(dx: -1, dy: -1), cornerWidth: 10, cornerHeight: 10)
        }
        let maskLayer = CAShapeLayer()
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = NSColor.black.cgColor
        layer.mask = maskLayer
    }
}

private struct TerminalPaneHighlightView: View {
    let session: TrackedSession
    @State private var isVisible = false
    @State private var pulse = false
    private let highlightColor = Color(red: 0.20, green: 0.88, blue: 1.00)

    var body: some View {
        ZStack {
            Color.clear

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(highlightColor.opacity(isVisible ? 0.92 : 0), lineWidth: 2.5)
                .shadow(color: highlightColor.opacity(isVisible ? 0.52 : 0), radius: pulse ? 8 : 4)

            PaneCornerBrackets(color: highlightColor)
                .opacity(isVisible ? 1 : 0)
                .scaleEffect(pulse ? 1 : 0.992)

            VStack {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder")
                    Text("Focused pane")
                    Text(session.name)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlightColor)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color(red: 0.025, green: 0.029, blue: 0.038).opacity(0.94), in: Capsule())
                .overlay {
                    Capsule().stroke(highlightColor.opacity(0.46), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                .padding(.top, 10)
                Spacer()
            }
            .opacity(isVisible ? 1 : 0)
        }
        .padding(3)
        .onAppear {
            withAnimation(.easeOut(duration: 0.14)) { isVisible = true }
            withAnimation(.easeInOut(duration: 0.52).repeatCount(3, autoreverses: true)) {
                pulse = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PaneCornerBrackets: View {
    let color: Color

    var body: some View {
        ZStack {
            corner(rotation: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            corner(rotation: 90)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            corner(rotation: 270)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            corner(rotation: 180)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    private func corner(rotation: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 2, y: 26))
            path.addLine(to: CGPoint(x: 2, y: 2))
            path.addLine(to: CGPoint(x: 26, y: 2))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        .frame(width: 28, height: 28)
        .rotationEffect(.degrees(rotation))
        .shadow(color: color.opacity(0.72), radius: 5)
    }
}
