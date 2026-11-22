class_name ItemIcons
extends Node
## Shop and Inspector pictures. Each building and turret is rendered once at
## startup from its real in-game model into a small off-screen viewport
## (transparent background, three-quarter view like the game camera), so the
## pictures always match the models with no image files to keep in sync.
##
## Art hook: an "icon": "res://art/icons/<name>.png" entry on a structure in
## structures.json (or a turret in turrets.json) replaces the rendered picture
## with your own image (see README "Using your own models and icons").
##
## Headless runs have no renderer: only custom icons load there, and the UI
## falls back to text.

signal icons_ready

const SIZE := 192
const YAW := 35.0      # degrees around the model
const PITCH := 30.0    # degrees above the horizon

var icons := {}        # id -> Texture2D
var ready_done := false


func get_icon(id: String) -> Texture2D:
	return icons.get(id, null)


## Renders every id (structures, turrets, "command_hab") in one batch: all
## viewports draw in the same frame, are read back, then freed.
func generate(ids: Array) -> void:
	var batch: Array = []
	var can_render := DisplayServer.get_name() != "headless"
	for id: String in ids:
		var custom := str(GameConfig.structure_def(id).get("icon", ""))
		if custom != "" and ResourceLoader.exists(custom):
			var tex: Variant = load(custom)
			if tex is Texture2D:
				icons[id] = tex
				continue
		if custom != "":
			push_warning("icon '%s' for %s not found, using the rendered model" % [custom, id])
		if can_render:
			batch.append([id, _make_stage(id)])
	if not batch.is_empty():
		# draw once, wait until the GPU has finished, read the pixels back
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		for e: Array in batch:
			var vp: SubViewport = e[1]
			var img := vp.get_texture().get_image()
			if img and not img.is_empty():
				icons[e[0]] = ImageTexture.create_from_image(img)
			vp.queue_free()
	ready_done = true
	icons_ready.emit()


## Dev: writes every icon as a PNG (`-- --export-icons=<folder>`).
func export_png(folder: String) -> int:
	DirAccess.make_dir_recursive_absolute(folder)
	var n := 0
	for id: String in icons:
		var tex: Texture2D = icons[id]
		var img := tex.get_image()
		if img and img.save_png(folder.path_join(id + ".png")) == OK:
			n += 1
	return n


# ------------------------------------------------------------ rendering

func _make_stage(id: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.56, 0.66)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.1
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	# warm key light like the planet's sun, cool fill from the other side
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, 40, 0)
	key.light_color = Color(1.0, 0.9, 0.8)
	key.light_energy = 1.25
	key.shadow_enabled = true
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, -140, 0)
	fill.light_color = Color(0.6, 0.65, 0.95)
	fill.light_energy = 0.45
	vp.add_child(fill)

	var model := build_model(id)
	vp.add_child(model)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	_frame(cam, model)
	cam.current = true
	return vp


## The item's in-game model (tier I), centred on the origin.
static func build_model(id: String) -> Node3D:
	var root := Node3D.new()
	var d := GameConfig.structure_def(id)
	var fp := int(d.get("footprint", 1))
	if d.has("damage_type"):
		TurretModels.build(root, id, GameConfig.damage_color(GameConfig.damage_index(d.damage_type)))
		return root
	match id:
		"command_hab":
			StationModels.build_command_hab(root)
		"wall":
			# a short run of wall: post, panel, post, panel, post
			for k in 3:
				_mesh(root, StationModels.wall_post_mesh(), Vector3(k - 1.0, 0, 0))
			for k in 2:
				_mesh(root, StationModels.wall_panel_mesh(), Vector3(k - 1.0, 0, 0))
		"blast_door":
			_mesh(root, StationModels.door_mesh(), Vector3.ZERO)
			for sx: float in [-1.0, 1.0]:
				_mesh(root, StationModels.wall_post_mesh(), Vector3(sx, 0, 0))
			_mesh(root, StationModels.wall_panel_mesh(), Vector3(-1.0, 0, 0)).scale.x = 0.45
			_mesh(root, StationModels.wall_panel_mesh(), Vector3(0.55, 0, 0)).scale.x = 0.45
		"harvester_bay":
			StationModels.build_bay(root)
			var drone := MeshInstance3D.new()
			drone.mesh = StationModels.drone_mesh()
			drone.material_override = StationModels.station_material()
			drone.position = Vector3(-0.48, 0.75, 0.42)
			root.add_child(drone)
		"floodlight":
			StationModels.build_floodlight(root, 6.0)
		_:
			StationModels.build_building(root, id, fp)
	return root


static func _mesh(root: Node3D, m: Mesh, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = StationModels.station_material()
	mi.position = at
	root.add_child(mi)
	return mi


## Points an orthographic camera at the model from the game's three-quarter
## angle and sizes it so the model fills the picture.
static func _frame(cam: Camera3D, model: Node3D) -> void:
	var box := AABB()
	var first := true
	for n in model.find_children("*", "VisualInstance3D", true, false):
		var vi := n as VisualInstance3D
		if vi is Light3D:
			continue
		var b := _to_model(model, vi) * vi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		box = AABB(Vector3(-1, 0, -1), Vector3(2, 2, 2))
	var dir := Vector3(sin(deg_to_rad(YAW)) * cos(deg_to_rad(PITCH)), sin(deg_to_rad(PITCH)), cos(deg_to_rad(YAW)) * cos(deg_to_rad(PITCH)))
	var center := box.get_center()
	var basis := Basis.looking_at(-dir, Vector3.UP)
	var right := basis.x
	var up := basis.y
	var w := 0.0
	var h := 0.0
	for k in 8:
		var p := box.get_endpoint(k) - center
		w = maxf(w, absf(p.dot(right)))
		h = maxf(h, absf(p.dot(up)))
	cam.size = maxf(w, h) * 2.0 * 1.08
	cam.transform = Transform3D(basis, center + dir * 30.0)
	cam.near = 0.1
	cam.far = 80.0


## A node's transform relative to the model root (works before the first
## frame, without relying on global transforms).
static func _to_model(model: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != model:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t
