# Claude Code Prompt — "Lanternfall" (iOS top-down survivor game)

> Paste everything below into Claude Code from an empty folder on your Mac (Xcode installed). Or save it as `GAME_SPEC.md` in the project root and tell Claude Code: "Read GAME_SPEC.md and build Phase 1."

---

## Role & goal

You are a senior iOS game developer. Build an original top-down **survivor / bullet-heaven** game for iPhone, in the spirit of Vampire Survivors (auto-attacking hero, swarms of enemies, level-up upgrade choices) but with its own theme, characters and art. Start with **one playable level**, built so more levels can be added later through data files rather than new code.

Work in phases. After each phase: build, run in the iOS Simulator, fix all errors and warnings, then summarise what's done and what's next. Don't start the next phase until I confirm.

## Tech stack

- Swift 5.9+, **SpriteKit** for gameplay, **SwiftUI** for menus/HUD overlays (via `SpriteView`)
- Target iOS 17+, iPhone, **portrait** orientation, 60 fps
- No third-party dependencies for v1
- Game content (weapons, passives, enemies, waves, level config) defined in **JSON files** loaded at launch
- Save data: `Codable` structs persisted to Application Support (iCloud later)
- Unit tests (XCTest) for upgrade maths, XP curve, wave spawning and save/load

## Concept

**Theme: escaping hell.** You died, and the underworld took you. But you stole something on the way down: a lantern of heavenly light. Now you're climbing out through the circles of hell while demons swarm to drag you back. Survive each circle until its gate opens.

**Main character (default): Wick, the Stolen Flame**: a small hooded soul with an oversized lantern of pale-gold holy light and a ghostly white scarf. The lantern's glow radius doubles as the XP pickup radius: freed souls (the XP) drift into its light.

Unlockable characters later (stub the data, don't implement art yet):
- **Bolt** — a scrap robot; starts with Spark Coil, +10% armour, slower move speed
- **Moss** — a mushroom druid; starts with Spore Cloud, regenerates HP, low base damage
- **Rook** — a crow-masked plague doctor; starts with Feather Daggers, +crit chance

## Core loop

1. **In-run:** Move only (auto-attack). Kill demons → they release **souls** (XP). Fill XP bar → game pauses → choose **1 of 3** random upgrades (new weapon, new passive, or level up an owned one). Max 6 weapons + 6 passives.
2. **End of level:** Survive the timer and defeat the circle's gatekeeper → **Results screen**: time survived, kills, obols earned, level reached, damage per weapon.
3. **Between levels (Camp: a hidden shrine between circles):** Spend **obols** (the ferryman's coins, the gold currency) on permanent upgrades. Unlock characters and the next circles up.

## Controls & feel

- Floating virtual joystick: touch anywhere on the lower 2/3 of screen, drag to move; release to stop
- Auto-aim weapons target nearest enemy (or fire in move direction, per weapon)
- Pause button top-right
- Haptics: light tap on level-up, medium on taking damage, heavy on boss spawn/death (`UIImpactFeedbackGenerator`)
- "Juice": hit-flash white on enemies, floating damage numbers, small screen shake on big hits, particle bursts on death, souls magnetise toward player

## Level 1 — "The Ashen Wastes" (First Circle)

- Duration: **8 minutes** (mobile-friendly session), then boss
- Map: large tiled field of ash and cooling lava (e.g. 4000×4000 pts) with brimstone boulders and bone piles as obstacles; camera follows player
- Destructible **hellfire braziers** that drop pickups
- Waves (data-driven, ramp up density and mix every 60s):

| Time | Spawns |
|---|---|
| 0:00–1:30 | Imps (slow, weak, swarm) |
| 1:30–3:00 | + Hellbats (fast, erratic, low HP) |
| 3:00–4:30 | + Brimstone Brutes (slow tanks, high HP) |
| 4:00 | Elite: **Hellhound** (charges in a line, drops a chest) |
| 4:30–6:30 | + Cinder Witches (keep distance, fire slow fireballs) |
| 6:30–8:00 | Swarm surge — dense rings of Imps closing in |
| 8:00 | **Boss: The Gatekeeper** — a towering horned demon guarding the way up; phases: fire geysers erupting under the player, summons Imps, at 50% HP spins and spits fireballs |

- Enemy cap ~300 on screen; spawn just off-screen around the player

## Weapons (start with 6 for v1)

Each has 5 levels (damage, cooldown, count, area, duration increase per level).

| Weapon | Behaviour |
|---|---|
| **Lantern Flare** (Wick's starter) | Fires a bolt of stolen heavenly light at the nearest enemy |
| **Halo Shards** | Shards of a broken halo circle the player, damaging on contact |
| **Feather Daggers** | Throws fallen-angel feathers in movement direction, pierce |
| **Spark Coil** | Chain lightning jumping between nearby enemies |
| **Sunburst** | Periodic damaging pulse around the player (aura) |
| **Moth Swarm** | Homing moths that seek random enemies |

**Evolutions** (max-level weapon + specific passive → evolved weapon, granted from a boss/elite chest):
- Lantern Flare + Holy Oil → **Solar Lance** (piercing beam)
- Halo Shards + Bellows → **Seraph's Ring** (larger, burn effect)
- Spark Coil + Copper Wire → **Storm Crown** (strikes all enemies on screen periodically)

## Passives (v1: 8)

| Passive | Effect per level |
|---|---|
| Holy Oil | +10% damage |
| Bellows | +10% area |
| Copper Wire | -8% cooldown |
| Wax Seal | +1 armour |
| Hearthstone | +20 max HP |
| Swift Boots | +10% move speed |
| Moth Lure | +25% pickup radius |
| Ferryman's Coin | +10% luck (better upgrade/drop odds) |

## Pickups

- **Souls (XP)** — small (1), medium (5), large (25); merge nearby souls when too many on the map (performance)
- **Obols** — meta currency
- **Holy Water / Communion Bread** — heal 30 HP
- **Lantern Magnet** — pulls all souls on map to player
- **Heaven's Light** — clears all normal enemies on screen
- **Treasure chest** — dropped by elites/boss; grants 1–3 upgrades with a slot-machine reveal animation

## Meta upgrades (Camp shop, bought with obols)

Max HP, Damage, Armour, Move Speed, Pickup Radius, Gold Gain, XP Gain, **Reroll** (reroll upgrade choices N times per run), **Banish** (remove an option from the pool for that run), **Revival** (revive once at 50% HP). Cost scales per rank.

## Art direction

- Style: **chunky pixel art, 32×32 characters**, 16×16 pickups; a scorched black-red underworld of hellfire, cut through by the cool pale-gold holy light of Wick's lantern
- Palette: background `#1A0D10` / `#33141A`, lava cracks `#FF5A1F`, holy light `#FFE7A3` / `#FFF6D6`, demons `#B8322A` / `#8E2B2B`, danger `#FF3B2F`, souls `#9FE8FF` / `#5FC8FF` / `#B98CFF`
- Lighting: use `SKLightNode` (or a radial gradient overlay) so the player's lantern lights the area around them and edges of screen fall into darkness
- **Phase 1–3: placeholder shapes only** (coloured circles/squares with simple particle glows) — get the game fun first
- Asset pipeline: put sprites in `Assets.xcassets` sprite atlases; name them consistently (`enemy_imp_walk_0…3`) so I can swap in real art later
- Fonts: a free pixel font (e.g. from Google Fonts, licence-checked) for HUD

## HUD

Top: XP bar (full width), level number, timer (counts up), kill count, obols. Bottom-left: HP bar under player sprite. Weapon/passive icons in a compact row under the XP bar.

## Screens

Main Menu → Character Select → Level Select → Gameplay → Level-up Modal / Pause Menu → Results → Camp (shop) → back to Level Select. Settings: sound/music volume, haptics on/off, joystick size.

## Architecture requirements

- Folders: `Core/` (game loop, scene), `Entities/` (Player, Enemy, Projectile, Pickup), `Systems/` (Spawner, Weapons, Collision, XP, Upgrades), `Data/` (JSON + Codable models), `UI/` (SwiftUI views), `Persistence/`
- Lightweight component approach — avoid deep inheritance
- **Object pooling** for enemies, projectiles, pickups and damage numbers
- **Spatial hash grid** for collision/target lookup (don't use SpriteKit physics for 300+ enemies)
- Fixed-timestep update; pause cleanly for level-up modal
- All tunable numbers in JSON (no magic numbers in code)

## Phases

1. **Core loop:** project setup, joystick movement, camera follow, one enemy type spawning and chasing, Lantern Flare auto-attack, enemy death + souls (XP), XP bar, level-up modal with 3 choices (from 2 weapons + 3 passives), player HP and game over
2. **Content:** all 6 weapons, 8 passives, all Level 1 enemies, wave timeline from JSON, pickups, elite + chest
3. **Boss & results:** Gatekeeper boss, win condition, results screen, obols, save data
4. **Meta & menus:** main menu, character select (Wick only playable), Camp shop, settings, haptics, sound hooks (placeholder SFX)
5. **Polish:** lighting, juice, evolutions, performance pass (profile with Instruments, hold 60 fps at 300 enemies on iPhone 12), real art swap

## Definition of done (v1)

- Builds with zero warnings, runs on simulator and a real iPhone
- A full 8-minute run of Level 1 is completable and fun to play
- Upgrades, obols and unlocks persist between launches
- Unit tests pass
- README explaining how to run, how to add a new weapon/enemy/level via JSON

Ask me before making major design changes. Start with Phase 1.
