import AppKit

enum NoturcodeSoundCue: String {
    case connect = "NoturcodeConnect"
    case open = "NoturcodeOpen"
    case close = "NoturcodeClose"
    case send = "NoturcodeSend"
    case asking = "NoturcodeAsking"
    case done = "NoturcodeDone"
    case failed = "NoturcodeFailed"
}

@MainActor
final class NoturcodeSoundPlayer: NSObject, NSSoundDelegate {
    static let shared = NoturcodeSoundPlayer()

    private var activeSounds: [ObjectIdentifier: NSSound] = [:]
    private var lastPlayedAt: [NoturcodeSoundCue: Date] = [:]

    func play(_ cue: NoturcodeSoundCue) {
        let now = Date()
        guard now.timeIntervalSince(lastPlayedAt[cue] ?? .distantPast) > 0.12 else { return }
        lastPlayedAt[cue] = now
        guard let asset = NSDataAsset(name: cue.rawValue),
              let sound = NSSound(data: asset.data) else { return }
        sound.delegate = self
        switch cue {
        case .done, .asking, .failed:
            sound.volume = 0.82
        case .connect, .open, .close:
            sound.volume = 0.42
        case .send:
            sound.volume = 0.34
        }
        activeSounds[ObjectIdentifier(sound)] = sound
        sound.play()
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying finishedPlaying: Bool) {
        let identifier = ObjectIdentifier(sound)
        Task { @MainActor [weak self] in
            self?.activeSounds[identifier] = nil
        }
    }
}
