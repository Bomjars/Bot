import LanternfallKit
import SpriteKit
import UIKit

/// Pooled floating damage numbers. Animated by hand in `update` (not
/// SKActions) so they freeze with the game when it pauses.
@MainActor
final class DamageNumberLayer {
    let node = SKNode()

    private var labels: [SKLabelNode] = []
    private var remaining: [Float] = []
    private var freeIndices: [Int] = []
    private let lifetime: Float
    private let riseSpeed: CGFloat

    init(config: JuiceConfig, color: UIColor) {
        lifetime = config.damageNumberLifetime
        riseSpeed = CGFloat(config.damageNumberRise / max(config.damageNumberLifetime, .ulpOfOne))
        for _ in 0..<config.damageNumberPoolSize {
            let label = SKLabelNode(fontNamed: "Menlo-Bold")
            label.fontSize = CGFloat(config.damageNumberFontSize)
            label.fontColor = color
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .center
            label.isHidden = true
            node.addChild(label)
            labels.append(label)
            remaining.append(0)
        }
        freeIndices = Array(labels.indices.reversed())
    }

    /// Silently skipped when every label is in use.
    func show(_ amount: Float, at position: CGPoint) {
        guard let index = freeIndices.popLast() else { return }
        let label = labels[index]
        label.text = String(Int(amount.rounded()))
        label.position = position
        label.alpha = 1
        label.isHidden = false
        remaining[index] = lifetime
    }

    func update(dt: Float) {
        guard dt > 0 else { return }
        for index in labels.indices where remaining[index] > 0 {
            remaining[index] -= dt
            let label = labels[index]
            if remaining[index] <= 0 {
                label.isHidden = true
                freeIndices.append(index)
                continue
            }
            label.position.y += riseSpeed * CGFloat(dt)
            label.alpha = CGFloat(remaining[index] / lifetime)
        }
    }
}
