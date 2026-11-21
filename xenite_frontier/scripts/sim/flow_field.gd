class_name FlowField
extends RefCounted
## Single shared flow field: one Dijkstra pass from the goal cells (8-connected,
## no corner cutting, integer costs via a bucket queue = O(cells)), then one
## direction vector per cell. Every alien just samples its cell - no per-unit
## pathfinding, so cost is independent of alien count.
##
## Rebuilds run on a worker thread into back buffers and are swapped in on the
## main thread (`poll()`), so placing or destroying walls never hitches a frame.

signal rebuilt

const UNREACHABLE := 1 << 29
const ORTHO := 10
const DIAG := 14
const MAX_CELL_COST := 32
const INV_SQRT2 := 0.70710678

var w := 0
var h := 0
var goals := PackedInt32Array()
# front buffers (read by the swarm)
var dist := PackedInt32Array()
var dir_x := PackedFloat32Array()
var dir_z := PackedFloat32Array()
var build_usec := 0
## stop expanding beyond this distance (0 = whole map). Cells further away
## stay UNREACHABLE. Used by the hunt field (Snatchers only look 14 m).
var max_dist := 0

var _map: OutpostMap
var _cost_name := "nav_cost"
var _task := -1
var _dirty := false
# back buffers (written by the worker)
var _b_dist := PackedInt32Array()
var _b_dx := PackedFloat32Array()
var _b_dz := PackedFloat32Array()
var _b_usec := 0
var _node_cell := PackedInt32Array()
var _node_next := PackedInt32Array()


## cost_name: which OutpostMap cost array to path over ("nav_cost" for the
## surface swarm, "burrow_cost" for tunnellers). Cost 0 = impassable.
## goals: cells with distance 0 (default: the outpost core). Can be changed
## later with set_goals() (hunt field follows colonists).
func _init(map: OutpostMap, cost_name := "nav_cost", goal_cells := PackedInt32Array()) -> void:
	_map = map
	_cost_name = cost_name
	w = map.w
	h = map.h
	goals = goal_cells if not goal_cells.is_empty() else map.goal_cells
	var n := w * h
	for a in [dist, _b_dist]:
		a.resize(n)
	for a in [dir_x, dir_z, _b_dx, _b_dz]:
		a.resize(n)
	_node_cell.resize(n * 4)
	_node_next.resize(n * 4)


## Blocking rebuild (startup).
func build() -> void:
	_compute(_costs(), goals.duplicate())
	_swap()


## Non-blocking rebuild; result appears after a later `poll()`.
func request_rebuild() -> void:
	if _task != -1:
		_dirty = true
		return
	# low priority: Godot caps these to a fraction of the pool, so several
	# queued rebuilds never starve the threaded swarm step
	_task = WorkerThreadPool.add_task(_compute.bind(_costs(), goals.duplicate()), false, "flow_field")


func busy() -> bool:
	return _task != -1


func poll() -> void:
	if _task == -1 or not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_swap()
	if _dirty:
		_dirty = false
		request_rebuild()


func _costs() -> PackedByteArray:
	var a: PackedByteArray = _map.get(_cost_name)
	return a.duplicate()


func _swap() -> void:
	var t := dist; dist = _b_dist; _b_dist = t
	var tx := dir_x; dir_x = _b_dx; _b_dx = tx
	var tz := dir_z; dir_z = _b_dz; _b_dz = tz
	build_usec = _b_usec
	rebuilt.emit()


func set_goals(g: PackedInt32Array) -> void:
	goals = g


func _compute(cst: PackedByteArray, goal_list: PackedInt32Array) -> void:
	# impassable mask derived from cost (0 = impassable)
	var blk := PackedByteArray()
	blk.resize(cst.size())
	for c in cst.size():
		blk[c] = 1 if cst[c] == 0 else 0
	var t0 := Time.get_ticks_usec()
	var ww := w
	var hh := h
	var n := ww * hh
	var d := _b_dist
	d.fill(UNREACHABLE)
	var kb := DIAG * MAX_CELL_COST + 1
	var heads := PackedInt32Array()
	heads.resize(kb)
	heads.fill(-1)
	var ncell := _node_cell
	var nnext := _node_next
	var cap := ncell.size()
	var nn := 0
	var pending := 0

	for g in goal_list:
		if blk[g] == 0:
			d[g] = 0
			ncell[nn] = g
			nnext[nn] = heads[0]
			heads[0] = nn
			nn += 1
			pending += 1

	# Border cells are always rock on our maps except canyon mouths, so neighbour
	# bounds are checked once per cell (edge flag) instead of per neighbour.
	var cur := 0
	var limit := max_dist if max_dist > 0 else UNREACHABLE
	while pending > 0:
		if cur > limit:
			break
		var b := cur % kb
		var node := heads[b]
		if node == -1:
			cur += 1
			continue
		heads[b] = nnext[node]
		pending -= 1
		var c := ncell[node]
		if d[c] != cur:
			continue
		var cx := c % ww
		var cz := c / ww
		var l := cx > 0
		var r := cx < ww - 1
		var u := cz > 0
		var dn := cz < hh - 1
		var fl := l and blk[c - 1] == 0
		var fr := r and blk[c + 1] == 0
		var fu := u and blk[c - ww] == 0
		var fd := dn and blk[c + ww] == 0
		if nn + 8 >= cap:
			cap *= 2
			ncell.resize(cap)
			nnext.resize(cap)
		var nc: int
		var nd: int
		if fl:
			nc = c - 1; nd = cur + ORTHO * cst[nc]
			if nd < d[nc]:
				d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fr:
			nc = c + 1; nd = cur + ORTHO * cst[nc]
			if nd < d[nc]:
				d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fu:
			nc = c - ww; nd = cur + ORTHO * cst[nc]
			if nd < d[nc]:
				d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fd:
			nc = c + ww; nd = cur + ORTHO * cst[nc]
			if nd < d[nc]:
				d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fl and fu:
			nc = c - ww - 1
			if blk[nc] == 0:
				nd = cur + DIAG * cst[nc]
				if nd < d[nc]:
					d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fr and fu:
			nc = c - ww + 1
			if blk[nc] == 0:
				nd = cur + DIAG * cst[nc]
				if nd < d[nc]:
					d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fl and fd:
			nc = c + ww - 1
			if blk[nc] == 0:
				nd = cur + DIAG * cst[nc]
				if nd < d[nc]:
					d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1
		if fr and fd:
			nc = c + ww + 1
			if blk[nc] == 0:
				nd = cur + DIAG * cst[nc]
				if nd < d[nc]:
					d[nc] = nd; ncell[nn] = nc; nnext[nn] = heads[nd % kb]; heads[nd % kb] = nn; nn += 1; pending += 1

	# Direction to the lowest-distance legal neighbour. Aliens standing inside a
	# freshly placed wall get a direction out of it (any free neighbour).
	var dx := _b_dx
	var dz := _b_dz
	dx.fill(0.0)
	dz.fill(0.0)
	for c in n:
		var inside := blk[c] == 1
		var best := d[c]
		if inside:
			best = UNREACHABLE
		elif best == 0 or best >= UNREACHABLE:
			continue
		var cx := c % ww
		var cz := c / ww
		if cx == 0 or cz == 0 or cx == ww - 1 or cz == hh - 1:
			# map edge (canyon mouths open onto it): bounds-checked slow path
			_edge_dir(c, cx, cz, d, blk, dx, dz, inside)
			continue
		var fl := blk[c - 1] == 0
		var fr := blk[c + 1] == 0
		var fu := blk[c - ww] == 0
		var fd := blk[c + ww] == 0
		var bx := 0.0
		var bz := 0.0
		if fl and d[c - 1] < best: best = d[c - 1]; bx = -1.0; bz = 0.0
		if fr and d[c + 1] < best: best = d[c + 1]; bx = 1.0; bz = 0.0
		if fu and d[c - ww] < best: best = d[c - ww]; bx = 0.0; bz = -1.0
		if fd and d[c + ww] < best: best = d[c + ww]; bx = 0.0; bz = 1.0
		var diag_ok := inside
		if (fl and fu) or diag_ok:
			var k := c - ww - 1
			if blk[k] == 0 and d[k] < best: best = d[k]; bx = -INV_SQRT2; bz = -INV_SQRT2
		if (fr and fu) or diag_ok:
			var k := c - ww + 1
			if blk[k] == 0 and d[k] < best: best = d[k]; bx = INV_SQRT2; bz = -INV_SQRT2
		if (fl and fd) or diag_ok:
			var k := c + ww - 1
			if blk[k] == 0 and d[k] < best: best = d[k]; bx = -INV_SQRT2; bz = INV_SQRT2
		if (fr and fd) or diag_ok:
			var k := c + ww + 1
			if blk[k] == 0 and d[k] < best: best = d[k]; bx = INV_SQRT2; bz = INV_SQRT2
		dx[c] = bx
		dz[c] = bz
	_smooth(blk, dx, dz)
	_b_usec = Time.get_ticks_usec() - t0


## Direction for a cell on the map border (neighbours may be off-map).
func _edge_dir(c: int, cx: int, cz: int, d: PackedInt32Array, blk: PackedByteArray,
		dx: PackedFloat32Array, dz: PackedFloat32Array, inside: bool) -> void:
	var best := UNREACHABLE if inside else d[c]
	var bx := 0.0
	var bz := 0.0
	for oz in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oz == 0:
				continue
			var nx := cx + ox
			var nz := cz + oz
			if nx < 0 or nz < 0 or nx >= w or nz >= h:
				continue
			var nc := nz * w + nx
			if blk[nc]:
				continue
			if ox != 0 and oz != 0 and not inside and (blk[cz * w + nx] or blk[nz * w + cx]):
				continue
			if d[nc] < best:
				best = d[nc]
				var l := sqrt(float(ox * ox + oz * oz))
				bx = ox / l
				bz = oz / l
	dx[c] = bx
	dz[c] = bz


## One box-blur pass over free cells turns the 8-way "lanes" Dijkstra produces
## into broad, curving streams so the horde spreads across a corridor.
func _smooth(blk: PackedByteArray, dx: PackedFloat32Array, dz: PackedFloat32Array) -> void:
	var ww := w
	var n := ww * h
	var sx := dx.duplicate()
	var sz := dz.duplicate()
	for c in range(ww + 1, n - ww - 1):
		if blk[c] or (sx[c] == 0.0 and sz[c] == 0.0):
			continue
		var ax := sx[c] * 2.0
		var az := sz[c] * 2.0
		if blk[c - 1] == 0: ax += sx[c - 1]; az += sz[c - 1]
		if blk[c + 1] == 0: ax += sx[c + 1]; az += sz[c + 1]
		if blk[c - ww] == 0: ax += sx[c - ww]; az += sz[c - ww]
		if blk[c + ww] == 0: ax += sx[c + ww]; az += sz[c + ww]
		var l := sqrt(ax * ax + az * az)
		if l > 0.001:
			dx[c] = ax / l
			dz[c] = az / l
