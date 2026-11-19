# Changelog

## M3 – Biomass economy, harvester drones, in-run turret tiers

### Added
- **`data/economy.json`**: every economy value in one file.
  - Used now: starting Biomass, per-corpse Biomass by strain, charred yield, build costs, upgrade costs, refund ratio, repair cost, harvester stats.
  - Ready for later milestones, already in final format: night bonus, early-call bonus, Xenite payouts, Threat Level and Hazard Contracts.
- **Biomass economy** (`econ/economy.gd`).
  - Building, upgrading and repairing cost Biomass.
  - Selling refunds 50% of everything invested.
  - The top bar shows income per minute.
  - Tools you can't afford are greyed out, and the ghost turns red.
- **Corpses hold Biomass.** Incendiary kills (including burn deaths) leave charred corpses worth 0.
  Corpses that decay before harvest are counted as lost.
- **Harvester Bay + drones** (`econ/harvester.gd`).
  - Drones (2/3/4 by bay tier) fly to the nearest unclaimed corpse in range (16/19/22 m).
  - Each drone strips corpses with a beam until it carries 24, then flies home and deposits; a "+N" pops up.
  - Harvesting removes the corpse and lowers its pile, so bays near walls stop the swarm climbing over.
  - Drones crash if their bay is destroyed.
- **Turret tiers I/II/III** (multipliers in `turrets.json`, costs in `economy.json`).
  - Tiers raise damage, range, crew efficiency (fire rate) and HP.
  - Tier pips light up on the base and the turret head grows.
  - Harvester Bays have tiers too: more drones, more range.
- **Floodlights.**
  - A real light plus a per-cell lit-coverage grid, ready for M5 nights.
- **Inspector panel.**
  - Select any structure to see HP, current and next-tier stats, kills, and drones and range.
  - It has Upgrade (U / X), Repair (R / Y) and Sell (B) buttons.
  - Range rings show for the selected or hovered structure.
- Floating text for Biomass deposits, and toasts for build errors ("Need 120 Biomass").
- The swarm ramps up over 90 s (`swarm.ramp_seconds`) so there is time to spend the starting Biomass.
- Starting kit: Harvester Bay, Autocannon, Flamethrower, Mortar, 2 Floodlights and 350 Biomass.
- Sandbox free build (F11 / `--free-build`).
- Scripted bot player for soak tests (`--bot`).

### Changed
- Build tools now use keys 1–9 and 0 (10 tools).
- Reset outpost moved to F10, and R is now Repair.
- Benchmark moved to B / F9 (keyboard only). Gamepad X / Y are now Upgrade / Repair.
- The flow-field heatmap is keyboard only (F).

### Known limitations
- Drones can't be attacked yet.
- Floodlights have no gameplay effect until night arrives in M5.
- Specialisations (tier III choice) unlock in M6.
- Colonists crewing turrets, and the 40% uncrewed rate, arrive in M4.
  `Turret.crew_factor` is already wired in.


## M2 – Walls, turrets, damage types, death, corpse piling

### Added
- **Damage types and counter matrix.**
  - Six damage types: Ballistic, Incendiary, Piercing, Shock, Explosive, Seismic.
  - The weak/resist table from `aliens.json` is compiled into a matrix (150% / 50%, set in `turrets.json`).
  - The build card and the Intel panel (**I**) show who each type counters.
- **Six turrets** with distinct behaviours and primitive models, stats in `data/turrets.json`:
  - Autocannon: rapid, dodgeable.
  - Flamethrower: cone plus burning.
  - Railgun: pierces 5 in a line.
  - Shock Grid: arcs into 14 and slows.
  - Mortar: lobbed splash shells, minimum range.
  - Seismic Spike: slam that also hits underground Burrowers and surfaces them.
  - All turrets use "first" targeting: the alien closest to the core along the flow field.
- **Structures:** walls, blast doors and turrets, each with HP and damage tint.
  - Drag-paint to build, right-drag to demolish.
  - A ghost preview and range ring show while placing.
  - The starting compound has a demo battery of one of each turret.
- **Aliens fight back.**
  - The flow field paths through structures at a cost, so aliens bash whatever the field leads them into.
  - Maulers deal x4 damage to doors.
  - Spitters shell structures with acid from 9 m.
  - Burrowers tunnel along a second flow field and surface near the core.
  - Brood Mothers birth Stalker broods.
  - Snatchers dodge 35% of aimed shots.
  - Aliens gnaw the core. Losing it means **OUTPOST OVERRUN**; press **R** to rebuild.
- **Death and corpse piling.**
  - Deaths are processed at the end of the frame (safe swap-remove).
  - Each death throws carapace gibs and an acidic ichor spray, and leaves a persistent ichor splat.
  - Pooled corpses are kept per strain, capped at `corpse_cap` with the oldest decaying first.
  - Corpses stack on per-cell pile heights.
  - Incendiary kills leave charred corpses (no Biomass from M3 on).
  - Living aliens walk on top of piles.
  - A pile of 1.6 m beside a wall makes the wall climbable: it tints green and the swarm pours over it.
- **Hit flash**, burn and slow status, and a gore toggle (**G**).
- **Spatial bucket grid** (4 m cells, linked lists rebuilt in one pass per frame) for turret queries.
- **Headless combat soak**: `-- --combat-test=60`.
- The benchmark now includes combat (core invulnerable during the run) and reports combat + fx ms.

### Changed
- Swarm pressure moved to + / − and F5–F8. Number keys 1–8 now pick build tools.
- Starting swarm pressure is 1,500.

### Measured (headless, slow 4-thread 2.1 GHz cloud CPU)
| Scenario | Result |
|---|---|
| Benchmark 10k with combat | 114 fps avg, 62 fps 1% low, sim 6.9 ms, combat+fx 1.2 ms – PASS |
| Soak 30 s at pressure 1,500 | 629 kills, all six turrets scoring, 4 walls made climbable, core 67% |
| Soak 60 s at pressure 6,000 | 3,833 kills, 37 structures lost, outpost overrun |

### Known limitations
- No economy yet: building is free (Biomass in M3).
- No colonists, abduction or feeding (M4). No waves or day/night (M5).
- Turret specialisations, upgrade tiers and Hive adaptation come in M3 to M6.
  Damage dealt per type is already tracked for adaptation.


## M1 – Swarm & flow field benchmark

### Added
- Godot 4.4 project `xenite_frontier/` (Forward+, 1280x800 base resolution, scales to any aspect).
- **Flow field** (`sim/flow_field.gd`)
  - 8-connected, corner-safe Dijkstra pass.
  - Bucket queue with integer costs, so it runs in O(cells).
  - Per-cell cost multiplier, ready for later "bash through the door" pathing.
  - Async rebuild on a worker thread with double-buffered swap.
  - Aliens caught inside a newly placed wall climb out.
- **Swarm simulation** (`sim/swarm.gd`, `sim/alien_pool.gd`)
  - Struct-of-arrays pools, one per strain.
  - Density-grid crowd separation and wall sliding.
  - Rate-limited spawning from canyon mouths.
  - Threaded 1,024-alien chunks.
  - Render buffer written in the same pass as the simulation.
- **Six strain silhouettes** built procedurally from primitives with baked part
  colours (`render/alien_meshes.gd`). Faceted shader with GPU gait animation and
  emissive bioluminescent parts. The shader already reserves a hit-flash channel
  for M2.
- **Test range map**
  - Cliff basin, three canyon mouths, noise-generated outcrops.
  - Walled compound with airlock gaps and catwalk baffles around a glowing core.
  - Wall placement and removal by click or gamepad.
  - Flow-field distance heatmap.
- **Angled top-down camera**: pan, edge scroll, drag, smooth zoom; keyboard, mouse and gamepad.
- **Benchmark**
  - HUD showing FPS, sim ms, upload ms, render CPU/GPU ms, draw calls and per-strain counts.
  - Scripted run (`B` key or `-- --benchmark[=N]`) reporting avg FPS, 1% low and p99 sim time.
  - Log written to `user://benchmark.log`.
- Data-driven tuning: `data/aliens.json`, `data/game_config.json`.
- Input actions registered in code (`core/input_setup.gd`) so they can be rebound in M8.

### Measured (headless, CPU only; 4-thread 2.1 GHz cloud Xeon, a slow machine)
| Aliens | Avg FPS | 1% low | Swarm sim avg / p99 |
|---|---|---|---|
| 10,000 | 145 | 144 | 4.8 ms / 7.8 ms |
| 20,000 | 142 | 90 | 6.4 ms / 9.9 ms |

Measured on a desktop with full rendering (Ryzen 7 9800X3D, RTX 5080, Windows, Vulkan):
| Aliens | Avg FPS | 1% low | Swarm sim avg / p99 | GPU |
|---|---|---|---|---|
| 10,000 | 515 | 238 | 1.29 ms / 1.75 ms | 0.47 ms |

Flow field rebuild (200x140 cells): ~54 ms on a worker thread, with no frame hitch.
GPU cost depends on your card. Run `B` in a windowed build to measure it.

### Fixed
- Fresh clones failed with `Identifier "InputSetup" not declared` because the script class cache (`.godot/`) is not in git. The README now documents the one-time `--import`, and `run_benchmark.bat` runs it automatically.

### Known limitations (by design for M1)
- Aliens that reach the core are recycled to a canyon mouth; there is no damage or death yet (M2).
- Aliens treat walls as impassable. Breaching, climbing piles and burrowing come in M2–M4.
