import Foundation

public struct ContentError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { "Content error: \(message)" }
}

/// All game data, loaded once at launch from the JSON files in `Data/Content`.
public struct GameContent {
    public let config: GameConfig
    public let enemies: [EnemyConfig]
    public let weapons: [WeaponConfig]
    public let passives: [PassiveConfig]
    public let characters: [CharacterConfig]
    /// Sorted by `order`.
    public let levels: [LevelConfig]

    private let enemyIndexByID: [String: Int]
    private let weaponIndexByID: [String: Int]
    private let passiveIndexByID: [String: Int]

    public init(
        config: GameConfig,
        enemies: [EnemyConfig],
        weapons: [WeaponConfig],
        passives: [PassiveConfig],
        characters: [CharacterConfig],
        levels: [LevelConfig]
    ) throws {
        self.config = config
        self.enemies = enemies
        self.weapons = weapons
        self.passives = passives
        self.characters = characters
        self.levels = levels.sorted { $0.order < $1.order }
        enemyIndexByID = try Self.index(enemies.map(\.id), kind: "enemy")
        weaponIndexByID = try Self.index(weapons.map(\.id), kind: "weapon")
        passiveIndexByID = try Self.index(passives.map(\.id), kind: "passive")
        _ = try Self.index(characters.map(\.id), kind: "character")
        _ = try Self.index(levels.map(\.id), kind: "level")
        try validate()
    }

    // MARK: Lookup

    public func enemyIndex(id: String) -> Int? { enemyIndexByID[id] }
    public func weaponIndex(id: String) -> Int? { weaponIndexByID[id] }
    public func passiveIndex(id: String) -> Int? { passiveIndexByID[id] }

    public func weapon(id: String) -> WeaponConfig? { weaponIndexByID[id].map { weapons[$0] } }
    public func passive(id: String) -> PassiveConfig? { passiveIndexByID[id].map { passives[$0] } }
    public func character(id: String) -> CharacterConfig? { characters.first { $0.id == id } }
    public func level(id: String) -> LevelConfig? { levels.first { $0.id == id } }

    // MARK: Loading

    /// Loads the content shipped inside this package.
    public static func loadBundled() throws -> GameContent {
        guard let url = Bundle.module.url(forResource: "Content", withExtension: nil) else {
            throw ContentError("bundled Content folder is missing")
        }
        return try load(from: url)
    }

    /// Loads `game.json`, `enemies.json`, `weapons.json`, `passives.json`,
    /// `characters.json` and every `levels/*.json` from `directory`.
    public static func load(from directory: URL) throws -> GameContent {
        let levelsDirectory = directory.appendingPathComponent("levels", isDirectory: true)
        let levelFiles = try FileManager.default
            .contentsOfDirectory(at: levelsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try GameContent(
            config: decode(GameConfig.self, at: directory.appendingPathComponent("game.json")),
            enemies: decode([EnemyConfig].self, at: directory.appendingPathComponent("enemies.json")),
            weapons: decode([WeaponConfig].self, at: directory.appendingPathComponent("weapons.json")),
            passives: decode([PassiveConfig].self, at: directory.appendingPathComponent("passives.json")),
            characters: decode([CharacterConfig].self, at: directory.appendingPathComponent("characters.json")),
            levels: levelFiles.map { try decode(LevelConfig.self, at: $0) }
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ContentError("cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ContentError("cannot decode \(url.lastPathComponent): \(error)")
        }
    }

    private static func index(_ ids: [String], kind: String) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, id) in ids.enumerated() {
            guard result[id] == nil else { throw ContentError("duplicate \(kind) id '\(id)'") }
            result[id] = index
        }
        return result
    }

    // MARK: Validation

    private func validate() throws {
        let rules = config.upgrades
        for id in rules.pool.weapons where weaponIndexByID[id] == nil {
            throw ContentError("upgrade pool references unknown weapon '\(id)'")
        }
        for id in rules.pool.passives where passiveIndexByID[id] == nil {
            throw ContentError("upgrade pool references unknown passive '\(id)'")
        }
        guard rules.choiceCount > 0, rules.maxWeapons > 0, rules.maxPassives >= 0 else {
            throw ContentError("upgrade rules need choiceCount > 0 and maxWeapons > 0")
        }

        guard let firstBracket = config.xp.brackets.first, firstBracket.fromLevel == 1 else {
            throw ContentError("xp.brackets must start at fromLevel 1")
        }
        let tierValues = config.pickups.emberTiers.map(\.value)
        guard !tierValues.isEmpty, tierValues == tierValues.sorted() else {
            throw ContentError("pickups.emberTiers must be non-empty and ascending by value")
        }

        for weapon in weapons {
            guard !weapon.levels.isEmpty else {
                throw ContentError("weapon '\(weapon.id)' has no levels")
            }
            for (index, level) in weapon.levels.enumerated() {
                let label = "weapon '\(weapon.id)' level \(index + 1)"
                guard level.count > 0, level.cooldown >= 0 else {
                    throw ContentError("\(label) needs count > 0 and cooldown >= 0")
                }
                switch weapon.behavior {
                case .projectile:
                    guard level.range != nil else { throw ContentError("\(label) needs 'range'") }
                case .orbit:
                    guard level.bodyRadius != nil, level.hitInterval != nil else {
                        throw ContentError("\(label) needs 'bodyRadius' and 'hitInterval'")
                    }
                }
            }
        }

        for passive in passives where passive.maxLevel < 1 {
            throw ContentError("passive '\(passive.id)' needs maxLevel >= 1")
        }

        // Locked characters may reference weapons that arrive in later phases.
        for character in characters where character.playable && weaponIndexByID[character.startingWeapon] == nil {
            throw ContentError("character '\(character.id)' starts with unknown weapon '\(character.startingWeapon)'")
        }

        for level in levels {
            for wave in level.waves {
                guard enemyIndexByID[wave.enemy] != nil else {
                    throw ContentError("level '\(level.id)' wave references unknown enemy '\(wave.enemy)'")
                }
                guard wave.interval > 0, wave.groupSize > 0, wave.end > wave.start else {
                    throw ContentError("level '\(level.id)' has a wave with bad timing for '\(wave.enemy)'")
                }
            }
            guard level.obstacles.kinds.contains(where: { $0.weight > 0 }) || level.obstacles.count == 0 else {
                throw ContentError("level '\(level.id)' obstacles need at least one kind with weight > 0")
            }
        }

        guard level(id: config.startup.levelID) != nil else {
            throw ContentError("startup level '\(config.startup.levelID)' not found")
        }
        guard let startCharacter = character(id: config.startup.characterID), startCharacter.playable else {
            throw ContentError("startup character '\(config.startup.characterID)' not found or not playable")
        }
    }
}
