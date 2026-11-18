// Codable models for everything in Data/Content/*.json.
// Every tunable number in the game lives in those files, not in code.

// MARK: - game.json

public struct GameConfig: Codable, Equatable {
    public var startup: StartupConfig
    public var simulation: SimulationConfig
    public var player: PlayerConfig
    public var xp: XPCurveConfig
    public var upgrades: UpgradeRulesConfig
    public var pickups: PickupConfig
    public var joystick: JoystickConfig
    public var camera: CameraConfig
    public var juice: JuiceConfig
    public var render: RenderConfig
    public var palette: PaletteConfig
}

public struct StartupConfig: Codable, Equatable {
    public var levelID: String
    public var characterID: String
}

public struct SimulationConfig: Codable, Equatable {
    /// Seconds per simulation step (1/60).
    public var fixedTimestep: Double
    /// Upper bound on catch-up steps after a slow frame.
    public var maxStepsPerFrame: Int
    /// Fraction of a step that may be "borrowed" so 60 Hz displays don't jitter between 0 and 2 steps.
    public var timestepSnapTolerance: Double
    public var spatialCellSize: Float
    public var maxProjectiles: Int
    /// How quickly overlapping enemies are pushed apart (fraction of overlap resolved per second).
    public var separationStrength: Float
    public var maxSeparationNeighbors: Int
    /// Extra distance beyond the screen's half-diagonal at which enemies spawn.
    public var spawnMargin: Float
    public var knockbackDamping: Float
    public var minContactDamage: Float
}

public struct PlayerConfig: Codable, Equatable {
    public var maxHP: Float
    public var moveSpeed: Float
    public var radius: Float
    public var armor: Float
    /// Lantern glow radius: souls inside it fly to the player.
    public var pickupRadius: Float
    /// Distance at which a magnetised soul is absorbed.
    public var collectRadius: Float
    public var invulnerabilityTime: Float
}

public struct XPCurveConfig: Codable, Equatable {
    /// XP needed to go from level 1 to level 2.
    public var firstLevelRequirement: Float
    /// Each level's requirement grows by the increment of the bracket it falls in.
    public var brackets: [XPBracket]
}

public struct XPBracket: Codable, Equatable {
    public var fromLevel: Int
    public var increment: Float
}

public struct UpgradeRulesConfig: Codable, Equatable {
    public var choiceCount: Int
    public var maxWeapons: Int
    public var maxPassives: Int
    /// Relative weight of "new item" options vs. "level up an owned item" options.
    public var newItemWeight: Float
    public var levelUpWeight: Float
    /// Offered when every item is maxed out.
    public var fallbackHealAmount: Float
    public var minCooldownMultiplier: Float
    /// Which items may appear as level-up choices in this build.
    public var pool: UpgradePool
}

public struct UpgradePool: Codable, Equatable {
    public var weapons: [String]
    public var passives: [String]
}

public struct PickupConfig: Codable, Equatable {
    /// Visual tiers, ascending by value (small 1 / medium 5 / large 25).
    public var emberTiers: [EmberTierConfig]
    /// When this many souls are on the map, new drops merge into the nearest one.
    public var maxActiveEmbers: Int
    public var magnetInitialSpeed: Float
    public var magnetAcceleration: Float
    public var magnetMaxSpeed: Float
}

public struct EmberTierConfig: Codable, Equatable {
    public var name: String
    public var value: Float
    public var radius: Float
    public var color: String
}

public struct JoystickConfig: Codable, Equatable {
    public var radius: Float
    public var knobRadius: Float
    /// Normalised input below this magnitude is ignored.
    public var deadZone: Float
    /// Joystick can start anywhere in the bottom fraction of the screen.
    public var activeAreaFraction: Float
}

public struct CameraConfig: Codable, Equatable {
    /// Exponential follow rate (higher = snappier).
    public var followSharpness: Float
}

public struct JuiceConfig: Codable, Equatable {
    public var hitFlashDuration: Float
    public var playerHurtFlashDuration: Float
    public var damageNumberLifetime: Float
    public var damageNumberRise: Float
    public var damageNumberPoolSize: Int
    public var damageNumberFontSize: Float
}

public struct RenderConfig: Codable, Equatable {
    /// On-screen size of the player sprite (art is 32×32).
    public var characterSpriteSize: Float
    /// Enemy sprites are drawn at hit-circle diameter × this.
    public var enemySpriteScale: Float
    public var groundTileSize: Float
    public var groundDetailCount: Int
    public var placeholderTextureSize: Float
    public var pickupGlowAlpha: Float
    public var projectileGlowScale: Float
    public var mapBorderWidth: Float
    public var healthBarWidth: Float
    public var healthBarHeight: Float
    public var healthBarOffset: Float
}

public struct PaletteConfig: Codable, Equatable {
    public var background: String
    public var backgroundAlt: String
    /// Lava-crack specks on the ground tiles.
    public var groundDetail: String
    public var light: String
    public var lightSoft: String
    public var enemyShadow: String
    public var danger: String
    public var playerCloak: String
    public var playerScarf: String
    public var text: String
}

// MARK: - enemies.json

public struct EnemyConfig: Codable, Equatable {
    public var id: String
    public var name: String
    public var maxHP: Float
    public var moveSpeed: Float
    public var contactDamage: Float
    public var radius: Float
    public var xpValue: Float
    public var color: String
    /// Base sprite name, e.g. "enemy_imp" → frames "enemy_imp_walk_0...3".
    public var spriteName: String
}

// MARK: - weapons.json

public enum WeaponBehavior: String, Codable, Equatable {
    /// Fires `count` bolts at the nearest enemy every `cooldown`.
    case projectile
    /// `count` bodies circle the player for `duration`, then rest for `cooldown`.
    case orbit
}

public struct WeaponConfig: Codable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var behavior: WeaponBehavior
    public var color: String
    public var spriteName: String
    /// One entry per level; `levels.count` is the max level.
    public var levels: [WeaponLevelConfig]

    public var maxLevel: Int { levels.count }
}

/// Stats for one weapon level. Shared fields mean different things per behaviour:
/// - projectile: `area` = bolt radius, `duration` = bolt lifetime, `speed` = points/s
/// - orbit: `area` = orbit radius, `duration` = active time, `speed` = radians/s
public struct WeaponLevelConfig: Codable, Equatable {
    public var damage: Float
    public var cooldown: Float
    public var count: Int
    public var area: Float
    public var duration: Float
    public var speed: Float
    public var description: String
    public var pierce: Int?
    public var range: Float?
    public var spreadDegrees: Float?
    public var knockback: Float?
    /// Orbit: how long an enemy is immune after being hit.
    public var hitInterval: Float?
    /// Orbit: radius of each orbiting body.
    public var bodyRadius: Float?
}

// MARK: - passives.json

public enum StatKind: String, Codable, Equatable, CaseIterable {
    case damage, area, cooldown, armor, maxHP, moveSpeed, pickupRadius, luck
}

public struct PassiveConfig: Codable, Equatable {
    public var id: String
    public var name: String
    public var stat: StatKind
    /// Per level. Fractions for multipliers (0.1 = +10%), flat for armor/maxHP.
    public var perLevel: Float
    public var maxLevel: Int
    public var description: String
    public var color: String
    public var spriteName: String
}

// MARK: - characters.json

public struct CharacterConfig: Codable, Equatable {
    public var id: String
    public var name: String
    public var title: String
    public var description: String
    public var startingWeapon: String
    public var playable: Bool
    public var color: String
    public var modifiers: CharacterModifiers
}

public struct CharacterModifiers: Codable, Equatable {
    public var maxHPBonus: Float
    public var damageMultiplier: Float
    public var moveSpeedMultiplier: Float
    public var damageTakenMultiplier: Float
    public var hpRegenPerSecond: Float
    /// Not used until crits land in a later phase.
    public var critChance: Float
}

// MARK: - levels/*.json

public struct LevelConfig: Codable, Equatable {
    public var id: String
    public var name: String
    public var order: Int
    /// Seconds to survive.
    public var duration: Float
    /// The map is a square of this many points per side.
    public var mapSize: Float
    public var enemyCap: Int
    public var obstacles: ObstacleFieldConfig
    public var waves: [WaveConfig]
}

public struct ObstacleFieldConfig: Codable, Equatable {
    public var count: Int
    public var minRadius: Float
    public var maxRadius: Float
    /// No obstacles within this distance of the player's spawn point.
    public var clearRadius: Float
    public var maxPlacementAttempts: Int
    public var kinds: [ObstacleKindConfig]
}

public struct ObstacleKindConfig: Codable, Equatable {
    public var id: String
    public var weight: Float
    public var color: String
}

public enum SpawnPattern: String, Codable, Equatable {
    /// Each enemy at a random angle around the player.
    case scatter
    /// The whole group evenly spaced on a ring that closes in.
    case ring
}

public struct WaveConfig: Codable, Equatable {
    public var enemy: String
    /// Active while start <= time < end (seconds).
    public var start: Float
    public var end: Float
    public var interval: Float
    public var groupSize: Int
    public var pattern: SpawnPattern
}
