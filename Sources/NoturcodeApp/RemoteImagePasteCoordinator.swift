import AppKit
import Foundation
import NoturcodeCore

private enum RemoteImagePasteError: LocalizedError {
    case sessionMissing
    case notRemote
    case invalidHost
    case imageTooLarge
    case commandFailed(String)
    case terminalMissing

    var errorDescription: String? {
        switch self {
        case .sessionMissing: "This iTerm2 pane is not connected to Noturcode."
        case .notRemote: "Open this SSH workspace again with `nc` to enable direct image paste."
        case .invalidHost: "The saved SSH host is not safe to use. Open the workspace again with `nc`."
        case .imageTooLarge: "The copied image is larger than 20 MB."
        case let .commandFailed(message): message
        case .terminalMissing: "Noturcode could not insert the image into this iTerm2 pane."
        }
    }
}

private actor RemoteImageUploader {
    func upload(localURL: URL, host: String, controlPath: String?) throws -> String {
        if let controlPath, !RemoteImageUploadPlan.isUsableControlSocket(controlPath) {
            throw RemoteImagePasteError.commandFailed(
                "This SSH workspace is closed or stale. Open it again with `nc`."
            )
        }
        let fileName = RemoteImageUploadPlan.fileName()
        guard let arguments = RemoteImageUploadPlan.sshArguments(
            host: host,
            fileName: fileName,
            controlPath: controlPath
        ) else {
            throw RemoteImagePasteError.invalidHost
        }
        let upload: BoundedProcessResult
        do {
            upload = try BoundedProcessRunner.run(
                executable: "/usr/bin/ssh",
                arguments: arguments,
                standardInputURL: localURL,
                timeout: 30
            )
        } catch BoundedProcessRunnerError.timedOut {
            throw RemoteImagePasteError.commandFailed("The image upload timed out after 30 seconds.")
        }
        let output = String(decoding: upload.output, as: UTF8.self)
        let error = String(decoding: upload.error, as: UTF8.self)
        guard upload.status == 0 else {
            let diagnostic = [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw RemoteImagePasteError.commandFailed(Self.message(for: diagnostic, action: "upload the image to the VPS"))
        }
        guard let remotePath = RemoteImageUploadPlan.validatedRemotePath(output) else {
            throw RemoteImagePasteError.commandFailed("The VPS returned an invalid image path.")
        }
        return remotePath
    }

    private static func message(for output: String, action: String) -> String {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "Noturcode could not \(action)." : "Noturcode could not \(action): \(detail)"
    }
}

@MainActor
final class RemoteImagePasteCoordinator {
    private let uploader = RemoteImageUploader()
    private let terminalSender: ITermPromptSender

    init(terminalSender: ITermPromptSender) {
        self.terminalSender = terminalSender
    }

    func handle(request: TerminalImagePasteRequest, sessions: [TrackedSession]) async throws -> Bool {
        let matchingSession = sessions.first(where: {
            $0.terminal?.uniqueID == request.terminalSessionID
        })
        let persistedTerminal = matchingSession?.terminal
        let registeredTerminal = RemoteTerminalRegistry().targets().first {
            $0.uniqueID == request.terminalSessionID
        }
        let terminal: TerminalTarget
        terminal = registeredTerminal
            ?? persistedTerminal
            ?? TerminalTarget(sessionID: request.terminalSessionID)
        guard let localURL = try persistClipboardImage() else {
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
            try await insert(text, into: terminal)
            return true
        }
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard matchingSession != nil else {
            throw RemoteImagePasteError.sessionMissing
        }
        guard let host = terminal.identity?.remoteHost, !host.isEmpty else {
            throw RemoteImagePasteError.notRemote
        }
        let remotePath = try await uploader.upload(
            localURL: localURL,
            host: host,
            controlPath: terminal.identity?.sshControlPath
        )
        try await insert(remotePath, into: terminal)
        return true
    }

    private func insert(_ text: String, into terminal: TerminalTarget) async throws {
        let result = await terminalSender.insertWithoutSubmitting(text, to: terminal)
        switch result {
        case .sent: return
        case .missing: throw RemoteImagePasteError.terminalMissing
        case let .failed(message): throw RemoteImagePasteError.commandFailed(message)
        }
    }

    private func persistClipboardImage() throws -> URL? {
        let pasteboard = NSPasteboard.general
        var image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        if image == nil {
            let imageTypes: [NSPasteboard.PasteboardType] = [
                .png, .tiff,
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.heic")
            ]
            for item in pasteboard.pasteboardItems ?? [] where image == nil {
                if let data = imageTypes.lazy.compactMap({ item.data(forType: $0) }).first {
                    image = NSImage(data: data)
                } else if let rawURL = item.string(forType: .fileURL),
                          let url = URL(string: rawURL) {
                    image = NSImage(contentsOf: url)
                }
            }
        }
        guard let image else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        guard png.count <= RemoteImageUploadPlan.maximumImageBytes else {
            throw RemoteImagePasteError.imageTooLarge
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-paste", isDirectory: true)
        try SecureLocalStorage.ensurePrivateDirectory(at: directory)
        let url = directory.appendingPathComponent("image-\(UUID().uuidString).png")
        try SecureLocalStorage.writePrivate(png, to: url)
        return url
    }
}
