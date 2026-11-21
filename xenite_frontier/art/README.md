# Custom art drop-in

Put `.glb` / `.gltf` models here, then point a strain at one in `data/aliens.json`:

```json
{ "id": "stalker", "mesh": "res://art/stalker.glb", ... }
```

## Requirements
- Face **+Z**, feet on **y = 0**, 1 unit = 1 metre.
- One mesh, ideally ~1,000 triangles or fewer. Every alien on screen draws it,
  and there can be 10,000.
- **Colour**: vertex colours (sRGB) are used as albedo. Vertex alpha below 1
  makes that part glow (eyes, sacs).
- **Animation**: the GPU rig reads a *part id* from **UV.x** of every vertex:
  `0` torso, `1` head, `2`/`3` upper arm L/R, `4`/`5` forearm L/R,
  `6`/`7` thigh L/R, `8`/`9` shin L/R, `10` static, `11` tail/abdomen.
  Joint heights come from the strain's rig (`AlienMeshes.rig()`), so match the
  procedural proportions or adjust `_cfg()` for that strain. A model without
  part ids still renders, but it glides without limb animation.

Godot imports files in this folder automatically. Re-run
`godot --headless --path xenite_frontier --import` after adding new ones.
