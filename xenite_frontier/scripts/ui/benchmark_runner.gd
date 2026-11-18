class_name BenchmarkRunner
extends Node
## Scripted perf test: ramps the horde to `target` aliens, holds, records frame
## times and reports avg FPS, 1% low, sim/upload/GPU ms. Results are appended
## to user://benchmark.log. Run headless/CI with:  godot -- --benchmark[=N]

signal finished(report: String)

enum State { IDLE, RAMP, SETTLE, HOLD }

var state := State.IDLE
var target := 10000
var ramp_seconds := 6.0
var hold_seconds := 20.0
var pass_fps := 60.0
var swarm: Swarm
var quit_when_done := false
var last_report := ""

var _t := 0.0
var _frames := PackedFloat32Array()
var _sim := PackedFloat32Array()
var _upload := PackedFloat32Array()
var _gpu := PackedFloat32Array()
var _prev_vsync := DisplayServer.VSYNC_ENABLED
var _prev_max_fps := 0


func _ready() -> void:
	var cfg := GameConfig.section("benchmark")
	target = int(cfg.get("target_aliens", target))
	ramp_seconds = cfg.get("ramp_seconds", ramp_seconds)
	hold_seconds = cfg.get("hold_seconds", hold_seconds)
	pass_fps = cfg.get("pass_fps", pass_fps)


func running() -> bool:
	return state != State.IDLE


func desired_population() -> int:
	match state:
		State.RAMP:
			return int(target * clampf(_t / ramp_seconds, 0.0, 1.0))
		State.SETTLE, State.HOLD:
			return target
	return -1


func start(count := -1) -> void:
	if count > 0:
		target = count
	_t = 0.0
	_frames.clear(); _sim.clear(); _upload.clear(); _gpu.clear()
	_prev_vsync = DisplayServer.window_get_vsync_mode()
	_prev_max_fps = Engine.max_fps
	# measure real headroom, not the monitor refresh
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	state = State.RAMP
	print("[benchmark] ramping to %d aliens..." % target)


func status_text() -> String:
	match state:
		State.RAMP: return "BENCHMARK: ramping %d / %d" % [swarm.total(), target]
		State.SETTLE: return "BENCHMARK: settling..."
		State.HOLD: return "BENCHMARK: recording %.0f / %.0fs" % [_t, hold_seconds]
	return ""


func _process(delta: float) -> void:
	if state == State.IDLE:
		return
	_t += delta
	match state:
		State.RAMP:
			if _t >= ramp_seconds and swarm.total() >= target:
				state = State.SETTLE
				_t = 0.0
		State.SETTLE:
			if _t >= 2.0:
				state = State.HOLD
				_t = 0.0
		State.HOLD:
			_frames.append(delta)
			_sim.append(swarm.sim_usec / 1000.0)
			_upload.append(swarm.upload_usec / 1000.0)
			var rid := get_viewport().get_viewport_rid()
			_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
			if _t >= hold_seconds:
				_finish()


static func _avg(a: PackedFloat32Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _finish() -> void:
	state = State.IDLE
	DisplayServer.window_set_vsync_mode(_prev_vsync)
	Engine.max_fps = _prev_max_fps
	var sorted := _frames.duplicate()
	sorted.sort()
	var n := sorted.size()
	var total_t := 0.0
	for v in sorted:
		total_t += v
	var avg_fps := n / maxf(total_t, 1e-6)
	# 1% low = average FPS over the slowest 1% of frames
	var worst := maxi(1, n / 100)
	var worst_t := 0.0
	for k in worst:
		worst_t += sorted[n - 1 - k]
	var low_fps := worst / maxf(worst_t, 1e-6)
	var sim_sorted := _sim.duplicate()
	sim_sorted.sort()
	var headless := DisplayServer.get_name() == "headless"
	var ok := low_fps >= pass_fps
	var lines := PackedStringArray([
		"=== Xenite Frontier swarm benchmark ===",
		"Date        : %s" % Time.get_datetime_string_from_system(),
		"Machine     : %s | %d threads | %s" % [OS.get_processor_name(), OS.get_processor_count(), RenderingServer.get_video_adapter_name()],
		"Display     : %s%s" % [DisplayServer.get_name(), " (no rendering: CPU-only figures)" if headless else ""],
		"Aliens      : %d (held %.0fs, %d frames)" % [swarm.total(), hold_seconds, n],
		"Avg FPS     : %.1f" % avg_fps,
		"1%% low FPS  : %.1f" % low_fps,
		"Frame time  : %.2f ms avg" % (1000.0 * total_t / maxi(n, 1)),
		"Swarm sim   : %.2f ms avg, %.2f ms p99" % [_avg(_sim), sim_sorted[clampi(int(n * 0.99), 0, n - 1)] if n > 0 else 0.0],
		"Buffer upld : %.2f ms avg" % _avg(_upload),
		"GPU render  : %.2f ms avg" % _avg(_gpu),
		"Flow field  : %.2f ms per rebuild" % (swarm.field.build_usec / 1000.0),
		"Result      : %s (target >= %.0f FPS 1%% low)" % ["PASS" if ok else "BELOW TARGET", pass_fps],
	])
	last_report = "\n".join(lines)
	print(last_report)
	var f := FileAccess.open("user://benchmark.log", FileAccess.READ_WRITE if FileAccess.file_exists("user://benchmark.log") else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_string(last_report + "\n\n")
		f.close()
	print("[benchmark] appended to %s" % ProjectSettings.globalize_path("user://benchmark.log"))
	finished.emit(last_report)
	if quit_when_done:
		get_tree().quit(0 if ok else 2)
