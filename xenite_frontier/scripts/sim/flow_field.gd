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
const MAX_CELL_COST := 8
const INV_SQRT2 := 0.70710678

var w := 0
var h := 0
var goals := PackedInt32Array()
# front buffers (read by the swarm)
var dist := PackedInt32Array()
var dir_x := PackedFloat32Array()
var dir_z := PackedFloat32Array()
var build_usec := 0

var _map: OutpostMap
var _task := -1
var _dirty := false
# back buffers (written by the worker)
var _b_dist := PackedInt32Array()
var _b_dx := PackedFloat32Array()
var _b_dz := PackedFloat32Array()
var _b_usec := 0
var _node_cell := PackedInt32Array()
var _node_next := PackedInt32Array()


func _init(map: OutpostMap) -> void:
	_map = map
	w = map.w
	h = map.h
	goals = map.goal_cells
	var n := w * h
	for a in [dist, _b_dist]:
		a.resize(n)
	for a in [dir_x, dir_z, _b_dx, _b_dz]:
		a.resize(n)
	_node_cell.resize(n * 4)
	_node_next.resize(n * 4)


## Blocking rebuild (startup).
func build() -> void:
	_compute(_map.blocked.duplicate(), _map.cost.duplicate())
	_swap()


## Non-blocking rebuild; result appears after a later `poll()`.
func request_rebuild() -> void:
	if _task != -1:
		_dirty = true
		return
	var blk := _map.blocked.duplicate()
	var cst := _map.cost.duplicate()
	_task = WorkerThreadPool.add_task(_compute.bind(blk, cst), true, "flow_field")


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


func _swap() -> void:
	var t := dist; dist = _b_dist; _b_dist = t
	var tx := dir_x; dir_x = _b_dx; _b_dx = tx
	var tz := dir_z; dir_z = _b_dz; _b_dz = tz
	build_usec = _b_usec
	rebuilt.emit()


func _compute(blk: PackedByteArray, cst: PackedByteArray) -> void:
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

	for g in goals:
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
	while pending > 0:
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
	_b_usec = Time.get_ticks_usec() - t0
