-- mpvgui: a zero-overhead GUI for stock mpv.
--
-- Architecture: mpv is the only Wayland client; every pixel of the GUI is an
-- `ass-events` OSD overlay drawn by this script.  No extra window, no extra
-- process, nothing allocated per video frame.
--
-- Layers (separate overlay objects, ordered back to front):
--   static    bar background + tracks          redrawn on layout change only
--   panel     playlist / shader / menu rows    redrawn on list/selection change
--   hover     icons, labels, fills, title       redrawn on state/hover change
--   transient seek / volume tooltip             redrawn on tooltip change
--
-- Updates are event driven.  The single timer that exists is the 4 Hz
-- seekbar sampler, and it only runs while the bar is visible during playback.

local msg = require("mp.msg")
local options = require("mp.options")
local utils = require("mp.utils")

local interact = require("interact")
local layout = require("layout")
local menu = require("menu")
local render = require("render")
local shaders = require("shaders")

local SCRIPT = "mpvgui"

local opts = {
	-- Seconds of inactivity (playing) before the bar hides itself.
	autohide_delay = 2.5,
	-- Extra multiplier for the whole GUI (on top of osd_height / 1080).
	scale = 1.0,
}

options.read_options(opts, SCRIPT)

local LAYERS = { "static", "panel", "hover", "transient", "prompt" }
local TICK_INTERVAL = 0.25 -- 4 Hz: allowed seekbar/time refresh while visible
local SCRUB_INTERVAL = 0.033 -- throttle for live scrub seeks

local state = {
	w = 0,
	h = 0,
	visible = false,
	enabled = true,
	panel_mode = nil,
	panel_open = false,
	panel_scroll = 0,
	menu_page = "root",
	menu_stack = {},
	menu_view = nil,
	menu_depth = 0,
	shader_rows = {},
	shader_active = "Off",
	toast = nil,
	pause = false,
	has_media = false,
	time_pos = nil,
	duration = nil,
	volume = 100,
	mute = false,
	speed = 1,
	fullscreen = false,
	eof = false,
	title = "",
	playlist = {},
	playlist_count = 0,
	playlist_pos = -1,
	playlist_labels = {},
	buffered_end = nil,
	track_list = {},
	aid = "auto",
	sid = "auto",
	vid = "auto",
	chapter_list = {},
	chapter = -1,
	loop_file = "no",
	loop_playlist = "no",
	aspect = "no",
	sub_visibility = true,
	sub_delay = 0,
	audio_delay = 0,
	video_zoom = 0,
	video_rotate = "no",
	deinterlace = "no",
	ab_loop_a = "no",
	ab_loop_b = "no",
	shuffle = false,
	hover = nil,
	hover_row = nil,
	mouse_x = -1,
	mouse_y = -1,
	scrub = nil,
	last_scrub = nil,
	last_tp = nil,
	last_tp_at = nil,
	tooltip = nil,
	no_dims_logged = false,
	settings = {},
	notify_ready = false,
	suppress_all_until = 0,
	last_notify = {},
	input_bindings = {},
	custom_bindings = {},
	keybind_filter = "",
	keybind_selected = nil,
	text_input = nil,
	gui = { autohide_delay = opts.autohide_delay, scale = opts.scale },
}

-- Common playback properties that a stray key press can change.  They are
-- observed at startup, shown in Settings and mirrored in a toast when an
-- external change happens (a key press, a script message, a menu action that
-- is not ours).  The defaults are read from mpv itself for Reset.
local SETTINGS_PROPS = {
	"video-zoom",
	"video-pan-x",
	"video-pan-y",
	"video-rotate",
	"video-aspect-override",
	"video-align-x",
	"video-align-y",
	"panscan",
	"brightness",
	"contrast",
	"saturation",
	"gamma",
	"hue",
	"deband",
	"volume",
	"mute",
	"audio-delay",
	"audio-channels",
	"audio-normalize-downmix",
	"sub-visibility",
	"sub-delay",
	"sub-speed",
	"sub-scale",
	"sub-pos",
	"sub-ass-override",
	"sub-font-size",
	"sub-border-size",
	"sub-shadow-offset",
	"speed",
	"keep-open",
	"cache",
	"shuffle",
	"loop-file",
	"loop-playlist",
	"ab-loop-a",
	"ab-loop-b",
	"deinterlace",
}

local RESET_VIEW = {
	"video-zoom",
	"video-pan-x",
	"video-pan-y",
	"video-rotate",
	"video-aspect-override",
	"video-align-x",
	"video-align-y",
	"panscan",
}

local RESET_AUDIO = { "volume", "mute", "audio-delay", "audio-channels", "audio-normalize-downmix" }

local RESET_SUBS = {
	"sub-visibility",
	"sub-delay",
	"sub-speed",
	"sub-scale",
	"sub-pos",
	"sub-ass-override",
	"sub-font-size",
	"sub-border-size",
	"sub-shadow-offset",
}

local RESET_PLAYBACK = { "speed", "loop-file", "loop-playlist", "keep-open", "cache", "shuffle" }

local RESET_NAMES = {
	"video-zoom",
	"video-pan-x",
	"video-pan-y",
	"video-rotate",
	"video-aspect-override",
	"video-align-x",
	"video-align-y",
	"panscan",
	"speed",
	"audio-delay",
	"sub-delay",
	"sub-speed",
	"sub-scale",
	"sub-pos",
	"sub-visibility",
	"mute",
	"brightness",
	"contrast",
	"saturation",
	"gamma",
	"hue",
	"deinterlace",
	"loop-file",
	"loop-playlist",
	"ab-loop-a",
	"ab-loop-b",
	"sub-ass-override",
	"sub-font-size",
	"sub-border-size",
	"sub-shadow-offset",
}

-- Keys owned by the GUI's forced bindings.  A custom binding for these is
-- accepted by mpv but can never fire, so the prompt refuses them.
local RESERVED_KEYS = {
	tab = true,
	["shift+m"] = true,
	["shift+x"] = true,
	esc = true,
	g = true,
	mbtn_left = true,
	mbtn_left_dbl = true,
	mbtn_right = true,
	wheel_up = true,
	wheel_down = true,
}

local layers = {}
for _, name in ipairs(LAYERS) do
	layers[name] = { ov = mp.create_osd_overlay("ass-events"), data = "", updates = 0 }
end

-- Forward declarations (Lua locals must exist before closures capture them).
local lay
local it
local clear_all, publish, publish_layout
local compute_layout, update_tooltip, update_areas
local draw_all, draw_hover, draw_panel, draw_transient
local show, hide, activity, apply_dims
local toggle_panel, toggle_gui, cycle_speed, play_index, relative_seek, scroll_panel
local set_volume_fraction, seek_time, on_activate, on_hover, on_drag, on_commit
local show_toast, refresh_shader_rows, apply_shader_row, prompt_import, on_shaders_changed
local panel_count, refresh_menu_view, publish_menu
local menu_set_page, menu_back, menu_dispatch, prompt_sub_add
local prompt_text, prompt_setting, prompt_set_property, prompt_gui_setting
local prompt_keybind_filter, prompt_keybind_add, prompt_keybind_rebind
local open_text_input, close_text_input, draw_prompt
local reset_tweaks, reset_gui
local bind_key, unbind_key, clear_custom_bindings
local save_custom_bindings, load_custom_bindings, refresh_input_bindings, effective_binding
local save_gui_options
local suppress_prop, notify_prop, watch_prop
local config_path, ensure_dir, trim

local tick_timer, hide_timer, toast_timer

-- Screen regions that belong to the GUI.  These sections carry no bindings;
-- they exist so mpv's input core knows the pointer is over the GUI:
--   * a MOUSE area stops mpv's built-in "drag the window" behaviour there
--     (which otherwise cancels a held MBTN_LEFT and takes over the pointer),
--   * and an enabled section keeps the cursor visible over our controls.
-- They are enabled *without* the allow-vo-dragging flag on purpose.
local AREA_BAR = SCRIPT .. "-bar-area"
local AREA_PANEL = SCRIPT .. "-panel-area"
mp.enable_key_bindings(AREA_BAR)
mp.enable_key_bindings(AREA_PANEL)

update_areas = function()
	if not lay or not state.visible or not state.enabled then
		mp.set_mouse_area(0, 0, 0, 0, AREA_BAR)
		mp.set_mouse_area(0, 0, 0, 0, AREA_PANEL)
		return
	end
	local bar = lay.bar
	mp.set_mouse_area(
		math.floor(bar.x0),
		math.floor(bar.y0),
		math.floor(bar.x1),
		math.floor(bar.y1),
		AREA_BAR
	)
	if lay.panel then
		local p = lay.panel
		mp.set_mouse_area(
			math.floor(p.x0),
			math.floor(p.y0),
			math.floor(p.x1),
			math.floor(p.y1),
			AREA_PANEL
		)
	else
		mp.set_mouse_area(0, 0, 0, 0, AREA_PANEL)
	end
end

publish = function()
	local total = 0
	for _, name in ipairs(LAYERS) do
		total = total + layers[name].updates
	end
	mp.set_property_native("user-data/" .. SCRIPT .. "/updates", total)
	for _, name in ipairs(LAYERS) do
		mp.set_property_native("user-data/" .. SCRIPT .. "/updates_" .. name, layers[name].updates)
	end
	-- Boolean for the test harness (it compares against false), numeric
	-- mirror for anything that wants 0/1.
	mp.set_property_native("user-data/" .. SCRIPT .. "/visible", state.visible == true)
	mp.set_property_native("user-data/" .. SCRIPT .. "/visible_num", state.visible and 1 or 0)
end

local function set_layer(name, data)
	local layer = layers[name]
	if layer.data == data then
		return
	end
	if state.w <= 0 or state.h <= 0 then
		-- No VO (headless / audio only): remember nothing was drawn.
		layer.data = nil
		return
	end
	local ov = layer.ov
	if ov.res_x ~= state.w or ov.res_y ~= state.h then
		ov.res_x, ov.res_y = state.w, state.h
	end
	ov.data = data
	ov:update()
	layer.data = data
	layer.updates = layer.updates + 1
end

clear_all = function()
	for _, name in ipairs(LAYERS) do
		set_layer(name, "")
	end
	publish()
end

publish_layout = function()
	if not lay then
		return
	end
	local buttons = {}
	for _, b in ipairs(lay.buttons) do
		buttons[b.id] = { b.x0, b.y0, b.x1, b.y1 }
	end
	local data = {
		w = state.w,
		h = state.h,
		panel_open = state.panel_open and true or false,
		bar = { lay.bar.x0, lay.bar.y0, lay.bar.x1, lay.bar.y1 },
		seek = { lay.seek.x0, lay.seek.y0, lay.seek.x1, lay.seek.y1 },
		volume = { lay.vol.x0, lay.vol.x1 },
		buttons = buttons,
	}
	if lay.panel then
		data.panel = {
			lay.panel.x0,
			lay.panel.x1,
			lay.panel.rows_y0,
			lay.panel.row_h,
			lay.panel.visible,
		}
	end
	mp.set_property("user-data/" .. SCRIPT .. "/layout", utils.format_json(data))
end

-- Menu ----------------------------------------------------------------------

-- Number of rows in the open panel, for scroll clamping.
panel_count = function()
	if state.panel_mode == "menu" then
		return state.menu_view and #state.menu_view.rows or 0
	elseif state.panel_mode == "shaders" then
		return #state.shader_rows
	elseif state.panel_mode == "playlist" then
		return #state.playlist
	end
	return 0
end

publish_menu = function()
	if state.panel_mode ~= "menu" or not state.menu_view then
		mp.set_property(
			"user-data/" .. SCRIPT .. "/menu",
			utils.format_json({ page = "", depth = 0, rows = {} })
		)
		return
	end
	local labels = {}
	for i, row in ipairs(state.menu_view.rows) do
		labels[i] = row.label
	end
	mp.set_property(
		"user-data/" .. SCRIPT .. "/menu",
		utils.format_json({ page = state.menu_page, depth = state.menu_depth, rows = labels })
	)
end

refresh_menu_view = function()
	if state.panel_mode ~= "menu" then
		state.menu_view = nil
		state.menu_depth = 0
		publish_menu()
		return
	end
	state.menu_view = menu.view(state, state.menu_page)
	state.menu_depth = #state.menu_stack
	if lay then
		state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll, panel_count())
	end
	if it then
		it:set_scroll(state.panel_scroll)
	end
	publish_menu()
end

menu_set_page = function(page, push)
	if push then
		state.menu_stack[#state.menu_stack + 1] = state.menu_page
	end
	state.menu_page = page
	state.panel_scroll = 0
	refresh_menu_view()
end

-- Back one page; from the root (or from a flat panel) close the panel.
menu_back = function()
	local n = #state.menu_stack
	if n > 0 then
		state.menu_page = state.menu_stack[n]
		state.menu_stack[n] = nil
		state.panel_scroll = 0
		refresh_menu_view()
	else
		toggle_panel(state.panel_mode)
	end
end

compute_layout = function()
	if state.w <= 0 or state.h <= 0 then
		lay = nil
		if it then
			it:set_layout(nil, state.panel_scroll)
		end
		return
	end
	lay = layout.compute(state.w, state.h, state.panel_mode, opts.scale)
	if it then
		it:set_layout(lay, state.panel_scroll)
	end
	publish_layout()
	update_areas()
end

draw_all = function()
	if not state.enabled or not state.visible or not lay or state.w <= 0 or state.h <= 0 then
		clear_all()
		return
	end
	set_layer("static", render.static(lay))
	set_layer("hover", render.hover(lay, state))
	set_layer("panel", state.panel_mode and render.panel(lay, state) or "")
	set_layer("transient", render.transient(lay, state.tooltip, state.toast))
	set_layer("prompt", state.text_input and render.prompt(lay, state) or "")
	publish()
end

draw_hover = function()
	if not state.enabled or not state.visible or not lay then
		return
	end
	set_layer("hover", render.hover(lay, state))
	publish()
end

draw_panel = function()
	if not state.enabled or not state.visible or not lay then
		return
	end
	if state.panel_mode == "menu" then
		refresh_menu_view()
	end
	set_layer("panel", state.panel_mode and render.panel(lay, state) or "")
	publish()
end

draw_transient = function()
	if not state.enabled or not state.visible or not lay then
		return
	end
	set_layer("transient", render.transient(lay, state.tooltip, state.toast))
	publish()
end

-- Timers --------------------------------------------------------------------

local function stop_tick()
	if tick_timer then
		tick_timer:kill()
		tick_timer = nil
	end
end

local function start_tick()
	if tick_timer or not state.visible or state.pause or not state.has_media then
		return
	end
	tick_timer = mp.add_periodic_timer(TICK_INTERVAL, function()
		if not state.visible or state.pause or not state.has_media then
			stop_tick()
			return
		end
		draw_hover()
	end)
end

local function stop_hide()
	if hide_timer then
		hide_timer:kill()
		hide_timer = nil
	end
end

local function arm_hide()
	stop_hide()
	if state.text_input then
		return
	end
	if not state.visible or not state.enabled or state.pause or not state.has_media then
		return
	end
	if it and it.drag then
		return
	end
	local delay = tonumber(opts.autohide_delay) or 2.5
	if state.toast then
		-- Keep the bar up until the toast's own 3 s timer has fired.
		delay = math.max(delay, 3.2)
	end
	if delay <= 0 then
		return
	end
	hide_timer = mp.add_timeout(delay, function()
		hide_timer = nil
		if it and it.drag then
			arm_hide()
			return
		end
		if state.visible and not state.pause then
			hide()
		end
	end)
end

show = function()
	if not state.enabled then
		return
	end
	state.visible = true
	draw_all()
	start_tick()
	arm_hide()
	publish()
	update_areas()
end

hide = function()
	if state.text_input then
		close_text_input(true)
	end
	state.visible = false
	stop_hide()
	stop_tick()
	state.tooltip = nil
	state.toast = nil
	mp.set_property("user-data/" .. SCRIPT .. "/toast", "")
	if it then
		it:cancel()
	end
	clear_all()
	publish()
	update_areas()
end

activity = function()
	if not state.enabled then
		return
	end
	if not state.visible then
		show()
		return
	end
	start_tick()
	arm_hide()
end

-- Tooltip -------------------------------------------------------------------

update_tooltip = function()
	state.tooltip = nil
	if not state.visible or not lay or not it or state.mouse_x < 0 then
		return
	end
	local kind = nil
	if it.drag then
		kind = it.drag.kind
	elseif it.hover == "seekbar" or it.hover == "volume" then
		kind = it.hover
	end
	if not kind then
		return
	end

	local x = state.mouse_x
	local f
	if it.drag and it.drag.kind == kind then
		f = it.drag.fraction
		if kind == "seekbar" then
			x = lay.seek.x0 + (lay.seek.x1 - lay.seek.x0) * f
		else
			x = lay.vol.x0 + (lay.vol.x1 - lay.vol.x0) * f
		end
	elseif kind == "seekbar" then
		f = layout.seek_fraction(lay, x)
	else
		f = layout.volume_fraction(lay, x)
	end

	if kind == "seekbar" then
		local dur = tonumber(state.duration) or 0
		if dur <= 0 then
			return
		end
		state.tooltip = { kind = "seek", x = x, text = render.fmt_time(f * dur) }
	else
		local percent = string.format("%d%%", math.floor(f * 100 + 0.5))
		state.tooltip = { kind = "volume", x = x, text = percent }
	end
end

-- Actions -------------------------------------------------------------------

seek_time = function(f)
	local dur = tonumber(state.duration)
	if not dur or dur <= 0 then
		return nil
	end
	return math.max(0, math.min(dur - 0.05, f * dur))
end

set_volume_fraction = function(f)
	f = math.max(0, math.min(1, tonumber(f) or 0))
	suppress_prop("volume")
	mp.set_property_number("volume", math.floor(f * 100 + 0.5))
	if state.mute then
		suppress_prop("mute")
		mp.set_property_native("mute", false)
	end
end

local SPEEDS = { 0.5, 0.75, 1, 1.25, 1.5, 2 }

cycle_speed = function()
	local cur = tonumber(mp.get_property_number("speed")) or 1
	local next_speed = SPEEDS[1]
	for _, v in ipairs(SPEEDS) do
		if v > cur + 0.0001 then
			next_speed = v
			break
		end
	end
	suppress_prop("speed")
	mp.set_property_number("speed", next_speed)
end

relative_seek = function(delta)
	mp.commandv("seek", tostring(delta), "relative")
	show()
end

play_index = function(index)
	index = tonumber(index)
	if not index then
		return
	end
	if index < 0 or index >= #state.playlist then
		return
	end
	mp.set_property_number("playlist-pos", index)
end

scroll_panel = function(delta)
	if not lay then
		return
	end
	local count = panel_count()
	state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll + delta, count)
	if it then
		it:set_scroll(state.panel_scroll)
	end
	draw_panel()
	activity()
end

-- Opens/closes the side panel. `mode` is "playlist", "shaders" or "menu";
-- calling it with the currently open mode closes the panel.
toggle_panel = function(mode)
	if not state.enabled then
		return
	end
	mode = mode or "playlist"
	if state.panel_mode == mode then
		state.panel_mode = nil
	else
		state.panel_mode = mode
		state.panel_scroll = 0
		if mode == "menu" then
			state.menu_page = "root"
			state.menu_stack = {}
		end
	end
	state.panel_open = state.panel_mode ~= nil
	if state.panel_mode == "shaders" then
		refresh_shader_rows()
	end
	refresh_menu_view()
	if state.panel_open and not state.visible then
		show()
	end
	if it then
		it:set_scroll(state.panel_scroll)
	end
	compute_layout()
	update_tooltip()
	draw_all()
	activity()
end

toggle_gui = function()
	state.enabled = not state.enabled
	mp.set_property_native("user-data/" .. SCRIPT .. "/enabled", state.enabled and 1 or 0)
	if state.enabled then
		show()
	else
		hide()
	end
end

prompt_sub_add = function()
	local function use(path)
		if path and path ~= "" then
			mp.commandv("sub-add", path, "select")
		end
	end
	prompt_text("subtitle file or URL: ", use)
end

-- Executes the action table attached to a menu row.  Every action lands in
-- a property set or an mpv command; nothing here runs on a timer.
menu_dispatch = function(action)
	if not action then
		return
	end
	local kind = action.kind
	if kind == "page" then
		menu_set_page(action.page, true)
	elseif kind == "panel" then
		toggle_panel(action.mode)
	elseif kind == "set" then
		suppress_prop(action.prop)
		if action.value_type == "native" then
			mp.set_property_native(action.prop, action.value)
		else
			mp.set_property(action.prop, action.value)
		end
	elseif kind == "set_number" then
		suppress_prop(action.prop)
		mp.set_property_native(action.prop, tonumber(action.value))
	elseif kind == "props" then
		for _, p in ipairs(action.props) do
			suppress_prop(p[1])
			if action.numbers then
				mp.set_property_native(p[1], tonumber(p[2]))
			else
				mp.set_property(p[1], p[2])
			end
		end
	elseif kind == "add" then
		suppress_prop(action.prop)
		mp.commandv("add", action.prop, tostring(action.value))
	elseif kind == "cmd" then
		mp.commandv(table.unpack(action.args))
	elseif kind == "seek_abs" then
		mp.commandv("seek", string.format("%.3f", tonumber(action.time) or 0), "absolute+exact")
	elseif kind == "set_time" then
		local t = tonumber(mp.get_property_number("time-pos")) or 0
		suppress_prop(action.prop)
		mp.set_property_native(action.prop, t)
		show_toast(action.prop .. " = " .. render.fmt_time(t))
	elseif kind == "rotate" then
		local cur = tonumber(mp.get_property_number("video-rotate")) or 0
		suppress_prop("video-rotate")
		mp.set_property_native("video-rotate", (cur + (tonumber(action.step) or 90)) % 360)
	elseif kind == "cycle_values" then
		local cur = tostring(mp.get_property(action.prop) or "")
		local values = action.values or {}
		local next_value = values[1]
		for i, v in ipairs(values) do
			if v == cur then
				next_value = values[(i % #values) + 1]
				break
			end
		end
		if next_value then
			suppress_prop(action.prop)
			mp.set_property(action.prop, next_value)
		end
	elseif kind == "reset_tweaks" then
		reset_tweaks()
	elseif kind == "reset_view" then
		reset_tweaks(RESET_VIEW)
	elseif kind == "reset_audio" then
		reset_tweaks(RESET_AUDIO)
	elseif kind == "reset_subs" then
		reset_tweaks(RESET_SUBS)
	elseif kind == "reset_playback" then
		reset_tweaks(RESET_PLAYBACK)
	elseif kind == "gui_reset" then
		reset_gui()
	elseif kind == "input" then
		if action.what == "sub-add" then
			prompt_sub_add()
		elseif action.what == "set_property" then
			if action.prop then
				prompt_setting(action.prop)
			else
				prompt_set_property()
			end
		elseif action.what == "keybind_filter" then
			prompt_keybind_filter()
		elseif action.what == "keybind_add" then
			prompt_keybind_add()
		elseif action.what == "keybind_rebind" then
			prompt_keybind_rebind()
		elseif action.what == "gui_set" then
			prompt_gui_setting(action.key)
		end
	elseif kind == "keybind_view" then
		state.keybind_selected = action.key
		menu_set_page("settings_key", true)
	elseif kind == "keybind_unbind" then
		if state.keybind_selected then
			unbind_key(state.keybind_selected)
			menu_back()
		end
	elseif kind == "keybind_clear" then
		clear_custom_bindings()
	elseif kind == "back" then
		menu_back()
	elseif kind == "close" then
		toggle_panel(state.panel_mode)
	end
	-- "page_hint" rows are labels only.
	draw_panel()
	activity()
end

on_activate = function(id, index)
	if id == "play" then
		mp.commandv("cycle", "pause")
	elseif id == "back" then
		relative_seek(-10)
	elseif id == "forward" then
		relative_seek(10)
	elseif id == "mute" then
		suppress_prop("mute")
		mp.set_property_native("mute", not state.mute)
	elseif id == "speed" then
		cycle_speed()
	elseif id == "playlist" then
		toggle_panel("playlist")
	elseif id == "menu" then
		toggle_panel("menu")
	elseif id == "fx" then
		toggle_panel("shaders")
	elseif id == "fullscreen" then
		mp.commandv("cycle", "fullscreen")
	elseif id == "header" then
		if state.panel_mode then
			menu_back()
		end
	elseif id == "row" then
		if state.panel_mode == "menu" then
			local rows = state.menu_view and state.menu_view.rows or {}
			local row = rows[(tonumber(index) or -1) + 1]
			if row and not row.disabled then
				menu_dispatch(row.action)
			end
		elseif state.panel_mode == "shaders" then
			apply_shader_row(index)
		elseif state.panel_mode == "playlist" then
			play_index(index)
			draw_panel()
		end
	end
	activity()
end

on_hover = function(id, index)
	state.hover = id
	state.hover_row = (id == "row") and index or nil
	update_tooltip()
	draw_hover()
	draw_transient()
end

on_drag = function(kind, f)
	if kind == "seekbar" then
		state.scrub = f
		local now = mp.get_time()
		if not state.last_scrub or (now - state.last_scrub) >= SCRUB_INTERVAL then
			state.last_scrub = now
			local t = seek_time(f)
			if t then
				mp.commandv("seek", string.format("%.3f", t), "absolute")
				state.time_pos = t
			end
		end
	else
		set_volume_fraction(f)
	end
	update_tooltip()
	draw_hover()
	draw_transient()
	arm_hide()
end

on_commit = function(kind, f)
	state.scrub = nil
	state.last_scrub = nil
	if kind == "seekbar" then
		local t = seek_time(f)
		if t then
			mp.commandv("seek", string.format("%.3f", t), "absolute+exact")
			state.time_pos = t
		end
	else
		set_volume_fraction(f)
	end
	update_tooltip()
	draw_hover()
	draw_transient()
	activity()
end

it = interact.new({
	on_hover = on_hover,
	on_drag = on_drag,
	on_commit = on_commit,
	on_activate = on_activate,
})

-- Pointer -------------------------------------------------------------------

local function refresh_pointer()
	local m = mp.get_property_native("mouse-pos")
	if m and m.x then
		return m.x, m.y
	end
	return state.mouse_x, state.mouse_y
end

local function on_pointer_move()
	if not state.enabled or state.text_input then
		return
	end
	local x, y = refresh_pointer()
	if x == nil or x < 0 or y == nil or y < 0 then
		if it then
			it:set_hover(nil)
		end
		update_tooltip()
		draw_hover()
		draw_transient()
		return
	end
	if x == state.mouse_x and y == state.mouse_y then
		return
	end
	state.mouse_x, state.mouse_y = x, y
	if not state.visible then
		show()
	end
	if lay and it then
		it:move(x, y)
	end
	update_tooltip()
	draw_hover()
	draw_transient()
	activity()
end

local function on_left(e)
	if not state.enabled or state.text_input then
		return
	end
	local x, y = refresh_pointer()
	state.mouse_x, state.mouse_y = x, y
	if not state.visible then
		show()
		return
	end
	if not lay then
		return
	end
	it:move(x, y)
	if e.event == "down" then
		it:down(x, y)
	elseif e.event == "up" then
		it:up(x, y)
	else
		it:press(x, y)
	end
	update_tooltip()
	draw_hover()
	draw_transient()
	activity()
end

local function on_left_dbl(e)
	if state.text_input then
		return
	end
	if e.event ~= "press" and e.event ~= "down" then
		return
	end
	local x, y = refresh_pointer()
	if not state.enabled or not state.visible or not lay then
		mp.commandv("cycle", "fullscreen")
		return
	end
	local id = interact.hit(lay, x, y, state.panel_scroll)
	if id == "video" or id == "bar" or id == nil then
		mp.commandv("cycle", "fullscreen")
	end
end

local function on_wheel(dir)
	if state.text_input then
		return
	end
	local x, y = refresh_pointer()
	state.mouse_x, state.mouse_y = x, y
	local target = "default"
	if state.enabled and state.visible and lay then
		target, dir = it:wheel(x, y, dir)
	end
	if target == "panel" then
		scroll_panel(-dir)
	elseif target == "volume" then
		suppress_prop("volume")
		mp.commandv("add", "volume", tostring(5 * dir))
		update_tooltip()
		draw_hover()
		draw_transient()
		activity()
	else
		-- mpv's built-in WHEEL_UP/DOWN defaults.
		mp.commandv("add", "volume", tostring(2 * dir))
	end
end

-- Dimensions ----------------------------------------------------------------

apply_dims = function(d)
	local w = math.floor(tonumber(d and d.w) or 0)
	local h = math.floor(tonumber(d and d.h) or 0)
	if w <= 0 or h <= 0 then
		if not state.no_dims_logged then
			msg.info("osd-dimensions is 0x0 (headless or no VO); drawing nothing")
			state.no_dims_logged = true
		end
		if state.w ~= 0 or state.h ~= 0 then
			state.w, state.h = 0, 0
			for _, name in ipairs(LAYERS) do
				layers[name].data = nil
			end
		end
		return
	end
	if w == state.w and h == state.h then
		return
	end
	state.w, state.h = w, h
	compute_layout()
	update_tooltip()
	if state.visible then
		draw_all()
	else
		clear_all()
	end
	publish()
end

-- Observers ----------------------------------------------------------------

mp.observe_property("pause", "native", function(_, v)
	if v == nil then
		return
	end
	state.pause = v == true
	if state.pause then
		show()
	else
		start_tick()
		activity()
	end
	draw_hover()
end)

mp.observe_property("time-pos", "native", function(_, v)
	if v == nil then
		return
	end
	local now = mp.get_time()
	local prev, prev_at = state.last_tp, state.last_tp_at
	state.time_pos = v
	state.last_tp = v
	state.last_tp_at = now
	if prev and prev_at and not state.pause and not (it and it.drag) then
		local dt = now - prev_at
		local dur = tonumber(state.duration) or 0
		-- A file that loops restarts time-pos at 0; that is not a user seek
		-- and must not pop the bar up on every loop iteration.
		local wrapped = dur > 0 and prev > dur - 0.75 and v < 0.75
		if dt > 0.0001 and math.abs((v - prev) - dt) > 0.4 and not wrapped then
			-- A default key binding seeked: reveal the bar.
			activity()
		end
	end
	if state.pause then
		draw_hover()
	end
end)

mp.observe_property("duration", "native", function(_, v)
	state.duration = v
	update_tooltip()
	draw_hover()
	draw_transient()
end)

mp.observe_property("volume", "native", function(_, v)
	if v == nil then
		return
	end
	state.volume = v
	draw_hover()
end)

mp.observe_property("mute", "native", function(_, v)
	state.mute = v == true
	draw_hover()
end)

mp.observe_property("speed", "native", function(_, v)
	if v == nil then
		return
	end
	state.speed = v
	draw_hover()
end)

mp.observe_property("fullscreen", "native", function(_, v)
	state.fullscreen = v == true
	draw_hover()
end)

mp.observe_property("media-title", "native", function(_, v)
	state.title = v or ""
	draw_hover()
end)

-- Properties the menu rows display.  They are cached here and redraw the
-- panel only while the menu is open, so they cost nothing during playback.
local function menu_prop(name, apply)
	mp.observe_property(name, "native", function(_, v)
		apply(v)
		if state.panel_mode == "menu" then
			draw_panel()
		end
	end)
end

menu_prop("track-list", function(v)
	state.track_list = type(v) == "table" and v or {}
end)
menu_prop("aid", function(v)
	state.aid = v
end)
menu_prop("sid", function(v)
	state.sid = v
end)
menu_prop("vid", function(v)
	state.vid = v
end)
menu_prop("chapter-list", function(v)
	state.chapter_list = type(v) == "table" and v or {}
end)
menu_prop("chapter", function(v)
	state.chapter = tonumber(v) or -1
end)
menu_prop("loop-file", function(v)
	state.loop_file = v
end)
menu_prop("loop-playlist", function(v)
	state.loop_playlist = v
end)
menu_prop("video-aspect-override", function(v)
	state.aspect = v
end)
menu_prop("sub-visibility", function(v)
	state.sub_visibility = v ~= false
end)
menu_prop("sub-delay", function(v)
	state.sub_delay = tonumber(v) or 0
end)
menu_prop("audio-delay", function(v)
	state.audio_delay = tonumber(v) or 0
end)
menu_prop("video-zoom", function(v)
	state.video_zoom = tonumber(v) or 0
end)
menu_prop("video-rotate", function(v)
	state.video_rotate = v
end)
menu_prop("deinterlace", function(v)
	state.deinterlace = v
end)
menu_prop("ab-loop-a", function(v)
	state.ab_loop_a = v
end)
menu_prop("ab-loop-b", function(v)
	state.ab_loop_b = v
end)
menu_prop("shuffle", function(v)
	state.shuffle = v == true
end)

local function playlist_label(entry)
	local title = entry and entry.title
	if not title or title == "" then
		local name = (entry and entry.filename) or ""
		local _, file = utils.split_path(name)
		if file and file ~= "" then
			title = file
		else
			title = name
		end
	end
	return title
end

mp.observe_property("playlist", "native", function(_, v)
	if v == nil then
		return
	end
	state.playlist = v
	state.playlist_count = #v
	state.playlist_labels = {}
	for i, entry in ipairs(v) do
		state.playlist_labels[i] = playlist_label(entry)
	end
	if lay then
		state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll, panel_count())
	end
	it:set_scroll(state.panel_scroll)
	draw_panel()
	draw_hover()
end)

mp.observe_property("playlist-pos", "native", function(_, v)
	state.playlist_pos = tonumber(v) or -1
	draw_panel()
	draw_hover()
end)

mp.observe_property("idle-active", "native", function(_, v)
	state.has_media = v ~= true
	if state.has_media then
		start_tick()
		arm_hide()
	else
		stop_tick()
	end
end)

mp.observe_property("eof-reached", "native", function(_, v)
	-- Reaching the end of a file is not user activity; playback usually pauses
	-- (or advances the playlist) right after, and the pause observer reveals
	-- the bar.  Popping the GUI up on every loop of a looping file would be
	-- noise, so nothing is shown here.
	state.eof = v == true
end)

mp.observe_property("demuxer-cache-state", "native", function(_, v)
	local end_time = nil
	if v and v["seekable-ranges"] then
		for _, range in ipairs(v["seekable-ranges"]) do
			local e = tonumber(range["end"])
			if e and (not end_time or e > end_time) then
				end_time = e
			end
		end
	end
	if end_time ~= state.buffered_end then
		state.buffered_end = end_time
		draw_hover()
	end
end)

mp.observe_property("osd-dimensions", "native", function(_, v)
	apply_dims(v)
end)

mp.observe_property("mouse-pos", "native", function(_, v)
	if not v then
		return
	end
	on_pointer_move()
end)

-- Key bindings.  Only keys the GUI needs are forced, and mpv's default action
-- is replicated whenever the GUI has nothing to do with the press.  Keys mpv
-- already binds stay with mpv: `Tab` is unbound upstream, `Shift+x` (X) is
-- unbound, `Shift+m` (M) is unbound, `g` is a no-op, and `Esc` defaults to
-- `set fullscreen no` (replicated below outside the panels).

mp.add_forced_key_binding("MBTN_LEFT", "mpvgui-left", on_left, { complex = true })
mp.add_forced_key_binding("MBTN_LEFT_DBL", "mpvgui-left-dbl", on_left_dbl, { complex = true })
mp.add_forced_key_binding("WHEEL_UP", "mpvgui-wheel-up", function()
	on_wheel(1)
end)
mp.add_forced_key_binding("WHEEL_DOWN", "mpvgui-wheel-down", function()
	on_wheel(-1)
end)
mp.add_forced_key_binding("Tab", "mpvgui-panel", function()
	if state.text_input then
		return
	end
	toggle_panel("playlist")
end)
mp.add_forced_key_binding("Shift+m", "mpvgui-menu", function()
	if state.text_input then
		return
	end
	toggle_panel("menu")
end)
mp.add_forced_key_binding("Shift+x", "mpvgui-shaders", function()
	if state.text_input then
		return
	end
	toggle_panel("shaders")
end)
mp.add_forced_key_binding("Esc", "mpvgui-back", function()
	if state.text_input then
		close_text_input(true)
		return
	end
	if state.panel_mode then
		menu_back()
	else
		-- mpv's default Esc binding.
		mp.commandv("set", "fullscreen", "no")
	end
end)
-- mpv's default MBTN_RIGHT is "cycle pause".  Keep it outside the GUI, but a
-- click on an open panel must not fall through to the video.
mp.add_forced_key_binding("MBTN_RIGHT", "mpvgui-right", function()
	if state.text_input then
		return
	end
	if state.panel_mode and state.visible then
		return
	end
	mp.commandv("cycle", "pause")
end)
mp.add_forced_key_binding("g", "mpvgui-toggle", function()
	if state.text_input then
		return
	end
	toggle_gui()
end)

-- Shaders ------------------------------------------------------------------

refresh_shader_rows = function()
	local entries = shaders.entries()
	local rows = {}
	local out = {}
	for i, entry in ipairs(entries) do
		local active = shaders.is_active(entry)
		rows[i] = { name = entry.name, kind = entry.kind, files = entry.files, active = active }
		out[i] = { name = entry.name, kind = entry.kind, active = active }
	end
	state.shader_rows = rows
	state.shader_active = shaders.active.name or "Off"
	mp.set_property(
		"user-data/" .. SCRIPT .. "/shaders",
		utils.format_json({ active = shaders.active.name, count = #out, entries = out })
	)
	if lay then
		state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll, panel_count())
	end
	if it then
		it:set_scroll(state.panel_scroll)
	end
end

show_toast = function(text)
	if not text or text == "" then
		return
	end
	state.toast = { text = text }
	mp.set_property("user-data/" .. SCRIPT .. "/toast", text)
	if not state.visible then
		-- A property change from a key press must be visible even when the
		-- bar has auto-hidden; show() draws the toast with everything else.
		show()
	else
		draw_transient()
		arm_hide()
	end
	if toast_timer then
		toast_timer:kill()
	end
	toast_timer = mp.add_timeout(3, function()
		toast_timer = nil
		state.toast = nil
		mp.set_property("user-data/" .. SCRIPT .. "/toast", "")
		draw_transient()
	end)
end

-- Settings ------------------------------------------------------------------

trim = function(s)
	return tostring(s or ""):match("^%s*(.-)%s*$")
end

config_path = function(rel)
	local ok, dir = pcall(mp.command_native, { "expand-path", "~~/" })
	if ok and type(dir) == "string" and dir:sub(1, 1) == "/" then
		return utils.join_path(dir, rel)
	end
	local opt = mp.get_property("options/config-dir")
	if type(opt) == "string" and opt ~= "" then
		return utils.join_path(opt, rel)
	end
	return rel
end

ensure_dir = function(dir)
	if not dir or dir == "" then
		return
	end
	pcall(utils.subprocess, { args = { "mkdir", "-p", dir }, playback_only = false })
end

local suppress_until = {}

suppress_prop = function(name)
	if name then
		suppress_until[name] = mp.get_time() + 0.6
	end
end

local function fmt_float(v, pattern)
	local n = tonumber(v)
	if n == nil then
		return tostring(v)
	end
	return string.format(pattern or "%.3f", n)
end

local function fmt_secs(v)
	return string.format("%+.2fs", tonumber(v) or 0)
end

local function onoff(v)
	if v == true then
		return "on"
	elseif v == false then
		return "off"
	end
	return tostring(v)
end

local TWEAK_FORMAT = {
	["video-zoom"] = function(v)
		return fmt_float(v, "%.3f")
	end,
	["video-pan-x"] = function(v)
		return fmt_float(v, "%.3f")
	end,
	["video-pan-y"] = function(v)
		return fmt_float(v, "%.3f")
	end,
	["video-align-x"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["video-align-y"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["panscan"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["brightness"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["contrast"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["saturation"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["gamma"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["hue"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["speed"] = function(v)
		return render.speed_label(v)
	end,
	["volume"] = function(v)
		return string.format("%d%%", tonumber(v) or 0)
	end,
	["mute"] = onoff,
	["sub-visibility"] = onoff,
	["deband"] = onoff,
	["audio-delay"] = fmt_secs,
	["sub-delay"] = fmt_secs,
	["sub-speed"] = function(v)
		return string.format("%.2fx", tonumber(v) or 1)
	end,
	["sub-scale"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["sub-pos"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["sub-font-size"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["sub-border-size"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["sub-shadow-offset"] = function(v)
		return fmt_float(v, "%.2f")
	end,
	["video-rotate"] = function(v)
		if v == nil or v == "no" then
			return "off"
		end
		return tostring(v) .. "°"
	end,
	["video-aspect-override"] = function(v)
		local n = tonumber(v)
		if not n or n < 0 then
			return "default"
		end
		return string.format("%.3f", n)
	end,
	["ab-loop-a"] = function(v)
		if v == nil or v == "no" then
			return "off"
		end
		return render.fmt_time(v)
	end,
	["ab-loop-b"] = function(v)
		if v == nil or v == "no" then
			return "off"
		end
		return render.fmt_time(v)
	end,
}

notify_prop = function(name, v)
	if not state.notify_ready then
		return
	end
	local now = mp.get_time()
	if now < (state.suppress_all_until or 0) then
		return
	end
	local until_t = suppress_until[name]
	if until_t and now < until_t then
		return
	end
	if state.last_notify[name] and now - state.last_notify[name] < 0.25 then
		return
	end
	state.last_notify[name] = now
	local fmt = TWEAK_FORMAT[name]
	local text = fmt and fmt(v) or tostring(v)
	show_toast(name .. " = " .. text)
end

watch_prop = function(name)
	state.settings[name] = mp.get_property_native(name)
	mp.observe_property(name, "native", function(_, v)
		local old = state.settings[name]
		state.settings[name] = v
		if old ~= v then
			notify_prop(name, v)
		end
		if state.panel_mode == "menu" then
			draw_panel()
		end
	end)
end

reset_tweaks = function(names)
	names = names or RESET_NAMES
	local count = 0
	for _, name in ipairs(names) do
		local default = mp.get_property_native("option-info/" .. name .. "/default-value")
		if default ~= nil then
			suppress_prop(name)
			local ok = pcall(mp.set_property_native, name, default)
			if ok then
				count = count + 1
			end
		end
	end
	show_toast("reset " .. tostring(count) .. " tweaks")
	draw_panel()
	publish()
end

save_gui_options = function()
	local path = config_path("script-opts/mpvgui.conf")
	ensure_dir(utils.split_path(path))
	local f = io.open(path, "w")
	if not f then
		show_toast("applied; could not save " .. path)
		return
	end
	f:write(
		string.format(
			"autohide_delay=%s\nscale=%s\n",
			tostring(opts.autohide_delay),
			tostring(opts.scale)
		)
	)
	f:close()
end

reset_gui = function()
	opts.autohide_delay = 2.5
	opts.scale = 1.0
	state.gui.autohide_delay = 2.5
	state.gui.scale = 1.0
	save_gui_options()
	compute_layout()
	draw_all()
	show_toast("interface reset")
end

-- Text input.  mpv 0.41.0 as packaged here has no mp.input module, so the GUI
-- owns the prompt: a top ASS layer draws the label/text and forced bindings
-- capture characters while it is open.  Bindings are added on open and removed
-- on close so normal playback keys are untouched otherwise.

draw_prompt = function()
	local ti = state.text_input
	mp.set_property(
		"user-data/" .. SCRIPT .. "/input",
		ti and utils.format_json({ label = ti.label, text = ti.text, cursor = ti.cursor }) or ""
	)
	if not lay then
		return
	end
	set_layer("prompt", ti and render.prompt(lay, state) or "")
	publish()
end

local function text_input_insert(ch)
	local ti = state.text_input
	if not ti or not ch or ch == "" then
		return
	end
	ch = ch:gsub("[\r\n]", "")
	if ch == "" then
		return
	end
	local c = math.max(0, math.min(#ti.text, ti.cursor))
	ti.text = ti.text:sub(1, c) .. ch .. ti.text:sub(c + 1)
	ti.cursor = c + #ch
	draw_prompt()
end

-- Byte offset of the previous/next UTF-8 codepoint.  Cursor positions are
-- always left at a codepoint boundary so deleting a non-ASCII character cannot
-- split its bytes.
local function prev_char_index(s, pos)
	local i = math.max(0, math.min(#s, pos))
	while i > 0 do
		local b = s:byte(i)
		i = i - 1
		if b and (b < 0x80 or b >= 0xC0) then
			break
		end
	end
	return i
end

local function next_char_index(s, pos)
	local i = math.max(0, math.min(#s, pos))
	while i < #s do
		i = i + 1
		local b = s:byte(i + 1)
		if b and (b < 0x80 or b >= 0xC0) then
			break
		end
	end
	return i
end

local function text_input_backspace()
	local ti = state.text_input
	if not ti or ti.cursor <= 0 then
		return
	end
	local c = prev_char_index(ti.text, ti.cursor)
	ti.text = ti.text:sub(1, c) .. ti.text:sub(ti.cursor + 1)
	ti.cursor = c
	draw_prompt()
end

local function text_input_delete()
	local ti = state.text_input
	if not ti or ti.cursor >= #ti.text then
		return
	end
	local c = next_char_index(ti.text, ti.cursor)
	ti.text = ti.text:sub(1, ti.cursor) .. ti.text:sub(c + 1)
	draw_prompt()
end

local function text_input_left()
	local ti = state.text_input
	if not ti then
		return
	end
	ti.cursor = prev_char_index(ti.text, ti.cursor)
	draw_prompt()
end

local function text_input_right()
	local ti = state.text_input
	if not ti then
		return
	end
	ti.cursor = next_char_index(ti.text, ti.cursor)
	draw_prompt()
end

local function text_input_home()
	local ti = state.text_input
	if ti then
		ti.cursor = 0
		draw_prompt()
	end
end

local function text_input_end()
	local ti = state.text_input
	if ti then
		ti.cursor = #ti.text
		draw_prompt()
	end
end

local function text_input_submit()
	local ti = state.text_input
	if not ti then
		return
	end
	local text = ti.text
	local submit = ti.on_submit
	close_text_input(false)
	if submit then
		submit(text)
	end
end

local TEXT_SECTION = "mpvgui-prompt"

close_text_input = function(canceled)
	local ti = state.text_input
	if not ti then
		return
	end
	mp.disable_key_bindings(TEXT_SECTION)
	state.text_input = nil
	draw_prompt()
	arm_hide()
	if canceled and ti.on_cancel then
		ti.on_cancel()
	end
end

open_text_input = function(label, default, on_submit, on_cancel)
	if state.text_input then
		close_text_input(false)
	end
	local text = tostring(default or "")
	state.text_input = {
		label = tostring(label or ""),
		text = text,
		cursor = #text,
		on_submit = on_submit,
		on_cancel = on_cancel,
	}
	mp.enable_key_bindings(TEXT_SECTION)
	stop_hide()
	if not state.visible then
		show()
	end
	draw_prompt()
end

-- The prompt keys live in a forced section that is enabled only while a
-- prompt is open.  Disabling the section restores mpv's own bindings for those
-- keys; adding and removing forced bindings instead would leave arrows, Enter
-- and Backspace unbound for the rest of the session.
local function register_text_input()
	mp.add_key_binding(nil, "text-any", function(e)
		text_input_insert(e and e.key_text)
	end, { complex = true })
	mp.add_key_binding(nil, "text-bs", text_input_backspace)
	mp.add_key_binding(nil, "text-del", text_input_delete)
	mp.add_key_binding(nil, "text-left", text_input_left)
	mp.add_key_binding(nil, "text-right", text_input_right)
	mp.add_key_binding(nil, "text-home", text_input_home)
	mp.add_key_binding(nil, "text-end", text_input_end)
	mp.add_key_binding(nil, "text-enter", text_input_submit)
	mp.add_key_binding(nil, "text-kp-enter", text_input_submit)
	local name = mp.get_script_name() or SCRIPT
	local lines = {
		"any_unicode script-binding " .. name .. "/text-any",
		"BS script-binding " .. name .. "/text-bs",
		"DEL script-binding " .. name .. "/text-del",
		"LEFT script-binding " .. name .. "/text-left",
		"RIGHT script-binding " .. name .. "/text-right",
		"HOME script-binding " .. name .. "/text-home",
		"END script-binding " .. name .. "/text-end",
		"ENTER script-binding " .. name .. "/text-enter",
		"KP_ENTER script-binding " .. name .. "/text-kp-enter",
	}
	mp.commandv("define-section", TEXT_SECTION, table.concat(lines, "\n"), "force")
	mp.disable_key_bindings(TEXT_SECTION)
end
register_text_input()

prompt_text = function(prompt, cb)
	open_text_input(prompt, "", cb, nil)
end

prompt_setting = function(prop)
	if not prop or prop == "" then
		return
	end
	local cur = mp.get_property(prop)
	if cur == nil then
		show_toast("unknown property: " .. tostring(prop))
		return
	end
	prompt_text(prop .. " = " .. tostring(cur) .. " (value, or +N/-N): ", function(text)
		text = trim(text)
		if text == "" then
			return
		end
		suppress_prop(prop)
		local ok, err
		if text:match("^[+-]") and tonumber(text) then
			ok, err = pcall(mp.commandv, "add", prop, text)
		else
			ok, err = pcall(mp.set_property, prop, text)
		end
		if ok then
			show_toast(prop .. " = " .. tostring(mp.get_property(prop)))
		else
			show_toast("set failed: " .. tostring(err))
		end
		draw_panel()
		publish()
	end)
end

prompt_set_property = function()
	prompt_text("property name (e.g. video-sync): ", function(name)
		name = trim(name)
		if name == "" then
			return
		end
		prompt_setting(name)
	end)
end

prompt_gui_setting = function(key)
	local label = key == "autohide_delay" and "autohide delay (seconds)" or "GUI scale"
	local cur = opts[key]
	prompt_text(label .. " = " .. tostring(cur) .. ": ", function(text)
		local n = tonumber(text)
		if not n then
			show_toast("not a number")
			return
		end
		if key == "autohide_delay" then
			n = math.max(0, n)
		else
			n = math.max(0.2, math.min(4, n))
		end
		opts[key] = n
		state.gui[key] = n
		save_gui_options()
		compute_layout()
		draw_all()
		show_toast(label .. " = " .. tostring(n))
	end)
end

-- Keybindings ---------------------------------------------------------------

save_custom_bindings = function()
	local path = config_path("mpvgui/input.conf")
	ensure_dir(utils.split_path(path))
	local keys = {}
	for key in pairs(state.custom_bindings) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return a:lower() < b:lower()
	end)
	local f = io.open(path, "w")
	if not f then
		show_toast("cannot write " .. path)
		return false
	end
	f:write("# mpvgui custom keybindings (Settings > Keybindings)\n")
	for _, key in ipairs(keys) do
		f:write(key .. " " .. tostring(state.custom_bindings[key]) .. "\n")
	end
	f:close()
	return true
end

load_custom_bindings = function()
	local path = config_path("mpvgui/input.conf")
	local f = io.open(path, "r")
	if not f then
		return
	end
	for line in f:lines() do
		line = line:match("^%s*(.-)%s*$")
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local key, cmd = line:match("^(%S+)%s+(.+)$")
			if key and cmd then
				state.custom_bindings[key] = cmd
			end
		end
	end
	f:close()
	if next(state.custom_bindings) ~= nil then
		local ok, err = pcall(mp.commandv, "load-input-conf", path)
		if not ok then
			msg.warn("custom input.conf: " .. tostring(err))
		end
	end
end

refresh_input_bindings = function()
	state.input_bindings = mp.get_property_native("input-bindings") or {}
	if state.panel_mode == "menu" then
		draw_panel()
	end
end

effective_binding = function(key)
	local best
	for _, b in ipairs(state.input_bindings or {}) do
		if b.key == key and b.section == "default" then
			if not best then
				best = b
			elseif best.is_weak and not b.is_weak then
				best = b
			elseif not best.is_weak and not b.is_weak then
				best = b
			end
		end
	end
	return best
end

bind_key = function(key, cmd, quiet)
	key = trim(key)
	cmd = trim(cmd):gsub("[\r\n]+", " ")
	if key == "" or cmd == "" then
		show_toast("key and command required")
		return false
	end
	if RESERVED_KEYS[key:lower()] then
		show_toast("reserved by the GUI: " .. key)
		return false
	end
	local prev = state.custom_bindings[key]
	pcall(mp.commandv, "keybind", key, cmd, "mpvgui")
	refresh_input_bindings()
	local got = effective_binding(key)
	if not got or got.cmd ~= cmd then
		if prev ~= nil then
			state.custom_bindings[key] = prev
		else
			state.custom_bindings[key] = nil
		end
		save_custom_bindings()
		show_toast("invalid key or command: " .. key)
		return false
	end
	state.custom_bindings[key] = cmd
	save_custom_bindings()
	refresh_input_bindings()
	if not quiet then
		show_toast("bound " .. key)
	end
	draw_panel()
	return true
end

unbind_key = function(key, quiet)
	key = trim(key)
	if key == "" then
		return false
	end
	if RESERVED_KEYS[key:lower()] then
		show_toast("reserved by the GUI: " .. key)
		return false
	end
	pcall(mp.commandv, "keybind", key, "ignore", "mpvgui")
	state.custom_bindings[key] = "ignore"
	save_custom_bindings()
	refresh_input_bindings()
	if not quiet then
		show_toast("unbound " .. key)
	end
	draw_panel()
	return true
end

clear_custom_bindings = function()
	for key in pairs(state.custom_bindings) do
		pcall(mp.commandv, "keybind", key, "ignore", "mpvgui")
	end
	state.custom_bindings = {}
	local path = config_path("mpvgui/input.conf")
	os.remove(path)
	refresh_input_bindings()
	show_toast("custom keybindings removed; restart mpv to restore defaults")
	draw_panel()
end

prompt_keybind_filter = function()
	prompt_text("filter key/command (empty = all): ", function(text)
		state.keybind_filter = trim(text)
		state.panel_scroll = 0
		refresh_menu_view()
		draw_panel()
		publish_menu()
		publish()
	end)
end

prompt_keybind_add = function()
	prompt_text("key to bind (e.g. Ctrl+1, F5): ", function(key)
		key = trim(key)
		if key == "" then
			return
		end
		prompt_text("command for " .. key .. ": ", function(cmd)
			cmd = trim(cmd)
			if cmd == "" then
				return
			end
			if bind_key(key, cmd) then
				state.keybind_selected = key
				menu_set_page("settings_key", true)
				draw_panel()
			end
		end)
	end)
end

prompt_keybind_rebind = function()
	local key = state.keybind_selected
	local binding = key and effective_binding(key)
	if not binding or binding.cmd == "ignore" then
		return
	end
	prompt_text(
		"new key for '" .. tostring(binding.cmd) .. "' (current " .. key .. "): ",
		function(newkey)
			newkey = trim(newkey)
			if newkey == "" then
				return
			end
			if bind_key(newkey, binding.cmd, true) then
				if newkey ~= key then
					unbind_key(key, true)
				end
				state.keybind_selected = newkey
				show_toast("rebound to " .. newkey)
			end
			refresh_menu_view()
			draw_panel()
		end
	)
end

-- Called only after a chain actually changed: the panel shows the new active
-- row, so exactly the panel layer is redrawn (plus the toast, if any).
on_shaders_changed = function()
	refresh_shader_rows()
	draw_panel()
	publish()
end

apply_shader_row = function(index)
	local row = state.shader_rows[(tonumber(index) or -1) + 1]
	if not row then
		return
	end
	if row.kind == "import" then
		prompt_import()
		return
	end
	shaders.apply({ name = row.name, kind = row.kind, files = row.files })
end

prompt_import = function()
	local function use(path)
		if path and path ~= "" and shaders.import(path) then
			-- The copy finishes asynchronously (mkdir is fire-and-forget).
			mp.add_timeout(0.4, function()
				refresh_shader_rows()
				draw_all()
			end)
		end
	end
	prompt_text("shader path: ", use)
end

shaders.set_callbacks({ toast = show_toast, on_change = on_shaders_changed })

-- mpv reports a failed user shader after the next frame; libplacebo's wording
-- on this build is "input:NN: error: ..." + "vk_compile_glsl(...): ..." +
-- "Failed executing hook, disabling" (verified against a broken shader).
local COMPILE_PATTERNS = {
	"vk_compile_glsl",
	"Failed executing hook, disabling",
	"Error compiling shader",
	"failed to compile",
	"Shader compilation failed",
}

mp.enable_messages("error")
mp.register_event("log-message", function(e)
	local text = e and e.text
	if not text then
		return
	end
	for _, pattern in ipairs(COMPILE_PATTERNS) do
		if text:find(pattern, 1, true) then
			if shaders.compile_failed() then
				refresh_shader_rows()
				draw_panel()
				publish()
			end
			return
		end
	end
end)

-- Instrumentation -----------------------------------------------------------

mp.register_script_message(SCRIPT .. "-reset-stats", function()
	for _, name in ipairs(LAYERS) do
		layers[name].updates = 0
	end
	publish()
end)

-- mpvgui-shader <name|off|index>  (index is 0-based into `entries`)
mp.register_script_message(SCRIPT .. "-shader", function(arg)
	if not arg or arg == "" then
		return
	end
	local ok
	local index = tonumber(arg)
	if index then
		ok = shaders.apply_index(index)
	elseif arg:lower() == "off" then
		ok = shaders.apply({ name = "Off", kind = "off", files = {} })
	else
		ok = shaders.apply_name(arg)
	end
	if ok then
		refresh_shader_rows()
		draw_panel()
	else
		show_toast("shader not found: " .. tostring(arg))
	end
	publish()
end)

mp.register_script_message(SCRIPT .. "-import", function(path)
	if path and shaders.import(path) then
		mp.add_timeout(0.4, function()
			refresh_shader_rows()
			draw_all()
		end)
	end
end)

-- mpvgui-keybind <key> <command>   bind and persist to ~~/mpvgui/input.conf
-- mpvgui-keyunbind <key>           disable the key and persist the override
mp.register_script_message(SCRIPT .. "-keybind", function(key, cmd)
	if key and cmd and key ~= "" and cmd ~= "" then
		bind_key(key, cmd)
	end
end)

mp.register_script_message(SCRIPT .. "-keyunbind", function(key)
	if key and key ~= "" then
		unbind_key(key)
	end
end)

-- mpvgui-reset-tweaks  reset the accidental-key properties (same as Settings)
mp.register_script_message(SCRIPT .. "-reset-tweaks", function()
	reset_tweaks()
end)

-- mpvgui-page <page|off>  opens a menu page (root, chapters, audio, subs,
-- video, speed, aspect, loop, tools) or closes whatever panel is open.
mp.register_script_message(SCRIPT .. "-page", function(arg)
	if not arg or arg == "" then
		return
	end
	if arg == "off" then
		if state.panel_mode then
			toggle_panel(state.panel_mode)
		end
		return
	end
	if state.panel_mode ~= "menu" then
		toggle_panel("menu")
	else
		state.menu_page = "root"
	end
	state.menu_stack = {}
	menu_set_page(arg, false)
	draw_all()
	publish()
end)

-- Events --------------------------------------------------------------------

mp.register_event("start-file", function()
	-- Properties such as deinterlace/volume can change while the file is
	-- opened; those are not the stray key presses this notification is for.
	state.suppress_all_until = mp.get_time() + 1.0
end)

mp.register_event("file-loaded", function()
	state.suppress_all_until = mp.get_time() + 1.0
	state.last_tp = nil
	state.last_tp_at = nil
	state.buffered_end = nil
	state.scrub = nil
	state.panel_scroll = 0
	it:set_scroll(0)
	apply_dims(mp.get_property_native("osd-dimensions"))
	start_tick()
	draw_panel()
	draw_hover()
end)

mp.register_event("video-reconfig", function()
	apply_dims(mp.get_property_native("osd-dimensions"))
end)

-- Init ----------------------------------------------------------------------

state.pause = mp.get_property_native("pause") == true
state.duration = mp.get_property_native("duration")
state.volume = tonumber(mp.get_property_native("volume")) or 100
state.mute = mp.get_property_native("mute") == true
state.speed = tonumber(mp.get_property_native("speed")) or 1
state.fullscreen = mp.get_property_native("fullscreen") == true
state.title = mp.get_property_native("media-title") or ""
state.playlist = mp.get_property_native("playlist") or {}
state.playlist_count = #state.playlist
for i, entry in ipairs(state.playlist) do
	state.playlist_labels[i] = playlist_label(entry)
end
state.playlist_pos = tonumber(mp.get_property_native("playlist-pos")) or -1
state.has_media = mp.get_property_native("idle-active") ~= true
state.track_list = mp.get_property_native("track-list") or {}
state.aid = mp.get_property_native("aid")
state.sid = mp.get_property_native("sid")
state.vid = mp.get_property_native("vid")
state.chapter_list = mp.get_property_native("chapter-list") or {}
state.chapter = tonumber(mp.get_property_native("chapter") or -1)
state.loop_file = mp.get_property_native("loop-file")
state.loop_playlist = mp.get_property_native("loop-playlist")
state.aspect = mp.get_property_native("video-aspect-override")
state.sub_visibility = mp.get_property_native("sub-visibility") ~= false
state.sub_delay = tonumber(mp.get_property_native("sub-delay") or 0)
state.audio_delay = tonumber(mp.get_property_native("audio-delay") or 0)
state.video_zoom = tonumber(mp.get_property_native("video-zoom") or 0)
state.video_rotate = mp.get_property_native("video-rotate")
state.deinterlace = mp.get_property_native("deinterlace")
state.ab_loop_a = mp.get_property_native("ab-loop-a")
state.ab_loop_b = mp.get_property_native("ab-loop-b")
state.shuffle = mp.get_property_native("shuffle") == true

load_custom_bindings()
state.input_bindings = mp.get_property_native("input-bindings") or {}
mp.observe_property("input-bindings", "native", function(_, v)
	state.input_bindings = v or {}
	if state.panel_mode == "menu" then
		draw_panel()
	end
end)
for _, name in ipairs(SETTINGS_PROPS) do
	watch_prop(name)
end

mp.set_property_native("user-data/" .. SCRIPT .. "/enabled", 1)
refresh_shader_rows()
shaders.load_state()
refresh_shader_rows()
publish_menu()
apply_dims(mp.get_property_native("osd-dimensions"))
show()
publish()
publish_layout()
local dims = string.format("%dx%d", state.w, state.h)
local autohide = tostring(opts.autohide_delay or 0)
msg.info(
	"loaded: osd "
		.. dims
		.. ", "
		.. state.playlist_count
		.. " playlist entries, autohide "
		.. autohide
		.. "s, shader "
		.. tostring(shaders.active.name)
		.. " ("
		.. tostring(#shaders.active_chain)
		.. " files)"
)
state.notify_ready = true
