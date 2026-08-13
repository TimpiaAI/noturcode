import Foundation

public struct AvatarIdentity: Equatable, Sendable {
    public var hue: Double
    public var secondaryHue: Double
    public var saturation: Double
    public var brightness: Double

    public init(name: String) {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        let base = Double(hash % 360) / 360.0
        let direction = ((hash >> 12) & 1) == 0 ? 1.0 : -1.0
        let offset = 0.075 + Double((hash >> 16) % 25) / 1000.0
        self.hue = base
        self.secondaryHue = (base + direction * offset).truncatingRemainder(dividingBy: 1.0).positiveUnit
        self.saturation = 0.52
        self.brightness = 0.94
    }
}
private extension Double {
    var positiveUnit: Double { self < 0 ? self + 1 : self }
}
