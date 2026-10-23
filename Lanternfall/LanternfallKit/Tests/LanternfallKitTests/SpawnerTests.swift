import XCTest
@testable import LanternfallKit

final class SpawnerTests: XCTestCase {
    private let dt: Float = 1.0 / 60.0
    private let mapSize: Float = 4000

    private func wave(start: Float, end: Float, interval: Float, group: Int, pattern: SpawnPattern = .scatter) -> WaveConfig {
        WaveConfig(enemy: "gloomling", start: start, end: end, interval: interval, groupSize: group, pattern: pattern)
    }

    /// Runs the spawner from `from` to `to` seconds and returns every request.
    private func run(_ waves: [WaveConfig], from: Float = 0, to: Float, slots: Int = .max) throws -> [SpawnRequest] {
        var spawner = Spawner(waves: waves, content: try TestContent.bundled())
        var rng = SplitMix64(seed: 99)
        var buffer: [SpawnRequest] = []
        var all: [SpawnRequest] = []
        var step = 0
        while true {
            let time = from + Float(step) * dt
            guard time < to else { break }
            spawner.update(time: time, dt: dt, center: Vec2(repeating: mapSize / 2), spawnDistance: 500,
                           mapSize: mapSize, edgePadding: 11, availableSlots: slots, using: &rng, into: &buffer)
            all += buffer
            step += 1
        }
        return all
    }

    func testNothingSpawnsBeforeWaveStarts() throws {
        XCTAssertTrue(try run([wave(start: 30, end: 60, interval: 1, group: 1)], to: 29.9).isEmpty)
    }

    func testSpawnRateMatchesIntervalAndGroupSize() throws {
        let requests = try run([wave(start: 0, end: 60, interval: 1.2, group: 2)], to: 60)
        // A group at t = 0, 1.2, ... 58.8 → 50 groups.
        XCTAssertTrue((98...102).contains(requests.count), "\(requests.count)")
    }

    func testWaveStopsAtEnd() throws {
        let inWindow = try run([wave(start: 0, end: 10, interval: 1, group: 1)], to: 10)
        let longer = try run([wave(start: 0, end: 10, interval: 1, group: 1)], to: 30)
        XCTAssertEqual(inWindow.count, longer.count)
    }

    func testSpawnsAppearAtSpawnDistance() throws {
        let center = Vec2(repeating: mapSize / 2)
        for request in try run([wave(start: 0, end: 5, interval: 0.5, group: 3)], to: 5) {
            XCTAssertEqual((request.position - center).length, 500, accuracy: 0.1)
        }
    }

    func testRingPatternIsEvenlySpaced() throws {
        let requests = try run([wave(start: 0, end: 1, interval: 10, group: 8, pattern: .ring)], to: 0.01)
        XCTAssertEqual(requests.count, 8)
        let center = Vec2(repeating: mapSize / 2)
        let first = requests[0].position - center
        let second = requests[1].position - center
        let angle = acos(min(1, (first.x * second.x + first.y * second.y) / (first.length * second.length)))
        XCTAssertEqual(angle, 2 * .pi / 8, accuracy: 1e-3)
    }

    func testRespectsAvailableSlots() throws {
        let requests = try run([wave(start: 0, end: 1, interval: 10, group: 20)], to: 0.01, slots: 5)
        XCTAssertEqual(requests.count, 5)
    }

    func testSpawnsAreClampedInsideMap() throws {
        var spawner = Spawner(waves: [wave(start: 0, end: 1, interval: 0.1, group: 10)], content: try TestContent.bundled())
        var rng = SplitMix64(seed: 5)
        var buffer: [SpawnRequest] = []
        spawner.update(time: 0, dt: dt, center: Vec2(20, 20), spawnDistance: 500, mapSize: mapSize,
                       edgePadding: 11, availableSlots: .max, using: &rng, into: &buffer)
        XCTAssertFalse(buffer.isEmpty)
        for request in buffer {
            XCTAssertTrue((11...(mapSize - 11)).contains(request.position.x))
            XCTAssertTrue((11...(mapSize - 11)).contains(request.position.y))
        }
    }

    func testShippedLevelRampsUp() throws {
        let level = try TestContent.bundled().levels[0]
        let early = try run(level.waves, from: 0, to: 60)
        let late = try run(level.waves, from: 360, to: 420)
        XCTAssertGreaterThan(late.count, early.count * 3)
    }
}
