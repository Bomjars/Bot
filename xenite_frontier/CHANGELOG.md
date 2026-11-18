# Changelog

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
| 10,000 | 145 | 134 | 4.0 ms / 6.1 ms |
| 20,000 | 142 | 90 | 6.4 ms / 9.9 ms |

Flow field rebuild (200x140 cells): ~54 ms on a worker thread, with no frame hitch.
GPU cost depends on your card. Run `B` in a windowed build to measure it.

### Known limitations (by design for M1)
- Aliens that reach the core are recycled to a canyon mouth; there is no damage or death yet (M2).
- Aliens treat walls as impassable. Breaching, climbing piles and burrowing come in M2–M4.
