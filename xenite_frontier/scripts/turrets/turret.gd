class_name Turret
extends Node3D
## One turret: reads its stats from data/turrets.json and fires using Combat's
## spatial queries. Six behaviours, one per damage type:
##   autocannon  rapid aimed shots (dodgeable)
##   flamethrower cone, sets burning
##   railgun     piercing line through up to N aliens (dodgeable)
##   shock_grid  arcs into up to N nearby aliens, slows them
##   mortar      lobbed shell, area damage, minimum range
##   seismic     ground slam incl. tunnelling burrowers, forces them up

var def: Dictionary
var cell := -1
var dtype := 0
var cooldown := 0.0
var kills := 0
var accent := Color.WHITE
var head: Node3D
var muzzle: Node3D
var base_mat: StandardMaterial3D
var crew_efficiency := 1.0   # M4: uncrewed turrets fire at 40%
var _slam := 0.0


func setup(d: Dictionary, c: int, pos: Vector3) -> void:
	def = d
	cell = c
	position = pos
	dtype = GameConfig.damage_index(d.damage_type)
	accent = GameConfig.damage_color(dtype)
	var parts := TurretModels.build(self, d.id, accent)
	base_mat = parts[0]
	head = parts[1]
	muzzle = parts[2]
	cooldown = randf() * 0.5


func set_health_ratio(r: float) -> void:
	base_mat.albedo_color = Color(0.42, 0.45, 0.48).lerp(Color(0.5, 0.12, 0.05), 1.0 - r)


func range_m() -> float:
	return float(def.range)


func tick(dt: float, combat: Combat) -> void:
	if _slam > 0.0:
		_slam = maxf(0.0, _slam - dt * 3.0)
		head.position.y = 0.55 + _slam
	cooldown -= dt
	if cooldown > 0.0:
		return
	var rate := float(def.fire_rate) * crew_efficiency
	var fired := false
	match def.id:
		"autocannon": fired = _fire_single(combat, Color(1.0, 0.85, 0.35, 0.9), 0.06, 0.05)
		"railgun": fired = _fire_rail(combat)
		"flamethrower": fired = _fire_flame(combat)
		"shock_grid": fired = _fire_shock(combat)
		"mortar": fired = _fire_mortar(combat)
		"seismic_spike": fired = _fire_seismic(combat)
	cooldown = (1.0 / rate) if fired else 0.15


func _aim(at: Vector3) -> Vector3:
	var d := at - global_position
	d.y = 0.0
	if d.length_squared() > 0.0001:
		head.rotation.y = atan2(d.x, d.z)
	return d.normalized()


func _fire_single(combat: Combat, col: Color, width: float, life: float) -> bool:
	var p := global_position
	var h := combat.find_target(p.x, p.z, float(def.range), 0.0)
	if h < 0:
		return false
	var tp := combat.pos_of(h) + Vector3(0, 0.5, 0)
	_aim(tp)
	var from := muzzle.global_position
	combat.fx.beam(from, tp, col, width, life)
	if combat.damage(h, float(def.damage), dtype, bool(def.get("dodgeable", false)), self):
		pass
	combat.fx.burst(tp, Color(1.0, 0.8, 0.3, 1.0), 2, 3.0, 0.06, 0.15, 0.5)
	return true


func _fire_rail(combat: Combat) -> bool:
	var p := global_position
	var h := combat.find_target(p.x, p.z, float(def.range), 0.0)
	if h < 0:
		return false
	var dir := _aim(combat.pos_of(h))
	var from := muzzle.global_position
	var to := from + dir * float(def.range)
	combat.damage_line(p, dir, float(def.range), float(def.width), int(def.pierce), float(def.damage), dtype, bool(def.get("dodgeable", false)), self)
	combat.fx.beam(from, Vector3(to.x, 0.5, to.z), Color(0.45, 0.8, 1.0, 1.0), 0.22, 0.3)
	combat.fx.burst(from, Color(0.6, 0.9, 1.0, 1.0), 6, 4.0, 0.08, 0.25, 0.0)
	return true


func _fire_flame(combat: Combat) -> bool:
	var p := global_position
	var h := combat.find_target(p.x, p.z, float(def.range), 0.0)
	if h < 0:
		return false
	var dir := _aim(combat.pos_of(h))
	var half := deg_to_rad(float(def.cone_deg) * 0.5)
	combat.damage_cone(p, dir, float(def.range), cos(half), float(def.damage), dtype, float(def.burn_time), self)
	var from := muzzle.global_position
	var fx := combat.fx
	for k in 4:
		var a := fx.rng.randf_range(-half, half)
		var d := dir.rotated(Vector3.UP, a)
		var col := Color(1.0, fx.rng.randf_range(0.3, 0.7), 0.1, 1.0)
		fx.particle(from, d * float(def.range) * fx.rng.randf_range(1.4, 2.0) + Vector3(0, 0.6, 0), col, 0.3, 0.45, -0.15)
	return true


func _fire_shock(combat: Combat) -> bool:
	var p := global_position
	var hits := combat.query_circle(p.x, p.z, float(def.range), false)
	if hits.is_empty():
		return false
	var n := mini(hits.size(), int(def.max_targets))
	var top := muzzle.global_position
	var col := Color(accent.r, accent.g, accent.b, 1.0)
	var victims := hits.slice(0, n)
	for k in victims.size():
		var hdl := victims[k]
		if k < 8:
			combat.fx.arc(top, combat.pos_of(hdl) + Vector3(0, 0.5, 0), col)
		combat.slow(hdl, float(def.slow_time))
		combat.damage(hdl, float(def.damage), dtype, false, self)
	return true


func _fire_mortar(combat: Combat) -> bool:
	var p := global_position
	var h := combat.find_target(p.x, p.z, float(def.range), float(def.get("min_range", 0.0)))
	if h < 0:
		return false
	var tp := combat.pos_of(h)
	_aim(tp)
	combat.launch_shell(muzzle.global_position, tp, float(def.shell_time), float(def.damage), float(def.aoe), dtype, self)
	combat.fx.burst(muzzle.global_position, Color(1.0, 0.8, 0.4, 1.0), 5, 3.0, 0.1, 0.25, 0.0)
	return true


func _fire_seismic(combat: Combat) -> bool:
	var p := global_position
	var hits := combat.query_circle(p.x, p.z, float(def.range), true)
	if hits.is_empty():
		return false
	var victims := hits.duplicate()
	for hdl in victims:
		combat.surface(hdl, float(def.surface_time))
		combat.damage(hdl, float(def.damage), dtype, false, self)
	_slam = 0.5
	var fx := combat.fx
	var r := float(def.range)
	for k in 28:
		var a := TAU * k / 28.0
		var d := Vector3(cos(a), 0, sin(a))
		fx.particle(p + d * 0.6 + Vector3(0, 0.1, 0), d * r * 1.6 + Vector3(0, 1.5, 0), Color(0.5, 0.38, 0.25, 0.0), 0.35, 0.5, 1.0)
	return true
