import AppKit
import ApplicationServices

@MainActor
final class ITermPaneGeometryResolver {
    func focusedPaneFrame() -> CGRect? {
        accessibilityFocusedPaneFrame()
    }

    private func accessibilityFocusedPaneFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.googlecode.iterm2"
              ).first else { return nil }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let focused = copiedElement(attribute: kAXFocusedUIElementAttribute as CFString, from: appElement),
              let pane = nearestTextArea(from: focused) else { return nil }
        guard let topLeft = point(attribute: kAXPositionAttribute as CFString, from: pane),
              let size = size(attribute: kAXSizeAttribute as CFString, from: pane),
              size.width > 40, size.height > 40 else { return nil }

        return decodedFrame(topLeft: topLeft, size: size)
    }

    private func systemEventsFocusedPaneFrame() -> CGRect? {
        guard let script = NSAppleScript(source: Self.systemEventsSource) else { return nil }
        var error: NSDictionary?
        let response = script.executeAndReturnError(&error)
        guard error == nil,
              let payload = response.stringValue,
              payload.hasPrefix("FOUND|") else { return nil }
        let components = payload.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count == 5,
              let rawX = Double(components[1]),
              let rawY = Double(components[2]),
              let rawWidth = Double(components[3]),
              let rawHeight = Double(components[4]) else { return nil }
        return decodedFrame(
            topLeft: CGPoint(x: rawX, y: rawY),
            size: CGSize(width: rawWidth, height: rawHeight)
        )
    }

    private func decodedFrame(topLeft: CGPoint, size: CGSize) -> CGRect? {
        var best: (frame: CGRect, visibleRatio: CGFloat, area: CGFloat)?
        for x in coordinateCandidates(topLeft.x) {
            for y in coordinateCandidates(topLeft.y) {
                for width in dimensionCandidates(size.width) {
                    for height in dimensionCandidates(size.height) {
                        let frame = appKitFrame(
                            topLeft: CGPoint(x: x, y: y),
                            size: CGSize(width: width, height: height)
                        )
                        let visibleArea = NSScreen.screens.map {
                            frame.intersection($0.frame).standardizedArea
                        }.max() ?? 0
                        let area = frame.standardizedArea
                        guard area > 0, visibleArea > 0 else { continue }
                        let ratio = visibleArea / area
                        if best == nil || ratio > best!.visibleRatio + 0.001
                            || (abs(ratio - best!.visibleRatio) <= 0.001 && area > best!.area) {
                            best = (frame, ratio, area)
                        }
                    }
                }
            }
        }
        guard let best, best.visibleRatio >= 0.80 else { return nil }
        return best.frame
    }

    private func coordinateCandidates(_ value: Double) -> [Double] {
        [value, value / 10, value / 100, value / 1_000]
            .filter { abs($0) <= 12_000 }
    }

    private func dimensionCandidates(_ value: Double) -> [Double] {
        [value, value / 10, value / 100, value / 1_000]
            .filter { $0 >= 40 && $0 <= 8_000 }
    }

    private func appKitFrame(topLeft: CGPoint, size: CGSize) -> CGRect {
        // AX/System Events use Core Graphics' top-left primary-display origin.
        // AppKit uses the primary display's bottom-left origin. Using the
        // primary screen height also handles displays positioned above it.
        let primaryTop = NSScreen.screens.first(where: {
            $0.frame.origin == .zero
        })?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: topLeft.x,
            y: primaryTop - topLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    static let systemEventsSource = """
    tell application "System Events"
        if not (exists process "iTerm2") then return "MISSING"
        tell process "iTerm2"
            set focusedElement to value of attribute "AXFocusedUIElement"
            repeat 8 times
                try
                    set roleValue to value of attribute "AXRole" of focusedElement
                    if roleValue is "AXTextArea" then
                        set panePosition to value of attribute "AXPosition" of focusedElement
                        set paneSize to value of attribute "AXSize" of focusedElement
                        set px to (item 1 of panePosition) as integer
                        set py to (item 2 of panePosition) as integer
                        set pw to (item 1 of paneSize) as integer
                        set ph to (item 2 of paneSize) as integer
                        return "FOUND|" & px & "|" & py & "|" & pw & "|" & ph
                    end if
                    set focusedElement to value of attribute "AXParent" of focusedElement
                on error
                    exit repeat
                end try
            end repeat
        end tell
    end tell
    return "MISSING"
    """

    private func nearestTextArea(from element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let candidate = current else { return nil }
            if string(attribute: kAXRoleAttribute as CFString, from: candidate) == kAXTextAreaRole {
                return candidate
            }
            current = copiedElement(attribute: kAXParentAttribute as CFString, from: candidate)
        }
        return nil
    }

    private func copiedElement(attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func string(attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func point(attribute: CFString, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func size(attribute: CFString, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}

private extension CGRect {
    var standardizedArea: CGFloat {
        let rect = standardized
        return rect.isNull || rect.isInfinite ? 0 : rect.width * rect.height
    }
}
