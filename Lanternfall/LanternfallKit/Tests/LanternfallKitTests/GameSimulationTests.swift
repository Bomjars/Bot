import XCTest
@testable import LanternfallKit

final class GameSimulationTests: XCTestCase {
    private let dt: Float = 1.0 / 60.0

    /// Content with no spawns, so tests control every enemy.
    private func quietContent() throws -> GameContent {
        try TestContent.modified(level: { $0.waves = []; $0.obstacles.count = 0 })
    }

    private func steps(_ sim: GameSimulation, seconds: Float) {
        for _ in 0..<Int(seconds / dt) {
            sim.step(dt: dt)
        }
    }

    func testStartsWithCharacterWeapon() throws {
        let sim = try TestContent.simulation(try TestContent.bundled())
        XCTAssertEqual(sim.loadout.weapons, [OwnedItem(id: "lantern_flare", level: 1)])
        XCTAssertEqual(sim.weapons.count, 1)
        XCTAssertEqual(sim.player.hp, sim.stats.maxHP)
        XCTAssertEqual(sim.phase, .playing)
    }

    func testObstaclesKeepSpawnClearAndDontOverlap() throws {
        let sim = try TestContent.simulation(try TestContent.bundled())
        let field = sim.level.obstacles
        XCTAssertGreaterThan(sim.obstacles.count, field.count / 2)
        for (index, obstacle) in sim.obstacles.enumerated() {
            XCTAssertGreaterThan((obstacle.position - sim.player.position).length, field.clearRadius)
            for other in sim.obstacles[(index + 1)...] {
                XCTAssertGreaterThanOrEqual((other.position - obstacle.position).length, other.radius + obstacle.radius)
            }
        }
    }

    func testPlayerMovesWithInputAndStaysInMap() throws {
        let sim = try TestContent.simulation(try quietContent())
        let start = sim.player.position
        sim.moveInput = Vec2(1, 0)
        steps(sim, seconds: 1)
        XCTAssertEqual(sim.player.position.x - start.x, sim.stats.moveSpeed, accuracy: 3)

        sim.player.position = Vec2(5, 5)
        sim.moveInput = Vec2(-1, -1)
        sim.step(dt: dt)
        XCTAssertGreaterThanOrEqual(sim.player.position.x, sim.content.config.player.radius)
        XCTAssertGreaterThanOrEqual(sim.player.position.y, sim.content.config.player.radius)
    }

    func testEnemiesChaseThePlayer() throws {
        let sim = try TestContent.simulation(try quietContent())
        let index = try XCTUnwrap(sim.spawnEnemy(typeIndex: 0, at: sim.player.position + Vec2(0, 1000)))
        let before = (sim.enemies.items[index].position - sim.player.position).length
        steps(sim, seconds: 1)
        let after = (sim.enemies.items[index].position - sim.player.position).length
        XCTAssertEqual(before - after, sim.content.enemies[0].moveSpeed, accuracy: 2)
    }

    func testLanternFlareKillsEnemyAndDropsEmber() throws {
        let sim = try TestContent.simulation(try quietContent())
        sim.spawnEnemy(typeIndex: 0, at: sim.player.position + Vec2(200, 0))
        steps(sim, seconds: 3)
        XCTAssertEqual(sim.kills, 1)
        XCTAssertEqual(sim.enemies.activeCount, 0)
        XCTAssertGreaterThan(sim.damageByWeapon["lantern_flare"] ?? 0, 0)
        var killed = false
        sim.drainEvents { if case .enemyKilled = $0 { killed = true } }
        XCTAssertTrue(killed)
        XCTAssertEqual(sim.embers.activeCount + (sim.player.xp > 0 ? 1 : 0), 1)
    }

    func testEmbersInsideGlowAreCollected() throws {
        let sim = try TestContent.simulation(try quietContent())
        sim.spawnEnemy(typeIndex: 0, at: sim.player.position + Vec2(40, 0))
        steps(sim, seconds: 2)
        XCTAssertEqual(sim.kills, 1)
        XCTAssertEqual(sim.embers.activeCount, 0)
        XCTAssertEqual(sim.player.xp, sim.content.enemies[0].xpValue)
    }

    func testEmbersOutsideGlowStay() throws {
        let sim = try TestContent.simulation(try quietContent())
        sim.spawnEnemy(typeIndex: 0, at: sim.player.position + Vec2(300, 0))
        steps(sim, seconds: 3)
        XCTAssertEqual(sim.kills, 1)
        XCTAssertEqual(sim.embers.activeCount, 1)
        XCTAssertEqual(sim.player.xp, 0)
    }

    func testLevelUpPausesAndChoiceResumes() throws {
        let sim = try TestContent.simulation(try quietContent())
        sim.gainXP(sim.xpRequiredForNextLevel)
        sim.step(dt: dt)
        XCTAssertEqual(sim.phase, .choosingUpgrade)
        XCTAssertEqual(sim.player.level, 2)
        XCTAssertEqual(sim.upgradeChoices.count, sim.content.config.upgrades.choiceCount)

        let frozenTime = sim.time
        steps(sim, seconds: 1)
        XCTAssertEqual(sim.time, frozenTime, "simulation must not advance while choosing")

        let choice = sim.upgradeChoices[0]
        XCTAssertTrue(sim.chooseUpgrade(choice))
        XCTAssertEqual(sim.phase, .playing)
        XCTAssertTrue(sim.upgradeChoices.isEmpty)
        let owned = choice.kind == .weapon ? sim.loadout.weaponLevel(choice.itemID) : sim.loadout.passiveLevel(choice.itemID)
        XCTAssertEqual(owned, choice.toLevel)
    }

    func testMultipleLevelUpsQueueChoices() throws {
        let sim = try TestContent.simulation(try quietContent())
        let curve = XPCurve(config: sim.content.config.xp)
        sim.gainXP(curve.totalXP(toReach: 4))
        sim.step(dt: dt)
        XCTAssertEqual(sim.player.level, 4)
        XCTAssertEqual(sim.pendingLevelUps, 3)
        for remaining in (0..<3).reversed() {
            XCTAssertTrue(sim.chooseUpgrade(sim.upgradeChoices[0]))
            XCTAssertEqual(sim.pendingLevelUps, remaining)
        }
        XCTAssertEqual(sim.phase, .playing)
    }

    func testRejectsChoiceNotOnOffer() throws {
        let sim = try TestContent.simulation(try quietContent())
        XCTAssertFalse(sim.chooseUpgrade(UpgradeOption(kind: .passive, itemID: "holy_oil", fromLevel: 0, toLevel: 1)))
    }

    func testNewWeaponFromUpgradeStartsFiring() throws {
        let sim = try TestContent.simulation(try TestContent.modified(
            config: { $0.upgrades.pool = UpgradePool(weapons: ["halo_shards"], passives: []) },
            level: { $0.waves = [] }
        ))
        sim.gainXP(sim.xpRequiredForNextLevel)
        sim.step(dt: dt)
        let orbit = try XCTUnwrap(sim.upgradeChoices.first { $0.itemID == "halo_shards" })
        sim.chooseUpgrade(orbit)
        steps(sim, seconds: 0.5)
        XCTAssertEqual(sim.weapons.count, 2)
        XCTAssertEqual(sim.orbitals.count, sim.content.weapon(id: "halo_shards")!.levels[0].count)
    }

    func testHearthstoneRaisesMaxAndCurrentHP() throws {
        let sim = try TestContent.simulation(try TestContent.modified(
            config: { $0.upgrades.pool = UpgradePool(weapons: [], passives: ["hearthstone"]) },
            level: { $0.waves = [] }
        ))
        let before = sim.player.hp
        sim.gainXP(sim.xpRequiredForNextLevel)
        sim.step(dt: dt)
        let hearthstone = try XCTUnwrap(sim.upgradeChoices.first { $0.itemID == "hearthstone" })
        sim.chooseUpgrade(hearthstone)
        XCTAssertEqual(sim.stats.maxHP, sim.content.config.player.maxHP + 20)
        XCTAssertEqual(sim.player.hp, before + 20)
    }

    func testContactDamageUsesInvulnerabilityAndEndsRun() throws {
        let sim = try TestContent.simulation(try quietContent())
        sim.player.hp = 10
        let enemyIndex = try XCTUnwrap(sim.spawnEnemy(typeIndex: 0, at: sim.player.position))
        sim.enemies.items[enemyIndex].hp = 1_000_000
        sim.step(dt: dt)
        let damage = sim.content.enemies[0].contactDamage
        XCTAssertEqual(sim.player.hp, 10 - damage, accuracy: 1e-4)
        sim.step(dt: dt)
        XCTAssertEqual(sim.player.hp, 10 - damage, accuracy: 1e-4, "invulnerability window")
        steps(sim, seconds: 2)
        XCTAssertEqual(sim.phase, .gameOver)
        XCTAssertEqual(sim.player.hp, 0)
    }

    func testPauseFreezesSimulation() throws {
        let sim = try TestContent.simulation(try TestContent.bundled())
        steps(sim, seconds: 1)
        sim.setPaused(true)
        let time = sim.time
        steps(sim, seconds: 1)
        XCTAssertEqual(sim.time, time)
        sim.setPaused(false)
        sim.step(dt: dt)
        XCTAssertGreaterThan(sim.time, time)
    }

    func testSurvivingTheTimerWins() throws {
        let sim = try TestContent.simulation(try TestContent.modified(level: { $0.duration = 2; $0.waves = [] }))
        steps(sim, seconds: 2.5)
        XCTAssertEqual(sim.phase, .victory)
    }

    func testEmberMergingWhenPoolIsFull() throws {
        let sim = try TestContent.simulation(try TestContent.modified(
            config: { $0.pickups.maxActiveEmbers = 2 },
            level: { $0.waves = [] }
        ))
        // Far from the player so nothing is collected; flare range is too short to reach.
        for offset in [Float(800), 820, 840] {
            let index = try XCTUnwrap(sim.spawnEnemy(typeIndex: 0, at: sim.player.position + Vec2(offset, 0)))
            sim.enemies.items[index].hp = 0.1
        }
        sim.player.position += Vec2(400, 0) // bring them into flare range
        steps(sim, seconds: 3)
        XCTAssertEqual(sim.kills, 3)
        XCTAssertEqual(sim.embers.activeCount, 2)
        let total = sim.embers.items.filter(\.isActive).reduce(Float(0)) { $0 + $1.value }
        XCTAssertEqual(total + sim.player.xp, 3)
    }

    func testEmberTierFollowsValue() throws {
        let sim = try TestContent.simulation(try quietContent())
        XCTAssertEqual(sim.emberTier(for: 1), 0)
        XCTAssertEqual(sim.emberTier(for: 4), 0)
        XCTAssertEqual(sim.emberTier(for: 5), 1)
        XCTAssertEqual(sim.emberTier(for: 30), 2)
    }

    func testFullLevelSoakRespectsEnemyCap() throws {
        let sim = try TestContent.simulation(try TestContent.bundled(), seed: 2024)
        var peak = 0
        // A greedy bot: walk to the nearest ember, always take the first upgrade,
        // and stay topped up so the run reaches the end.
        while sim.phase != .victory, sim.time <= sim.level.duration {
            let target = sim.embers.items.filter(\.isActive).min {
                ($0.position - sim.player.position).lengthSquared < ($1.position - sim.player.position).lengthSquared
            }
            sim.moveInput = target.map { ($0.position - sim.player.position).normalized() } ?? .zero
            if sim.phase == .choosingUpgrade {
                sim.chooseUpgrade(sim.upgradeChoices[0])
            }
            sim.player.hp = sim.stats.maxHP
            sim.step(dt: dt)
            sim.drainEvents { _ in }
            peak = max(peak, sim.enemies.activeCount)
        }
        XCTAssertEqual(sim.phase, .victory)
        XCTAssertLessThanOrEqual(peak, sim.level.enemyCap)
        XCTAssertGreaterThan(sim.kills, 500)
        XCTAssertGreaterThan(sim.player.level, 10)
    }
}
