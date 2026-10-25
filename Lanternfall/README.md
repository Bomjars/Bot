# Lanternfall

An original top-down survivor game for iPhone (SpriteKit + SwiftUI, iOS 17+, portrait).
You died, and the underworld took you, but you stole a lantern of heavenly light on the way down. As Wick, the Stolen Flame, you climb out through the circles of hell while demons swarm to drag you back. Survive each circle until its gate opens.

The full design is in [`GAME_SPEC.md`](GAME_SPEC.md).

**Status: Phase 1 (core loop).** You can move with the joystick, Imps spawn and chase you, Lantern Flare fires on its own, slain demons release souls (XP), and the XP bar fills up. Each level-up pauses the game and offers 1 of 3 upgrades drawn from 2 weapons and 3 passives. The run ends when your HP runs out, or when the 8:00 timer is up. The Gatekeeper boss replaces that timer win in Phase 3.

## Run it

1. Open `Lanternfall.xcodeproj` in Xcode 16 or newer.
2. Under *Signing & Capabilities*, pick your team. A real device needs this; the Simulator doesn't.
3. Choose an iPhone simulator and press **⌘R**.

Controls: touch anywhere on the lower two-thirds of the screen and drag to move. Weapons fire automatically. The pause button is at the top right.

Debug builds show FPS and node count in the corner.

### Tests

The gameplay logic is in the `LanternfallKit` Swift package. It has no UIKit or SpriteKit dependency, so the tests run anywhere:

```sh
cd LanternfallKit && swift test          # macOS or Linux
```

In Xcode, **⌘U** runs the same tests through the `Lanternfall` scheme. They cover the XP curve, upgrade maths and rolling, wave spawning, the spatial hash, the fixed-timestep clock, content validation, and simulation scenarios. One test plays a full 8-minute run.

### Regenerating the Xcode project

`Lanternfall.xcodeproj` is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and committed. Files inside `App/` and `LanternfallKit/` are picked up automatically. If you change the folder structure, or a file doesn't show up, regenerate:

```sh
brew install xcodegen
xcodegen generate
```

## Layout

```
Lanternfall/
├── project.yml                  XcodeGen spec (source of truth for the .xcodeproj)
├── App/                         iOS app target: rendering, input and UI only
│   ├── Core/                    GameScene (SpriteKit renderer), GameViewModel, VirtualJoystick
│   ├── Entities/                Node pools: damage numbers, placeholder textures, colours
│   ├── UI/                      SwiftUI: HUD, level-up modal, pause, run end
│   └── Resources/Assets.xcassets
└── LanternfallKit/              Swift package: all game rules, no UIKit
    ├── Sources/LanternfallKit/
    │   ├── Core/                GameSimulation (fixed-step world), events, run phases
    │   ├── Entities/            Player, Enemy, Projectile, Ember (souls), Obstacle structs, Pool
    │   ├── Systems/             Spawner, SpatialHashGrid, UpgradeSystem, PlayerStats, XPCurve, clock
    │   └── Data/                Codable models + Content/*.json
    └── Tests/
```

### Architecture

- **The simulation is separate from rendering.** `GameSimulation` owns the whole run as plain structs in fixed-capacity pools. `GameScene` calls `step(dt:)` at a fixed 60 Hz through `FixedTimestepClock`. After stepping, it syncs one pre-made `SKSpriteNode` per pool slot (show/hide, no allocation) and drains `SimEvent`s for the juice (damage numbers, hurt flash).
- **There's no SpriteKit physics.** A `SpatialHashGrid` is rebuilt every step with a counting sort. Collision, separation and nearest-target lookups all go through it. In release builds, a full run with 300 enemies costs about 0.06 ms per step on a desktop CPU.
- **Pausing is a phase.** The simulation only advances in `.playing`. The level-up modal, the pause menu and game over just change the phase, so nothing needs freezing or unfreezing.
- **Components, not inheritance.** Weapons are data (`behavior: projectile | orbit` plus per-level stats). Passives are stat modifiers that `PlayerStats.compute` folds together.
- **All tunables live in JSON.** That covers speeds, HP, XP curve, spawn waves, upgrade odds, pool sizes, joystick size, camera follow, juice timings and colours.

## Adding content via JSON

All content is in `LanternfallKit/Sources/LanternfallKit/Data/Content/`. It's validated at launch, so a bad reference fails with a clear message instead of misbehaving.

### A new enemy

Add an entry to `enemies.json`:

```json
{ "id": "hellbat", "name": "Hellbat", "maxHP": 5, "moveSpeed": 95, "contactDamage": 4,
  "radius": 9, "xpValue": 1, "color": "#7A1F2B", "spriteName": "enemy_hellbat" }
```

Then reference it from a wave in a level file. Phase 1 enemies all use the `chase` movement. Phase 2 adds per-enemy behaviours (erratic, ranged, charge).

### A new weapon

Add an entry to `weapons.json` with one object per level. The level count is the max level. Each level needs `damage`, `cooldown`, `count`, `area`, `duration`, `speed` and `description`. Then add behaviour-specific fields:

| behavior | meaning | extra fields |
|---|---|---|
| `projectile` | fires `count` bolts at the nearest enemy in `range` | `range` (required), `pierce`, `spreadDegrees`, `knockback` |
| `orbit` | `count` bodies circle at radius `area` for `duration`, then rest for `cooldown` | `bodyRadius`, `hitInterval` (required), `knockback` |

To make it appear on level-up, add its id to `upgrades.pool.weapons` in `game.json`. A new *kind* of behaviour (chain lightning, aura, homing) needs a new `WeaponBehavior` case and an update function in `GameSimulation`. That's planned for Phase 2.

### A new passive

Add an entry to `passives.json` with a `stat` (one of `damage`, `area`, `cooldown`, `armor`, `maxHP`, `moveSpeed`, `pickupRadius`, `luck`), plus `perLevel` and `maxLevel`. Then list its id in `upgrades.pool.passives`.

### A new level

Drop a new file into `levels/`. Every `*.json` there is loaded and sorted by `order`:

```json
{
  "id": "burning_river", "name": "The Burning River", "order": 2,
  "duration": 480, "mapSize": 4000, "enemyCap": 300,
  "obstacles": { "count": 120, "minRadius": 16, "maxRadius": 40, "clearRadius": 240,
                 "maxPlacementAttempts": 3000, "kinds": [{ "id": "obsidian", "weight": 1, "color": "#2A1A24" }] },
  "waves": [
    { "enemy": "imp", "start": 0, "end": 120, "interval": 1.2, "groupSize": 3, "pattern": "scatter" },
    { "enemy": "imp", "start": 100, "end": 480, "interval": 10, "groupSize": 24, "pattern": "ring" }
  ]
}
```

Each wave spawns `groupSize` enemies every `interval` seconds while `start <= t < end`. Spawns appear just off-screen and respect `enemyCap`. `scatter` places each enemy at a random angle; `ring` closes a full circle in around the player. Level select arrives in Phase 4. Until then, `startup.levelID` in `game.json` picks the level.

### Swapping in real art

Placeholder shapes are drawn at runtime. If the asset catalog contains an image with the expected name, it's used instead, with no code changes:

| thing | image name |
|---|---|
| player | `player_wick_idle_0` |
| enemy | `<spriteName>_walk_0` (e.g. `enemy_imp_walk_0`) and `<spriteName>_flash` (white silhouette for hit flash) |
| projectile / orbit body | `<weapon spriteName>_projectile` |
| soul (XP) | `pickup_soul_small`, `pickup_soul_medium`, `pickup_soul_large` |
| obstacle | `obstacle_brimstone`, `obstacle_bone_pile` |
| ground | `ground_ashen_wastes_0`…`_2` |

Put sprites in a `.spriteatlas` folder inside `App/Resources/Assets.xcassets`. Multi-frame walk animation comes in Phase 5.

## Roadmap

1. ~~Core loop~~ ✅
2. Content: all 6 weapons, 8 passives in the pool, all Level 1 enemies, full wave timeline, pickups, elite + chest
3. Boss & results: The Gatekeeper, win condition, results screen, obols (gold), save data
4. Meta & menus: main menu, character select, Camp shop, settings, haptics, sound hooks, pixel font
5. Polish: lighting, juice (particles, shake), evolutions, performance pass on device, real art
