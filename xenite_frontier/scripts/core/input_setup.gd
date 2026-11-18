class_name InputSetup
extends RefCounted
## Registers default input actions in code (keyboard, mouse and gamepad) so that
## the rebinding UI (M8) can rewrite them at runtime and save overrides.

const DEADZONE := 0.2

# action -> list of event descriptors
# "k:<keycode>"  key,  "m:<button>" mouse button,  "jb:<button>" joy button,
# "ja:<axis>:<sign>" joy axis
const DEFAULTS := {
	"cam_pan_left":  ["k:%d" % KEY_A, "k:%d" % KEY_LEFT, "ja:0:-1"],
	"cam_pan_right": ["k:%d" % KEY_D, "k:%d" % KEY_RIGHT, "ja:0:1"],
	"cam_pan_up":    ["k:%d" % KEY_W, "k:%d" % KEY_UP, "ja:1:-1"],
	"cam_pan_down":  ["k:%d" % KEY_S, "k:%d" % KEY_DOWN, "ja:1:1"],
	"cam_zoom_in":   ["k:%d" % KEY_E, "m:%d" % MOUSE_BUTTON_WHEEL_UP, "ja:5:1"],
	"cam_zoom_out":  ["k:%d" % KEY_Q, "m:%d" % MOUSE_BUTTON_WHEEL_DOWN, "ja:4:1"],
	"cam_fast":      ["k:%d" % KEY_SHIFT, "jb:%d" % JOY_BUTTON_LEFT_STICK],
	"primary":       ["m:%d" % MOUSE_BUTTON_LEFT, "jb:%d" % JOY_BUTTON_A],
	"pause":         ["k:%d" % KEY_SPACE, "jb:%d" % JOY_BUTTON_START],
	"bench_run":     ["k:%d" % KEY_B, "jb:%d" % JOY_BUTTON_Y],
	"bench_more":    ["k:%d" % KEY_EQUAL, "k:%d" % KEY_KP_ADD, "jb:%d" % JOY_BUTTON_RIGHT_SHOULDER],
	"bench_less":    ["k:%d" % KEY_MINUS, "k:%d" % KEY_KP_SUBTRACT, "jb:%d" % JOY_BUTTON_LEFT_SHOULDER],
	"bench_preset_1": ["k:%d" % KEY_1],
	"bench_preset_2": ["k:%d" % KEY_2],
	"bench_preset_3": ["k:%d" % KEY_3],
	"bench_preset_4": ["k:%d" % KEY_4],
	"debug_flowfield": ["k:%d" % KEY_F, "jb:%d" % JOY_BUTTON_X],
	"debug_hud":     ["k:%d" % KEY_F1, "jb:%d" % JOY_BUTTON_BACK],
	"reset_walls":   ["k:%d" % KEY_R],
}


static func ensure_defaults() -> void:
	for action: String in DEFAULTS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, DEADZONE)
		for desc: String in DEFAULTS[action]:
			var ev := make_event(desc)
			if ev:
				InputMap.action_add_event(action, ev)


static func make_event(desc: String) -> InputEvent:
	var p := desc.split(":")
	match p[0]:
		"k":
			var k := InputEventKey.new()
			k.physical_keycode = int(p[1]) as Key
			return k
		"m":
			var m := InputEventMouseButton.new()
			m.button_index = int(p[1]) as MouseButton
			return m
		"jb":
			var b := InputEventJoypadButton.new()
			b.button_index = int(p[1]) as JoyButton
			return b
		"ja":
			var a := InputEventJoypadMotion.new()
			a.axis = int(p[1]) as JoyAxis
			a.axis_value = float(p[2])
			return a
	return null
