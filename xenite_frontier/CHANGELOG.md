# Changelog

## M5a.1 – Humanoid Lineup v3 (concept sheet)

### Changed
- **All six aliens rebuilt from the concept sheet** "predatory/primal – Humanoid Lineup v3" (saved as `docs/concept_humanoid_lineup_v3.svg`).
  - Gaunt, faceted, flat-shaded bipeds in the sheet's palette: charcoal, light olive front panel, bone claws, one identity colour each.
  - Stalker: hunched long-jaw with back spikes. Mauler: boulder-shouldered gorilla with rock fists. Spitter: glowing throat sac. Snatcher: long dragging claws, yellow spines. Burrower: legless segmented torso with a circular orange maw and a dirt mound. Brood Mother: egg sac on her back, white spike crown.
- **Biped GPU rig:** per-vertex joint pivots for hips, knees, shoulders, elbows and neck. Posture blends to all fours when sprinting. Feeding crouch, attack rear-up, Spitter hunch-and-spit.
- **Burrowers breach:** while tunnelling the shader sinks the body so only the head and a widening dirt mound show. The mound disappears on death.
- **Brood young are runts:** small (x0.62), weaker Stalkers.
- Corpse poses per the brief. Mauler boulders crack off.
- Alien triangles: 620–930 near, 390–540 far (lighter than before).
- HUD and Intel strain colours use the sheet's swatches.


## M5a – Waves with a build timer, landing site, workers & soldiers, finance, art direction

### Added
- **Waves** (`game/wave_director.gd`, `data/waves.json`).
  - Run flow: landing, then a build countdown (90 s / 40 s), then a wave, then payday.
  - **Call the wave early** (N) for +3 Biomass per second remaining.
  - Waves arrive as packs from random canyon mouths. Sizes are **x0.7 (30% fewer enemies)** via `size_multiplier`.
  - Waves grow 45% per wave, with +4% alien HP per wave.
  - **Threat Level** +0.25 per wave. Stragglers time out so a wave can't soft-lock.
- **Choose the landing site.** Click to drop the Command Hab on any valid 7x7 open area away from the canyon mouths. The pad is levelled and the scenery rebuilt around it. Runs start empty.
- **Xenite deposits** (10 glowing outcrops) and **Mining Rigs** on them. The company buys mined Xenite after every wave (x3 Biomass); 25% is banked for the Colony Charter.
- **Workers.**
  - Construction is no longer instant: sites with scaffolding, build time in work-seconds, up to 2 builders each. Cancelling a site gives a full refund.
  - Workers repair automatically (paying Biomass per HP), staff economy buildings and rigs, and crew spare turrets.
- **Soldiers.**
  - Trained at a **Barracks**. They crew turrets, garrison **Guard Posts** (+4 m range) and fire rifles (ballistic; Armory +25%).
  - **Squad control:** click or drag-select, right-click to move and hold, H to release.
- **Finance.**
  - Company bounty x Threat Level after every wave, ore sales, early-call bonus.
  - **Wages** per worker and soldier per wave. Unpaid wages mean low morale: crews and soldiers fire at 80%.
  - Upgrade buildings: Bio-Refinery (+25% Biomass), Fabricator (-15% costs), Armory (tier III gate + soldier damage), Medbay (2x recovery), Hab Module (+4 population).
  - Recruitment from the Command Hab (workers) and Barracks (soldiers), with a population cap.
- **UI.**
  - Build bar categories (Defence / Turrets / Colony; Tab).
  - Wave panel with countdown and a call-early button; payday report popup.
  - Worker/soldier breakdown, Xenite mined/banked, wages.
  - Inspector actions: recruit, train, cancel construction, staff and garrison names.
  - Drag-select box.
- **More realistic horde:** stride synced to the distance actually walked (no foot sliding), packs with shared lanes, sniff pauses out in the open, wider size and speed variation, stronger separation.
- **Art direction pass.**
  - Six new dark-chitin alien body plans with a general GPU rig: per-vertex joint pivots and phases for hexapod, quadruped, knuckle-walk and worm motion, pulsing sacs, cracking shells.
  - Custom corpse looks and death effects: plates scatter, acid pool, the Brood Mother's dead young plus a huge ichor pool.
  - Acid-green ichor; industrial off-white / hazard-yellow / worn-grey palette.
  - Damage-type turret accents and matching muzzle effects; tier II/III armour plating and +10% size per tier.
  - New worker and soldier suits; dragged colonists flail and kick.
  - Rust-orange planet under a dim violet sky with a ringed gas giant and a small moon. The camera tilts toward the horizon when zoomed in.
  - Map-edge plateau so the world never ends in a void.

### Changed
- Runs no longer start with a pre-built compound. Tests and the benchmark use `--classic` / `--auto-land`.
- The old continuous spawning is now `--sandbox` only.
- `--fast-waves` dev flag for soak tests.

### Measured (headless, slow 4-thread cloud CPU)
- Bot soak (fast timers) reached wave 5 with the core intact. Guard Posts, Mining Rig, Hab Module, Barracks and Bio-Refinery were all active. Bounties 510, ore sales 123, wages 152. 0 stuck aliens.
- 10k benchmark: 1% low 67 fps, sim 8.4 ms. PASS.


## M4.5 – Visual pass: grey aliens, space suits, Mars-base outpost, alien planet

### Added
- **Grey alien family** (`render/alien_meshes.gd`, `render/alien.gdshader`).
  - Bald, big-headed predatory greys with glowing almond eyes, toothed mouths and long clawed limbs.
  - Every strain is redesigned in this style with its own silhouette, posture and identity colour.
  - **GPU joint rig:** vertices carry a part id (UV.x), and the shader rotates parts about the hip, knee, shoulder, elbow and neck.
  - Aliens walk upright and **drop to all fours to sprint** (posture blends with speed). They crouch and peck when feeding, and rear up and slash when attacking.
  - The swarm sim writes each alien's state (speed / feeding / attacking) into `INSTANCE_CUSTOM.a`.
  - Near and far meshes: about 1,000–1,500 triangles zoomed in, 430–670 zoomed out. Corpses use the far mesh.
- **Space-suited colonists**: white EVA suit, orange trim, gold visor, life-support pack, oxygen tanks, boots, and a walk cycle.
- **Mars-base outpost** (`render/station_models.gd`, `render/station.gdshader`).
  - Hab dome core with window band, airlock tunnel, side module and comms dish.
  - Barrier walls: posts, plus composite panels on regolith berms that **join neighbouring walls and doors into continuous lines**, with damage tint and climbable tint.
  - Chevron airlock blast doors, oriented to the wall line.
  - Octagonal Harvester Bay landing pad with a biomass tank and gantry; lattice floodlight masts.
  - Turrets on round strut-mounted pads.
  - Solar arrays, tanks and comms towers on the mesas.
- **Alien planet terrain**.
  - Half-metre heightfield replacing the stacked cubes.
  - Basalt mesas with cliff faces and strata bands, uneven lumpy regolith, 60 craters, dark gravel fields.
  - A levelled base pad, boulders at cliff feet, teal Xenite crystal clusters on the mesas.
  - Violet-to-salmon procedural sky, dusty fog, SSAO, ACES tonemap, low sun with a cool fill light.
  - The build grid shows only while a build tool is selected.
- Everything follows the terrain height (bilinear sampling, inside the threaded swarm loop as well).
- **Custom model hook:** `"mesh": "res://art/x.glb"` per strain in `aliens.json`; see `art/README.md`.
- Dev `--showcase [--pair=N]`: lineup of every strain in five poses, in photo mode.

### Fixed
- Vertex colours are now treated as sRGB in the alien, station and fx shaders. Before, everything rendered washed out.

### Measured (headless, slow 4-thread cloud CPU)
- 10k benchmark: 1% low 66–76 fps, sim 6.5–7.1 ms (terrain sampling adds about 0.5 ms). PASS.
- 3-min soak at 240/min, bot: core 5997/6000, 10/10 colonists, 0 stuck aliens.
- GPU cost depends on your card. Press B in game.


## M4.1 – Stuck-alien fix and rebalance (from playtest feedback)

### Fixed
- **Aliens stuck at the canyon mouths.** The flow field's optimised direction pass skipped map-border cells, but the canyon mouths open onto the map edge. Any alien that spawned on an edge cell had direction (0, 0) and never moved. They also counted toward the swarm-pressure limit, so over a few minutes much of the "swarm" sat idle at the mouths. Border cells now get a bounds-checked direction pass. Measured: 88 of 676 aliens stuck before, 0 after.
- **Sandbox spawning could never be out-killed.** "Swarm pressure N" meant "keep N alive", so every kill was replaced instantly. Pressure is now a **spawn rate** (aliens per minute, default 240, ramping over 90 s, cap 20,000 alive). The benchmark keeps its fixed-population mode.
- **Brood spawned inside rock** when a Brood Mother hugged a cliff. Brood now only lands on open, reachable ground.

### Added
- Per-alien stuck timer, counting only time spent not moving without a reason. Eating, bashing, shelling and gnawing the core don't count.
- Unstick safety net: once a second, aliens stuck over 6 s inside rock or in a no-path cell are moved to the nearest reachable cell, or removed.
- `--stuck-report` diagnostics, grouped by cell with the likely cause and an ASCII map.

### Rebalanced
The M2 to M4 numbers were tuned against a partly frozen swarm.
- Feeding: Stalker / Mauler / Burrower feed rate 0.35 / 0.25 / 0.3 → 0.15, Spitter 0.15 → 0.1, HP per meal 35% → 25%. Brood Mothers still gorge.
- Soak-test bot now plays sensibly: it seals three airlocks, keeps turrets inside, and uses the north airlock as the kill zone.

| 3 minutes, headless | Result |
|---|---|
| 240/min, bot | core 6000/6000, 10/10 colonists crewing, 0 stuck |
| 240/min, no player | overrun |
| 480/min, bot | overrun |
| 1,200/min | overrun, 0 stuck |


## M4 – Colonists, abduction, feeding

### Added
- **Colonists** (`colony/colonists.gd`, `data/colonists.json`). There are 10 named contract workers.
  - They shelter in the core and automatically walk out to crew the most valuable uncrewed turrets.
  - **Uncrewed turrets fire at 40%.** Crewed turrets fire at tier crew efficiency (100 / 115 / 130%).
  - Walking uses `AStarGrid2D`. **Blast Doors let colonists through but not aliens.** Unreachable posts are reported.
- **Abduction.**
  - Snatchers and Burrowers grab exposed colonists: anyone walking, bailed out of a destroyed turret, or limping home.
  - The carrier drags them along a **retreat flow field** to the nearest canyon mouth at 70% speed, leaving a blood trail.
  - **Snatchers hunt.** A dedicated hunt flow field around exposed colonists and crewed turrets (rebuilt only when someone moves, radius-capped) leads them in, and they **pull crews out of turrets**.
  - **Turrets prioritise carriers.** Killing a carrier drops the colonist, wounded. They recover in the core for 40 s before returning to duty.
  - If the carrier reaches the edge, the colonist is lost for the run.
- **Mauling.** Maulers (70 damage) and Brood Mothers (250) strike exposed colonists, who have 100 HP.
  - Survivors are knocked down and wounded. The dead leave human remains.
  - Grab immunity (1.5 s) after a rescue or knockdown.
- **Feeding.**
  - Aliens standing on corpses stop to eat (per-strain `feed_rate`; Brood Mothers gorge).
  - Each meal: x1.12 size (cap x1.9) and +35% base HP. **Human remains = 3 meals**, eaten first.
  - Eaten corpses yield nothing and lower piles. Grown aliens leave bigger corpses worth more Biomass.
- **UI.**
  - Colonist bar (alive, crewed/turrets, reserve, carried, recovering, lost).
  - Colony event feed: seized, rescued, mauled, dragged off, back on duty.
  - The Inspector shows the crew name or "UNCREWED – firing at 40%".
- Corpse per-cell index (`corpse_count` grid) so the threaded swarm knows where it can feed.
- Soak report adds colonist and feeding stats.

### Changed
- **Flow-field rebuilds now run as low-priority worker tasks.** Several queued rebuilds (surface, burrow, retreat, hunt) no longer starve the threaded swarm step. Sim p99 went from 25 ms to 10.7 ms on the 4-thread test machine.
- Flow fields accept custom goal sets and a max search distance.

### Measured (headless, slow 4-thread 2.1 GHz cloud CPU)
| Scenario | Result |
|---|---|
| Benchmark 10k with combat + colonists | 115 fps avg, 65 fps 1% low, sim 7.1 ms (p99 10.8) – PASS |
| 3-min soak, bot player, pressure 500 | core held (1471/6000), 7/10 colonists alive and crewing, 4 abductions (all rescued), 3 mauled, 97 meals, largest alien x1.9 |
| 3-min soak, no player, pressure 500 | overrun; 22 abductions, 19 rescued, 3 dragged off |

### Balance notes
- Stalkers do **not** abduct. With 55% of the swarm grabbing people, abductions were constant noise (82 in 3 minutes). Abduction now belongs to Snatchers (hunters) and Burrowers (they surface inside your walls).


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

### Measured (headless 3-minute soaks, swarm pressure 500, slow cloud CPU)
| | No player | Scripted bot (`--bot`) |
|---|---|---|
| Core | overrun | 5708 / 6000, held |
| Biomass collected / spent | 730 / 0 | 1,875 / 2,115 |
| Drone trips / corpses harvested | 45 / 278 | 83 / 545 |
| Upgrades bought | – | 11 structures to tier II (incl. both bays, 6 drones) |
| Swarm sim / combat / fx | 0.7 / 0.03 / 0.15 ms | 1.1 / 0.06 / 0.28 ms |

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
