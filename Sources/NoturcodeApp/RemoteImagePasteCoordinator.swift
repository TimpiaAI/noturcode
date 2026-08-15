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
    private struct Result {
        let status: Int32
        let output: String
        let error: String

        var diagnostic: String {
            [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    func upload(localURL: URL, host: String) throws -> String {
        guard Self.valid(host: host) else { throw RemoteImagePasteError.invalidHost }
        let remoteDirectory = ".cache/noturcode/attachments"
        let fileName = "image-\(UUID().uuidString).png"
        let prepare = try run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "--", host,
                "umask 077; mkdir -p \"$HOME/\(remoteDirectory)\"; chmod 700 \"$HOME/.cache/noturcode\" \"$HOME/\(remoteDirectory)\"; printf '%s' \"$HOME\""
            ]
        )
        guard prepare.status == 0 else {
            throw RemoteImagePasteError.commandFailed(Self.message(for: prepare.diagnostic, action: "prepare the VPS image folder"))
        }
        let remoteHome = prepare.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteHome.hasPrefix("/"),
              remoteHome.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/")).contains($0)
              }) else {
            throw RemoteImagePasteError.commandFailed("The VPS returned an invalid home folder.")
        }
        let remotePath = "\(remoteHome)/\(remoteDirectory)/\(fileName)"
        let copy = try run(
            executable: "/usr/bin/scp",
            arguments: [
                "-q",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "--", localURL.path, "\(host):\(remotePath)"
            ]
        )
        guard copy.status == 0 else {
            throw RemoteImagePasteError.commandFailed(Self.message(for: copy.diagnostic, action: "copy the image to the VPS"))
        }
        let protect = try run(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "--", host,
                "chmod 600 \"\(remotePath)\""
            ]
        )
        guard protect.status == 0 else {
            throw RemoteImagePasteError.commandFailed(Self.message(for: protect.diagnostic, action: "protect the VPS image"))
        }
        return remotePath
    }

    private func run(executable: String, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Result(status: process.terminationStatus, output: output, error: error)
    }

    private static func valid(host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), host.count <= 255 else { return false }
        return host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@")).contains($0)
        }
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
        let terminal = matchingSession?.terminal ?? TerminalTarget(sessionID: request.terminalSessionID)
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
        let remotePath = try await uploader.upload(localURL: localURL, host: host)
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
        guard png.count <= 20 * 1_024 * 1_024 else { throw RemoteImagePasteError.imageTooLarge }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noturcode-remote-paste", isDirectory: true)
        try SecureLocalStorage.ensurePrivateDirectory(at: directory)
        let url = directory.appendingPathComponent("image-\(UUID().uuidString).png")
        try SecureLocalStorage.writePrivate(png, to: url)
        return url
    }
}
