/// Scatters non-overlapping trees and rocks over the map, keeping the spawn clear.
public enum ObstacleGenerator {
    public static func generate<R: RandomNumberGenerator>(
        field: ObstacleFieldConfig,
        mapSize: Float,
        using rng: inout R
    ) -> [Obstacle] {
        let totalWeight = field.kinds.reduce(0) { $0 + max(0, $1.weight) }
        guard field.count > 0, totalWeight > 0, field.maxRadius > 0 else { return [] }

        let center = Vec2(repeating: mapSize / 2)
        var obstacles: [Obstacle] = []
        var attempts = 0
        while obstacles.count < field.count, attempts < field.maxPlacementAttempts {
            attempts += 1
            let radius = Float.random(in: field.minRadius...field.maxRadius, using: &rng)
            let position = Vec2(
                Float.random(in: radius...(mapSize - radius), using: &rng),
                Float.random(in: radius...(mapSize - radius), using: &rng)
            )
            guard (position - center).length > field.clearRadius + radius else { continue }
            let overlaps = obstacles.contains { other in
                (other.position - position).length < other.radius + radius
            }
            guard !overlaps else { continue }
            obstacles.append(Obstacle(position: position, radius: radius, kindIndex: pickKind(field.kinds, totalWeight: totalWeight, using: &rng)))
        }
        return obstacles
    }

    private static func pickKind<R: RandomNumberGenerator>(
        _ kinds: [ObstacleKindConfig],
        totalWeight: Float,
        using rng: inout R
    ) -> Int {
        var roll = Float.random(in: 0..<totalWeight, using: &rng)
        for (index, kind) in kinds.enumerated() where kind.weight > 0 {
            if roll < kind.weight { return index }
            roll -= kind.weight
        }
        return kinds.lastIndex { $0.weight > 0 } ?? 0
    }
}
