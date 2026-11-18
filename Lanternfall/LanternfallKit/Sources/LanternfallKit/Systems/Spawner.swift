public struct SpawnRequest: Equatable {
    public let enemyIndex: Int
    public let position: Vec2
}

/// Turns the level's wave timeline into spawn requests just off-screen.
public struct Spawner {
    private struct Entry {
        let wave: WaveConfig
        let enemyIndex: Int
    }

    private let entries: [Entry]
    private var timers: [Float]

    /// Waves whose enemy id isn't in `content` are skipped (content validation rejects them anyway).
    public init(waves: [WaveConfig], content: GameContent) {
        entries = waves.compactMap { wave in
            content.enemyIndex(id: wave.enemy).map { Entry(wave: wave, enemyIndex: $0) }
        }
        timers = Array(repeating: 0, count: entries.count)
    }

    /// Advances wave timers for the step starting at `time` and appends spawns to `requests`.
    /// - Parameters:
    ///   - spawnDistance: distance from `center` at which enemies appear.
    ///   - availableSlots: free enemy slots; extra spawns are dropped (the cap).
    ///   - edgePadding: keeps spawns this far inside the map edges.
    public mutating func update<R: RandomNumberGenerator>(
        time: Float,
        dt: Float,
        center: Vec2,
        spawnDistance: Float,
        mapSize: Float,
        edgePadding: Float,
        availableSlots: Int,
        using rng: inout R,
        into requests: inout [SpawnRequest]
    ) {
        requests.removeAll(keepingCapacity: true)
        for index in entries.indices {
            let entry = entries[index]
            let wave = entry.wave
            guard time >= wave.start, time < wave.end else { continue }

            timers[index] -= dt
            while timers[index] <= 0 {
                timers[index] += wave.interval
                let baseAngle = Float.random(in: 0..<(2 * .pi), using: &rng)
                for member in 0..<wave.groupSize where requests.count < availableSlots {
                    let angle: Float
                    switch wave.pattern {
                    case .scatter:
                        angle = Float.random(in: 0..<(2 * .pi), using: &rng)
                    case .ring:
                        angle = baseAngle + Float(member) * 2 * .pi / Float(wave.groupSize)
                    }
                    var position = center + Vec2.unit(angle: angle) * spawnDistance
                    position.x = min(max(position.x, edgePadding), mapSize - edgePadding)
                    position.y = min(max(position.y, edgePadding), mapSize - edgePadding)
                    requests.append(SpawnRequest(enemyIndex: entry.enemyIndex, position: position))
                }
            }
        }
    }
}
