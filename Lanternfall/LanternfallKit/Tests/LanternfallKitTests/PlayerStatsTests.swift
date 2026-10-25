import XCTest
@testable import LanternfallKit

final class PlayerStatsTests: XCTestCase {
    private func stats(_ passives: [(String, Int)], content: GameContent) -> PlayerStats {
        let resolved = passives.map { (config: content.passive(id: $0.0)!, level: $0.1) }
        return PlayerStats.compute(
            player: content.config.player,
            character: content.character(id: "wick")!.modifiers,
            passives: resolved,
            rules: content.config.upgrades
        )
    }

    func testBaseStatsMatchConfig() throws {
        let content = try TestContent.bundled()
        let base = stats([], content: content)
        XCTAssertEqual(base.maxHP, content.config.player.maxHP)
        XCTAssertEqual(base.moveSpeed, content.config.player.moveSpeed)
        XCTAssertEqual(base.damageMultiplier, 1)
        XCTAssertEqual(base.cooldownMultiplier, 1)
    }

    func testPassivesScalePerLevel() throws {
        let content = try TestContent.bundled()
        let result = stats([("holy_oil", 3), ("hearthstone", 2), ("swift_boots", 1), ("wax_seal", 4), ("moth_lure", 2)], content: content)
        XCTAssertEqual(result.damageMultiplier, 1.3, accuracy: 1e-5)
        XCTAssertEqual(result.maxHP, content.config.player.maxHP + 40, accuracy: 1e-5)
        XCTAssertEqual(result.moveSpeed, content.config.player.moveSpeed * 1.1, accuracy: 1e-4)
        XCTAssertEqual(result.armor, 4, accuracy: 1e-5)
        XCTAssertEqual(result.pickupRadius, content.config.player.pickupRadius * 1.5, accuracy: 1e-4)
    }

    func testCooldownReductionIsClamped() throws {
        let content = try TestContent.modified(config: { $0.upgrades.minCooldownMultiplier = 0.7 })
        XCTAssertEqual(stats([("copper_wire", 2)], content: content).cooldownMultiplier, 0.84, accuracy: 1e-5)
        XCTAssertEqual(stats([("copper_wire", 5)], content: content).cooldownMultiplier, 0.7, accuracy: 1e-5)
    }

    func testCharacterModifiersApply() throws {
        let content = try TestContent.bundled()
        let bolt = PlayerStats.compute(
            player: content.config.player,
            character: content.character(id: "bolt")!.modifiers,
            passives: [],
            rules: content.config.upgrades
        )
        XCTAssertEqual(bolt.moveSpeed, content.config.player.moveSpeed * 0.9, accuracy: 1e-4)
        XCTAssertEqual(bolt.damageTakenMultiplier, 0.9, accuracy: 1e-5)
    }
}
