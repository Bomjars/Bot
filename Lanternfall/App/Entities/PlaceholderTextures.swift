import LanternfallKit
import SpriteKit
import UIKit

/// Draws simple placeholder textures at runtime so the game is playable
/// before real art exists. `artOrPlaceholder` prefers an image with the
/// given name from the asset catalog, so dropping in e.g.
/// `enemy_gloomling_walk_0` replaces the placeholder with no code change.
@MainActor
final class PlaceholderTextures {
    private var cache: [String: SKTexture] = [:]
    private let pixelSize: CGFloat

    init(textureSize: Float) {
        pixelSize = CGFloat(textureSize)
    }

    func artOrPlaceholder(_ name: String, placeholder: () -> SKTexture) -> SKTexture {
        if let cached = cache["art:\(name)"] {
            return cached
        }
        let texture = UIImage(named: name) != nil ? SKTexture(imageNamed: name) : placeholder()
        cache["art:\(name)"] = texture
        return texture
    }

    /// A shaded round body, optionally with two glowing eyes (for creatures).
    func blob(key: String, color: UIColor, eyeColor: UIColor? = nil) -> SKTexture {
        cached(key) { context, rect in
            let body = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: body)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(rect.width * 0.06)
            context.strokeEllipse(in: body)
            context.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
            context.fillEllipse(in: CGRect(x: rect.width * 0.26, y: rect.height * 0.16, width: rect.width * 0.3, height: rect.height * 0.2))
            if let eyeColor {
                context.setFillColor(eyeColor.cgColor)
                let eye = rect.width * 0.13
                context.fillEllipse(in: CGRect(x: rect.width * 0.3, y: rect.height * 0.38, width: eye, height: eye))
                context.fillEllipse(in: CGRect(x: rect.width * 0.57, y: rect.height * 0.38, width: eye, height: eye))
            }
        }
    }

    /// Soft radial falloff, used for the lantern glow.
    func glow(key: String, color: UIColor) -> SKTexture {
        cached(key) { context, rect in
            drawRadial(in: context, rect: rect, colors: [color, color.withAlphaComponent(0)], locations: [0, 1])
        }
    }

    /// Bright core with a coloured halo: projectiles, embers, orbitals.
    func orb(key: String, color: UIColor) -> SKTexture {
        cached(key) { context, rect in
            drawRadial(
                in: context,
                rect: rect,
                colors: [.white, color, color.withAlphaComponent(0)],
                locations: [0, 0.3, 1]
            )
        }
    }

    /// Placeholder Wick: hooded cloak, glowing eyes, bright scarf.
    func keeper(key: String, cloak: UIColor, scarf: UIColor, eyes: UIColor) -> SKTexture {
        cached(key) { context, rect in
            let w = rect.width
            let h = rect.height
            context.setFillColor(cloak.cgColor)
            context.fillEllipse(in: CGRect(x: w * 0.12, y: h * 0.08, width: w * 0.76, height: h * 0.84))
            context.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
            context.fillEllipse(in: CGRect(x: w * 0.27, y: h * 0.2, width: w * 0.46, height: h * 0.34))
            context.setFillColor(eyes.cgColor)
            context.fillEllipse(in: CGRect(x: w * 0.36, y: h * 0.32, width: w * 0.09, height: w * 0.09))
            context.fillEllipse(in: CGRect(x: w * 0.55, y: h * 0.32, width: w * 0.09, height: w * 0.09))
            context.setFillColor(scarf.cgColor)
            context.fill(CGRect(x: w * 0.16, y: h * 0.56, width: w * 0.68, height: h * 0.13))
            context.fill(CGRect(x: w * 0.6, y: h * 0.62, width: w * 0.14, height: h * 0.28))
        }
    }

    /// Forest floor tile with scattered specks; `seed` picks the pattern.
    func groundTile(key: String, seed: UInt64, base: UIColor, details: [UIColor], detailCount: Int) -> SKTexture {
        let texture = cached(key) { context, rect in
            context.setFillColor(base.cgColor)
            context.fill(rect)
            guard !details.isEmpty else { return }
            var rng = SplitMix64(seed: seed)
            for index in 0..<detailCount {
                let size = CGFloat(Int.random(in: 1...3, using: &rng)) * rect.width / 32
                let x = CGFloat.random(in: 0..<(rect.width - size), using: &rng)
                let y = CGFloat.random(in: 0..<(rect.height - size), using: &rng)
                context.setFillColor(details[index % details.count].cgColor)
                context.fill(CGRect(x: x, y: y, width: size, height: size))
            }
        }
        texture.filteringMode = .nearest
        return texture
    }

    // MARK: Drawing

    private func cached(_ key: String, draw: (CGContext, CGRect) -> Void) -> SKTexture {
        if let texture = cache[key] {
            return texture
        }
        let rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { rendererContext in
            draw(rendererContext.cgContext, rect)
        }
        let texture = SKTexture(image: image)
        cache[key] = texture
        return texture
    }

    private func drawRadial(in context: CGContext, rect: CGRect, colors: [UIColor], locations: [CGFloat]) {
        let cgColors = colors.map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: locations) else {
            return
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: rect.width / 2, options: [])
    }
}
