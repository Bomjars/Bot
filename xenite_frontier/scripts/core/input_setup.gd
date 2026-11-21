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
	"demolish":      ["m:%d" % MOUSE_BUTTON_RIGHT, "jb:%d" % JOY_BUTTON_B],
	"cancel":        ["k:%d" % KEY_ESCAPE],
	"tool_next":     ["jb:%d" % JOY_BUTTON_RIGHT_SHOULDER],
	"category_next": ["k:%d" % KEY_TAB],
	"call_wave":     ["k:%d" % KEY_N, "jb:%d" % JOY_BUTTON_DPAD_LEFT],
	"release_squad": ["k:%d" % KEY_H],
	"tool_prev":     ["jb:%d" % JOY_BUTTON_LEFT_SHOULDER],
	"tool_1": ["k:%d" % KEY_1], "tool_2": ["k:%d" % KEY_2], "tool_3": ["k:%d" % KEY_3], "tool_4": ["k:%d" % KEY_4],
	"tool_5": ["k:%d" % KEY_5], "tool_6": ["k:%d" % KEY_6], "tool_7": ["k:%d" % KEY_7], "tool_8": ["k:%d" % KEY_8],
	"tool_9": ["k:%d" % KEY_9], "tool_10": ["k:%d" % KEY_0],
	"upgrade":       ["k:%d" % KEY_U, "jb:%d" % JOY_BUTTON_X],
	"repair":        ["k:%d" % KEY_R, "jb:%d" % JOY_BUTTON_Y],
	"free_build":    ["k:%d" % KEY_F11],
	"intel":         ["k:%d" % KEY_I, "jb:%d" % JOY_BUTTON_DPAD_RIGHT],
	"pause":         ["k:%d" % KEY_SPACE, "jb:%d" % JOY_BUTTON_START],
	"bench_run":     ["k:%d" % KEY_B, "k:%d" % KEY_F9],
	"bench_more":    ["k:%d" % KEY_EQUAL, "k:%d" % KEY_KP_ADD, "jb:%d" % JOY_BUTTON_DPAD_UP],
	"bench_less":    ["k:%d" % KEY_MINUS, "k:%d" % KEY_KP_SUBTRACT, "jb:%d" % JOY_BUTTON_DPAD_DOWN],
	"bench_preset_1": ["k:%d" % KEY_F5],
	"bench_preset_2": ["k:%d" % KEY_F6],
	"bench_preset_3": ["k:%d" % KEY_F7],
	"bench_preset_4": ["k:%d" % KEY_F8],
	"debug_flowfield": ["k:%d" % KEY_F],
	"debug_hud":     ["k:%d" % KEY_F1, "jb:%d" % JOY_BUTTON_BACK],
	"reset_walls":   ["k:%d" % KEY_F10],
	"toggle_gore":   ["k:%d" % KEY_G],
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
