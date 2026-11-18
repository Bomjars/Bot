import LanternfallKit
import SpriteKit
import UIKit

/// Floating joystick: appears where the thumb lands in the lower part of the
/// screen, and drags along behind the thumb if it slides past the rim.
/// Lives on the camera node, so all locations are in camera space
/// (origin at the centre of the screen).
@MainActor
final class VirtualJoystick {
    let node = SKNode()

    private let base: SKShapeNode
    private let knob: SKShapeNode
    private let radius: CGFloat
    private let deadZone: Float
    private let activeAreaFraction: CGFloat
    private var origin = CGPoint.zero

    private(set) var touch: UITouch?
    /// Normalised direction × strength (0...1).
    private(set) var vector = Vec2.zero

    var isActive: Bool { touch != nil }

    init(config: JoystickConfig, color: UIColor) {
        radius = CGFloat(config.radius)
        deadZone = config.deadZone
        activeAreaFraction = CGFloat(config.activeAreaFraction)

        base = SKShapeNode(circleOfRadius: radius)
        base.fillColor = color.withAlphaComponent(0.08)
        base.strokeColor = color.withAlphaComponent(0.45)
        base.lineWidth = 2

        knob = SKShapeNode(circleOfRadius: CGFloat(config.knobRadius))
        knob.fillColor = color.withAlphaComponent(0.55)
        knob.strokeColor = .clear

        node.addChild(base)
        node.addChild(knob)
        node.isHidden = true
    }

    /// True when `location` is inside the bottom `activeAreaFraction` of the screen.
    func canBegin(at location: CGPoint, viewHeight: CGFloat) -> Bool {
        let boundary = viewHeight / 2 - viewHeight * (1 - activeAreaFraction)
        return location.y <= boundary
    }

    func begin(touch: UITouch, at location: CGPoint) {
        self.touch = touch
        origin = location
        node.position = location
        knob.position = .zero
        node.isHidden = false
        vector = .zero
    }

    func move(to location: CGPoint) {
        var dx = location.x - origin.x
        var dy = location.y - origin.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > radius {
            let excess = (distance - radius) / distance
            origin.x += dx * excess
            origin.y += dy * excess
            node.position = origin
            dx = location.x - origin.x
            dy = location.y - origin.y
        }
        knob.position = CGPoint(x: dx, y: dy)

        let length = (dx * dx + dy * dy).squareRoot()
        let magnitude = Float(min(1, length / radius))
        guard length > 0, magnitude > deadZone else {
            vector = .zero
            return
        }
        let strength = (magnitude - deadZone) / (1 - deadZone)
        vector = Vec2(Float(dx / length), Float(dy / length)) * strength
    }

    func end() {
        touch = nil
        vector = .zero
        node.isHidden = true
    }
}
