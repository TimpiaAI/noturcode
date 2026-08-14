import AppKit
import QuartzCore
import SwiftUI

/// A render-server driven thinking orb for the always-resident notch surface.
/// Frames preserve the approved dotted ribbon/ring design, while Core Animation
/// advances them without rebuilding the surrounding SwiftUI hierarchy.
struct ColoredThinkingOrb: NSViewRepresentable {
    enum Motion: String {
        case composing
        case breathing
    }

    let motion: Motion
    let size: CGFloat
    let primaryHue: Double
    let secondaryHue: Double
    let saturation: Double
    let isAnimated: Bool

    func makeNSView(context: Context) -> ThinkingOrbAnimationView {
        ThinkingOrbAnimationView()
    }

    func updateNSView(_ view: ThinkingOrbAnimationView, context: Context) {
        view.configure(
            motion: motion,
            size: size,
            primaryHue: primaryHue,
            secondaryHue: secondaryHue,
            saturation: saturation,
            animated: isAnimated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    static func dismantleNSView(_ view: ThinkingOrbAnimationView, coordinator: ()) {
        view.stopAnimating()
    }
}

final class ThinkingOrbAnimationView: NSView {
    static let animationKey = "noturcode.thinking-orb.contents"

    private struct Configuration: Equatable {
        let motion: ColoredThinkingOrb.Motion
        let pixelSize: Int
        let primaryHue: Int
        let secondaryHue: Int
        let saturation: Int
        let animated: Bool
    }

    private var configuration: Configuration?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    func configure(
        motion: ColoredThinkingOrb.Motion,
        size: CGFloat,
        primaryHue: Double,
        secondaryHue: Double,
        saturation: Double,
        animated: Bool
    ) {
        let scale = window?.backingScaleFactor
            ?? NSScreen.screens.map(\.backingScaleFactor).max()
            ?? 2
        let next = Configuration(
            motion: motion,
            pixelSize: max(1, Int((size * scale).rounded())),
            primaryHue: Int((primaryHue * 10_000).rounded()),
            secondaryHue: Int((secondaryHue * 10_000).rounded()),
            saturation: Int((saturation * 10_000).rounded()),
            animated: animated
        )
        guard configuration != next else { return }
        configuration = next

        let frames = ThinkingOrbFrameStore.shared.frames(
            motion: motion,
            pointSize: size,
            scale: scale,
            primaryHue: primaryHue,
            secondaryHue: secondaryHue,
            saturation: saturation,
            animated: animated
        )
        guard let first = frames.first else { return }

        layer?.removeAnimation(forKey: Self.animationKey)
        layer?.contentsScale = scale
        layer?.contents = first
        guard animated, frames.count > 1, let layer else { return }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.duration = 2.4
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.animationKey)
    }

    func stopAnimating() {
        layer?.removeAnimation(forKey: Self.animationKey)
    }
}

private final class ThinkingOrbFrames: NSObject {
    let images: [CGImage]

    init(_ images: [CGImage]) {
        self.images = images
    }
}

@MainActor
private final class ThinkingOrbFrameStore {
    static let shared = ThinkingOrbFrameStore()

    private let cache = NSCache<NSString, ThinkingOrbFrames>()

    private init() {
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func frames(
        motion: ColoredThinkingOrb.Motion,
        pointSize: CGFloat,
        scale: CGFloat,
        primaryHue: Double,
        secondaryHue: Double,
        saturation: Double,
        animated: Bool
    ) -> [CGImage] {
        let frameCount = animated ? 48 : 1
        let key = NSString(
            format: "%@-%d-%d-%d-%d-%d",
            motion.rawValue,
            Int((pointSize * scale).rounded()),
            Int((primaryHue * 10_000).rounded()),
            Int((secondaryHue * 10_000).rounded()),
            Int((saturation * 10_000).rounded()),
            frameCount
        )
        if let cached = cache.object(forKey: key) {
            return cached.images
        }

        let images = (0..<frameCount).compactMap { index in
            let phase = frameCount == 1 ? 0.6 : Double(index) / Double(frameCount) * 2 * .pi
            return ThinkingOrbRenderer.image(
                motion: motion,
                pointSize: pointSize,
                scale: scale,
                phase: phase,
                primaryHue: primaryHue,
                secondaryHue: secondaryHue,
                saturation: saturation
            )
        }
        let boxed = ThinkingOrbFrames(images)
        let pixelWidth = max(1, Int((pointSize * scale).rounded()))
        cache.setObject(boxed, forKey: key, cost: pixelWidth * pixelWidth * 4 * max(1, images.count))
        return images
    }
}

private enum ThinkingOrbRenderer {
    private struct Dot {
        let point: CGPoint
        let depth: Double
        let radius: Double
        let ink: Double
        let opacity: Double
    }

    static func image(
        motion: ColoredThinkingOrb.Motion,
        pointSize: CGFloat,
        scale: CGFloat,
        phase: Double,
        primaryHue: Double,
        secondaryHue: Double,
        saturation: Double
    ) -> CGImage? {
        let pixelSize = max(1, Int((pointSize * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: pixelSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        let dots = dots(motion: motion, size: Double(pointSize), phase: phase)
            .sorted(by: { $0.depth < $1.depth })
        for dot in dots {
            context.setFillColor(
                color(
                    ink: dot.ink,
                    opacity: dot.opacity,
                    primaryHue: primaryHue,
                    secondaryHue: secondaryHue,
                    saturation: saturation
                )
            )
            context.fillEllipse(in: CGRect(
                x: dot.point.x - dot.radius,
                y: dot.point.y - dot.radius,
                width: dot.radius * 2,
                height: dot.radius * 2
            ))
        }
        return context.makeImage()
    }

    private static func dots(
        motion: ColoredThinkingOrb.Motion,
        size: Double,
        phase: Double
    ) -> [Dot] {
        let radius = size * 0.39
        let cameraTilt = 0.3
        let radiusScale = pow(size / 300, 0.6)
        let isFaceOn = motion == .breathing
        var result: [Dot] = []

        if !isFaceOn {
            let ghostCount = max(5, Int((size / 20 * 8).rounded()))
            for index in 0..<ghostCount {
                let direction = fibonacciDirection(index: index, count: ghostCount)
                let projected = project(
                    x: direction.x * radius,
                    y: direction.y * radius,
                    z: direction.z * radius,
                    tilt: cameraTilt,
                    center: CGPoint(x: size / 2, y: size / 2)
                )
                let depth = (projected.z / radius + 1) / 2
                result.append(Dot(
                    point: projected.point,
                    depth: projected.z,
                    radius: max(0.25, 0.8 * radiusScale),
                    ink: 0.78,
                    opacity: 0.10 + 0.22 * depth
                ))
            }
        }

        let angle = isFaceOn ? -cameraTilt : 0.55
        let ux = 1.0
        let uz = 0.0
        let vx = -uz * sin(angle)
        let vy = cos(angle)
        let vz = ux * sin(angle)
        let nx = -uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy
        let wobbleMultiplier = isFaceOn ? 0.565 : 1.0
        let wobbleAmplitude = 0.23 * wobbleMultiplier
        let baseRadius = isFaceOn ? radius / (1 + 0.85 * wobbleAmplitude) : radius
        let laneCount = isFaceOn ? 8 : 10
        let segmentCount = max(isFaceOn ? 15 : 20, Int((size * (isFaceOn ? 0.75 : 1.0)).rounded()))
        let baseDotRadius = isFaceOn ? 1.1 * 1.622 : 1.1 * 1.073
        let depthDotRadius = isFaceOn ? 1.7 * 1.622 : 1.7 * 1.073

        for lane in 0..<laneCount {
            let laneOffset = (Double(lane) - Double(laneCount - 1) / 2) * 0.075
            let edge = abs(Double(lane) - Double(laneCount - 1) / 2) / max(1, Double(laneCount - 1) / 2)
            for segment in 0..<segmentCount {
                let a = Double(segment) / Double(segmentCount) * 2 * .pi
                let wobble = (
                    0.16 * sin(a * 3 - phase * 2 + Double(lane) * 0.22)
                        + 0.07 * sin(a * 5 + phase)
                ) * wobbleMultiplier
                let radial = isFaceOn ? 1 + wobble : 1
                let offset = isFaceOn ? laneOffset : laneOffset + wobble
                let x = ux * cos(a) + vx * sin(a) + nx * offset
                let y = vy * sin(a) + ny * offset
                let z = uz * cos(a) + vz * sin(a) + nz * offset
                let length = sqrt(x * x + y * y + z * z)
                let projected = project(
                    x: x / length * baseRadius * radial,
                    y: y / length * baseRadius * radial,
                    z: z / length * baseRadius * radial,
                    tilt: cameraTilt,
                    center: CGPoint(x: size / 2, y: size / 2)
                )
                let depth = (projected.z / radius + 1) / 2
                let dotRadius = (baseDotRadius + depthDotRadius * depth) * (1 - 0.25 * edge) * radiusScale
                result.append(Dot(
                    point: projected.point,
                    depth: projected.z,
                    radius: max(0.25, dotRadius),
                    ink: 0.52 - 0.44 * depth + 0.18 * edge,
                    opacity: 0.40 + 0.60 * depth
                ))
            }
        }
        return result
    }

    private static func color(
        ink: Double,
        opacity: Double,
        primaryHue: Double,
        secondaryHue: Double,
        saturation: Double
    ) -> CGColor {
        let depth = min(1, max(0, 1 - ink))
        var hueDelta = primaryHue - secondaryHue
        if hueDelta > 0.5 { hueDelta -= 1 }
        if hueDelta < -0.5 { hueDelta += 1 }
        var hue = secondaryHue + hueDelta * depth
        if hue < 0 { hue += 1 }
        if hue >= 1 { hue -= 1 }
        return NSColor(
            calibratedHue: hue,
            saturation: saturation * (0.78 + 0.22 * depth),
            brightness: 0.70 + 0.30 * depth,
            alpha: opacity
        ).cgColor
    }

    private static func fibonacciDirection(index: Int, count: Int) -> (x: Double, y: Double, z: Double) {
        let y = 1 - (Double(index) + 0.5) / Double(count) * 2
        let radial = sqrt(max(0, 1 - y * y))
        let angle = Double(index) * .pi * (3 - sqrt(5))
        return (cos(angle) * radial, y, sin(angle) * radial)
    }

    private static func project(
        x: Double,
        y: Double,
        z: Double,
        tilt: Double,
        center: CGPoint
    ) -> (point: CGPoint, z: Double) {
        let projectedY = y * cos(tilt) - z * sin(tilt)
        let projectedZ = y * sin(tilt) + z * cos(tilt)
        return (CGPoint(x: center.x + x, y: center.y + projectedY), projectedZ)
    }
}
