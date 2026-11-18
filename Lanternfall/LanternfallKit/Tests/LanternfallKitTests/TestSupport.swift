import XCTest
@testable import LanternfallKit

enum TestContent {
    /// The real shipped content.
    static func bundled() throws -> GameContent {
        try GameContent.loadBundled()
    }

    /// Shipped content with edits applied, e.g. a shorter level.
    static func modified(
        config edit: (inout GameConfig) -> Void = { _ in },
        level levelEdit: (inout LevelConfig) -> Void = { _ in }
    ) throws -> GameContent {
        let base = try bundled()
        var config = base.config
        edit(&config)
        let levels = base.levels.map { level -> LevelConfig in
            var copy = level
            levelEdit(&copy)
            return copy
        }
        return try GameContent(
            config: config,
            enemies: base.enemies,
            weapons: base.weapons,
            passives: base.passives,
            characters: base.characters,
            levels: levels
        )
    }

    static func simulation(_ content: GameContent, seed: UInt64 = 42) throws -> GameSimulation {
        try GameSimulation(
            content: content,
            levelID: content.config.startup.levelID,
            characterID: content.config.startup.characterID,
            seed: seed
        )
    }
}
