class_name Economy
extends Node
## In-run Biomass wallet. Every number comes from data/economy.json.
## Income only arrives through harvester drones depositing at a Harvester Bay;
## deposit() applies the night bonus (M5) and Charter multipliers (M6).

signal changed(biomass: float)
signal deposited(amount: float, pos: Vector3)

var biomass := 0.0
var free_build := false        # dev/sandbox: costs ignored
var night := false             # set by the day/night cycle (M5)
var biomass_mult := 1.0        # Colony Charter: Logistics (M6)
var refund_ratio := 0.5
var repair_per_hp := 0.04

# run stats
var bounties := 0.0
var ore_sales := 0.0
var wages_paid := 0.0
var collected := 0.0
var spent := 0.0
var refunded := 0.0
var _window: Array[Vector2] = []  # (time, amount) for income/min


func setup() -> void:
	var b := GameConfig.econ("biomass")
	refund_ratio = float(b.get("refund_ratio", refund_ratio))
	repair_per_hp = float(b.get("repair_cost_per_hp", repair_per_hp))
	reset()


func reset() -> void:
	biomass = float(GameConfig.econ("biomass").get("starting", 300))
	bounties = 0.0
	ore_sales = 0.0
	wages_paid = 0.0
	collected = 0.0
	spent = 0.0
	refunded = 0.0
	_window.clear()
	changed.emit(biomass)


func can_afford(cost: float) -> bool:
	return free_build or biomass >= cost


func spend(cost: float) -> bool:
	if free_build:
		return true
	if biomass < cost:
		return false
	biomass -= cost
	spent += cost
	changed.emit(biomass)
	return true


func refund(amount: float) -> void:
	if free_build or amount <= 0.0:
		return
	biomass += amount
	refunded += amount
	changed.emit(biomass)


## Company payments (bounties, ore sales, early-call bonus).
func credit(amount: float, reason: String) -> void:
	if amount <= 0.0:
		return
	biomass += amount
	if reason == "ore sale":
		ore_sales += amount
	else:
		bounties += amount
	changed.emit(biomass)


## Wages and other running costs (never below zero).
func pay(amount: float, _reason: String) -> void:
	var a := minf(amount, biomass)
	biomass -= a
	wages_paid += a
	changed.emit(biomass)


## Drone delivery. Returns the amount actually credited.
func deposit(raw: float, pos: Vector3) -> float:
	var night_bonus := float(GameConfig.econ("biomass").get("night_bonus", 0.5)) if night else 0.0
	var amount := raw * (1.0 + night_bonus) * biomass_mult
	if amount <= 0.0:
		return 0.0
	biomass += amount
	collected += amount
	_window.append(Vector2(Time.get_ticks_msec() / 1000.0, amount))
	changed.emit(biomass)
	deposited.emit(amount, pos)
	return amount


## Biomass per minute over the last 30 seconds.
func income_per_min() -> float:
	var now := Time.get_ticks_msec() / 1000.0
	while not _window.is_empty() and now - _window[0].x > 30.0:
		_window.pop_front()
	var s := 0.0
	for v in _window:
		s += v.y
	return s * 2.0
