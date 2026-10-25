/// High-level state of a run. The simulation only advances while `.playing`.
public enum RunPhase: Equatable {
    case playing
    case choosingUpgrade
    case paused
    case gameOver
    /// Survived the level timer. Phase 3 replaces this with the boss fight.
    case victory
}

/// One-shot things that happened during a step. The renderer drains these
/// every frame to drive juice (damage numbers, flashes, haptics, sound).
public enum SimEvent: Equatable {
    case enemyDamaged(position: Vec2, amount: Float)
    case enemyKilled(position: Vec2, typeIndex: Int)
    case playerDamaged(amount: Float)
    case emberCollected(value: Float)
    case levelUp(newLevel: Int)
    case weaponFired(weaponIndex: Int)
    case runEnded(victory: Bool)
}
