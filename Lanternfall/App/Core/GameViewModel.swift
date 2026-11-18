import Combine
import Foundation
import LanternfallKit

struct HUDState: Equatable {
    var level = 1
    /// 0...1, rounded so tiny XP changes don't re-render SwiftUI.
    var xpFraction: Double = 0
    var elapsedSeconds = 0
    var kills = 0
    var weapons: [OwnedItem] = []
    var passives: [OwnedItem] = []
}

struct RunSummary {
    struct WeaponDamage: Identifiable {
        let id: String
        let name: String
        let damage: Int
    }

    let victory: Bool
    let secondsSurvived: Int
    let kills: Int
    let level: Int
    let damage: [WeaponDamage]
}

/// Bridges the simulation to SwiftUI. The scene calls `sync()` every frame;
/// published values only change when what's on screen would change.
@MainActor
final class GameViewModel: ObservableObject {
    let simulation: GameSimulation

    @Published private(set) var hud = HUDState()
    @Published private(set) var phase: RunPhase = .playing
    @Published private(set) var choices: [UpgradeOption] = []

    private static let xpBarSteps = 200.0

    var content: GameContent { simulation.content }

    init(simulation: GameSimulation) {
        self.simulation = simulation
        sync()
    }

    func sync() {
        let required = max(simulation.xpRequiredForNextLevel, 1)
        let fraction = Double(min(1, simulation.player.xp / required))
        let next = HUDState(
            level: simulation.player.level,
            xpFraction: (fraction * Self.xpBarSteps).rounded() / Self.xpBarSteps,
            elapsedSeconds: Int(simulation.time),
            kills: simulation.kills,
            weapons: simulation.loadout.weapons,
            passives: simulation.loadout.passives
        )
        if next != hud {
            hud = next
        }
        if simulation.phase != phase {
            phase = simulation.phase
        }
        if simulation.upgradeChoices != choices {
            choices = simulation.upgradeChoices
        }
    }

    func choose(_ option: UpgradeOption) {
        simulation.chooseUpgrade(option)
        sync()
    }

    func pause() {
        simulation.setPaused(true)
        sync()
    }

    func resume() {
        simulation.setPaused(false)
        sync()
    }

    var summary: RunSummary {
        let damage = simulation.loadout.weapons.map { item in
            RunSummary.WeaponDamage(
                id: item.id,
                name: content.weapon(id: item.id)?.name ?? item.id,
                damage: Int(simulation.damageByWeapon[item.id] ?? 0)
            )
        }
        return RunSummary(
            victory: simulation.phase == .victory,
            secondsSurvived: Int(simulation.time),
            kills: simulation.kills,
            level: simulation.player.level,
            damage: damage
        )
    }
}
