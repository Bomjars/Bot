// Plain-data entities. The simulation owns and mutates them; the renderer
// only reads them. Kept as structs in pools (no class hierarchy).

public struct PlayerState: Equatable {
    public var position: Vec2
    /// Last non-zero movement direction (for direction-firing weapons and the lantern sprite).
    public var facing = Vec2(1, 0)
    public var hp: Float
    public var level = 1
    /// XP collected towards the next level.
    public var xp: Float = 0
    public var invulnerability: Float = 0
}

public struct Enemy: Poolable {
    public var isActive = false
    /// Unique per spawn; lets the renderer notice a reused slot.
    public var serial: UInt32 = 0
    public var typeIndex = 0
    public var position = Vec2.zero
    public var knockback = Vec2.zero
    public var hp: Float = 0
    public var maxHP: Float = 0
    public var speed: Float = 0
    public var radius: Float = 0
    public var contactDamage: Float = 0
    public var xpValue: Float = 0
    /// > 0 while the hit flash is showing.
    public var flashTimer: Float = 0
    /// > 0 while immune to orbit/aura hits.
    public var contactImmunity: Float = 0

    public init() {}
}

public struct Projectile: Poolable {
    public var isActive = false
    public var weaponIndex = 0
    public var position = Vec2.zero
    public var velocity = Vec2.zero
    public var radius: Float = 0
    public var damage: Float = 0
    public var lifetime: Float = 0
    /// Remaining extra enemies this projectile may pass through.
    public var pierceRemaining = 0
    public var knockback: Float = 0
    /// Enemies already hit (only grows for piercing projectiles).
    public var hitSerials: [UInt32] = []

    public init() {}
}

/// XP pickup ("soul" in game).
public struct Ember: Poolable {
    public var isActive = false
    public var position = Vec2.zero
    public var value: Float = 0
    /// Index into `PickupConfig.emberTiers`, derived from `value`.
    public var tier = 0
    public var isMagnetized = false
    public var speed: Float = 0

    public init() {}
}

public struct Obstacle: Equatable {
    public var position: Vec2
    public var radius: Float
    /// Index into `ObstacleFieldConfig.kinds`.
    public var kindIndex: Int
}

/// Runtime state of an owned weapon.
public struct WeaponInstance: Equatable {
    /// Index into `GameContent.weapons`.
    public var weaponIndex: Int
    public var level: Int
    public var cooldownTimer: Float = 0
    /// Orbit: current rotation.
    public var angle: Float = 0
    /// Orbit: whether the bodies are currently out.
    public var isCycleActive = false
    public var activeRemaining: Float = 0
}

/// A body of an orbit weapon, rebuilt every step for the renderer.
public struct Orbital: Equatable {
    public var position: Vec2
    public var radius: Float
    public var weaponIndex: Int
}
