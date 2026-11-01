-- mpvgui: a zero-overhead GUI for stock mpv.
--
-- Architecture: mpv is the only Wayland client; every pixel of the GUI is an
-- `ass-events` OSD overlay drawn by this script.  No extra window, no extra
-- process, nothing allocated per video frame.
--
-- Layers (separate overlay objects, ordered back to front):
--   static    bar background + tracks          redrawn on layout change only
--   hover     icons, labels, fills, title       redrawn on state/hover change
--   panel     playlist rows                     redrawn on list/selection change
--   transient seek / volume tooltip             redrawn on tooltip change
--
-- Updates are event driven.  The single timer that exists is the 4 Hz
-- seekbar sampler, and it only runs while the bar is visible during playback.

local msg = require("mp.msg")
local options = require("mp.options")
local utils = require("mp.utils")

local interact = require("interact")
local layout = require("layout")
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

local LAYERS = { "static", "hover", "panel", "transient" }
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
	shader_rows = {},
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
	hover = nil,
	mouse_x = -1,
	mouse_y = -1,
	scrub = nil,
	last_scrub = nil,
	last_tp = nil,
	last_tp_at = nil,
	tooltip = nil,
	no_dims_logged = false,
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

compute_layout = function()
	if state.w <= 0 or state.h <= 0 then
		lay = nil
		if it then
			it:set_layout(nil, state.panel_scroll)
		end
		return
	end
	lay = layout.compute(state.w, state.h, state.panel_open, opts.scale)
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
	if not state.visible or not state.enabled or state.pause or not state.has_media then
		return
	end
	if it and it.drag then
		return
	end
	local delay = tonumber(opts.autohide_delay) or 2.5
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
	state.visible = false
	stop_hide()
	stop_tick()
	state.tooltip = nil
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
	mp.set_property_number("volume", math.floor(f * 100 + 0.5))
	if state.mute then
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
	local count = state.panel_mode == "shaders" and #state.shader_rows or #state.playlist
	state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll + delta, count)
	if it then
		it:set_scroll(state.panel_scroll)
	end
	draw_panel()
	activity()
end

-- Opens/closes the side panel. `mode` is "playlist" or "shaders"; calling it
-- with the currently open mode closes the panel.
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
	end
	state.panel_open = state.panel_mode ~= nil
	if state.panel_mode == "shaders" then
		refresh_shader_rows()
	end
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

on_activate = function(id, index)
	if id == "play" then
		mp.commandv("cycle", "pause")
	elseif id == "back" then
		relative_seek(-10)
	elseif id == "forward" then
		relative_seek(10)
	elseif id == "mute" then
		mp.set_property_native("mute", not state.mute)
	elseif id == "speed" then
		cycle_speed()
	elseif id == "playlist" then
		toggle_panel("playlist")
	elseif id == "fx" then
		toggle_panel("shaders")
	elseif id == "fullscreen" then
		mp.commandv("cycle", "fullscreen")
	elseif id == "row" then
		if state.panel_mode == "shaders" then
			apply_shader_row(index)
		else
			play_index(index)
			draw_panel()
		end
	end
	activity()
end

on_hover = function(id)
	state.hover = id
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
	if not state.enabled then
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
	if not state.enabled then
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
	local x, y = refresh_pointer()
	state.mouse_x, state.mouse_y = x, y
	local target = "default"
	if state.enabled and state.visible and lay then
		target, dir = it:wheel(x, y, dir)
	end
	if target == "panel" then
		scroll_panel(-dir)
	elseif target == "volume" then
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
	if lay and state.panel_mode ~= "shaders" then
		state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll, #v)
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

-- Key bindings.  Only what the GUI itself needs is forced; every other key
-- stays bound to mpv's defaults.

mp.add_forced_key_binding("MBTN_LEFT", "mpvgui-left", on_left, { complex = true })
mp.add_forced_key_binding("MBTN_LEFT_DBL", "mpvgui-left-dbl", on_left_dbl, { complex = true })
mp.add_forced_key_binding("WHEEL_UP", "mpvgui-wheel-up", function()
	on_wheel(1)
end)
mp.add_forced_key_binding("WHEEL_DOWN", "mpvgui-wheel-down", function()
	on_wheel(-1)
end)
mp.add_forced_key_binding("Tab", "mpvgui-panel", function()
	toggle_panel("playlist")
end)
mp.add_forced_key_binding("Shift+s", "mpvgui-shaders", function()
	toggle_panel("shaders")
end)
mp.add_forced_key_binding("Esc", "mpvgui-close-panel", function()
	if state.panel_mode then
		toggle_panel(state.panel_mode)
	end
end)
-- mpv's default MBTN_RIGHT is "cycle pause".  Keep it outside the GUI, but a
-- click on an open panel must not fall through to the video.
mp.add_forced_key_binding("MBTN_RIGHT", "mpvgui-right", function()
	if state.panel_mode and state.visible then
		return
	end
	mp.commandv("cycle", "pause")
end)
mp.add_forced_key_binding("g", "mpvgui-toggle", function()
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
	mp.set_property(
		"user-data/" .. SCRIPT .. "/shaders",
		utils.format_json({ active = shaders.active.name, count = #out, entries = out })
	)
	if lay then
		local count = state.panel_mode == "shaders" and #rows or #state.playlist
		state.panel_scroll = layout.clamp_scroll(lay, state.panel_scroll, count)
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
	draw_transient()
	if toast_timer then
		toast_timer:kill()
	end
	toast_timer = mp.add_timeout(3, function()
		toast_timer = nil
		state.toast = nil
		draw_transient()
	end)
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
		if shaders.import(path) then
			-- The copy finishes asynchronously (mkdir is fire-and-forget).
			mp.add_timeout(0.4, function()
				refresh_shader_rows()
				draw_all()
			end)
		end
	end
	if not mp.input then
		show_toast("import: no input API")
		return
	end
	local ok, result = pcall(mp.input.get, { prompt = "shader path: " }, function(text)
		if text and text ~= "" then
			use(text)
		end
	end)
	if not ok then
		show_toast("import: input unavailable")
	elseif type(result) == "string" and result ~= "" then
		use(result)
	end
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

-- Events --------------------------------------------------------------------

mp.register_event("file-loaded", function()
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

mp.set_property_native("user-data/" .. SCRIPT .. "/enabled", 1)
refresh_shader_rows()
shaders.load_state()
refresh_shader_rows()
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
