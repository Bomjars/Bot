import XCTest
@testable import LanternfallKit

final class XPCurveTests: XCTestCase {
    private let curve = XPCurve(config: XPCurveConfig(
        firstLevelRequirement: 5,
        brackets: [XPBracket(fromLevel: 1, increment: 10), XPBracket(fromLevel: 20, increment: 13)]
    ))

    func testFirstLevels() {
        XCTAssertEqual(curve.requirement(forLevel: 1), 5)
        XCTAssertEqual(curve.requirement(forLevel: 2), 15)
        XCTAssertEqual(curve.requirement(forLevel: 3), 25)
    }

    func testBracketChangesIncrement() {
        XCTAssertEqual(curve.requirement(forLevel: 20), 195)
        XCTAssertEqual(curve.requirement(forLevel: 21), 208)
        XCTAssertEqual(curve.requirement(forLevel: 22), 221)
    }

    func testTotalXP() {
        XCTAssertEqual(curve.totalXP(toReach: 1), 0)
        XCTAssertEqual(curve.totalXP(toReach: 2), 5)
        XCTAssertEqual(curve.totalXP(toReach: 4), 5 + 15 + 25)
    }

    func testRequirementsNeverDecrease() throws {
        let shipped = XPCurve(config: try TestContent.bundled().config.xp)
        for level in 1..<100 {
            XCTAssertLessThan(shipped.requirement(forLevel: level), shipped.requirement(forLevel: level + 1))
        }
    }
}
