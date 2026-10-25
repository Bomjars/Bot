/// Uniform grid over the square map, rebuilt each step with a counting sort.
/// Used instead of SpriteKit physics for 300+ enemies: rebuild is O(n),
/// a radius query only touches the cells it overlaps, and nothing allocates
/// once the buffers have grown.
public struct SpatialHashGrid {
    public let cellSize: Float
    public let columns: Int

    /// `cellStart[c]..<cellStart[c + 1]` indexes `items` for cell `c`.
    private var cellStart: [Int]
    private var cursor: [Int]
    private var items: [Int] = []
    private var itemCell: [Int] = []

    public init(worldSize: Float, cellSize: Float) {
        self.cellSize = cellSize
        columns = max(1, Int((worldSize / cellSize).rounded(.up)))
        cellStart = Array(repeating: 0, count: columns * columns + 1)
        cursor = cellStart
    }

    /// Re-buckets indices `0..<count`; `position` returns nil for inactive slots.
    public mutating func rebuild(count: Int, position: (Int) -> Vec2?) {
        if itemCell.count < count {
            itemCell = Array(repeating: -1, count: count)
        }
        for cell in cellStart.indices {
            cellStart[cell] = 0
        }

        var total = 0
        for index in 0..<count {
            guard let point = position(index) else {
                itemCell[index] = -1
                continue
            }
            let cell = cellIndex(point)
            itemCell[index] = cell
            cellStart[cell + 1] += 1
            total += 1
        }

        for cell in 0..<(cellStart.count - 1) {
            cellStart[cell + 1] += cellStart[cell]
        }
        for cell in cellStart.indices {
            cursor[cell] = cellStart[cell]
        }
        if items.count < total {
            items = Array(repeating: 0, count: total)
        }
        for index in 0..<count {
            let cell = itemCell[index]
            guard cell >= 0 else { continue }
            items[cursor[cell]] = index
            cursor[cell] += 1
        }
    }

    /// Calls `body` for every index in cells overlapping the square around
    /// `center`. Callers do the exact distance test.
    public func query(center: Vec2, radius: Float, _ body: (Int) -> Void) {
        let minX = coordinate(center.x - radius)
        let maxX = coordinate(center.x + radius)
        let minY = coordinate(center.y - radius)
        let maxY = coordinate(center.y + radius)
        for row in minY...maxY {
            for column in minX...maxX {
                let cell = row * columns + column
                for slot in cellStart[cell]..<cellStart[cell + 1] {
                    body(items[slot])
                }
            }
        }
    }

    /// Index of the closest point within `maxDistance`, or nil.
    public func nearest(to point: Vec2, maxDistance: Float, position: (Int) -> Vec2?) -> Int? {
        var best: Int?
        var bestDistanceSquared = maxDistance * maxDistance
        query(center: point, radius: maxDistance) { index in
            guard let candidate = position(index) else { return }
            let distanceSquared = (candidate - point).lengthSquared
            if distanceSquared <= bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                best = index
            }
        }
        return best
    }

    private func coordinate(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return min(max(Int(value / cellSize), 0), columns - 1)
    }

    private func cellIndex(_ point: Vec2) -> Int {
        coordinate(point.y) * columns + coordinate(point.x)
    }
}
