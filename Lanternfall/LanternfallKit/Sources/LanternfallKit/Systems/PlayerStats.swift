/// The player's effective stats after character modifiers and passives.
public struct PlayerStats: Equatable {
    public var maxHP: Float
    public var moveSpeed: Float
    public var armor: Float
    public var pickupRadius: Float
    public var damageMultiplier: Float
    public var areaMultiplier: Float
    public var cooldownMultiplier: Float
    public var luck: Float
    public var xpMultiplier: Float
    public var damageTakenMultiplier: Float
    public var hpRegenPerSecond: Float

    /// Passive bonuses stack additively per stat (two +10% passives = +20%),
    /// then multiply the base value.
    public static func compute(
        player: PlayerConfig,
        character: CharacterModifiers,
        passives: [(config: PassiveConfig, level: Int)],
        rules: UpgradeRulesConfig
    ) -> PlayerStats {
        var bonus: [StatKind: Float] = [:]
        for (config, level) in passives {
            bonus[config.stat, default: 0] += config.perLevel * Float(level)
        }
        func total(_ stat: StatKind) -> Float { bonus[stat] ?? 0 }

        return PlayerStats(
            maxHP: player.maxHP + character.maxHPBonus + total(.maxHP),
            moveSpeed: player.moveSpeed * character.moveSpeedMultiplier * (1 + total(.moveSpeed)),
            armor: player.armor + total(.armor),
            pickupRadius: player.pickupRadius * (1 + total(.pickupRadius)),
            damageMultiplier: character.damageMultiplier * (1 + total(.damage)),
            areaMultiplier: 1 + total(.area),
            cooldownMultiplier: max(rules.minCooldownMultiplier, 1 + total(.cooldown)),
            luck: 1 + total(.luck),
            xpMultiplier: 1,
            damageTakenMultiplier: character.damageTakenMultiplier,
            hpRegenPerSecond: character.hpRegenPerSecond
        )
    }
}
