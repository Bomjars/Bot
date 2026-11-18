import XCTest
@testable import LanternfallKit

final class UpgradeSystemTests: XCTestCase {
    func testFreshLoadoutOffersOnlyPoolItems() throws {
        let content = try TestContent.bundled()
        let pool = content.config.upgrades.pool
        let candidates = UpgradeSystem.candidates(for: Loadout(), content: content)
        XCTAssertEqual(candidates.count, pool.weapons.count + pool.passives.count)
        XCTAssertTrue(candidates.allSatisfy(\.isNew))
    }

    func testOwnedItemsOfferNextLevelInsteadOfNew() throws {
        let content = try TestContent.bundled()
        var loadout = Loadout()
        UpgradeSystem.apply(UpgradeOption(kind: .weapon, itemID: "lantern_flare", fromLevel: 0, toLevel: 1), to: &loadout)
        let candidates = UpgradeSystem.candidates(for: loadout, content: content)
        let flare = candidates.filter { $0.itemID == "lantern_flare" }
        XCTAssertEqual(flare, [UpgradeOption(kind: .weapon, itemID: "lantern_flare", fromLevel: 1, toLevel: 2)])
    }

    func testMaxedItemsAreNeverOffered() throws {
        let content = try TestContent.bundled()
        var loadout = Loadout()
        UpgradeSystem.apply(UpgradeOption(kind: .weapon, itemID: "lantern_flare", fromLevel: 4, toLevel: 5), to: &loadout)
        UpgradeSystem.apply(UpgradeOption(kind: .passive, itemID: "holy_oil", fromLevel: 4, toLevel: 5), to: &loadout)
        let ids = UpgradeSystem.candidates(for: loadout, content: content).map(\.itemID)
        XCTAssertFalse(ids.contains("lantern_flare"))
        XCTAssertFalse(ids.contains("holy_oil"))
    }

    func testFullSlotsBlockNewItems() throws {
        let content = try TestContent.modified(config: { $0.upgrades.maxWeapons = 1; $0.upgrades.maxPassives = 1 })
        var loadout = Loadout()
        UpgradeSystem.apply(UpgradeOption(kind: .weapon, itemID: "lantern_flare", fromLevel: 0, toLevel: 1), to: &loadout)
        UpgradeSystem.apply(UpgradeOption(kind: .passive, itemID: "hearthstone", fromLevel: 0, toLevel: 1), to: &loadout)
        let candidates = UpgradeSystem.candidates(for: loadout, content: content)
        XCTAssertEqual(Set(candidates.map(\.itemID)), ["lantern_flare", "hearthstone"])
        XCTAssertFalse(candidates.contains(where: \.isNew))
    }

    func testRollReturnsDistinctOptions() throws {
        let content = try TestContent.bundled()
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200 {
            let options = UpgradeSystem.rollOptions(for: Loadout(), content: content, using: &rng)
            XCTAssertEqual(options.count, content.config.upgrades.choiceCount)
            XCTAssertEqual(Set(options).count, options.count)
        }
    }

    func testRollFallsBackToHealWhenEverythingIsMaxed() throws {
        let content = try TestContent.bundled()
        var loadout = Loadout()
        for id in content.config.upgrades.pool.weapons {
            UpgradeSystem.apply(UpgradeOption(kind: .weapon, itemID: id, fromLevel: 0, toLevel: content.weapon(id: id)!.maxLevel), to: &loadout)
        }
        for id in content.config.upgrades.pool.passives {
            UpgradeSystem.apply(UpgradeOption(kind: .passive, itemID: id, fromLevel: 0, toLevel: content.passive(id: id)!.maxLevel), to: &loadout)
        }
        var rng = SplitMix64(seed: 1)
        XCTAssertEqual(UpgradeSystem.rollOptions(for: loadout, content: content, using: &rng), [.heal])
    }

    func testFewerCandidatesThanChoicesReturnsAllOfThem() throws {
        let content = try TestContent.modified(config: { $0.upgrades.pool = UpgradePool(weapons: ["lantern_flare"], passives: []) })
        var rng = SplitMix64(seed: 3)
        let options = UpgradeSystem.rollOptions(for: Loadout(), content: content, using: &rng)
        XCTAssertEqual(options.map(\.itemID), ["lantern_flare"])
    }
}
