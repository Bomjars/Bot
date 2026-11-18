import XCTest
@testable import LanternfallKit

final class SpatialHashGridTests: XCTestCase {
    func testQueryFindsExactlyThePointsInRange() {
        var rng = SplitMix64(seed: 11)
        let points: [Vec2?] = (0..<500).map { index in
            index % 7 == 0 ? nil : Vec2(Float.random(in: 0..<1000, using: &rng), Float.random(in: 0..<1000, using: &rng))
        }
        var grid = SpatialHashGrid(worldSize: 1000, cellSize: 64)
        grid.rebuild(count: points.count) { points[$0] }

        for _ in 0..<50 {
            let center = Vec2(Float.random(in: 0..<1000, using: &rng), Float.random(in: 0..<1000, using: &rng))
            let radius = Float.random(in: 5..<200, using: &rng)
            var found = Set<Int>()
            grid.query(center: center, radius: radius) { index in
                if let point = points[index], (point - center).length <= radius { found.insert(index) }
            }
            let expected = Set(points.indices.filter { index in
                guard let point = points[index] else { return false }
                return (point - center).length <= radius
            })
            XCTAssertEqual(found, expected)
        }
    }

    func testEachItemIsReportedOnce() {
        let points = [Vec2(10, 10), Vec2(12, 12), Vec2(500, 500)]
        var grid = SpatialHashGrid(worldSize: 1000, cellSize: 64)
        grid.rebuild(count: points.count) { points[$0] }
        var seen: [Int] = []
        grid.query(center: Vec2(250, 250), radius: 1000) { seen.append($0) }
        XCTAssertEqual(seen.sorted(), [0, 1, 2])
    }

    func testNearest() {
        let points = [Vec2(100, 100), Vec2(300, 300), Vec2(140, 100)]
        var grid = SpatialHashGrid(worldSize: 1000, cellSize: 64)
        grid.rebuild(count: points.count) { points[$0] }
        XCTAssertEqual(grid.nearest(to: Vec2(150, 100), maxDistance: 400) { points[$0] }, 2)
        XCTAssertNil(grid.nearest(to: Vec2(900, 900), maxDistance: 50) { points[$0] })
    }

    func testRebuildWithFewerItemsForgetsOldOnes() {
        var grid = SpatialHashGrid(worldSize: 1000, cellSize: 64)
        grid.rebuild(count: 3) { _ in Vec2(50, 50) }
        grid.rebuild(count: 3) { $0 == 1 ? Vec2(50, 50) : nil }
        var seen: [Int] = []
        grid.query(center: Vec2(50, 50), radius: 10) { seen.append($0) }
        XCTAssertEqual(seen, [1])
    }

    func testOutOfBoundsPointsAreClampedNotLost() {
        let points = [Vec2(-20, -20), Vec2(1200, 1200)]
        var grid = SpatialHashGrid(worldSize: 1000, cellSize: 64)
        grid.rebuild(count: points.count) { points[$0] }
        var seen: [Int] = []
        grid.query(center: Vec2(0, 0), radius: 30) { seen.append($0) }
        XCTAssertEqual(seen, [0])
    }
}
