# Xenite Frontier

*Horde tower defence. Contracted colonists hold remote mining outposts against
a starving, predatory alien swarm.*

Engine: **Godot 4.4** (GDScript, Forward+). Original placeholder art built from
low-poly primitives at runtime; no imported assets.

---

## Current milestone: **M1 – swarm & flow field benchmark**

M1 is a test range, not the game yet. It proves the core tech: **10,000+
aliens** steering by a shared flow field and rendered via one MultiMesh per strain.

### Running

1. Install Godot **4.4.x** (standard build, not .NET).
2. Open `xenite_frontier/project.godot` in the editor and press **F5**, or run:

```bash
godot --path xenite_frontier
```

### Benchmark

Press **B** in game. The run ramps to 10,000 aliens over 6 s, settles for 2 s,
then records 20 s. VSync and the FPS cap are switched off while it records so
the numbers show real headroom. The report shows avg FPS, 1% low, swarm-sim ms,
buffer upload ms and GPU ms. It is also appended to `user://benchmark.log`.
On Linux that is `~/.local/share/godot/app_userdata/Xenite Frontier/benchmark.log`.
On Windows it is `%APPDATA%\Godot\app_userdata\Xenite Frontier\benchmark.log`.

From the command line (prints the report and quits; exit code 0 = pass, 2 = below 60 fps 1% low):

```bash
godot --path xenite_frontier -- --benchmark
```

```bash
godot --path xenite_frontier -- --benchmark=20000
```

```bash
godot --headless --path xenite_frontier -- --benchmark
```

The last form is CPU only (no rendering): it measures the simulation alone.

Benchmark settings live in `data/game_config.json → benchmark`.

### Controls (M1)

| Action | Keyboard / mouse | Gamepad |
|---|---|---|
| Pan camera | WASD / arrows / screen edge / middle-drag | Left stick |
| Fast pan | Shift | L3 |
| Zoom | Mouse wheel / Q, E | LT / RT |
| Place / remove wall | Left click | A (at screen centre) |
| Flow-field heatmap | F | X |
| Run benchmark | B | Y |
| Alien count presets | 1 / 2 / 3 / 4 = 1k / 5k / 10k / 20k | – |
| ±1000 aliens | + / − | RB / LB |
| Pause simulation | Space | Start |
| Reset walls | R | – |
| Hide HUD | F1 | Back |

Walls you place re-route the whole horde. The flow field is rebuilt on a
worker thread and swapped in, so wall changes never stall a frame.

---

## Architecture

```
xenite_frontier/
  project.godot
  data/
    aliens.json        strain stats, counters (weak/resists), spawn weights
    game_config.json   benchmark / swarm / map tuning
  scenes/main.tscn     root; everything else is built in code
  scripts/
    core/game_config.gd   autoload: loads all data files
    core/input_setup.gd   default key/mouse/pad bindings (rebindable later)
    sim/flow_field.gd     Dijkstra bucket-queue flow field, async rebuild
    sim/alien_pool.gd     struct-of-arrays storage per strain + MultiMesh
    sim/swarm.gd          threaded per-chunk swarm step
    render/alien_meshes.gd   procedural predator silhouettes
    render/alien.gdshader    faceted shading, GPU gait, hit-flash channel
    render/ground.gdshader
    world/outpost_map.gd  grid (ground/rock/wall), spawn zones, core, visuals
    camera/rts_camera.gd  angled top-down camera
    ui/benchmark_*.gd     HUD + scripted benchmark
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
- [ ] **M2** Walls, turrets, damage types and counter table, death, corpse piling
- [ ] **M3** Biomass economy, harvester drones, in-run turret tiers
- [ ] **M4** Colonists, abduction, feeding
- [ ] **M5** Build/battle phases, waves, day/night, abilities, Threat Level
- [ ] **M6** Xenite, Colony Charter, specialisations, Hazard Contracts, save/load
- [ ] **M7** Gore/juice pass, 3 outposts, balance pass
- [ ] **M8** Steam (GodotSteam), achievements, cloud saves, Deck/controller, export + upload scripts

See `CHANGELOG.md` for per-milestone notes.
