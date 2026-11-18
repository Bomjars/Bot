import XCTest
@testable import LanternfallKit

final class FixedTimestepClockTests: XCTestCase {
    func testFirstFrameOnlyRecordsTime() {
        var clock = FixedTimestepClock(stepDuration: 1.0 / 60, maxSteps: 5, snapTolerance: 0.05)
        XCTAssertEqual(clock.advance(to: 100), 0)
    }

    func testSixtyHertzFramesGiveOneStepEach() {
        var clock = FixedTimestepClock(stepDuration: 1.0 / 60, maxSteps: 5, snapTolerance: 0.05)
        _ = clock.advance(to: 10)
        var total = 0
        for frame in 1...600 {
            let steps = clock.advance(to: 10 + Double(frame) / 60)
            XCTAssertEqual(steps, 1)
            total += steps
        }
        XCTAssertEqual(total, 600)
    }

    func testOneHundredTwentyHertzAlternates() {
        var clock = FixedTimestepClock(stepDuration: 1.0 / 60, maxSteps: 5, snapTolerance: 0.05)
        _ = clock.advance(to: 0)
        var total = 0
        for frame in 1...120 {
            total += clock.advance(to: Double(frame) / 120)
        }
        XCTAssertEqual(total, 60)
    }

    func testLongHitchIsCapped() {
        var clock = FixedTimestepClock(stepDuration: 1.0 / 60, maxSteps: 5, snapTolerance: 0.05)
        _ = clock.advance(to: 0)
        XCTAssertEqual(clock.advance(to: 2), 5)
        XCTAssertEqual(clock.advance(to: 2 + 1.0 / 60), 1)
    }

    func testResetForgetsLastTime() {
        var clock = FixedTimestepClock(stepDuration: 1.0 / 60, maxSteps: 5, snapTolerance: 0.05)
        _ = clock.advance(to: 0)
        clock.reset()
        XCTAssertEqual(clock.advance(to: 50), 0)
    }
}
