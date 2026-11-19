# Xenite Frontier

*Horde tower defence. Contracted colonists hold remote mining outposts against
a starving, predatory alien swarm.*

Engine: **Godot 4.4** (GDScript, Forward+). Original placeholder art built from
low-poly primitives at runtime; no imported assets.

---

## Current milestone: **M2 – walls, turrets, counters, death, corpse piles**

M2 turns the test range into a combat sandbox. The swarm flows endlessly from
three canyon mouths toward the outpost core. You hold it with walls, blast
doors and the six turret types. Economy (Biomass), colonists, waves and the
meta progression arrive in M3 to M6, so building is free for now.

### Running

1. Install Godot **4.4.x** (standard build, not .NET).
2. **First run after cloning or pulling:** import the project once so Godot
   builds its script class cache (`.godot/`, not in git). Opening the project
   in the editor does this automatically. Without it a fresh clone fails with
   `Identifier "InputSetup" not declared`.

```bash
godot --headless --path xenite_frontier --import
```

3. Run the game:

```bash
godot --path xenite_frontier
```

On Windows, `run_benchmark.bat` does the import and runs the benchmark:

```bash
xenite_frontier\run_benchmark.bat "C:\path\to\Godot_v4.4.1-stable_win64_console.exe"
```

### Controls (M2)

| Action | Keyboard / mouse | Gamepad |
|---|---|---|
| Pick build tool | 1-8 (Tab cycles) | LB / RB |
| Build (drag to paint walls/doors) | Left click | A (at screen-centre crosshair) |
| Demolish (drag) | Right click | B |
| Deselect tool | Esc | – |
| Intel: counter table | I | D-pad right |
| Swarm pressure ±500 | + / − | D-pad up / down |
| Swarm pressure 1k / 5k / 10k / 20k | F5 / F6 / F7 / F8 | – |
| Pan camera | WASD / arrows / screen edge / middle-drag | Left stick |
| Fast pan | Shift | L3 |
| Zoom | Mouse wheel / Q, E | LT / RT |
| Flow-field heatmap | F | X |
| Gore on/off | G | – |
| Pause simulation | Space | Start |
| Reset outpost | R | – |
| Run benchmark | B | Y |
| Detailed perf HUD | F1 | Back |

Hovering a turret, or holding a turret tool, shows its range ring. The
build bar's info card lists every tool's counters, so you never need to hover.

### Damage types and counters

Weak = 150% damage, resists = 50%. This lives in `data/aliens.json` and is
shown in game in the build card and the Intel panel (**I**).

| Strain | Trait | Weak to | Resists |
|---|---|---|---|
| Stalker | fast swarm, low HP | Incendiary, Shock | Piercing |
| Mauler | armoured; x4 damage to blast doors | Piercing | Ballistic |
| Spitter | stops at range and lobs acid at structures | Explosive | Shock |
| Snatcher | fast; dodges 35% of aimed shots | Shock, Ballistic | Explosive |
| Burrower | tunnels under walls; only Seismic reaches it underground | Seismic | Incendiary |
| Brood Mother | boss; births Stalker broods | Piercing, Explosive | Shock |

| Turret | Type | Behaviour |
|---|---|---|
| Autocannon | Ballistic | rapid aimed shots (dodgeable) |
| Flamethrower | Incendiary | cone that sets aliens burning; incendiary kills leave charred corpses |
| Railgun | Piercing | long-range slug through up to 5 aliens in a line |
| Shock Grid | Shock | arcs into up to 14 nearby aliens and slows them |
| Mortar | Explosive | lobbed splash shells, 6 m minimum range, out-ranges Spitters |
| Seismic Spike | Seismic | ground slam that hits tunnelling Burrowers and forces them up |

### How the swarm fights structures
* **The flow field paths *through* structures at a cost.** A wall costs 24
  metres of detour. If the way around is longer, the field leads into the wall
  and aliens bash it. Seal the outpost completely and they pick the cheapest
  wall and pile in.
* **Corpses pile up physically.** Each corpse adds height to its cell
  (Stalker 0.14 m up to Brood Mother 1.2 m) and rests on top of the pile.
  When a pile beside a wall reaches **1.6 m**, the wall becomes climbable.
  It tints green, its path cost drops, and the swarm streams over the top.
  Clear kill zones away from your walls.
* **Spitters** stop up to 9 m short and shell structures with acid.
  **Burrowers** follow a second flow field where only rock blocks, and surface
  8 m from the core or when a Seismic Spike slams them.
  **Brood Mothers** spawn 4 Stalkers every 7 s.
* Losing the core = **OUTPOST OVERRUN**. Press **R** to rebuild.

### Benchmark

Press **B** in game. The run ramps to 10,000 aliens over 6 s, settles for 2 s,
then records 20 s. During the run the core is invulnerable, aliens that reach
it are recycled, and turrets keep fighting, so the figures include combat.
VSync and the FPS cap are switched off while it records. The report is
appended to `user://benchmark.log`.
On Windows that is `%APPDATA%\Godot\app_userdata\Xenite Frontier\benchmark.log`.

```bash
godot --path xenite_frontier -- --benchmark
```

```bash
godot --path xenite_frontier -- --benchmark=20000
```

Exit code 0 = pass, 2 = 1% low below 60 fps. Add `--headless` to measure the
simulation alone, without rendering.

Headless combat soak (prints kills by strain and turret, damage share, core HP):

```bash
godot --headless --path xenite_frontier -- --aliens=3000 --combat-test=60
```

---

## Architecture

```
xenite_frontier/
  project.godot
  data/
    aliens.json        strain stats, traits, counters (weak/resists), spawn weights
    turrets.json       damage types, counter multipliers, turret stats
    structures.json    walls, blast doors, core HP, climb height
    game_config.json   benchmark / swarm / combat caps / map tuning
  scenes/main.tscn     root; everything else is built in code
  scripts/
    core/game_config.gd   autoload: loads all data files
    core/input_setup.gd   default key/mouse/pad bindings (rebindable later)
    sim/flow_field.gd     cost-based Dijkstra flow field (surface + burrow), async rebuild
    sim/alien_pool.gd     struct-of-arrays storage per strain + MultiMesh
    sim/swarm.gd          threaded per-chunk swarm step incl. strain traits
    sim/combat.gd         spatial grid, damage/counters, projectiles, deaths
    turrets/turret.gd     six turret behaviours
    turrets/turret_models.gd  primitive turret models
    world/structures.gd   walls/doors/turrets: HP, placement, destruction
    world/corpses.gd      pooled corpses + pile heights
    render/alien_meshes.gd   procedural predator silhouettes
    render/alien.gdshader    faceted shading, GPU gait, hit-flash channel
    render/fx.gd / fx.gdshader  pooled particles, beams, ichor splats
    render/ground.gdshader
    world/outpost_map.gd  grid (ground/rock/wall), spawn zones, core, visuals
    camera/rts_camera.gd  angled top-down camera
    ui/hud.gd, build_bar.gd, ui_style.gd   HUD, build bar, Intel panel
    ui/benchmark_runner.gd  scripted benchmark
```

### How 10k aliens stay cheap
* **No per-unit pathfinding.** One flow field covers the whole map. It is an
  8-connected Dijkstra pass from the outpost core using an O(cells) bucket queue,
  then one direction per cell. Each alien reads its cell. A rebuild costs the
  same at 10 aliens or 100,000.
* **Struct-of-arrays pools** (`PackedFloat32Array`) per strain, dense with
  swap-remove. No nodes, no objects, no allocations per alien.
* **Crowd separation without neighbour queries.** Aliens splat their mass
  into a 0.5 m density grid. Next frame each alien is pushed down the density
  gradient, plus a spread within its cell. This is O(1) per alien and produces
  the piling, pressing horde look.
* **Threaded.** Each frame the swarm is cut into 1,024-alien chunks that run on
  `WorkerThreadPool`.
* **One upload per strain.** The simulation writes transforms straight into the
  MultiMesh buffer, which goes to the GPU with a single `multimesh_set_buffer`
  call. That gives 6 draw calls for the whole swarm.
* **Animation on the GPU.** Gait swing and bob happen in the vertex shader,
  phased by `INSTANCE_ID`.

### Alien silhouettes
| Strain | Read it by |
|---|---|
| Stalker | low, long, bone-yellow, back spines, red maw |
| Mauler | hulking rust-red block, huge forearms, grey plates |
| Spitter | thin grey body under a glowing green acid sac |
| Snatcher | tall violet stick-figure, long hooked arms |
| Burrower | flat orange segmented grub, steel drill head |
| Brood Mother | huge crimson-magenta abdomen, glowing egg sacs, bone crown |

---

## Roadmap
- [x] **M1** 10k aliens via flow field, perf benchmark
- [x] **M2** Walls, turrets, damage types and counter table, death, corpse piling
- [ ] **M3** Biomass economy, harvester drones, in-run turret tiers
- [ ] **M4** Colonists, abduction, feeding
- [ ] **M5** Build/battle phases, waves, day/night, abilities, Threat Level
- [ ] **M6** Xenite, Colony Charter, specialisations, Hazard Contracts, save/load
- [ ] **M7** Gore/juice pass, 3 outposts, balance pass
- [ ] **M8** Steam (GodotSteam), achievements, cloud saves, Deck/controller, export + upload scripts

See `CHANGELOG.md` for per-milestone notes.

## Screenshots (software-rendered)

![M2 combat: the swarm floods the airlocks while the demo battery fires](docs/m2_combat.png)
![M2 breach: Maulers and Stalkers pour through the north airlock over corpse piles](docs/m2_breach.png)
![M2 Intel panel and build card with counters](docs/m2_intel.png)

![Horde streaming into the compound](docs/m1_overview.png)
![Strain silhouettes](docs/m1_strains.png)
