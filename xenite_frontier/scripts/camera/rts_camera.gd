class_name RTSCamera
extends Node3D
## Angled top-down camera. Pan: WASD / arrows / left stick / screen edge /
## middle-mouse drag. Zoom: wheel / Q,E / triggers. Shift (L3) pans faster.

@export var pitch_deg := 56.0
@export var min_distance := 10.0
@export var max_distance := 150.0
@export var pan_speed := 0.9        # screen-heights per second at current zoom
@export var edge_scroll := true
@export var edge_margin := 6.0

var distance := 60.0
var _target_distance := 60.0
var bounds := Rect2(-100, -70, 200, 140)
var camera: Camera3D
var _dragging := false


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 50.0
	camera.far = 600.0
	add_child(camera)
	camera.make_current()
	_apply()


func _apply() -> void:
	var p := deg_to_rad(pitch_deg)
	camera.position = Vector3(0.0, sin(p) * distance, cos(p) * distance)
	camera.rotation = Vector3(-p, 0.0, 0.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_distance *= 0.88
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_distance *= 1.12
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		var k := distance / get_viewport().get_visible_rect().size.y * 1.6
		position.x -= mm.relative.x * k
		position.z -= mm.relative.y * k


func _process(delta: float) -> void:
	var move := Input.get_vector("cam_pan_left", "cam_pan_right", "cam_pan_up", "cam_pan_down")
	if edge_scroll and DisplayServer.window_is_focused() and not _dragging:
		var vp := get_viewport()
		var mp := vp.get_mouse_position()
		var sz := vp.get_visible_rect().size
		if Rect2(Vector2.ZERO, sz).has_point(mp):
			if mp.x < edge_margin: move.x -= 1.0
			elif mp.x > sz.x - edge_margin: move.x += 1.0
			if mp.y < edge_margin: move.y -= 1.0
			elif mp.y > sz.y - edge_margin: move.y += 1.0
	move = move.limit_length(1.0)
	var fast := 2.5 if Input.is_action_pressed("cam_fast") else 1.0
	position += Vector3(move.x, 0.0, move.y) * distance * pan_speed * fast * delta
	# held zoom (keys / triggers); wheel handled as events
	var z := Input.get_action_strength("cam_zoom_out") - Input.get_action_strength("cam_zoom_in")
	if absf(z) > 0.01 and not _wheel_only():
		_target_distance *= 1.0 + z * 1.6 * delta
	_target_distance = clampf(_target_distance, min_distance, max_distance)
	distance = lerpf(distance, _target_distance, minf(1.0, delta * 10.0))
	position.x = clampf(position.x, bounds.position.x, bounds.end.x)
	position.z = clampf(position.z, bounds.position.y, bounds.end.y)
	_apply()


func _wheel_only() -> bool:
	# wheel buttons register as "pressed" for one frame; ignore that here
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_UP) or Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_DOWN)


## Ray-cast the cursor onto the ground plane (y = 0).
func ground_point(screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-4:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	return from + dir * t
