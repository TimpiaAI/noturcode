import AppKit
import NoturcodeCore
import SwiftUI

@MainActor
final class SelectionQuestionCoordinator {
    private var controller: NSWindowController?

    func show(request: SelectionContextRequest, sessions: [TrackedSession]) {
        let cwd = sessions.first(where: {
            guard let terminalSessionID = request.terminalSessionID else { return false }
            return $0.terminal.sessionID == terminalSessionID || $0.terminal.uniqueID == terminalSessionID
        })?.cwd

        if let window = controller?.window {
            window.contentView = NSHostingView(rootView: SelectionQuestionView(
                selection: request.selection,
                cwd: cwd,
                onClose: { [weak window] in window?.orderOut(nil) }
            ))
            position(window)
            window.makeKey()
            window.orderFrontRegardless()
            return
        }

        let panel = SelectionQuestionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 360, height: 280)
        panel.maxSize = NSSize(width: 760, height: 760)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SelectionQuestionView(
            selection: request.selection,
            cwd: cwd,
            onClose: { [weak panel] in panel?.orderOut(nil) }
        ))
        let windowController = NSWindowController(window: panel)
        controller = windowController
        position(panel)
        windowController.showWindow(nil)
        panel.makeKey()
        panel.orderFrontRegardless()
    }

    private func position(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - window.frame.height - 14)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - window.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - window.frame.height - 8)
        window.setFrameOrigin(origin)
    }
}

private final class SelectionQuestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct SelectionQuestionView: View {
    let selection: String
    let cwd: String?
    let onClose: () -> Void

    @State private var question = "What does this do?"
    @State private var answer = ""
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                NoturcodeBrandMark(size: 19)
                Text("Ask about selection").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("private side question")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(selection)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: answer.isEmpty ? 170 : 110)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))

            Text("Nothing is sent until you press Ask. The selected excerpt and your question go to your local Claude CLI.")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.42))

            if isLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Claude is reading only this selection…")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.52))
            } else if let error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.red.opacity(0.82))
            } else if !answer.isEmpty {
                ScrollView {
                    Text(answer)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: 7) {
                TextField("Ask Claude about the highlighted text…", text: $question)
                    .textFieldStyle(.plain)
                    .onSubmit(ask)
                Button(action: ask) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(.white.opacity(question.isEmpty ? 0.05 : 0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .foregroundStyle(.white.opacity(0.9))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.10), lineWidth: 0.7))
        .accessibilityIdentifier("selection-question-panel")
    }

    private func ask() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isLoading else { return }
        isLoading = true
        error = nil
        answer = ""
        let selected = selection
        let workingDirectory = cwd
        Task {
            do {
                answer = try await SelectionQuestionRunner.answer(
                    question: value,
                    selection: selected,
                    cwd: workingDirectory
                )
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private enum SelectionQuestionRunner {
    static func answer(question: String, selection: String, cwd: String?) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            guard let executable = [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.local/bin/claude"
            ].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw NSError(domain: "NoturcodeSelection", code: 127, userInfo: [
                    NSLocalizedDescriptionKey: "Claude Code is not installed or could not be found."
                ])
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "--print", "--safe-mode", "--no-session-persistence",
                "--tools", "", "--model", "haiku", "--max-budget-usd", "0.03",
                "Answer concisely. Explain only the supplied terminal selection. Do not run tools.\n\nQuestion: \(question)\n\nSelection:\n\(String(selection.prefix(20_000)))"
            ]
            if let cwd, FileManager.default.fileExists(atPath: cwd) {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            }
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, !result.isEmpty else {
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "NoturcodeSelection", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: detail.isEmpty ? "Claude did not return an answer." : detail
                ])
            }
            return result
        }.value
    }
}
