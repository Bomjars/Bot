class_name WaveDirector
extends Node
## Run flow: LANDING (pick the outpost site) -> BUILD (countdown; "call the
## wave early" pays a Biomass bonus for the time left) -> WAVE (packs spawn
## from the canyon mouths over spawn_seconds; the wave ends when every alien,
## brood included, is dead) -> payday (company bounty x Threat Level, Xenite
## ore sale, wages) -> BUILD ...
## All numbers: data/waves.json and data/economy.json.

signal phase_changed(phase: int)
signal report(text: String)

enum Phase { LANDING, BUILD, WAVE, OVER }

var phase := Phase.LANDING
var wave := 0
var timer := 0.0
var threat := 1.0
var swarm: Swarm
var economy: Economy
var structures: Structures
var colonists: ColonistSystem
var map: OutpostMap

# this run
var xenite_mined := 0.0       # mined since the last sale
var xenite_banked := 0.0      # contract share kept for the Colony Charter
var morale_low := false
var last_report := ""
var wave_total := 0
var _queue: Array[Dictionary] = []
var _wave_t := 0.0
var _rng := RandomNumberGenerator.new()


func setup(s: Swarm, e: Economy, st: Structures, c: ColonistSystem, m: OutpostMap) -> void:
	swarm = s
	economy = e
	structures = st
	colonists = c
	map = m


func cfg() -> Dictionary:
	return GameConfig.waves


func reset() -> void:
	phase = Phase.LANDING
	wave = 0
	timer = 0.0
	threat = 1.0
	xenite_mined = 0.0
	xenite_banked = 0.0
	morale_low = false
	last_report = ""
	_queue.clear()
	phase_changed.emit(phase)


func begin_after_landing() -> void:
	phase = Phase.BUILD
	timer = float(cfg().get("first_build_seconds", 90))
	phase_changed.emit(phase)


func early_bonus() -> int:
	if phase != Phase.BUILD:
		return 0
	return int(timer * float(GameConfig.econ("biomass").get("early_call_bonus_per_second", 3.0)))


## Skip the rest of the build phase for a Biomass bonus.
func call_early() -> void:
	if phase != Phase.BUILD:
		return
	var b := early_bonus()
	if b > 0:
		economy.credit(b, "early call")
		report.emit("Wave called early: +%d Biomass" % b)
	_start_wave()


func remaining() -> int:
	var queued := 0
	for p in _queue:
		queued += (p.types as PackedInt32Array).size()
	return swarm.total() + queued


## How many of each strain wave `w` sends (already x size_multiplier).
func composition(w: int) -> Dictionary:
	var out := {}
	var strains: Dictionary = cfg().get("strains", {})
	var mult := float(cfg().get("size_multiplier", 1.0))
	var growth := float(cfg().get("growth_per_wave", 0.45))
	for id: String in strains:
		var sd: Dictionary = strains[id]
		var from := int(sd.get("from_wave", 1))
		if w < from:
			continue
		var every := int(sd.get("every", 1))
		if every > 1 and (w - from) % every != 0:
			continue
		var n := int(round(float(sd.base) * (1.0 + growth * (w - 1)) * mult))
		if id == "brood_mother":
			n = maxi(1, int(round(float(sd.base) * (1.0 + 0.5 * floor((w - from) / 10.0)))))
		if n > 0:
			out[id] = n
	return out


func _start_wave() -> void:
	wave += 1
	var tcfg := GameConfig.econ("threat")
	threat = minf(float(tcfg.get("max", 6.0)), float(tcfg.get("start", 1.0)) + float(tcfg.get("per_wave", 0.25)) * (wave - 1))
	swarm.hp_mult = 1.0 + float(cfg().get("hp_growth_per_wave", 0.04)) * (wave - 1)
	var comp := composition(wave)
	var all := PackedInt32Array()
	for id: String in comp:
		var t := GameConfig.alien_index(id)
		for k in comp[id]:
			all.append(t)
	# shuffle, then cut into packs that leave from one canyon mouth together
	for k in range(all.size() - 1, 0, -1):
		var j := _rng.randi_range(0, k)
		var tmp := all[k]
		all[k] = all[j]
		all[j] = tmp
	_queue.clear()
	var spawn_s := float(cfg().get("spawn_seconds", 28))
	var pmin := int(cfg().get("pack_size_min", 5))
	var pmax := int(cfg().get("pack_size_max", 14))
	var i := 0
	var packs: Array[PackedInt32Array] = []
	while i < all.size():
		var n := mini(_rng.randi_range(pmin, pmax), all.size() - i)
		packs.append(all.slice(i, i + n))
		i += n
	for k in packs.size():
		var at := spawn_s * float(k) / maxf(1.0, packs.size() - 1) if packs.size() > 1 else 0.0
		_queue.append({"t": at + _rng.randf_range(0.0, 2.0), "types": packs[k], "mouth": _rng.randi() % maxi(1, map.mouth_cells.size())})
	wave_total = all.size()
	_wave_t = 0.0
	phase = Phase.WAVE
	phase_changed.emit(phase)
	report.emit("WAVE %d - %d hostiles inbound (Threat x%.2f)" % [wave, wave_total, threat])


func tick(dt: float) -> void:
	_mine(dt)
	match phase:
		Phase.BUILD:
			timer -= dt
			if timer <= 0.0:
				_start_wave()
		Phase.WAVE:
			_wave_t += dt
			var k := 0
			while k < _queue.size():
				if _queue[k].t <= _wave_t:
					swarm.spawn_pack(_queue[k].types, _queue[k].mouth)
					_queue.remove_at(k)
				else:
					k += 1
			if _queue.is_empty():
				var left := swarm.total()
				if left == 0:
					_end_wave()
				elif _wave_t > float(cfg().get("straggler_timeout_seconds", 240)) and left <= 5:
					swarm.clear()  # the last stragglers slink back into the canyons
					_end_wave()


func _mine(dt: float) -> void:
	var per_min := float(structures.defs.get("mining_rig", {}).get("xenite_per_minute", 14))
	var rigs := structures.count_active("mining_rig")
	xenite_mined += rigs * per_min / 60.0 * dt


func _end_wave() -> void:
	var lines := PackedStringArray(["WAVE %d SURVIVED" % wave])
	var wb := GameConfig.econ("wave_bounty")
	var bounty := int((float(wb.get("base", 60)) + float(wb.get("per_wave", 12)) * wave) * threat)
	economy.credit(bounty, "bounty")
	lines.append("Company bounty  +%d" % bounty)
	var xs := GameConfig.econ("xenite_sale")
	var share := float(xs.get("contract_share", 0.25))
	var sold := xenite_mined * (1.0 - share)
	var ore := int(sold * float(xs.get("biomass_per_xenite", 3.0)))
	xenite_banked += xenite_mined * share
	if xenite_mined > 0.0:
		economy.credit(ore, "ore sale")
		lines.append("Xenite sold %d  +%d   (banked %d for the Charter)" % [int(sold), ore, int(xenite_mined * share)])
	xenite_mined = 0.0
	var wages := colonists.wages_due()
	if wages > 0:
		if economy.biomass >= wages:
			economy.pay(wages, "wages")
			morale_low = false
			lines.append("Wages  -%d" % wages)
		else:
			var paid := int(economy.biomass)
			economy.pay(paid, "wages")
			morale_low = true
			lines.append("Wages  -%d  (%d UNPAID: morale low, crews fire 20%% slower)" % [paid, wages - paid])
	colonists.morale = float(GameConfig.econ("wages_per_wave").get("unpaid_fire_rate", 0.8)) if morale_low else 1.0
	last_report = "\n".join(lines)
	report.emit(last_report)
	phase = Phase.BUILD
	timer = float(cfg().get("build_seconds", 40))
	phase_changed.emit(phase)
