-- Page definitions for the clickable menu panel.
--
-- Everything here is pure data: a page is a title plus rows, and a row is
-- `{ label, detail, active, disabled, action }`.  `action` is a small table
-- that main.lua executes (set a property, run a command, open another page,
-- ...), so this module never touches mp.* and stays trivially reviewable.
--
-- The rows are rebuilt from the state snapshot main.lua keeps (track list,
-- chapter list, current properties).  Nothing is cached between rebuilds: a
-- redraw of the panel is the only cost, and it happens on state change only.

local render = require("render")

local menu = {}

-- ISO 639 codes -> display names, for track rows that have no title.
local LANG = {
	ara = "Arabic",
	chi = "Chinese",
	zho = "Chinese",
	zh = "Chinese",
	ces = "Czech",
	cze = "Czech",
	dan = "Danish",
	deu = "German",
	ger = "German",
	ell = "Greek",
	gre = "Greek",
	eng = "English",
	en = "English",
	fin = "Finnish",
	fra = "French",
	fre = "French",
	fr = "French",
	heb = "Hebrew",
	hin = "Hindi",
	hi = "Hindi",
	hun = "Hungarian",
	ind = "Indonesian",
	ita = "Italian",
	it = "Italian",
	jpn = "Japanese",
	ja = "Japanese",
	kor = "Korean",
	ko = "Korean",
	nld = "Dutch",
	dut = "Dutch",
	nor = "Norwegian",
	pol = "Polish",
	por = "Portuguese",
	pt = "Portuguese",
	ron = "Romanian",
	rum = "Romanian",
	rus = "Russian",
	ru = "Russian",
	spa = "Spanish",
	es = "Spanish",
	swe = "Swedish",
	tha = "Thai",
	tur = "Turkish",
	ukr = "Ukrainian",
	vie = "Vietnamese",
}

local CHANNELS = { [1] = "mono", [2] = "stereo", [6] = "5.1", [8] = "7.1" }

-- Page order used by the root menu; the ids are also the `menu` script-message
-- argument and the published user-data page name.
menu.PAGES = {
	"playlist",
	"chapters",
	"audio",
	"subs",
	"video",
	"speed",
	"aspect",
	"loop",
	"tools",
	"shaders",
	"settings",
	"settings_video",
	"settings_audio",
	"settings_subs",
	"settings_playback",
	"settings_interface",
	"settings_keys",
	"settings_key",
}

local function value(v)
	if v == nil then
		return "auto"
	elseif v == false then
		return "no"
	elseif v == true then
		return "yes"
	elseif type(v) == "number" then
		if v == math.floor(v) then
			return string.format("%d", v)
		end
		return string.format("%.3f", v)
	end
	return tostring(v)
end

local function track_name(t)
	if t.title and t.title ~= "" then
		return t.title
	end
	local code = t.lang and tostring(t.lang):lower()
	if code and LANG[code] then
		return LANG[code]
	end
	if code and code ~= "" then
		return code:upper()
	end
	return "Track " .. value(t.id)
end

local function track_detail(t)
	local bits = {}
	if t.codec and t.codec ~= "" then
		bits[#bits + 1] = tostring(t.codec):upper()
	end
	local ch = tonumber(t.channels)
	if ch and ch > 0 then
		bits[#bits + 1] = CHANNELS[ch] or (string.format("%dch", ch))
	end
	if t["demux-w"] and t["demux-h"] then
		bits[#bits + 1] = string.format("%dx%d", t["demux-w"], t["demux-h"])
	end
	if t.default then
		bits[#bits + 1] = "default"
	end
	if t.forced then
		bits[#bits + 1] = "forced"
	end
	if t.external then
		bits[#bits + 1] = "external"
	end
	if t.image then
		bits[#bits + 1] = "image"
	end
	return table.concat(bits, " · ")
end

local function tracks_of(state, kind)
	local out = {}
	for _, t in ipairs(state.track_list or {}) do
		if t.type == kind then
			out[#out + 1] = t
		end
	end
	return out
end

-- Label of the currently selected track of `kind`, for the root menu detail.
-- `prop` is the selection property ("aid", "sid", "vid").
local function current_track(state, prop, kind)
	local sel = state[prop]
	if value(sel) == "no" then
		return "off"
	end
	if value(sel) ~= "auto" then
		for _, t in ipairs(tracks_of(state, kind)) do
			if value(t.id) == value(sel) then
				return track_name(t)
			end
		end
	end
	-- Nothing chosen explicitly: report the track mpv picked.
	for _, t in ipairs(tracks_of(state, kind)) do
		if t.selected then
			return track_name(t)
		end
	end
	return "auto"
end

local function loop_label(state)
	if value(state.loop_file) ~= "no" then
		return "file"
	end
	if value(state.loop_playlist) ~= "no" then
		return "playlist"
	end
	return "off"
end

local function ab_label(state)
	local a = state.ab_loop_a
	local b = state.ab_loop_b
	local function t(v)
		if v == nil or value(v) == "no" then
			return nil
		end
		return render.fmt_time(v)
	end
	local ta, tb = t(a), t(b)
	if not ta and not tb then
		return "off"
	end
	return (ta or "A") .. " → " .. (tb or "B")
end

-- mpv reports video-aspect-override as a number (-2 auto, -1 disabled,
-- otherwise the ratio); the panel shows "default" for any negative value.
local function aspect_label(aspect)
	local n = tonumber(aspect)
	if not n or n < 0 then
		return "default"
	end
	return string.format("%.3f", n)
end

-- Track pages ---------------------------------------------------------------

local function track_page(state, kind, title, prop, extra)
	local rows = {}
	local cur = value(state[prop])
	local tracks = tracks_of(state, kind)
	local function add(track)
		rows[#rows + 1] = {
			label = track_name(track),
			detail = track_detail(track),
			active = cur == value(track.id),
			action = { kind = "set", prop = prop, value = value(track.id) },
		}
	end

	rows[#rows + 1] = {
		label = "Automatic",
		detail = "default selection",
		active = cur == "auto",
		action = { kind = "set", prop = prop, value = "auto" },
	}
	rows[#rows + 1] = {
		label = "Off",
		detail = "disable " .. kind,
		active = cur == "no",
		action = { kind = "set", prop = prop, value = "no" },
	}
	if #tracks == 0 then
		rows[#rows + 1] = { label = "No " .. kind .. " tracks", detail = "", disabled = true }
	else
		for _, t in ipairs(tracks) do
			add(t)
		end
	end
	for _, row in ipairs(extra or {}) do
		rows[#rows + 1] = row
	end
	return { title = title, rows = rows }
end

-- Page builders -------------------------------------------------------------

local pages = {}

pages.root = function(state)
	local count = tonumber(state.playlist_count) or 0
	local chapters = #(state.chapter_list or {})
	return {
		title = "MENU",
		rows = {
			{
				label = "Playlist",
				detail = count > 0
						and (count == 1 and "1 file" or string.format("%d files", count))
					or "",
				action = { kind = "panel", mode = "playlist" },
			},
			{
				label = "Chapters",
				detail = chapters > 0 and string.format("%d", chapters) or "none",
				action = { kind = "page", page = "chapters" },
			},
			{
				label = "Audio track",
				detail = current_track(state, "aid", "audio"),
				action = { kind = "page", page = "audio" },
			},
			{
				label = "Subtitles",
				detail = current_track(state, "sid", "sub"),
				action = { kind = "page", page = "subs" },
			},
			{
				label = "Video track",
				detail = current_track(state, "vid", "video"),
				action = { kind = "page", page = "video" },
			},
			{
				label = "Speed",
				detail = render.speed_label(state.speed),
				action = { kind = "page", page = "speed" },
			},
			{
				label = "Aspect ratio",
				detail = aspect_label(state.aspect),
				action = { kind = "page", page = "aspect" },
			},
			{
				label = "Loop",
				detail = loop_label(state),
				action = { kind = "page", page = "loop" },
			},
			{ label = "Tools", detail = "", action = { kind = "page", page = "tools" } },
			{
				label = "Shaders",
				detail = state.shader_active or "Off",
				action = { kind = "panel", mode = "shaders" },
			},
			{
				label = "Settings",
				detail = "keybinds, tweaks, reset",
				action = { kind = "page", page = "settings" },
			},
			{
				label = state.fullscreen and "Leave fullscreen" or "Fullscreen",
				detail = state.fullscreen and "on" or "off",
				action = { kind = "cmd", args = { "cycle", "fullscreen" } },
			},
			{
				label = "Screenshot",
				detail = "with subtitles",
				action = { kind = "cmd", args = { "screenshot" } },
			},
			{ label = "Quit", detail = "", action = { kind = "cmd", args = { "quit" } } },
		},
	}
end

pages.audio = function(state)
	return track_page(state, "audio", "AUDIO TRACKS", "aid", {
		{
			label = "Cycle audio track",
			detail = "mpv's #",
			action = { kind = "cmd", args = { "cycle", "audio" } },
		},
	})
end

pages.subs = function(state)
	local vis = state.sub_visibility ~= false
	return track_page(state, "sub", "SUBTITLES", "sid", {
		{
			label = "Subtitles visible",
			detail = vis and "on" or "off",
			active = vis,
			action = {
				kind = "set",
				prop = "sub-visibility",
				value = vis and "no" or "yes",
				value_type = "native",
			},
		},
		{
			label = "Add subtitle file…",
			detail = "path",
			action = { kind = "input", what = "sub-add" },
		},
		{
			label = "Cycle subtitle track",
			detail = "mpv's j",
			action = { kind = "cmd", args = { "cycle", "sub" } },
		},
	})
end

pages.video = function(state)
	return track_page(state, "video", "VIDEO TRACKS", "vid", {
		{
			label = "Cycle video track",
			detail = "mpv's _",
			action = { kind = "cmd", args = { "cycle", "video" } },
		},
	})
end

pages.chapters = function(state)
	local rows = {}
	local list = state.chapter_list or {}
	local cur = tonumber(state.chapter) or -1
	if #list == 0 then
		rows[1] = { label = "No chapters in this file", detail = "", disabled = true }
	else
		for i, ch in ipairs(list) do
			local title = ch.title
			if not title or title == "" then
				title = "Chapter " .. tostring(i)
			end
			rows[#rows + 1] = {
				label = title,
				detail = render.fmt_time(ch.time),
				active = (i - 1) == cur,
				action = { kind = "seek_abs", time = tonumber(ch.time) or 0 },
			}
		end
	end
	return { title = "CHAPTERS", rows = rows }
end

local SPEEDS = { 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4 }

pages.speed = function(state)
	local cur = tonumber(state.speed) or 1
	local rows = {}
	for _, v in ipairs(SPEEDS) do
		rows[#rows + 1] = {
			label = render.speed_label(v),
			detail = v == 1 and "normal" or "",
			active = math.abs(cur - v) < 0.001,
			action = { kind = "set_number", prop = "speed", value = v },
		}
	end
	rows[#rows + 1] = {
		label = "Slower (-0.05)",
		detail = "",
		action = { kind = "add", prop = "speed", value = -0.05 },
	}
	rows[#rows + 1] = {
		label = "Faster (+0.05)",
		detail = "",
		action = { kind = "add", prop = "speed", value = 0.05 },
	}
	rows[#rows + 1] = {
		label = "Reset",
		detail = "1x",
		action = { kind = "set_number", prop = "speed", value = 1 },
	}
	return { title = "SPEED", rows = rows }
end

-- Aspect ratios: mpv reports video-aspect-override as a number (-2 auto,
-- -1 disabled, otherwise the ratio), and accepts "no" or "16:9" on input.
local ASPECTS = {
	{ value = "no", label = "Default" },
	{ value = "16:9", label = "16:9", ratio = 16 / 9 },
	{ value = "4:3", label = "4:3", ratio = 4 / 3 },
	{ value = "1:1", label = "1:1", ratio = 1 },
	{ value = "21:9", label = "21:9", ratio = 21 / 9 },
	{ value = "2.35:1", label = "2.35:1", ratio = 2.35 },
}

pages.aspect = function(state)
	local cur = tonumber(state.aspect) or -2
	local rows = {}
	for _, a in ipairs(ASPECTS) do
		local active
		if a.ratio then
			active = math.abs(cur - a.ratio) < 0.01
		else
			active = cur < 0
		end
		rows[#rows + 1] = {
			label = a.label,
			detail = active and "current" or "",
			active = active,
			action = { kind = "set", prop = "video-aspect-override", value = a.value },
		}
	end
	return { title = "ASPECT RATIO", rows = rows }
end

pages.loop = function(state)
	local cur = loop_label(state)
	local rows = {
		{
			label = "Off",
			detail = "play once",
			active = cur == "off",
			action = {
				kind = "props",
				props = { { "loop-file", "no" }, { "loop-playlist", "no" } },
			},
		},
		{
			label = "Loop file",
			detail = "repeat current file",
			active = cur == "file",
			action = {
				kind = "props",
				props = { { "loop-file", "inf" }, { "loop-playlist", "no" } },
			},
		},
		{
			label = "Loop playlist",
			detail = "repeat the queue",
			active = cur == "playlist",
			action = {
				kind = "props",
				props = { { "loop-playlist", "inf" }, { "loop-file", "no" } },
			},
		},
		{
			label = "Shuffle",
			detail = state.shuffle and "on" or "off",
			active = state.shuffle == true,
			action = {
				kind = "set",
				prop = "shuffle",
				value = state.shuffle and "no" or "yes",
				value_type = "native",
			},
		},
	}
	return { title = "LOOP", rows = rows }
end

pages.tools = function(state)
	local function secs(v)
		local n = tonumber(v) or 0
		return string.format("%+.2fs", n)
	end
	local zoom = tonumber(state.video_zoom) or 0
	local rotate = value(state.video_rotate)
	return {
		title = "TOOLS",
		rows = {
			{
				label = "Screenshot (subs)",
				detail = "with subtitles",
				action = { kind = "cmd", args = { "screenshot" } },
			},
			{
				label = "Screenshot (video)",
				detail = "video only",
				action = { kind = "cmd", args = { "screenshot", "video" } },
			},
			{
				label = "Screenshot (window)",
				detail = "window + GUI",
				action = { kind = "cmd", args = { "screenshot", "window" } },
			},
			{
				label = "Subtitle delay",
				detail = secs(state.sub_delay),
				action = { kind = "page_hint", hint = "sub-delay" },
			},
			{
				label = "Subtitles -0.1s",
				detail = "",
				action = { kind = "add", prop = "sub-delay", value = -0.1 },
			},
			{
				label = "Subtitles +0.1s",
				detail = "",
				action = { kind = "add", prop = "sub-delay", value = 0.1 },
			},
			{
				label = "Reset subtitle delay",
				detail = secs(state.sub_delay),
				action = { kind = "set_number", prop = "sub-delay", value = 0 },
			},
			{
				label = "Audio delay",
				detail = secs(state.audio_delay),
				action = { kind = "page_hint", hint = "audio-delay" },
			},
			{
				label = "Audio -0.1s",
				detail = "",
				action = { kind = "add", prop = "audio-delay", value = -0.1 },
			},
			{
				label = "Audio +0.1s",
				detail = "",
				action = { kind = "add", prop = "audio-delay", value = 0.1 },
			},
			{
				label = "Reset audio delay",
				detail = secs(state.audio_delay),
				action = { kind = "set_number", prop = "audio-delay", value = 0 },
			},
			{
				label = "Zoom in",
				detail = string.format("%.2f", zoom),
				action = { kind = "add", prop = "video-zoom", value = 0.1 },
			},
			{
				label = "Zoom out",
				detail = string.format("%.2f", zoom),
				action = { kind = "add", prop = "video-zoom", value = -0.1 },
			},
			{
				label = "Reset zoom / pan",
				detail = "",
				action = {
					kind = "props",
					props = {
						{ "video-zoom", 0 },
						{ "video-pan-x", 0 },
						{ "video-pan-y", 0 },
					},
					numbers = true,
				},
			},
			{
				label = "Rotate 90°",
				detail = rotate .. "°",
				action = { kind = "rotate", step = 90 },
			},
			{
				label = "Deinterlace",
				detail = value(state.deinterlace),
				action = {
					kind = "cycle_values",
					prop = "deinterlace",
					values = { "no", "auto", "yes" },
				},
			},
			{
				label = "A-B loop",
				detail = ab_label(state),
				action = { kind = "page_hint", hint = "ab-loop" },
			},
			{
				label = "Set loop start (A)",
				detail = "at playhead",
				action = { kind = "set_time", prop = "ab-loop-a" },
			},
			{
				label = "Set loop end (B)",
				detail = "at playhead",
				action = { kind = "set_time", prop = "ab-loop-b" },
			},
			{
				label = "Clear A-B loop",
				detail = "",
				action = {
					kind = "props",
					props = { { "ab-loop-a", "no" }, { "ab-loop-b", "no" } },
				},
			},
			{ label = "Stop", detail = "", action = { kind = "cmd", args = { "stop" } } },
			{ label = "Quit", detail = "", action = { kind = "cmd", args = { "quit" } } },
		},
	}
end

-- Settings pages ------------------------------------------------------------

local function settings_value(state, prop)
	return state.settings and state.settings[prop]
end

local function fmt_float(v, pattern)
	local n = tonumber(v)
	if n == nil then
		return value(v)
	end
	return string.format(pattern or "%.2f", n)
end

local function fmt_secs(v)
	return string.format("%+.2fs", tonumber(v) or 0)
end

local function short(v, n)
	local s = tostring(v or "")
	if #s <= n then
		return s
	end
	return s:sub(1, n - 1) .. "…"
end

local function prop_row(state, prop, label, pattern)
	return {
		label = label,
		detail = fmt_float(settings_value(state, prop), pattern),
		action = { kind = "input", what = "set_property", prop = prop },
	}
end

local function delay_row(state, prop, label)
	return {
		label = label,
		detail = fmt_secs(settings_value(state, prop)),
		action = { kind = "input", what = "set_property", prop = prop },
	}
end

local function toggle_row(state, prop, label)
	local on = settings_value(state, prop) == true
	return {
		label = label,
		detail = on and "on" or "off",
		active = on,
		action = { kind = "set", prop = prop, value = not on, value_type = "native" },
	}
end

local function cycle_row(state, prop, label, values)
	local cur = tostring(settings_value(state, prop) or "")
	return {
		label = label,
		detail = cur ~= "" and cur or "auto",
		action = { kind = "cycle_values", prop = prop, values = values },
	}
end

local function link_row(label, page, detail)
	return { label = label, detail = detail or "", action = { kind = "page", page = page } }
end

pages.settings = function(state)
	local keys = 0
	for _, b in ipairs(state.input_bindings or {}) do
		if b.section == "default" then
			keys = keys + 1
		end
	end
	return {
		title = "SETTINGS",
		rows = {
			link_row("Video tweaks", "settings_video", "zoom, colors, aspect"),
			link_row("Audio tweaks", "settings_audio", "delay, channels, mute"),
			link_row("Subtitle tweaks", "settings_subs", "delay, scale, position"),
			link_row("Playback tweaks", "settings_playback", "speed, loop, cache"),
			link_row("Keybindings", "settings_keys", keys > 0 and (keys .. " keys") or ""),
			link_row("Interface", "settings_interface", "autohide, scale"),
			{
				label = "Reset accidental changes",
				detail = "zoom, pan, colors, delays",
				action = { kind = "reset_tweaks" },
			},
			{
				label = "Set any property…",
				detail = "advanced",
				action = { kind = "input", what = "set_property" },
			},
		},
	}
end

pages.settings_video = function(state)
	local aspect = aspect_label(settings_value(state, "video-aspect-override"))
	return {
		title = "VIDEO TWEAKS",
		rows = {
			link_row("Aspect ratio", "aspect", aspect),
			prop_row(state, "video-zoom", "Zoom", "%.3f"),
			prop_row(state, "video-pan-x", "Pan X", "%.3f"),
			prop_row(state, "video-pan-y", "Pan Y", "%.3f"),
			{
				label = "Rotation",
				detail = value(settings_value(state, "video-rotate")),
				action = { kind = "input", what = "set_property", prop = "video-rotate" },
			},
			prop_row(state, "panscan", "Panscan", "%.2f"),
			prop_row(state, "video-align-x", "Align X", "%.2f"),
			prop_row(state, "video-align-y", "Align Y", "%.2f"),
			cycle_row(state, "deinterlace", "Deinterlace", { "no", "auto", "yes" }),
			prop_row(state, "brightness", "Brightness", "%.2f"),
			prop_row(state, "contrast", "Contrast", "%.2f"),
			prop_row(state, "saturation", "Saturation", "%.2f"),
			prop_row(state, "gamma", "Gamma", "%.2f"),
			prop_row(state, "hue", "Hue", "%.2f"),
			toggle_row(state, "deband", "Deband"),
			{
				label = "Reset view",
				detail = "zoom, pan, rotate",
				action = { kind = "reset_view" },
			},
		},
	}
end

pages.settings_audio = function(state)
	return {
		title = "AUDIO TWEAKS",
		rows = {
			{
				label = "Volume",
				detail = string.format("%d%%", tonumber(settings_value(state, "volume")) or 0),
				action = { kind = "input", what = "set_property", prop = "volume" },
			},
			toggle_row(state, "mute", "Mute"),
			delay_row(state, "audio-delay", "Audio delay"),
			cycle_row(
				state,
				"audio-channels",
				"Channels",
				{ "auto", "mono", "stereo", "5.1", "7.1" }
			),
			toggle_row(state, "audio-normalize-downmix", "Normalize downmix"),
			{
				label = "Reset audio tweaks",
				detail = "delay, mute, channels",
				action = { kind = "reset_audio" },
			},
		},
	}
end

pages.settings_subs = function(state)
	return {
		title = "SUBTITLE TWEAKS",
		rows = {
			toggle_row(state, "sub-visibility", "Visible"),
			delay_row(state, "sub-delay", "Delay"),
			prop_row(state, "sub-speed", "Speed", "%.2f"),
			prop_row(state, "sub-scale", "Scale", "%.2f"),
			prop_row(state, "sub-pos", "Position", "%.2f"),
			cycle_row(
				state,
				"sub-ass-override",
				"ASS override",
				{ "no", "yes", "scale", "force", "strip" }
			),
			prop_row(state, "sub-font-size", "Font size", "%.2f"),
			prop_row(state, "sub-border-size", "Border size", "%.2f"),
			prop_row(state, "sub-shadow-offset", "Shadow offset", "%.2f"),
			{
				label = "Reset subtitle tweaks",
				detail = "delay, scale, position",
				action = { kind = "reset_subs" },
			},
		},
	}
end

pages.settings_playback = function(state)
	return {
		title = "PLAYBACK TWEAKS",
		rows = {
			link_row("Speed", "speed", render.speed_label(state.speed)),
			link_row("Loop", "loop", loop_label(state)),
			{
				label = "Pause",
				detail = state.pause and "paused" or "playing",
				action = {
					kind = "set",
					prop = "pause",
					value = not state.pause,
					value_type = "native",
				},
			},
			cycle_row(state, "keep-open", "Keep open", { "no", "yes", "always" }),
			cycle_row(state, "cache", "Cache", { "auto", "yes", "no" }),
			toggle_row(state, "shuffle", "Shuffle"),
			{
				label = "Reset playback tweaks",
				detail = "speed, loop, cache",
				action = { kind = "reset_playback" },
			},
		},
	}
end

pages.settings_interface = function(state)
	local gui = state.gui or {}
	return {
		title = "INTERFACE",
		rows = {
			{
				label = "Autohide delay",
				detail = string.format("%.1fs", tonumber(gui.autohide_delay) or 0),
				action = { kind = "input", what = "gui_set", key = "autohide_delay" },
			},
			{
				label = "GUI scale",
				detail = string.format("%.2fx", tonumber(gui.scale) or 1),
				action = { kind = "input", what = "gui_set", key = "scale" },
			},
			{
				label = "Reset interface",
				detail = "2.5s, 1.00x",
				action = { kind = "gui_reset" },
			},
		},
	}
end

-- Keybinding pages ----------------------------------------------------------

local function binding_list(state)
	local map = {}
	for _, b in ipairs(state.input_bindings or {}) do
		if b.section == "default" then
			local cur = map[b.key]
			if not cur or (cur.is_weak and not b.is_weak) or (not cur.is_weak and not b.is_weak) then
				map[b.key] = b
			end
		end
	end
	local list = {}
	for _, b in pairs(map) do
		list[#list + 1] = b
	end
	table.sort(list, function(a, b)
		local ak = tostring(a.key):lower()
		local bk = tostring(b.key):lower()
		if ak == bk then
			return tostring(a.cmd) < tostring(b.cmd)
		end
		return ak < bk
	end)
	return list
end

pages.settings_keys = function(state)
	local filter = tostring(state.keybind_filter or "")
	local needle = filter:lower()
	local rows = {
		{
			label = "Filter",
			detail = filter ~= "" and filter or "all",
			action = { kind = "input", what = "keybind_filter" },
		},
		{
			label = "Add binding…",
			detail = "key + command",
			action = { kind = "input", what = "keybind_add" },
		},
	}
	local shown = 0
	for _, b in ipairs(binding_list(state)) do
		local hay =
			(tostring(b.key) .. " " .. tostring(b.cmd) .. " " .. tostring(b.comment or "")):lower()
		if needle == "" or hay:find(needle, 1, true) then
			shown = shown + 1
			local detail = b.cmd == "ignore" and "disabled" or tostring(b.cmd)
			if state.custom_bindings and state.custom_bindings[b.key] ~= nil then
				detail = detail .. " · custom"
			end
			rows[#rows + 1] = {
				label = b.key,
				detail = short(detail, 54),
				action = { kind = "keybind_view", key = b.key },
			}
		end
	end
	if shown == 0 then
		rows[#rows + 1] = { label = "No matching bindings", detail = filter, disabled = true }
	end
	rows[#rows + 1] = {
		label = "GUI keys",
		detail = "Tab · Shift+x · Shift+m · g · Esc",
		disabled = true,
	}
	if state.custom_bindings and next(state.custom_bindings) ~= nil then
		rows[#rows + 1] = {
			label = "Clear custom bindings",
			detail = "restart restores defaults",
			action = { kind = "keybind_clear" },
		}
	end
	return { title = "KEYBINDINGS", rows = rows }
end

pages.settings_key = function(state)
	local key = state.keybind_selected
	local binding
	if key then
		for _, b in ipairs(binding_list(state)) do
			if b.key == key then
				binding = b
				break
			end
		end
	end
	local rows = {}
	if not binding then
		rows[#rows + 1] = { label = "No binding selected", detail = "", disabled = true }
	else
		rows[#rows + 1] = { label = "Key", detail = binding.key, disabled = true }
		rows[#rows + 1] = { label = "Command", detail = short(binding.cmd, 80), disabled = true }
		if binding.comment and binding.comment ~= "" then
			rows[#rows + 1] = { label = "Comment", detail = short(binding.comment, 80), disabled = true }
		end
		if binding.cmd == "ignore" then
			rows[#rows + 1] = {
				label = "Already unbound",
				detail = "use Add binding to restore",
				disabled = true,
			}
		else
			rows[#rows + 1] = {
				label = "Rebind key…",
				detail = "new key",
				action = { kind = "input", what = "keybind_rebind" },
			}
			rows[#rows + 1] = {
				label = "Unbind",
				detail = "disable this key",
				action = { kind = "keybind_unbind" },
			}
		end
	end
	rows[#rows + 1] = { label = "Back", detail = "", action = { kind = "back" } }
	return { title = "KEYBINDING", rows = rows }
end

-- The playlist and shader pages are rendered by render.lua from their own
-- state; they are still selectable from the root menu (as panels).

function menu.view(state, page)
	local build = pages[page or "root"]
	if not build then
		return nil
	end
	return build(state)
end

return menu
