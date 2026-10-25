import XCTest
@testable import LanternfallKit

final class ContentTests: XCTestCase {
    func testBundledContentLoads() throws {
        let content = try TestContent.bundled()
        XCTAssertEqual(content.levels.first?.id, "hollow_woods")
        XCTAssertNotNil(content.weapon(id: "lantern_flare"))
        XCTAssertNotNil(content.enemyIndex(id: "gloomling"))
        XCTAssertEqual(content.passives.count, 8)
        XCTAssertEqual(content.character(id: "wick")?.playable, true)
        XCTAssertEqual(content.characters.filter { !$0.playable }.map(\.id), ["bolt", "moss", "rook"])
    }

    func testEveryWeaponHasFiveLevels() throws {
        for weapon in try TestContent.bundled().weapons {
            XCTAssertEqual(weapon.maxLevel, 5, weapon.id)
        }
    }

    func testRejectsWaveWithUnknownEnemy() throws {
        XCTAssertThrowsError(try TestContent.modified(level: { $0.waves[0].enemy = "nope" })) { error in
            XCTAssertTrue("\(error)".contains("unknown enemy 'nope'"))
        }
    }

    func testRejectsUnknownPoolItem() throws {
        XCTAssertThrowsError(try TestContent.modified(config: { $0.upgrades.pool.passives.append("ghost") }))
    }
}
