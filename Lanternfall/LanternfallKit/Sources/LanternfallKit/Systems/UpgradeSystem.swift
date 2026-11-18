public struct OwnedItem: Equatable, Hashable {
    public let id: String
    public internal(set) var level: Int
}

/// Weapons and passives the player owns this run, in pickup order.
public struct Loadout: Equatable {
    public internal(set) var weapons: [OwnedItem] = []
    public internal(set) var passives: [OwnedItem] = []

    public init() {}

    public func weaponLevel(_ id: String) -> Int { weapons.first { $0.id == id }?.level ?? 0 }
    public func passiveLevel(_ id: String) -> Int { passives.first { $0.id == id }?.level ?? 0 }
}

/// One card on the level-up screen.
public struct UpgradeOption: Equatable, Hashable, Identifiable {
    public enum Kind: String, Equatable, Hashable {
        case weapon, passive, heal
    }

    public let kind: Kind
    public let itemID: String
    /// 0 when the item is new.
    public let fromLevel: Int
    public let toLevel: Int

    public var id: String { "\(kind.rawValue):\(itemID)" }
    public var isNew: Bool { fromLevel == 0 && kind != .heal }

    public static let heal = UpgradeOption(kind: .heal, itemID: "heal", fromLevel: 0, toLevel: 0)
}

public enum UpgradeSystem {
    /// Every option currently valid: level-ups for owned items that aren't maxed,
    /// plus new items from the pool while slots are free.
    public static func candidates(for loadout: Loadout, content: GameContent) -> [UpgradeOption] {
        let rules = content.config.upgrades
        var result: [UpgradeOption] = []

        for item in loadout.weapons {
            if let weapon = content.weapon(id: item.id), item.level < weapon.maxLevel {
                result.append(UpgradeOption(kind: .weapon, itemID: item.id, fromLevel: item.level, toLevel: item.level + 1))
            }
        }
        if loadout.weapons.count < rules.maxWeapons {
            for id in rules.pool.weapons where loadout.weaponLevel(id) == 0 {
                result.append(UpgradeOption(kind: .weapon, itemID: id, fromLevel: 0, toLevel: 1))
            }
        }
        for item in loadout.passives {
            if let passive = content.passive(id: item.id), item.level < passive.maxLevel {
                result.append(UpgradeOption(kind: .passive, itemID: item.id, fromLevel: item.level, toLevel: item.level + 1))
            }
        }
        if loadout.passives.count < rules.maxPassives {
            for id in rules.pool.passives where loadout.passiveLevel(id) == 0 {
                result.append(UpgradeOption(kind: .passive, itemID: id, fromLevel: 0, toLevel: 1))
            }
        }
        return result
    }

    /// Picks up to `choiceCount` distinct options by weighted random draw.
    /// Falls back to a single heal when nothing is left to upgrade.
    public static func rollOptions<R: RandomNumberGenerator>(
        for loadout: Loadout,
        content: GameContent,
        using rng: inout R
    ) -> [UpgradeOption] {
        let rules = content.config.upgrades
        var pool = candidates(for: loadout, content: content)
        guard !pool.isEmpty else { return [.heal] }

        var picked: [UpgradeOption] = []
        while picked.count < rules.choiceCount, !pool.isEmpty {
            let weights = pool.map { $0.isNew ? rules.newItemWeight : rules.levelUpWeight }
            let total = weights.reduce(0, +)
            var index = pool.count - 1
            if total > 0 {
                var roll = Float.random(in: 0..<total, using: &rng)
                for (candidate, weight) in weights.enumerated() {
                    if roll < weight {
                        index = candidate
                        break
                    }
                    roll -= weight
                }
            } else {
                index = Int.random(in: 0..<pool.count, using: &rng)
            }
            picked.append(pool.remove(at: index))
        }
        return picked
    }

    /// Applies a weapon/passive option to the loadout. Heal options don't change it.
    public static func apply(_ option: UpgradeOption, to loadout: inout Loadout) {
        switch option.kind {
        case .weapon:
            if let index = loadout.weapons.firstIndex(where: { $0.id == option.itemID }) {
                loadout.weapons[index].level = option.toLevel
            } else {
                loadout.weapons.append(OwnedItem(id: option.itemID, level: option.toLevel))
            }
        case .passive:
            if let index = loadout.passives.firstIndex(where: { $0.id == option.itemID }) {
                loadout.passives[index].level = option.toLevel
            } else {
                loadout.passives.append(OwnedItem(id: option.itemID, level: option.toLevel))
            }
        case .heal:
            break
        }
    }
}
