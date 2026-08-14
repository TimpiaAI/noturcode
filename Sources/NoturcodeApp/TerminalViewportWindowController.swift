import AppKit
import NoturcodeCore
import SwiftUI
import WebKit

@MainActor
final class TerminalViewportWindowCoordinator {
    private var entries: [String: TerminalWindowEntry] = [:]

    func show(session: TrackedSession, model: AppModel) {
        let key = session.id
        if let existing = entries[key] {
            existing.windowController.showWindow(nil)
            existing.windowController.window?.orderFrontRegardless()
            return
        }

        let window = FloatingTerminalPanel(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(session.name) · chat"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.preservesContentDuringLiveResize = true
        window.minSize = CGSize(width: 460, height: 320)
        window.maxSize = CGSize(width: 1_240, height: 920)
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let resizeState = TerminalLiveResizeState()
        window.contentView = NSHostingView(rootView: TerminalViewportWindowView(
            store: model.store,
            fallback: session,
            reader: model.transcriptReader,
            sender: model.promptSender,
            nativeSessions: model.nativeSessions,
            resizeState: resizeState,
            onPreviewFile: { [weak model] url in
                model?.filePreviews.show(url: url)
            },
            onClose: { [weak window] in
                NoturcodeSoundPlayer.shared.play(.close)
                window?.close()
            }
        ))
        window.center()
        let offset = CGFloat(entries.count % 6) * 28
        window.setFrameOrigin(CGPoint(x: window.frame.origin.x + offset, y: window.frame.origin.y - offset))

        let controller = NSWindowController(window: window)
        let entry = TerminalWindowEntry(key: key, windowController: controller, resizeState: resizeState) { [weak self] key in
            self?.entries[key] = nil
        }
        window.delegate = entry
        entries[key] = entry
        controller.showWindow(nil)
        window.orderFrontRegardless()
    }

    func closeAll() {
        let openEntries = Array(entries.values)
        entries.removeAll()
        openEntries.forEach { $0.windowController.close() }
    }
}

private final class FloatingTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TerminalLiveResizeState: ObservableObject {
    @Published var snapshot: NSImage?
    @Published var isResizing = false
}

@MainActor
private final class TerminalWindowEntry: NSObject, NSWindowDelegate {
    let key: String
    let windowController: NSWindowController
    let resizeState: TerminalLiveResizeState?
    let onClose: @MainActor (String) -> Void

    init(key: String, windowController: NSWindowController, resizeState: TerminalLiveResizeState? = nil,
         onClose: @escaping @MainActor (String) -> Void) {
        self.key = key
        self.windowController = windowController
        self.resizeState = resizeState
        self.onClose = onClose
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let view = windowController.window?.contentView else { return }
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        view.layer?.shouldRasterize = true
        view.layer?.rasterizationScale = view.window?.backingScaleFactor ?? 2
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let view = windowController.window?.contentView else { return }
        view.layer?.shouldRasterize = false
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        view.needsLayout = true
        view.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        onClose(key)
    }
}

private struct TerminalViewportWindowView: View {
    @ObservedObject var store: SessionStore
    let fallback: TrackedSession
    let reader: AgentTranscriptReader
    let sender: SessionPromptRouter
    let nativeSessions: NativeSessionCoordinator
    @ObservedObject var resizeState: TerminalLiveResizeState
    let onPreviewFile: (URL) -> Void
    let onClose: () -> Void

    private var session: TrackedSession {
        store.sessions.first(where: { $0.key == fallback.key }) ?? fallback
    }

    var body: some View {
        ZStack {
            Group {
                if resizeState.isResizing, let snapshot = resizeState.snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .interpolation(.medium)
                        .accessibilityHidden(true)
                } else {
                    TerminalViewportContent(
                        session: session,
                        reader: reader,
                        sender: sender,
                        nativeSessions: nativeSessions,
                        onPreviewFile: onPreviewFile,
                        onClose: onClose
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .accessibilityIdentifier("terminal-window-content")

            ResizeAffordanceOverlay()
                .allowsHitTesting(false)
        }
    }
}

private struct ResizeAffordanceOverlay: View {
    var body: some View {
        ZStack {
            HStack {
                resizeBar(width: 2, height: 34)
                Spacer()
                resizeBar(width: 2, height: 34)
            }
            VStack {
                resizeBar(width: 34, height: 2)
                Spacer()
                resizeBar(width: 34, height: 2)
            }
        }
        .padding(2)
        .accessibilityIdentifier("resize-affordances")
    }

    private func resizeBar(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.22))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.28), radius: 2)
    }
}

@MainActor
final class FilePreviewWindowCoordinator {
    private var entries: [String: TerminalWindowEntry] = [:]

    func show(url: URL) {
        let key = url.standardizedFileURL.path
        if let existing = entries[key] {
            existing.windowController.showWindow(nil)
            existing.windowController.window?.orderFrontRegardless()
            return
        }

        let window = FloatingTerminalPanel(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(url.lastPathComponent) · preview"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.minSize = CGSize(width: 420, height: 300)
        window.maxSize = CGSize(width: 1_400, height: 1_000)
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: FilePreviewWindowView(
            url: url,
            onClose: { [weak window] in window?.close() }
        ))
        window.center()
        window.setFrameOrigin(CGPoint(x: window.frame.origin.x + 36, y: window.frame.origin.y - 36))

        let controller = NSWindowController(window: window)
        let entry = TerminalWindowEntry(key: key, windowController: controller) { [weak self] key in
            self?.entries[key] = nil
        }
        window.delegate = entry
        entries[key] = entry
        controller.showWindow(nil)
        window.orderFrontRegardless()
    }
}

private struct FilePreviewWindowView: View {
    let url: URL
    let onClose: () -> Void

    @State private var content = "Loading preview…"
    @State private var image: NSImage?
    @State private var mode: FilePreviewMode

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        _mode = State(initialValue: FilePreviewKind(url: url).defaultMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                WindowDragHandle(identifier: "file-preview-drag-handle", label: "Drag file preview")
                Capsule().fill(.white.opacity(0.24)).frame(width: 38, height: 3).allowsHitTesting(false)
            }
            .frame(height: 10)

            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.cyan.opacity(0.70))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                    Text(url.deletingLastPathComponent().path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if image == nil, FilePreviewKind(url: url).supportsRenderedPreview {
                    Picker("View", selection: $mode) {
                        Text("Preview").tag(FilePreviewMode.preview)
                        Text("Source").tag(FilePreviewMode.source)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 132)
                    .controlSize(.small)
                    .accessibilityIdentifier("file-preview-mode")
                } else {
                    Text("LOCAL PREVIEW")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.30))
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel("Close file preview")
                .accessibilityIdentifier("close-file-preview")
            }

            Group {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(minWidth: 260, minHeight: 180)
                            .padding(16)
                    }
                } else if mode == .preview, FilePreviewKind(url: url) == .markdown {
                    MarkdownDocumentPreview(source: content, baseURL: url.deletingLastPathComponent())
                        .accessibilityIdentifier("rendered-markdown-preview")
                } else if mode == .preview, FilePreviewKind(url: url) == .html {
                    LocalHTMLPreview(url: url)
                        .accessibilityIdentifier("rendered-html-preview")
                } else {
                    SyntaxHighlightedTextView(text: lineNumbered(content), languageHint: url.lastPathComponent)
                        .accessibilityIdentifier("syntax-highlighted-file")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.7)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 0.7)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preview-window")
        .task(id: url) {
            if let loaded = NSImage(contentsOf: url) {
                image = loaded
                return
            }
            content = await Task.detached(priority: .userInitiated) {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let previewLimit = 400_000
                    let data = try handle.read(upToCount: previewLimit) ?? Data()
                    guard !data.contains(0) else { return "Binary file preview is unavailable." }
                    let text = String(decoding: data, as: UTF8.self)
                    return data.count == previewLimit ? text + "\n\n… preview limited to 400 KB" : text
                } catch {
                    return "Could not preview this file: \(error.localizedDescription)"
                }
            }.value
        }
    }

    private func lineNumbered(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { String(format: "%4d  %@", $0.offset + 1, String($0.element)) }
            .joined(separator: "\n")
    }
}

private enum FilePreviewMode: Hashable {
    case preview
    case source
}

private enum FilePreviewKind: Equatable {
    case markdown
    case html
    case source

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown": self = .markdown
        case "html", "htm": self = .html
        default: self = .source
        }
    }

    var supportsRenderedPreview: Bool { self != .source }
    var defaultMode: FilePreviewMode { supportsRenderedPreview ? .preview : .source }
}

private struct MarkdownDocumentPreview: View {
    let source: String
    let baseURL: URL

    private var rendered: AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full),
            baseURL: baseURL
        )) ?? AttributedString(source)
    }

    var body: some View {
        ScrollView(.vertical) {
            Text(rendered)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
    }
}

private struct LocalHTMLPreview: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        context.coordinator.loadedURL = url
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let destination = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(destination.isFileURL || destination.scheme == "about" ? .allow : .cancel)
        }
    }
}

struct WindowDragHandle: NSViewRepresentable {
    let identifier: String
    let label: String

    func makeNSView(context: Context) -> NSView {
        let view = NativeWindowDragView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class NativeWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// A native, selectable code surface. NSTextView keeps large previews smooth while
/// AppKit performs syntax coloring once per content update instead of on every SwiftUI frame.
struct SyntaxHighlightedTextView: NSViewRepresentable {
    let text: String
    let languageHint: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 9)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.renderedText != text || context.coordinator.languageHint != languageHint else { return }
        context.coordinator.renderedText = text
        context.coordinator.languageHint = languageHint
        context.coordinator.textView?.textStorage?.setAttributedString(
            SyntaxHighlighter.highlight(text, languageHint: languageHint)
        )
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var renderedText = ""
        var languageHint: String?
    }
}

@MainActor
enum SyntaxHighlighter {
    private static let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let base = NSColor.white.withAlphaComponent(0.76)
    private static let keyword = NSColor.systemPurple.blended(withFraction: 0.18, of: .white) ?? .systemPurple
    private static let string = NSColor.systemGreen.blended(withFraction: 0.14, of: .white) ?? .systemGreen
    private static let number = NSColor.systemOrange.blended(withFraction: 0.12, of: .white) ?? .systemOrange
    private static let comment = NSColor.white.withAlphaComponent(0.36)
    private static let key = NSColor.systemCyan.blended(withFraction: 0.12, of: .white) ?? .systemCyan
    private static let cache = NSCache<NSString, NSAttributedString>()

    static func highlight(_ source: String, languageHint: String?) -> NSAttributedString {
        cache.countLimit = 160
        cache.totalCostLimit = 8 * 1_024 * 1_024
        let cacheKey = NSString(string: "\(languageHint ?? "")\u{0}\(source)")
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: font,
                .foregroundColor: base,
                .paragraphStyle: paragraphStyle
            ]
        )
        let full = NSRange(source.startIndex..<source.endIndex, in: source)

        apply(#"\b(?:true|false|null|nil|let|var|func|struct|class|enum|protocol|extension|import|return|if|else|guard|for|while|switch|case|default|async|await|throws|throw|try|catch|private|public|internal|static|const|function|export|from|interface|type|new|in|do|done|then|fi|elif)\b"#, color: keyword, to: result, range: full)
        apply(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: number, to: result, range: full)
        apply(#"(?m)(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#, color: string, to: result, range: full)
        apply(#"(?m)^\s*\"[^\"\n]+\"(?=\s*:)"#, color: key, to: result, range: full)
        apply(#"(?m)(//.*$|#(?![0-9A-Fa-f]{3,8}\b).*$|/\*[\s\S]*?\*/)"#, color: comment, to: result, range: full)
        cache.setObject(result, forKey: cacheKey, cost: source.utf8.count)
        return result
    }

    static func attributed(_ source: String, languageHint: String?) -> AttributedString {
        (try? AttributedString(highlight(source, languageHint: languageHint), including: \.appKit))
            ?? AttributedString(source)
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }

    private static func apply(_ pattern: String, color: NSColor, to text: NSMutableAttributedString, range: NSRange) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for match in regex.matches(in: text.string, range: range) {
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
