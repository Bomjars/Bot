class_name HarvesterSystem
extends Node3D
## Harvester Bays and their drones. Each bay launches drones (2/3/4 by tier)
## that fly to the nearest unclaimed corpse with Biomass inside the bay's
## range, hover over it, strip it (the corpse is removed, lowering its pile),
## keep collecting until full, then fly home and deposit into the Economy.
## Drones are invulnerable for now; if their bay is destroyed they crash and
## the cargo is lost.

enum S { IDLE, OUTBOUND, HARVEST, RETURN, DEPOSIT, CRASH }

class Drone:
	var node: Node3D
	var pos := Vector3.ZERO
	var state := S.IDLE
	var target: Array = []
	var cargo := 0.0
	var timer := 0.0
	var bob := 0.0
	var vel := Vector3.ZERO

class Bay:
	var cell := -1
	var pos := Vector3.ZERO
	var tier := 1
	var drones: Array[Drone] = []

var map: OutpostMap
var corpses: Corpses
var economy: Economy
var fx: Fx
var bays := {}   # cell -> Bay

var speed := 10.0
var altitude := 3.5
var harvest_time := 0.45
var capacity := 24.0
var deposit_time := 0.3
var drones_per_tier: Array = [2, 3, 4]
var range_per_tier: Array = [16.0, 19.0, 22.0]
var range_mult := 1.0      # Colony Charter: Logistics (M6)
var speed_mult := 1.0      # Colony Charter: Logistics (M6)

var trips := 0
var _search_budget := 0
var _drone_mesh: Mesh
var _drone_mat: StandardMaterial3D
var _cargo_mat: StandardMaterial3D


func setup(m: OutpostMap, c: Corpses, e: Economy, effects: Fx) -> void:
	map = m
	corpses = c
	economy = e
	fx = effects
	var h := GameConfig.econ("harvester")
	speed = float(h.get("drone_speed", speed))
	altitude = float(h.get("drone_altitude", altitude))
	harvest_time = float(h.get("harvest_time", harvest_time))
	capacity = float(h.get("capacity", capacity))
	deposit_time = float(h.get("deposit_time", deposit_time))
	drones_per_tier = h.get("drones_per_tier", drones_per_tier)
	range_per_tier = h.get("range_per_tier", range_per_tier)
	_drone_mat = TurretModels.mat(Color(0.75, 0.78, 0.8), 0.0, 0.6)
	_cargo_mat = TurretModels.mat(Color(0.45, 1.0, 0.35), 1.6, 0.0)


func bay_range(tier: int) -> float:
	return float(range_per_tier[clampi(tier - 1, 0, range_per_tier.size() - 1)]) * range_mult


func add_bay(cell: int, tier := 1, pos := Vector3.INF) -> void:
	var b := Bay.new()
	b.cell = cell
	b.pos = pos if pos != Vector3.INF else map.cell_ground(cell)
	b.tier = tier
	bays[cell] = b
	_sync_drones(b)


func set_tier(cell: int, tier: int) -> void:
	if bays.has(cell):
		bays[cell].tier = tier
		_sync_drones(bays[cell])


func remove_bay(cell: int) -> void:
	if not bays.has(cell):
		return
	var b: Bay = bays[cell]
	for d in b.drones:
		corpses.claim(d.target, false)
		d.state = S.CRASH
		d.vel = Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))
		_crash(d)
	bays.erase(cell)


func clear() -> void:
	for b: Bay in bays.values():
		for d in b.drones:
			d.node.queue_free()
	bays.clear()
	trips = 0


func drone_count() -> int:
	var n := 0
	for b: Bay in bays.values():
		n += b.drones.size()
	return n


func cargo_in_flight() -> float:
	var s := 0.0
	for b: Bay in bays.values():
		for d in b.drones:
			s += d.cargo
	return s


func _sync_drones(b: Bay) -> void:
	var want := int(drones_per_tier[clampi(b.tier - 1, 0, drones_per_tier.size() - 1)])
	while b.drones.size() < want:
		var d := Drone.new()
		d.node = _make_drone_node()
		d.pos = b.pos + Vector3(randf_range(-0.5, 0.5), 2.0, randf_range(-0.5, 0.5))
		d.node.position = d.pos
		d.bob = randf() * TAU
		add_child(d.node)
		b.drones.append(d)
	while b.drones.size() > want:
		var d: Drone = b.drones.pop_back()
		corpses.claim(d.target, false)
		d.node.queue_free()


func _make_drone_node() -> Node3D:
	var n := Node3D.new()
	var body := MeshInstance3D.new()
	body.mesh = StationModels.drone_mesh()
	body.material_override = StationModels.station_material()
	n.add_child(body)
	# carried biomass chunk (dark red), grows with the load
	var cargo := TurretModels.part(n, MeshAcc.ball(1.0, 5, 3), TurretModels.mat(Color("8a2b2b"), 0.0, 0.1), Vector3(0, -0.4, 0))
	cargo.name = "Cargo"
	cargo.scale = Vector3.ONE * 0.01
	return n


func tick(dt: float) -> void:
	_search_budget = 4
	for b: Bay in bays.values():
		var r := bay_range(b.tier)
		for d in b.drones:
			_tick_drone(d, b, r, dt)


func _tick_drone(d: Drone, b: Bay, r: float, dt: float) -> void:
	d.bob += dt * 3.0
	var home := b.pos + Vector3(0, 2.2, 0)
	var spd := speed * speed_mult
	match d.state:
		S.IDLE:
			d.pos = d.pos.move_toward(home, spd * dt)
			d.timer -= dt
			if d.timer <= 0.0 and _search_budget > 0:
				_search_budget -= 1
				d.timer = 0.4
				if _pick_target(d, b, r):
					d.state = S.OUTBOUND
		S.OUTBOUND:
			if not corpses.is_valid(d.target):
				d.target = []
				if not _pick_target(d, b, r):
					d.state = S.RETURN if d.cargo > 0.0 else S.IDLE
				return
			var tp := corpses.position_of(d.target) + Vector3(0, 1.6, 0)
			var cruise := Vector3(tp.x, maxf(altitude + map.height_at(d.pos.x, d.pos.z), tp.y), tp.z)
			var flat := Vector2(tp.x - d.pos.x, tp.z - d.pos.z).length()
			var goal := cruise if flat > 1.5 else tp
			d.pos = d.pos.move_toward(goal, spd * dt)
			if d.pos.distance_to(tp) < 0.4:
				d.state = S.HARVEST
				d.timer = harvest_time
		S.HARVEST:
			if not corpses.is_valid(d.target):
				d.state = S.OUTBOUND
				return
			var cp := corpses.position_of(d.target)
			if randf() < 0.6:
				fx.beam(d.pos + Vector3(0, -0.2, 0), cp + Vector3(randf_range(-0.3, 0.3), 0.2, randf_range(-0.3, 0.3)), Color(0.45, 1.0, 0.35, 1.0), 0.05, 0.06)
			d.timer -= dt
			if d.timer <= 0.0:
				var v := corpses.harvest(d.target)
				d.cargo += v
				d.target = []
				fx.burst(cp + Vector3(0, 0.3, 0), Color(0.4, 0.9, 0.3, 0.8), 6, 1.5, 0.08, 0.5, -0.3)
				if d.cargo >= capacity or not _pick_target(d, b, r):
					d.state = S.RETURN
				else:
					d.state = S.OUTBOUND
		S.RETURN:
			var flat := Vector2(home.x - d.pos.x, home.z - d.pos.z).length()
			var goal := Vector3(home.x, altitude + map.height_at(d.pos.x, d.pos.z), home.z) if flat > 1.0 else home
			d.pos = d.pos.move_toward(goal, spd * dt)
			if d.pos.distance_to(home) < 0.3:
				d.state = S.DEPOSIT
				d.timer = deposit_time
		S.DEPOSIT:
			d.timer -= dt
			if d.timer <= 0.0:
				if d.cargo > 0.0:
					economy.deposit(d.cargo, b.pos + Vector3(0, 2.5, 0))
					trips += 1
				d.cargo = 0.0
				d.state = S.IDLE
				d.timer = 0.0
	# visuals
	d.node.position = d.pos + Vector3(0, sin(d.bob) * 0.08, 0)
	var cg: Node3D = d.node.get_node("Cargo")
	cg.scale = Vector3.ONE * (0.01 + 0.16 * clampf(d.cargo / capacity, 0.0, 1.0))


func _pick_target(d: Drone, b: Bay, r: float) -> bool:
	var ref := corpses.find_harvestable(b.pos, r, d.pos)
	if ref.is_empty():
		return false
	corpses.claim(ref, true)
	d.target = ref
	return true


func _crash(d: Drone) -> void:
	fx.burst(d.pos, Color(0.7, 0.7, 0.7, 0.0), 6, 3.0, 0.12, 1.5, 1.0)
	fx.burst(d.pos, Color(1.0, 0.6, 0.2, 1.0), 6, 4.0, 0.08, 0.4, 0.5)
	d.node.queue_free()
