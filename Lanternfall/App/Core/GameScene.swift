import LanternfallKit
import SpriteKit
import UIKit

/// Renders the simulation. Holds no game rules: each frame it runs the
/// simulation's fixed steps, then syncs pooled nodes (one per simulation
/// pool slot) to the state and plays back the step's events.
final class GameScene: SKScene {
    private enum Layer {
        static let ground: CGFloat = 0
        static let obstacles: CGFloat = 10
        static let embers: CGFloat = 20
        static let glow: CGFloat = 25
        static let enemies: CGFloat = 30
        static let player: CGFloat = 40
        static let healthBar: CGFloat = 41
        static let orbitals: CGFloat = 45
        static let projectiles: CGFloat = 50
        static let damageNumbers: CGFloat = 60
        static let joystick: CGFloat = 100
    }

    private let model: GameViewModel
    private let simulation: GameSimulation
    private let config: GameConfig
    private let textures: PlaceholderTextures
    private var clock: FixedTimestepClock

    private let world = SKNode()
    private let cameraNode = SKCameraNode()
    private let joystick: VirtualJoystick
    private let damageNumbers: DamageNumberLayer

    private let playerNode = SKSpriteNode()
    private let lanternNode = SKSpriteNode()
    private let glowNode = SKSpriteNode()
    private let healthBack = SKSpriteNode()
    private let healthFill = SKSpriteNode()

    private var enemyNodes: [SKSpriteNode] = []
    private var enemySerials: [UInt32] = []
    private var enemyFlashing: [Bool] = []
    private var enemyTextures: [SKTexture] = []
    private var enemyFlashTextures: [SKTexture] = []
    private var projectileNodes: [SKSpriteNode] = []
    private var projectileTextures: [SKTexture] = []
    private var emberNodes: [SKSpriteNode] = []
    private var emberTiers: [Int] = []
    private var emberTextures: [SKTexture] = []
    private var orbitalNodes: [SKSpriteNode] = []
    private var orbitalTextures: [SKTexture] = []

    private var hasBuiltWorld = false
    private var lastFrameTime: TimeInterval?
    private var playerHurtTimer: Float = 0
    private var renderedPickupRadius: Float = -1

    init(model: GameViewModel) {
        let config = model.simulation.content.config
        self.model = model
        self.config = config
        simulation = model.simulation
        textures = PlaceholderTextures(textureSize: config.render.placeholderTextureSize)
        clock = FixedTimestepClock(config: config.simulation)
        joystick = VirtualJoystick(config: config.joystick, color: UIColor(hex: config.palette.lightSoft))
        damageNumbers = DamageNumberLayer(config: config.juice, color: UIColor(hex: config.palette.text))
        super.init(size: CGSize(width: 390, height: 844))
        scaleMode = .resizeFill
        backgroundColor = UIColor(hex: config.palette.background)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = false
        guard !hasBuiltWorld else { return }
        hasBuiltWorld = true

        addChild(world)
        addChild(cameraNode)
        camera = cameraNode

        buildGround()
        buildObstacles()
        buildPools()
        buildPlayer()

        damageNumbers.node.zPosition = Layer.damageNumbers
        world.addChild(damageNumbers.node)
        joystick.node.zPosition = Layer.joystick
        cameraNode.addChild(joystick.node)
        cameraNode.position = point(simulation.player.position)
    }

    override func update(_ currentTime: TimeInterval) {
        guard hasBuiltWorld else { return }
        let maxFrameDelta = config.simulation.fixedTimestep * Double(config.simulation.maxStepsPerFrame)
        let frameDelta = lastFrameTime.map { min(currentTime - $0, maxFrameDelta) } ?? 0
        lastFrameTime = currentTime

        if simulation.phase != .playing, joystick.isActive {
            joystick.end()
        }
        simulation.viewportSize = Vec2(Float(size.width), Float(size.height))
        simulation.moveInput = joystick.vector

        let steps = clock.advance(to: currentTime)
        let dt = Float(clock.stepDuration)
        for _ in 0..<steps {
            simulation.step(dt: dt)
        }

        renderFrame(frameDelta: simulation.phase == .playing ? Float(frameDelta) : 0)
        model.sync()
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard simulation.phase == .playing, !joystick.isActive else { return }
        for touch in touches {
            let location = touch.location(in: cameraNode)
            if joystick.canBegin(at: location, viewHeight: size.height) {
                joystick.begin(touch: touch, at: location)
                return
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = joystick.touch, touches.contains(touch) else { return }
        joystick.move(to: touch.location(in: cameraNode))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = joystick.touch, touches.contains(touch) {
            joystick.end()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = joystick.touch, touches.contains(touch) {
            joystick.end()
        }
    }

    // MARK: - Building

    private func buildGround() {
        let palette = config.palette
        let mapSize = CGFloat(simulation.level.mapSize)
        let tileSize = CGFloat(config.render.groundTileSize)
        let detailColors = [UIColor(hex: palette.backgroundAlt), UIColor(hex: palette.groundDetail)]
        let tiles = (0..<3).map { variant in
            textures.artOrPlaceholder("ground_\(simulation.level.id)_\(variant)") {
                textures.groundTile(
                    key: "ground_\(variant)",
                    seed: UInt64(variant + 1),
                    base: UIColor(hex: palette.background),
                    details: detailColors,
                    detailCount: config.render.groundDetailCount
                )
            }
        }

        let count = Int((mapSize / tileSize).rounded(.up))
        for row in 0..<count {
            for column in 0..<count {
                let tile = SKSpriteNode(texture: tiles[(row * 7 + column * 3) % tiles.count], size: CGSize(width: tileSize, height: tileSize))
                tile.anchorPoint = .zero
                tile.position = CGPoint(x: CGFloat(column) * tileSize, y: CGFloat(row) * tileSize)
                tile.zPosition = Layer.ground
                world.addChild(tile)
            }
        }

        let border = SKShapeNode(rect: CGRect(x: 0, y: 0, width: mapSize, height: mapSize))
        border.strokeColor = UIColor(hex: palette.enemyShadow)
        border.fillColor = .clear
        border.lineWidth = CGFloat(config.render.mapBorderWidth)
        border.zPosition = Layer.ground + 1
        world.addChild(border)
    }

    private func buildObstacles() {
        let kinds = simulation.level.obstacles.kinds
        let kindTextures = kinds.map { kind in
            textures.artOrPlaceholder("obstacle_\(kind.id)") {
                textures.blob(key: "obstacle_\(kind.id)", color: UIColor(hex: kind.color))
            }
        }
        for obstacle in simulation.obstacles {
            let diameter = CGFloat(obstacle.radius * 2)
            let node = SKSpriteNode(texture: kindTextures[obstacle.kindIndex], size: CGSize(width: diameter, height: diameter))
            node.position = point(obstacle.position)
            node.zPosition = Layer.obstacles
            world.addChild(node)
        }
    }

    private func buildPools() {
        let content = simulation.content
        let palette = config.palette
        let eyeColor = UIColor(hex: palette.lightSoft)

        enemyTextures = content.enemies.map { enemy in
            textures.artOrPlaceholder("\(enemy.spriteName)_walk_0") {
                textures.blob(key: enemy.spriteName, color: UIColor(hex: enemy.color), eyeColor: eyeColor)
            }
        }
        enemyFlashTextures = content.enemies.map { enemy in
            textures.artOrPlaceholder("\(enemy.spriteName)_flash") {
                textures.blob(key: "\(enemy.spriteName)_flash", color: .white)
            }
        }
        projectileTextures = content.weapons.map { weapon in
            textures.artOrPlaceholder("\(weapon.spriteName)_projectile") {
                textures.orb(key: "\(weapon.id)_orb", color: UIColor(hex: weapon.color))
            }
        }
        orbitalTextures = projectileTextures
        emberTextures = config.pickups.emberTiers.map { tier in
            textures.artOrPlaceholder("pickup_soul_\(tier.name)") {
                textures.orb(key: "ember_\(tier.name)", color: UIColor(hex: tier.color))
            }
        }

        enemyNodes = makeNodes(count: simulation.enemies.capacity, zPosition: Layer.enemies, additive: false)
        enemySerials = Array(repeating: 0, count: enemyNodes.count)
        enemyFlashing = Array(repeating: false, count: enemyNodes.count)
        projectileNodes = makeNodes(count: simulation.projectiles.capacity, zPosition: Layer.projectiles, additive: true)
        emberNodes = makeNodes(count: simulation.embers.capacity, zPosition: Layer.embers, additive: true)
        emberTiers = Array(repeating: -1, count: emberNodes.count)
        let maxOrbitals = content.weapons
            .filter { $0.behavior == .orbit }
            .reduce(0) { $0 + ($1.levels.map(\.count).max() ?? 0) }
        orbitalNodes = makeNodes(count: maxOrbitals, zPosition: Layer.orbitals, additive: true)
    }

    private func makeNodes(count: Int, zPosition: CGFloat, additive: Bool) -> [SKSpriteNode] {
        (0..<count).map { _ in
            let node = SKSpriteNode()
            node.isHidden = true
            node.zPosition = zPosition
            if additive {
                node.blendMode = .add
            }
            world.addChild(node)
            return node
        }
    }

    private func buildPlayer() {
        let palette = config.palette
        let render = config.render
        let spriteSize = CGFloat(render.characterSpriteSize)

        glowNode.texture = textures.glow(key: "lantern_glow", color: UIColor(hex: palette.light))
        glowNode.alpha = CGFloat(render.pickupGlowAlpha)
        glowNode.blendMode = .add
        glowNode.zPosition = Layer.glow
        world.addChild(glowNode)

        playerNode.texture = textures.artOrPlaceholder("player_\(simulation.character.id)_idle_0") {
            textures.keeper(
                key: "player_\(simulation.character.id)",
                cloak: UIColor(hex: palette.playerCloak),
                scarf: UIColor(hex: palette.playerScarf),
                eyes: UIColor(hex: palette.lightSoft)
            )
        }
        playerNode.size = CGSize(width: spriteSize, height: spriteSize)
        playerNode.color = UIColor(hex: palette.danger)
        playerNode.zPosition = Layer.player
        world.addChild(playerNode)

        lanternNode.texture = textures.orb(key: "lantern", color: UIColor(hex: palette.light))
        lanternNode.size = CGSize(width: spriteSize * 0.5, height: spriteSize * 0.5)
        lanternNode.blendMode = .add
        lanternNode.zPosition = 1
        playerNode.addChild(lanternNode)

        let barSize = CGSize(width: CGFloat(render.healthBarWidth), height: CGFloat(render.healthBarHeight))
        for (bar, color) in [(healthBack, UIColor.black.withAlphaComponent(0.6)), (healthFill, UIColor(hex: palette.danger))] {
            bar.color = color
            bar.size = barSize
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            bar.zPosition = Layer.healthBar
            world.addChild(bar)
        }
        healthFill.zPosition = Layer.healthBar + 1
    }

    // MARK: - Rendering

    private func renderFrame(frameDelta: Float) {
        renderPlayer(frameDelta: frameDelta)
        renderEnemies()
        renderProjectiles()
        renderEmbers()
        renderOrbitals()

        simulation.drainEvents { event in
            switch event {
            case let .enemyDamaged(position, amount):
                damageNumbers.show(amount, at: point(position))
            case .playerDamaged:
                playerHurtTimer = config.juice.playerHurtFlashDuration
            default:
                break
            }
        }
        damageNumbers.update(dt: frameDelta)
        followPlayer(frameDelta: frameDelta)
    }

    private func renderPlayer(frameDelta: Float) {
        let player = simulation.player
        let position = point(player.position)
        playerNode.position = position

        let spriteSize = CGFloat(config.render.characterSpriteSize)
        let side: CGFloat = player.facing.x < 0 ? -1 : 1
        lanternNode.position = CGPoint(x: side * spriteSize * 0.42, y: -spriteSize * 0.12)

        playerHurtTimer = max(0, playerHurtTimer - frameDelta)
        playerNode.colorBlendFactor = playerHurtTimer > 0 ? 0.7 : 0
        playerNode.alpha = player.invulnerability > 0 ? 0.65 : 1

        let pickupRadius = simulation.stats.pickupRadius
        if pickupRadius != renderedPickupRadius {
            renderedPickupRadius = pickupRadius
            let diameter = CGFloat(pickupRadius * 2)
            glowNode.size = CGSize(width: diameter, height: diameter)
        }
        glowNode.position = position

        let barOrigin = CGPoint(x: position.x - CGFloat(config.render.healthBarWidth) / 2, y: position.y - CGFloat(config.render.healthBarOffset))
        healthBack.position = barOrigin
        healthFill.position = barOrigin
        healthFill.xScale = CGFloat(max(0, min(1, player.hp / max(simulation.stats.maxHP, 1))))
    }

    private func renderEnemies() {
        let enemies = simulation.enemies.items
        let scale = config.render.enemySpriteScale
        for index in enemies.indices {
            let node = enemyNodes[index]
            let enemy = enemies[index]
            guard enemy.isActive else {
                if !node.isHidden {
                    node.isHidden = true
                }
                continue
            }
            if node.isHidden || enemySerials[index] != enemy.serial {
                enemySerials[index] = enemy.serial
                enemyFlashing[index] = false
                node.texture = enemyTextures[enemy.typeIndex]
                let diameter = CGFloat(enemy.radius * 2 * scale)
                node.size = CGSize(width: diameter, height: diameter)
                node.isHidden = false
            }
            let flashing = enemy.flashTimer > 0
            if flashing != enemyFlashing[index] {
                enemyFlashing[index] = flashing
                node.texture = flashing ? enemyFlashTextures[enemy.typeIndex] : enemyTextures[enemy.typeIndex]
            }
            node.position = point(enemy.position)
        }
    }

    private func renderProjectiles() {
        let projectiles = simulation.projectiles.items
        let glowScale = config.render.projectileGlowScale
        for index in projectiles.indices {
            let node = projectileNodes[index]
            let projectile = projectiles[index]
            guard projectile.isActive else {
                if !node.isHidden {
                    node.isHidden = true
                }
                continue
            }
            let texture = projectileTextures[projectile.weaponIndex]
            if node.texture !== texture {
                node.texture = texture
            }
            let diameter = CGFloat(projectile.radius * 2 * glowScale)
            let size = CGSize(width: diameter, height: diameter)
            if node.size != size {
                node.size = size
            }
            node.position = point(projectile.position)
            node.isHidden = false
        }
    }

    private func renderEmbers() {
        let embers = simulation.embers.items
        let tiers = config.pickups.emberTiers
        let glowScale = config.render.projectileGlowScale
        for index in embers.indices {
            let node = emberNodes[index]
            let ember = embers[index]
            guard ember.isActive else {
                if !node.isHidden {
                    node.isHidden = true
                }
                continue
            }
            if emberTiers[index] != ember.tier {
                emberTiers[index] = ember.tier
                node.texture = emberTextures[ember.tier]
                let diameter = CGFloat(tiers[ember.tier].radius * 2 * glowScale)
                node.size = CGSize(width: diameter, height: diameter)
            }
            node.position = point(ember.position)
            node.isHidden = false
        }
    }

    private func renderOrbitals() {
        let orbitals = simulation.orbitals
        let glowScale = config.render.projectileGlowScale
        for (index, node) in orbitalNodes.enumerated() {
            guard index < orbitals.count else {
                if !node.isHidden {
                    node.isHidden = true
                }
                continue
            }
            let orbital = orbitals[index]
            node.texture = orbitalTextures[orbital.weaponIndex]
            let diameter = CGFloat(orbital.radius * 2 * glowScale)
            node.size = CGSize(width: diameter, height: diameter)
            node.position = point(orbital.position)
            node.isHidden = false
        }
    }

    private func followPlayer(frameDelta: Float) {
        guard frameDelta > 0 else { return }
        let target = playerNode.position
        let blend = CGFloat(1 - exp(-config.camera.followSharpness * frameDelta))
        cameraNode.position = CGPoint(
            x: cameraNode.position.x + (target.x - cameraNode.position.x) * blend,
            y: cameraNode.position.y + (target.y - cameraNode.position.y) * blend
        )
    }

    private func point(_ vector: Vec2) -> CGPoint {
        CGPoint(x: CGFloat(vector.x), y: CGFloat(vector.y))
    }
}
