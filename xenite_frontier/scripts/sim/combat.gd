class_name Combat
extends Node
## Main-thread combat after each swarm step:
##  - a bucket grid (linked lists, rebuilt every frame in one O(n) pass) so
##    turrets query only nearby aliens
##  - damage with the counter matrix (weak 150% / resist 50%), dodge, burrowed
##    immunity (only Seismic reaches underground Burrowers)
##  - swarm events: burn deaths, structure bashing, acid spits, broods, core
##  - projectiles (mortar shells, acid globs)
##  - deferred deaths: removed at end of frame in descending index order so
##    swap-remove never invalidates a pending handle; each leaves gibs,
##    an ichor splat and a corpse that adds to the pile.

const SHIFT := Swarm.SHIFT
const MASK := Swarm.MASK

var swarm: Swarm
var map: OutpostMap
var structures: Structures
var fx: Fx
var corpses: Corpses
var colonists: ColonistSystem
var rng := RandomNumberGenerator.new()

var kills := 0
var kills_by_alien := PackedInt32Array()
var damage_by_type := PackedFloat32Array()   # feeds Hive adaptation (M5)
var dodges := 0
var meals := 0
var biggest := 1.0
var combat_usec := 0

var _head := PackedInt32Array()
var _q := PackedInt32Array()
var _dead := PackedInt32Array()
var _dead_cause := PackedByteArray()
var _despawn := PackedInt32Array()
var _growth := 0.12
var _max_size := 1.9
var _hp_per_meal := 0.35
var _shells: Array[Dictionary] = []
var _acid: Array[Dictionary] = []
var _body_colors: Array[Color] = []


func setup(s: Swarm, m: OutpostMap, st: Structures, effects: Fx, c: Corpses) -> void:
	swarm = s
	map = m
	structures = st
	fx = effects
	corpses = c
	_head.resize(swarm.grid_w * swarm.grid_h)
	kills_by_alien.resize(swarm.pools.size())
	kills_by_alien.fill(0)
	damage_by_type.resize(GameConfig.DMG_COUNT)
	damage_by_type.fill(0.0)
	var fd := GameConfig.feeding
	_growth = float(fd.get("growth_per_meal", _growth))
	_max_size = float(fd.get("max_size", _max_size))
	_hp_per_meal = float(fd.get("hp_per_meal", _hp_per_meal))
	var cols := {"stalker": Color(0.14, 0.1, 0.12), "mauler": Color(0.16, 0.1, 0.11), "spitter": Color(0.14, 0.11, 0.12),
		"snatcher": Color(0.13, 0.1, 0.12), "burrower": Color(0.18, 0.11, 0.1), "brood_mother": Color(0.2, 0.12, 0.15)}
	for p in swarm.pools:
		_body_colors.append(cols.get(p.def.id, Color.GRAY))


func reset_stats() -> void:
	kills = 0
	dodges = 0
	meals = 0
	biggest = 1.0
	_despawn.clear()
	kills_by_alien.fill(0)
	damage_by_type.fill(0.0)
	_shells.clear()
	_acid.clear()
	_dead.clear()
	_dead_cause.clear()


# ------------------------------------------------------------ frame steps

func process_swarm_events() -> void:
	var t0 := Time.get_ticks_usec()
	for h in swarm.out_dead:
		_dead.append(h)
		_dead_cause.append(GameConfig.Dmg.INCENDIARY)
	structures.apply_hits(swarm.out_hit_cell, swarm.out_hit_dmg)
	structures.damage_core(swarm.core_damage)
	var sp := swarm.out_spit
	for k in range(0, sp.size(), 4):
		var from := Vector3(sp[k], 0.9, sp[k + 1])
		var cell := int(sp[k + 2])
		var to := map.cell_ground(cell) + Vector3(0, map.sheight[cell] * 0.7, 0)
		_acid.append({"from": from, "to": to, "t": 0.0, "T": 0.6 + from.distance_to(to) * 0.05, "cell": cell, "dmg": sp[k + 3]})
	var ev := swarm.out_eat
	for k in range(0, ev.size(), 2):
		var m := corpses.eat_one(ev[k + 1])
		if m > 0.0:
			_grow(ev[k], m)
	var br := swarm.out_brood
	for k in range(0, br.size(), 3):
		var mother: AlienPool = swarm.pools[int(br[k + 2])]
		for n in mother.brood_count:
			# brood only lands on open ground (never inside rock or walls)
			var bx := br[k] + rng.randf_range(-1.5, 1.5)
			var bz := br[k + 1] + rng.randf_range(-1.5, 1.5)
			var bc := map.cell_of(Vector3(bx, 0, bz))
			if bc < 0 or map.blocked[bc] or swarm.field.dist[bc] >= FlowField.UNREACHABLE:
				bx = br[k]
				bz = br[k + 1]
			swarm.spawn_at(mother.brood_type, bx, bz)
		fx.burst(Vector3(br[k], 1.0, br[k + 1]), mother.ichor, 8, 3.0, 0.12, 0.6)
	combat_usec = Time.get_ticks_usec() - t0


func build_grid() -> void:
	var t0 := Time.get_ticks_usec()
	var head := _head
	head.fill(-1)
	for p in swarm.pools:
		var n := p.count
		var bk := p.bucket
		var nx := p.lnext
		var hb := p.type_id << SHIFT
		for i in n:
			var b := bk[i]
			nx[i] = head[b]
			head[b] = hb | i
	combat_usec += Time.get_ticks_usec() - t0


func tick_projectiles(dt: float) -> void:
	var i := 0
	while i < _shells.size():
		var s := _shells[i]
		s.t += dt
		var k: float = s.t / s.T
		var from: Vector3 = s.from
		var to: Vector3 = s.to
		var p := from.lerp(to, minf(k, 1.0))
		p.y += sin(minf(k, 1.0) * PI) * (3.0 + from.distance_to(to) * 0.3)
		fx.particle(p, Vector3.ZERO, Color(1.0, 0.75, 0.3, 1.0), 0.18, 0.12, 0.0)
		if k >= 1.0:
			damage_circle(to.x, to.z, s.aoe, s.dmg, s.dtype, s.src if is_instance_valid(s.src) else null)
			fx.burst(to + Vector3(0, 0.3, 0), Color(1.0, 0.82, 0.15, 1.0), 18, 7.0, 0.2, 0.45, 0.4)
			fx.burst(to + Vector3(0, 0.3, 0), Color(0.25, 0.22, 0.2, 0.0), 10, 3.0, 0.4, 1.2, -0.1)
			_shells.remove_at(i)
			continue
		i += 1
	i = 0
	while i < _acid.size():
		var a := _acid[i]
		a.t += dt
		var k: float = a.t / a.T
		var from: Vector3 = a.from
		var to: Vector3 = a.to
		var p := from.lerp(to, minf(k, 1.0))
		p.y += sin(minf(k, 1.0) * PI) * 2.5
		fx.particle(p, Vector3.ZERO, Color(0.5, 1.0, 0.2, 0.9), 0.2, 0.1, 0.0)
		if k >= 1.0:
			structures.damage(a.cell, a.dmg)
			fx.burst(to, Color(0.5, 1.0, 0.2, 0.8), 8, 2.5, 0.1, 0.5, 1.0)
			_acid.remove_at(i)
			continue
		i += 1


## Feeding: the alien grows in size and HP (aliens.json "feeding").
func _grow(h: int, meals_eaten: float) -> void:
	var p := swarm.pools[h >> SHIFT]
	var i := h & MASK
	if i >= p.count or p.hp[i] <= 0.0:
		return
	meals += 1
	var base := float(p.def.size)
	var old := p.size[i]
	var ns := minf(base * _max_size, old * pow(1.0 + _growth, meals_eaten))
	p.size[i] = ns
	p.hp[i] += float(p.def.hp) * _hp_per_meal * meals_eaten
	biggest = maxf(biggest, ns / base)
	var r := ns / old
	var o := i * AlienPool.STRIDE
	for k in [0, 2, 5, 8, 10]:
		p.buf[o + k] *= r
	fx.burst(Vector3(p.px[i], 0.3, p.pz[i]), Color(0.55, 0.05, 0.05, 0.0), 4, 2.0, 0.08, 0.5, 1.0)


## Safety net (call ~once a second): an alien stuck >6 s inside rock or in a
## cell with no path to anything is moved to the nearest reachable open cell,
## or removed if there is none. Returns how many were rescued/removed.
func unstick() -> int:
	var fixed := 0
	var gf := swarm.field
	for p in swarm.pools:
		for i in p.count:
			if p.stuck[i] < 6.0 or p.aux[i] > 0.5:
				continue
			var c := map.cell_of(Vector3(p.px[i], 0, p.pz[i]))
			if c >= 0 and map.kind[c] != OutpostMap.Kind.ROCK and gf.dist[c] < FlowField.UNREACHABLE:
				continue  # crowded but on a valid cell: leave it to the crowd
			var to := _nearest_reachable(c)
			p.stuck[i] = 0.0
			fixed += 1
			if to < 0:
				_despawn.append((p.type_id << SHIFT) | i)
				continue
			var wp := map.cell_center(to)
			p.px[i] = wp.x
			p.pz[i] = wp.z
			p.vx[i] = 0.0
			p.vz[i] = 0.0
	return fixed


func _nearest_reachable(c: int) -> int:
	if c < 0:
		return -1
	var cx := c % map.w
	var cz := c / map.w
	for r in range(1, 7):
		for oz in range(-r, r + 1):
			for ox in range(-r, r + 1):
				if maxi(absi(ox), absi(oz)) != r:
					continue
				var x := cx + ox
				var z := cz + oz
				if not map.in_bounds(x, z):
					continue
				var n := map.idx(x, z)
				if map.kind[n] == OutpostMap.Kind.GROUND and swarm.field.dist[n] < FlowField.UNREACHABLE:
					return n
	return -1


## Removes an alien without a corpse (carrier escaped off the map).
func despawn(h: int) -> void:
	_despawn.append(h)


## Removes everything that died or despawned this frame, in one pass per
## strain in descending index order (swap-remove never moves a pending slot).
## Deaths leave gibs, a splat and a corpse; despawns (carriers escaping off
## the map) leave nothing. A carrier that dies drops its colonist.
func flush_deaths() -> void:
	if _dead.is_empty() and _despawn.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var per_type: Array[PackedInt32Array] = []
	for t in swarm.pools.size():
		per_type.append(PackedInt32Array())
	var cause_of := {}
	for k in _dead.size():
		var h := _dead[k]
		per_type[h >> SHIFT].append((h & MASK) << 1)
		cause_of[h] = _dead_cause[k]
	for h in _despawn:
		per_type[h >> SHIFT].append(((h & MASK) << 1) | 1)
	for t in per_type.size():
		var codes := per_type[t]
		if codes.is_empty():
			continue
		codes.sort()
		var p := swarm.pools[t]
		var height := float(p.def.get("corpse_height", 0.15))
		var last := -1
		for k in range(codes.size() - 1, -1, -1):
			var i := codes[k] >> 1
			if i == last or i >= p.count:
				continue
			last = i
			if codes[k] & 1:
				p.carry[i] = -1
				p.remove(i)
				continue
			var x := p.px[i]
			var z := p.pz[i]
			var sz := p.size[i]
			var big := sz * (3.0 if p.brood_interval > 0.0 else (1.6 if p.def.mass >= 4 else 1.0))
			var charred: bool = cause_of.get((t << SHIFT) | i, -1) == GameConfig.Dmg.INCENDIARY
			if p.carry[i] >= 0 and colonists:
				colonists.drop(p.carry[i], Vector3(x, 0.0, z))
				p.carry[i] = -1
			var gy := map.height_at(x, z)
			fx.gib(Vector3(x, gy, z), _body_colors[t], p.ichor, big)
			_death_special(p, Vector3(x, gy, z), sz)
			corpses.add(t, x, z, p.yaw(i), sz, height * sz, charred)
			kills += 1
			kills_by_alien[t] += 1
			p.remove(i)
	_dead.clear()
	_dead_cause.clear()
	_despawn.clear()
	combat_usec += Time.get_ticks_usec() - t0


## Strain-specific death effects (art direction).
func _death_special(p: AlienPool, at: Vector3, sz: float) -> void:
	match p.def.id:
		"mauler":
			# the shell cracks and its plates scatter
			fx.burst(at + Vector3(0, 1.4, 0), Color(0.12, 0.09, 0.1, 0.0), 10, 5.5, 0.3, 2.5, 1.0, 0.8)
			fx.burst(at + Vector3(0, 1.6, 0), Color(0.6, 0.05, 0.04, 0.3), 5, 5.0, 0.22, 2.5, 1.0, 0.8)
		"spitter":
			# throat sac bursts: acid pool
			fx.burst(at + Vector3(0, 1.7, 0), Color(0.5, 1.0, 0.15, 0.8), 16, 4.0, 0.1, 0.8, 1.0)
			fx.splat(at, Color(0.5, 1.0, 0.15), 1.4, 0.35)
		"brood_mother":
			# the egg sac ruptures and spills dead young
			fx.burst(at + Vector3(0, 1.6, 0), Color(1.0, 0.2, 0.75, 0.6), 24, 6.0, 0.18, 1.2, 1.0)
			for k in 3:
				fx.splat(at + Vector3(rng.randf_range(-1.5, 1.5), 0, rng.randf_range(-2.5, 0.5)), p.ichor, 2.0, 0.1)
			var st := GameConfig.alien_index("stalker")
			for k in 5:
				var a := rng.randf() * TAU
				var r := rng.randf_range(1.0, 2.6)
				corpses.add(st, at.x + cos(a) * r, at.z + sin(a) * r - 1.5, rng.randf() * TAU, 0.38 * sz, 0.03, false)


# ------------------------------------------------------------ queries

func pos_of(h: int) -> Vector3:
	var p := swarm.pools[h >> SHIFT]
	var i := h & MASK
	return Vector3(p.px[i], 0.0, p.pz[i])


## Handles of living aliens within r of (x, z). The returned array is reused:
## copy it before calling another query.
func query_circle(x: float, z: float, r: float, include_burrowed: bool) -> PackedInt32Array:
	_q.clear()
	var gs := 1.0 / swarm.grid_cell
	var gx := x - map.origin.x
	var gz := z - map.origin.y
	var bx0 := maxi(0, int((gx - r) * gs))
	var bx1 := mini(swarm.grid_w - 1, int((gx + r) * gs))
	var bz0 := maxi(0, int((gz - r) * gs))
	var bz1 := mini(swarm.grid_h - 1, int((gz + r) * gs))
	var r2 := r * r
	var pools := swarm.pools
	for bz in range(bz0, bz1 + 1):
		for bx in range(bx0, bx1 + 1):
			var hd := _head[bz * swarm.grid_w + bx]
			while hd != -1:
				var p := pools[hd >> SHIFT]
				var i := hd & MASK
				var dx := p.px[i] - x
				var dz := p.pz[i] - z
				if dx * dx + dz * dz <= r2 and p.hp[i] > 0.0 and (include_burrowed or p.aux[i] < 0.5):
					_q.append(hd)
				hd = p.lnext[i]
	return _q


## Best target in range: the alien closest to the core along the flow field
## ("first" targeting). Underground burrowers are not targetable.
func find_target(x: float, z: float, r: float, min_r: float) -> int:
	var cand := query_circle(x, z, r, false)
	var best := -1
	var best_d := FlowField.UNREACHABLE + 1
	var min2 := min_r * min_r
	var dist := swarm.field.dist
	for h in cand:
		var p := swarm.pools[h >> SHIFT]
		var i := h & MASK
		var dx := p.px[i] - x
		var dz := p.pz[i] - z
		if dx * dx + dz * dz < min2:
			continue
		var c := map.cell_of(Vector3(p.px[i], 0, p.pz[i]))
		var d := dist[c] if c >= 0 else FlowField.UNREACHABLE
		if p.carry[i] >= 0:
			d = -1  # carrying a colonist: kill it first
		if d < best_d:
			best_d = d
			best = h
	return best


# ------------------------------------------------------------ damage

## Applies damage with the counter multiplier. Returns true if it killed.
func damage(h: int, amount: float, dtype: int, dodgeable := false, src: Turret = null) -> bool:
	var t := h >> SHIFT
	var i := h & MASK
	var p := swarm.pools[t]
	if i >= p.count or p.hp[i] <= 0.0:
		return false
	if p.aux[i] > 0.5 and dtype != GameConfig.Dmg.SEISMIC:
		return false
	if dodgeable and p.dodge > 0.0 and rng.randf() < p.dodge:
		dodges += 1
		fx.burst(Vector3(p.px[i], 0.8, p.pz[i]), Color(0.8, 0.7, 1.0, 0.8), 2, 2.0, 0.05, 0.15, 0.0)
		return false
	var dealt := amount * GameConfig.counter[t * GameConfig.DMG_COUNT + dtype]
	var hp := p.hp[i] - dealt
	p.hp[i] = hp
	p.buf[i * AlienPool.STRIDE + 12] = 1.0
	damage_by_type[dtype] += dealt
	if hp <= 0.0:
		_dead.append(h)
		_dead_cause.append(dtype)
		if src:
			src.kills += 1
		return true
	return false


func damage_circle(x: float, z: float, r: float, amount: float, dtype: int, src: Turret = null) -> void:
	var hits := query_circle(x, z, r, dtype == GameConfig.Dmg.SEISMIC).duplicate()
	for h in hits:
		damage(h, amount, dtype, false, src)


func damage_cone(origin: Vector3, dir: Vector3, r: float, cos_half: float, amount: float, dtype: int, burn_time: float, src: Turret = null) -> void:
	var hits := query_circle(origin.x, origin.z, r, false).duplicate()
	for h in hits:
		var p := swarm.pools[h >> SHIFT]
		var i := h & MASK
		var d := Vector3(p.px[i] - origin.x, 0, p.pz[i] - origin.z)
		var l := d.length()
		if l < 0.5 or d.dot(dir) / l >= cos_half:
			if burn_time > 0.0:
				p.burn[i] = maxf(p.burn[i], burn_time)
			damage(h, amount, dtype, false, src)


## Piercing line: hits the first `pierce` aliens within `width` of the ray.
func damage_line(origin: Vector3, dir: Vector3, length: float, width: float, pierce: int, amount: float, dtype: int, dodgeable: bool, src: Turret = null) -> void:
	var mid := origin + dir * length * 0.5
	var hits := query_circle(mid.x, mid.z, length * 0.5 + width, false).duplicate()
	var cand: Array = []
	for h in hits:
		var p := swarm.pools[h >> SHIFT]
		var i := h & MASK
		var rel := Vector3(p.px[i] - origin.x, 0, p.pz[i] - origin.z)
		var along := rel.dot(dir)
		if along < 0.0 or along > length:
			continue
		var perp := (rel - dir * along).length()
		if perp <= width * (1.0 + 0.4 * p.size[i]):
			cand.append([along, h])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	var n := 0
	for e in cand:
		if n >= pierce:
			break
		damage(e[1], amount, dtype, dodgeable and n == 0, src)
		n += 1


func slow(h: int, seconds: float) -> void:
	var p := swarm.pools[h >> SHIFT]
	var i := h & MASK
	p.slow[i] = maxf(p.slow[i], seconds)


## Seismic: forces a tunnelling burrower to the surface for `seconds`.
func surface(h: int, seconds: float) -> void:
	var p := swarm.pools[h >> SHIFT]
	if not p.burrows:
		return
	var i := h & MASK
	if p.aux[i] > 0.5:
		fx.burst(Vector3(p.px[i], 0.2, p.pz[i]), Color(0.45, 0.33, 0.22, 0.0), 6, 4.0, 0.2, 0.8, 1.0)
	p.aux[i] = 0.0
	p.timer[i] = seconds


func launch_shell(from: Vector3, to: Vector3, time: float, amount: float, aoe: float, dtype: int, src: Turret = null) -> void:
	_shells.append({"from": from, "to": to, "t": 0.0, "T": time, "dmg": amount, "aoe": aoe, "dtype": dtype, "src": src})
