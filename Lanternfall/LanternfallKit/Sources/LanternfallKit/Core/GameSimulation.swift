import Foundation

/// The whole run, independent of rendering. Call `step(dt:)` at a fixed rate;
/// the SpriteKit scene reads the public state and drains `events` to draw it.
public final class GameSimulation {
    public let content: GameContent
    public let level: LevelConfig
    public let character: CharacterConfig
    public let obstacles: [Obstacle]

    public private(set) var phase: RunPhase = .playing
    /// Seconds survived.
    public private(set) var time: Float = 0
    public internal(set) var player: PlayerState
    public private(set) var stats: PlayerStats
    public private(set) var loadout = Loadout()
    public private(set) var weapons: [WeaponInstance] = []
    public internal(set) var enemies: Pool<Enemy>
    public private(set) var projectiles: Pool<Projectile>
    public private(set) var embers: Pool<Ember>
    public private(set) var orbitals: [Orbital] = []
    public private(set) var upgradeChoices: [UpgradeOption] = []
    public private(set) var pendingLevelUps = 0
    public private(set) var kills = 0
    /// Total damage dealt per weapon id (for the results screen).
    public private(set) var damageByWeapon: [String: Float] = [:]

    /// Movement input, magnitude 0...1 (longer vectors are normalised).
    public var moveInput: Vec2 = .zero
    /// Visible area in world points; enemies spawn just outside it.
    public var viewportSize = Vec2(390, 844)

    private let config: GameConfig
    private let xpCurve: XPCurve
    private var spawner: Spawner
    private var spawnBuffer: [SpawnRequest] = []
    private var enemyGrid: SpatialHashGrid
    private var obstacleGrid: SpatialHashGrid
    private var events: [SimEvent] = []
    private var hitScratch: [Int] = []
    private var rng: SplitMix64
    private var nextSerial: UInt32 = 1
    private let maxEnemyRadius: Float
    private let maxObstacleRadius: Float

    public init(content: GameContent, levelID: String, characterID: String, seed: UInt64) throws {
        guard let level = content.level(id: levelID) else {
            throw ContentError("unknown level '\(levelID)'")
        }
        guard let character = content.character(id: characterID) else {
            throw ContentError("unknown character '\(characterID)'")
        }
        guard let startingWeapon = content.weaponIndex(id: character.startingWeapon) else {
            throw ContentError("character '\(characterID)' has no implemented starting weapon")
        }

        let config = content.config
        var rng = SplitMix64(seed: seed)
        let obstacles = ObstacleGenerator.generate(field: level.obstacles, mapSize: level.mapSize, using: &rng)
        let stats = PlayerStats.compute(player: config.player, character: character.modifiers, passives: [], rules: config.upgrades)

        self.content = content
        self.level = level
        self.character = character
        self.config = config
        self.obstacles = obstacles
        self.rng = rng
        self.stats = stats
        player = PlayerState(position: Vec2(repeating: level.mapSize / 2), hp: stats.maxHP)
        xpCurve = XPCurve(config: config.xp)
        spawner = Spawner(waves: level.waves, content: content)
        enemies = Pool(capacity: level.enemyCap, placeholder: Enemy())
        projectiles = Pool(capacity: config.simulation.maxProjectiles, placeholder: Projectile())
        embers = Pool(capacity: config.pickups.maxActiveEmbers, placeholder: Ember())
        enemyGrid = SpatialHashGrid(worldSize: level.mapSize, cellSize: config.simulation.spatialCellSize)
        obstacleGrid = SpatialHashGrid(worldSize: level.mapSize, cellSize: config.simulation.spatialCellSize)
        maxEnemyRadius = content.enemies.map(\.radius).max() ?? 0
        maxObstacleRadius = obstacles.map(\.radius).max() ?? 0

        obstacleGrid.rebuild(count: obstacles.count) { obstacles[$0].position }
        UpgradeSystem.apply(UpgradeOption(kind: .weapon, itemID: character.startingWeapon, fromLevel: 0, toLevel: 1), to: &loadout)
        weapons.append(WeaponInstance(weaponIndex: startingWeapon, level: 1))
    }

    // MARK: - Public API

    public var xpRequiredForNextLevel: Float { xpCurve.requirement(forLevel: player.level) }

    /// Hands every event since the last call to `body`, then clears them.
    public func drainEvents(_ body: (SimEvent) -> Void) {
        for event in events {
            body(event)
        }
        events.removeAll(keepingCapacity: true)
    }

    public func setPaused(_ paused: Bool) {
        if paused, phase == .playing {
            phase = .paused
        } else if !paused, phase == .paused {
            phase = .playing
        }
    }

    /// Applies one of the offered `upgradeChoices`. Returns false if it wasn't on offer.
    @discardableResult
    public func chooseUpgrade(_ option: UpgradeOption) -> Bool {
        guard phase == .choosingUpgrade, upgradeChoices.contains(option) else { return false }

        UpgradeSystem.apply(option, to: &loadout)
        switch option.kind {
        case .weapon:
            if let index = weapons.firstIndex(where: { content.weapons[$0.weaponIndex].id == option.itemID }) {
                weapons[index].level = option.toLevel
            } else if let weaponIndex = content.weaponIndex(id: option.itemID) {
                weapons.append(WeaponInstance(weaponIndex: weaponIndex, level: option.toLevel))
            }
        case .passive:
            recomputeStats()
        case .heal:
            player.hp = min(stats.maxHP, player.hp + config.upgrades.fallbackHealAmount)
        }

        pendingLevelUps -= 1
        if pendingLevelUps > 0 {
            upgradeChoices = UpgradeSystem.rollOptions(for: loadout, content: content, using: &rng)
        } else {
            upgradeChoices = []
            phase = .playing
        }
        return true
    }

    /// Advances the run by one fixed step. Does nothing unless `.playing`.
    public func step(dt: Float) {
        guard phase == .playing else { return }
        let stepStart = time
        time += dt

        updatePlayer(dt: dt)
        spawnEnemies(stepStart: stepStart, dt: dt)
        rebuildEnemyGrid()
        updateEnemies(dt: dt)
        rebuildEnemyGrid()
        updateWeapons(dt: dt)
        updateProjectiles(dt: dt)
        applyContactDamage()
        updateEmbers(dt: dt)
        processLevelUps()

        if phase == .playing, time >= level.duration {
            phase = .victory
            events.append(.runEnded(victory: true))
        }
    }

    // MARK: - Player

    private func updatePlayer(dt: Float) {
        var input = moveInput
        if input.lengthSquared > 1 {
            input = input.normalized()
        }
        var position = player.position + input * stats.moveSpeed * dt
        if input.lengthSquared > 0 {
            player.facing = input.normalized()
        }
        pushOutOfObstacles(&position, radius: config.player.radius)
        player.position = clampToMap(position, padding: config.player.radius)

        if stats.hpRegenPerSecond > 0 {
            player.hp = min(stats.maxHP, player.hp + stats.hpRegenPerSecond * dt)
        }
        if player.invulnerability > 0 {
            player.invulnerability -= dt
        }
    }

    private func applyContactDamage() {
        guard player.invulnerability <= 0 else { return }
        let playerRadius = config.player.radius
        var strongest: Float = 0
        enemyGrid.query(center: player.position, radius: playerRadius + maxEnemyRadius) { index in
            let enemy = enemies.items[index]
            guard enemy.isActive else { return }
            let reach = playerRadius + enemy.radius
            if (enemy.position - player.position).lengthSquared <= reach * reach {
                strongest = max(strongest, enemy.contactDamage)
            }
        }
        guard strongest > 0 else { return }

        let damage = max(config.simulation.minContactDamage, strongest - stats.armor) * stats.damageTakenMultiplier
        player.hp -= damage
        player.invulnerability = config.player.invulnerabilityTime
        events.append(.playerDamaged(amount: damage))
        if player.hp <= 0 {
            player.hp = 0
            phase = .gameOver
            events.append(.runEnded(victory: false))
        }
    }

    // MARK: - Enemies

    private func spawnEnemies(stepStart: Float, dt: Float) {
        let spawnDistance = (viewportSize * 0.5).length + config.simulation.spawnMargin
        spawner.update(
            time: stepStart,
            dt: dt,
            center: player.position,
            spawnDistance: spawnDistance,
            mapSize: level.mapSize,
            edgePadding: maxEnemyRadius,
            availableSlots: enemies.availableCount,
            using: &rng,
            into: &spawnBuffer
        )
        for request in spawnBuffer {
            spawnEnemy(typeIndex: request.enemyIndex, at: request.position)
        }
    }

    @discardableResult
    func spawnEnemy(typeIndex: Int, at position: Vec2) -> Int? {
        let type = content.enemies[typeIndex]
        var enemy = Enemy()
        enemy.serial = nextSerial
        enemy.typeIndex = typeIndex
        enemy.position = position
        enemy.hp = type.maxHP
        enemy.maxHP = type.maxHP
        enemy.speed = type.moveSpeed
        enemy.radius = type.radius
        enemy.contactDamage = type.contactDamage
        enemy.xpValue = type.xpValue
        guard let index = enemies.spawn(enemy) else { return nil }
        nextSerial &+= 1
        return index
    }

    private func rebuildEnemyGrid() {
        enemyGrid.rebuild(count: enemies.capacity) { index in
            enemies.items[index].isActive ? enemies.items[index].position : nil
        }
    }

    private func updateEnemies(dt: Float) {
        let sim = config.simulation
        let separationFactor = min(1, sim.separationStrength * dt)
        let damping = max(0, 1 - sim.knockbackDamping * dt)

        for index in 0..<enemies.capacity where enemies.items[index].isActive {
            var enemy = enemies.items[index]

            let chase = (player.position - enemy.position).normalized() * enemy.speed
            var separation = Vec2.zero
            var neighbours = 0
            enemyGrid.query(center: enemy.position, radius: enemy.radius + maxEnemyRadius) { other in
                guard other != index, neighbours < sim.maxSeparationNeighbors else { return }
                let neighbour = enemies.items[other]
                guard neighbour.isActive else { return }
                let offset = enemy.position - neighbour.position
                let minDistance = enemy.radius + neighbour.radius
                let distanceSquared = offset.lengthSquared
                guard distanceSquared < minDistance * minDistance, distanceSquared > 0 else { return }
                let distance = distanceSquared.squareRoot()
                separation += offset / distance * (minDistance - distance)
                neighbours += 1
            }

            var position = enemy.position + (chase + enemy.knockback) * dt + separation * separationFactor
            pushOutOfObstacles(&position, radius: enemy.radius)
            enemy.position = clampToMap(position, padding: enemy.radius)
            enemy.knockback *= damping
            enemy.flashTimer = max(0, enemy.flashTimer - dt)
            enemy.contactImmunity = max(0, enemy.contactImmunity - dt)
            enemies.items[index] = enemy
        }
    }

    private func damageEnemy(_ index: Int, amount: Float, direction: Vec2, knockback: Float, weaponIndex: Int) {
        enemies.items[index].hp -= amount
        enemies.items[index].flashTimer = config.juice.hitFlashDuration
        enemies.items[index].knockback += direction * knockback
        events.append(.enemyDamaged(position: enemies.items[index].position, amount: amount))
        damageByWeapon[content.weapons[weaponIndex].id, default: 0] += amount
        if enemies.items[index].hp <= 0 {
            killEnemy(index)
        }
    }

    private func killEnemy(_ index: Int) {
        let enemy = enemies.items[index]
        enemies.despawn(at: index)
        kills += 1
        events.append(.enemyKilled(position: enemy.position, typeIndex: enemy.typeIndex))
        dropEmber(at: enemy.position, value: enemy.xpValue)
    }

    private func nearestEnemy(to point: Vec2, within distance: Float) -> Int? {
        enemyGrid.nearest(to: point, maxDistance: distance) { index in
            enemies.items[index].isActive ? enemies.items[index].position : nil
        }
    }

    // MARK: - Weapons

    private func updateWeapons(dt: Float) {
        orbitals.removeAll(keepingCapacity: true)
        for index in weapons.indices {
            let weapon = content.weapons[weapons[index].weaponIndex]
            let stats = weapon.levels[weapons[index].level - 1]
            switch weapon.behavior {
            case .projectile:
                updateProjectileWeapon(at: index, stats: stats, dt: dt)
            case .orbit:
                updateOrbitWeapon(at: index, stats: stats, dt: dt)
            }
        }
    }

    private func updateProjectileWeapon(at index: Int, stats levelStats: WeaponLevelConfig, dt: Float) {
        var weapon = weapons[index]
        defer { weapons[index] = weapon }

        weapon.cooldownTimer -= dt
        guard weapon.cooldownTimer <= 0 else { return }
        guard let target = nearestEnemy(to: player.position, within: levelStats.range ?? 0) else {
            // Hold the shot until something is in range.
            weapon.cooldownTimer = 0
            return
        }

        var aim = (enemies.items[target].position - player.position).normalized()
        if aim == .zero {
            aim = player.facing
        }
        let baseAngle = atan2(aim.y, aim.x)
        let spread = (levelStats.spreadDegrees ?? 0) * .pi / 180
        let count = levelStats.count
        for shot in 0..<count {
            let offset = (Float(shot) - Float(count - 1) / 2) * spread
            var projectile = Projectile()
            projectile.weaponIndex = weapon.weaponIndex
            projectile.position = player.position
            projectile.velocity = Vec2.unit(angle: baseAngle + offset) * levelStats.speed
            projectile.radius = levelStats.area * stats.areaMultiplier
            projectile.damage = levelStats.damage * stats.damageMultiplier
            projectile.lifetime = levelStats.duration
            projectile.pierceRemaining = levelStats.pierce ?? 0
            projectile.knockback = levelStats.knockback ?? 0
            projectiles.spawn(projectile)
        }
        events.append(.weaponFired(weaponIndex: weapon.weaponIndex))
        weapon.cooldownTimer = levelStats.cooldown * stats.cooldownMultiplier
    }

    private func updateOrbitWeapon(at index: Int, stats levelStats: WeaponLevelConfig, dt: Float) {
        var weapon = weapons[index]
        if weapon.isCycleActive {
            weapon.activeRemaining -= dt
            weapon.angle = (weapon.angle + levelStats.speed * dt).truncatingRemainder(dividingBy: 2 * .pi)
            if weapon.activeRemaining <= 0 {
                weapon.isCycleActive = false
                weapon.cooldownTimer = levelStats.cooldown * stats.cooldownMultiplier
            }
        } else {
            weapon.cooldownTimer -= dt
            if weapon.cooldownTimer <= 0 {
                weapon.isCycleActive = true
                weapon.activeRemaining = levelStats.duration
                events.append(.weaponFired(weaponIndex: weapon.weaponIndex))
            }
        }
        weapons[index] = weapon
        guard weapon.isCycleActive else { return }

        let orbitRadius = levelStats.area * stats.areaMultiplier
        let bodyRadius = (levelStats.bodyRadius ?? 0) * stats.areaMultiplier
        let damage = levelStats.damage * stats.damageMultiplier
        for body in 0..<levelStats.count {
            let angle = weapon.angle + Float(body) * 2 * .pi / Float(levelStats.count)
            let center = player.position + Vec2.unit(angle: angle) * orbitRadius
            orbitals.append(Orbital(position: center, radius: bodyRadius, weaponIndex: weapon.weaponIndex))

            hitScratch.removeAll(keepingCapacity: true)
            enemyGrid.query(center: center, radius: bodyRadius + maxEnemyRadius) { candidate in
                let enemy = enemies.items[candidate]
                guard enemy.isActive, enemy.contactImmunity <= 0 else { return }
                let reach = bodyRadius + enemy.radius
                if (enemy.position - center).lengthSquared <= reach * reach {
                    hitScratch.append(candidate)
                }
            }
            for target in hitScratch where enemies.items[target].isActive {
                enemies.items[target].contactImmunity = levelStats.hitInterval ?? 0
                let push = (enemies.items[target].position - player.position).normalized()
                damageEnemy(target, amount: damage, direction: push, knockback: levelStats.knockback ?? 0, weaponIndex: weapon.weaponIndex)
            }
        }
    }

    private func updateProjectiles(dt: Float) {
        for index in 0..<projectiles.capacity where projectiles.items[index].isActive {
            var projectile = projectiles.items[index]
            projectile.position += projectile.velocity * dt
            projectile.lifetime -= dt
            guard projectile.lifetime > 0, isInsideMap(projectile.position) else {
                projectiles.despawn(at: index)
                continue
            }

            hitScratch.removeAll(keepingCapacity: true)
            enemyGrid.query(center: projectile.position, radius: projectile.radius + maxEnemyRadius) { candidate in
                let enemy = enemies.items[candidate]
                guard enemy.isActive else { return }
                let reach = projectile.radius + enemy.radius
                guard (enemy.position - projectile.position).lengthSquared <= reach * reach else { return }
                guard !projectile.hitSerials.contains(enemy.serial) else { return }
                hitScratch.append(candidate)
            }

            var isSpent = false
            let direction = projectile.velocity.normalized()
            for target in hitScratch where enemies.items[target].isActive {
                let serial = enemies.items[target].serial
                damageEnemy(target, amount: projectile.damage, direction: direction, knockback: projectile.knockback, weaponIndex: projectile.weaponIndex)
                if projectile.pierceRemaining <= 0 {
                    isSpent = true
                    break
                }
                projectile.pierceRemaining -= 1
                projectile.hitSerials.append(serial)
            }

            if isSpent {
                projectiles.despawn(at: index)
            } else {
                projectiles.items[index] = projectile
            }
        }
    }

    // MARK: - Embers & XP

    private func dropEmber(at position: Vec2, value: Float) {
        guard value > 0 else { return }
        if embers.isFull {
            // Too many on the map: fold this drop into the nearest ember instead.
            var nearest = -1
            var nearestDistance = Float.greatestFiniteMagnitude
            for index in 0..<embers.capacity where embers.items[index].isActive {
                let distance = (embers.items[index].position - position).lengthSquared
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearest = index
                }
            }
            guard nearest >= 0 else { return }
            embers.items[nearest].value += value
            embers.items[nearest].tier = emberTier(for: embers.items[nearest].value)
            return
        }
        var ember = Ember()
        ember.position = position
        ember.value = value
        ember.tier = emberTier(for: value)
        embers.spawn(ember)
    }

    func emberTier(for value: Float) -> Int {
        content.config.pickups.emberTiers.lastIndex { $0.value <= value } ?? 0
    }

    private func updateEmbers(dt: Float) {
        let pickups = config.pickups
        let pickupRadiusSquared = stats.pickupRadius * stats.pickupRadius
        let collectRadius = config.player.collectRadius

        for index in 0..<embers.capacity where embers.items[index].isActive {
            var ember = embers.items[index]
            let offset = player.position - ember.position
            let distanceSquared = offset.lengthSquared
            if !ember.isMagnetized, distanceSquared <= pickupRadiusSquared {
                ember.isMagnetized = true
                ember.speed = pickups.magnetInitialSpeed
            }
            if ember.isMagnetized {
                ember.speed = min(pickups.magnetMaxSpeed, ember.speed + pickups.magnetAcceleration * dt)
                let distance = distanceSquared.squareRoot()
                if distance <= collectRadius + ember.speed * dt {
                    embers.despawn(at: index)
                    gainXP(ember.value)
                    events.append(.emberCollected(value: ember.value))
                    continue
                }
                ember.position += offset / distance * ember.speed * dt
            }
            embers.items[index] = ember
        }
    }

    func gainXP(_ amount: Float) {
        player.xp += amount * stats.xpMultiplier
    }

    private func processLevelUps() {
        while player.xp >= xpCurve.requirement(forLevel: player.level) {
            player.xp -= xpCurve.requirement(forLevel: player.level)
            player.level += 1
            pendingLevelUps += 1
            events.append(.levelUp(newLevel: player.level))
        }
        if pendingLevelUps > 0, phase == .playing {
            upgradeChoices = UpgradeSystem.rollOptions(for: loadout, content: content, using: &rng)
            phase = .choosingUpgrade
        }
    }

    private func recomputeStats() {
        let previousMaxHP = stats.maxHP
        let passives = loadout.passives.compactMap { item in
            content.passive(id: item.id).map { (config: $0, level: item.level) }
        }
        stats = PlayerStats.compute(player: config.player, character: character.modifiers, passives: passives, rules: config.upgrades)
        if stats.maxHP > previousMaxHP {
            player.hp += stats.maxHP - previousMaxHP
        }
        player.hp = min(player.hp, stats.maxHP)
    }

    // MARK: - World geometry

    private func pushOutOfObstacles(_ position: inout Vec2, radius: Float) {
        obstacleGrid.query(center: position, radius: radius + maxObstacleRadius) { index in
            let obstacle = obstacles[index]
            let offset = position - obstacle.position
            let minDistance = radius + obstacle.radius
            let distanceSquared = offset.lengthSquared
            guard distanceSquared < minDistance * minDistance else { return }
            let direction = distanceSquared > 0 ? offset / distanceSquared.squareRoot() : Vec2(1, 0)
            position = obstacle.position + direction * minDistance
        }
    }

    private func clampToMap(_ position: Vec2, padding: Float) -> Vec2 {
        let upper = level.mapSize - padding
        return Vec2(min(max(position.x, padding), upper), min(max(position.y, padding), upper))
    }

    private func isInsideMap(_ position: Vec2) -> Bool {
        position.x >= 0 && position.y >= 0 && position.x <= level.mapSize && position.y <= level.mapSize
    }
}
