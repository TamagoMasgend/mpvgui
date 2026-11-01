-- ASS event construction.
--
-- Each function returns the *data* string for one `ass-events` overlay:
-- newline-separated ASS event text lines (no dialogue headers, no styles).
-- All coordinates are OSD pixels because the overlay PlayRes is set to the OSD
-- size by main.lua.

local theme = require("theme")

local render = {}

-- ASS wants plain decimal numbers; rounding to integers keeps the output
-- locale-independent (no decimal comma risk) and makes drawings crisp.
local function n(v)
	v = math.floor(v + 0.5)
	if v == 0 then
		v = 0
	end
	return string.format("%d", v)
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

-- Text that goes into an ASS event: no newlines (they would split the event),
-- and braces would be parsed as override blocks.
function render.sanitize(s)
	s = tostring(s or "")
	s = s:gsub("[%c]+", " ")
	s = s:gsub("{", "("):gsub("}", ")")
	return s
end

function render.fmt_time(t)
	t = tonumber(t) or 0
	if t < 0 or t ~= t then
		t = 0
	end
	t = math.floor(t + 0.5)
	local hh = math.floor(t / 3600)
	local mm = math.floor((t % 3600) / 60)
	local ss = t % 60
	if hh > 0 then
		return string.format("%d:%02d:%02d", hh, mm, ss)
	end
	return string.format("%d:%02d", mm, ss)
end

function render.speed_label(v)
	v = tonumber(v) or 1
	local rounded = math.floor(v + 0.5)
	if math.abs(v - rounded) < 0.001 then
		return string.format("%dx", rounded)
	end
	return string.format("%gx", v)
end

-- Drawing primitives --------------------------------------------------------

-- Join drawing command tokens with single spaces.
local function cmd(...)
	return table.concat({ ... }, " ")
end

local function rect_path(x0, y0, x1, y1)
	return cmd("m", n(x0), n(y0), "l", n(x1), n(y0), n(x1), n(y1), n(x0), n(y1))
end

local function round_rect_path(x0, y0, x1, y1, r)
	r = math.floor(r + 0.5)
	local half = math.floor(math.min(x1 - x0, y1 - y0) / 2)
	if r > half then
		r = half
	end
	if r < 1 then
		return rect_path(x0, y0, x1, y1)
	end
	local k = r * 0.5523
	local parts = {
		cmd("m", n(x0 + r), n(y0)),
		cmd("l", n(x1 - r), n(y0)),
		cmd("b", n(x1 - r + k), n(y0), n(x1), n(y0 + r - k), n(x1), n(y0 + r)),
		cmd("l", n(x1), n(y1 - r)),
		cmd("b", n(x1), n(y1 - r + k), n(x1 - r + k), n(y1), n(x1 - r), n(y1)),
		cmd("l", n(x0 + r), n(y1)),
		cmd("b", n(x0 + r - k), n(y1), n(x0), n(y1 - r + k), n(x0), n(y1 - r)),
		cmd("l", n(x0), n(y0 + r)),
		cmd("b", n(x0), n(y0 + r - k), n(x0 + r - k), n(y0), n(x0 + r), n(y0)),
	}
	return table.concat(parts, " ")
end

local function poly_path(points)
	local parts = { cmd("m", n(points[1][1]), n(points[1][2])) }
	for i = 2, #points do
		parts[#parts + 1] = cmd("l", n(points[i][1]), n(points[i][2]))
	end
	return table.concat(parts, " ")
end

local function line_path(x0, y0, x1, y1, thickness)
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.01 then
		return ""
	end
	local nx, ny = -dy / len * thickness / 2, dx / len * thickness / 2
	return poly_path({
		{ x0 + nx, y0 + ny },
		{ x1 + nx, y1 + ny },
		{ x1 - nx, y1 - ny },
		{ x0 - nx, y0 - ny },
	})
end

local function shape(color, alpha, path)
	local tag = "{\\an7\\pos(0,0)\\p1\\bord0\\shad0\\blur0\\1c&H" .. color .. "&"
	if alpha then
		tag = tag .. "\\1a&H" .. alpha .. "&"
	end
	return tag .. "}" .. path .. "{\\p0}"
end

local function text_event(x, y, an, str, size, color, alpha, clip)
	local tags = {
		"{\\an" .. an,
		"\\pos(" .. n(x) .. "," .. n(y) .. ")",
		"\\q2\\fs" .. n(size),
		"\\b0\\i0\\bord0\\shad0\\blur0",
		"\\1c&H" .. color .. "&",
	}
	if alpha then
		tags[#tags + 1] = "\\1a&H" .. alpha .. "&"
	end
	if clip then
		local c = table.concat({ n(clip[1]), n(clip[2]), n(clip[3]), n(clip[4]) }, ",")
		tags[#tags + 1] = "\\clip(" .. c .. ")"
	end
	return table.concat(tags) .. "}" .. str
end

render.text = text_event

-- Convenience wrappers so layer code stays short and readable.
local function add_rect(ev, color, alpha, x0, y0, x1, y1)
	ev[#ev + 1] = shape(color, alpha, rect_path(x0, y0, x1, y1))
end

local function add_round(ev, color, alpha, x0, y0, x1, y1, r)
	ev[#ev + 1] = shape(color, alpha, round_rect_path(x0, y0, x1, y1, r))
end

local function add_shape(ev, color, alpha, path)
	ev[#ev + 1] = shape(color, alpha, path)
end

-- Icons ---------------------------------------------------------------------

local function icon_play(cx, cy, size)
	local h = size * 0.5
	local w = size * 0.78
	local x0 = cx - w * 0.42
	return poly_path({ { x0, cy - h }, { x0 + w, cy }, { x0, cy + h } })
end

local function icon_pause(cx, cy, size)
	local bw = math.max(1, size * 0.22)
	local gap = math.max(2, size * 0.26)
	local h = size * 0.5
	local left = rect_path(cx - gap / 2 - bw, cy - h, cx - gap / 2, cy + h)
	local right = rect_path(cx + gap / 2, cy - h, cx + gap / 2 + bw, cy + h)
	return left .. " " .. right
end

local function icon_speaker(cx, cy, size, muted)
	local x0 = cx - size * 0.42
	local body_y0 = cy - size * 0.16
	local body_y1 = cy + size * 0.16
	local cone_x = x0 + size * 0.22
	local tip_x = x0 + size * 0.46
	local paths = {
		rect_path(x0, body_y0, cone_x, body_y1),
		poly_path({
			{ cone_x, body_y0 },
			{ tip_x, cy - size * 0.42 },
			{ tip_x, cy + size * 0.42 },
			{ cone_x, body_y1 },
		}),
	}
	if muted then
		local slash =
			line_path(tip_x, cy - size * 0.5, tip_x + size * 0.46, cy + size * 0.5, size * 0.1)
		paths[#paths + 1] = slash
	else
		local t = math.max(1, size * 0.08)
		paths[#paths + 1] =
			line_path(tip_x + size * 0.12, cy - size * 0.2, tip_x + size * 0.24, cy, t)
		paths[#paths + 1] =
			line_path(tip_x + size * 0.12, cy + size * 0.2, tip_x + size * 0.24, cy, t)
	end
	return table.concat(paths, " ")
end

local function icon_list(cx, cy, size)
	local h = math.max(1, size * 0.1)
	local half = size * 0.42
	local paths = {}
	for i = -1, 1 do
		local y = cy + i * size * 0.26
		paths[#paths + 1] = rect_path(cx - half, y - h / 2, cx + half, y + h / 2)
	end
	return table.concat(paths, " ")
end

local function icon_fullscreen(cx, cy, size, active)
	local ext = size * (active and 0.3 or 0.48)
	local t = math.max(1, size * 0.1)
	local arm = math.max(2, size * 0.18)
	local x0, x1 = cx - ext, cx + ext
	local y0, y1 = cy - ext, cy + ext
	local paths = {
		rect_path(x0, y0, x0 + arm, y0 + t),
		rect_path(x0, y0, x0 + t, y0 + arm),
		rect_path(x1 - arm, y0, x1, y0 + t),
		rect_path(x1 - t, y0, x1, y0 + arm),
		rect_path(x0, y1 - t, x0 + arm, y1),
		rect_path(x0, y1 - arm, x0 + t, y1),
		rect_path(x1 - arm, y1 - t, x1, y1),
		rect_path(x1 - t, y1 - arm, x1, y1),
	}
	return table.concat(paths, " ")
end

-- Layers --------------------------------------------------------------------

-- Static chrome: only the things that depend on geometry, never on state.
function render.static(L)
	local ev = {}
	local bar = L.bar
	if bar.x1 - bar.x0 < 4 or bar.y1 - bar.y0 < 4 then
		return ""
	end
	add_round(ev, theme.color.bar, theme.alpha.bar, bar.x0, bar.y0, bar.x1, bar.y1, L.radius)

	local sk = L.seek
	if sk.x1 - sk.x0 > 2 then
		local y0, y1 = sk.track_y - sk.track_h / 2, sk.track_y + sk.track_h / 2
		add_round(ev, theme.color.track, nil, sk.x0, y0, sk.x1, y1, sk.track_h / 2)
	end

	local v = L.vol
	if v.x1 - v.x0 > 2 then
		local y0, y1 = v.y - v.h / 2, v.y + v.h / 2
		add_round(ev, theme.color.track, nil, v.x0, y0, v.x1, y1, v.h / 2)
	end

	return table.concat(ev, "\n")
end

-- Everything that changes on hover / playback state.
function render.hover(L, state)
	local ev = {}
	local bar = L.bar
	local cy = (bar.y0 + bar.y1) / 2
	local dur = tonumber(state.duration) or 0
	local pos = tonumber(state.time_pos) or 0
	local scrub = tonumber(state.scrub)
	if scrub then
		pos = scrub * dur
	end
	local frac = 0
	if dur > 0 then
		frac = clamp(pos / dur, 0, 1)
	end

	-- Hover highlight behind the hovered button.
	local hovered = state.hover and L.by_id[state.hover]
	if hovered then
		local x0, y0 = hovered.x0 + 2, hovered.y0 + 4
		local x1, y1 = hovered.x1 - 2, hovered.y1 - 4
		add_round(ev, theme.color.hover, theme.alpha.hover, x0, y0, x1, y1, L.btn_radius)
	end

	-- Seekbar: buffered band, played fill, knob.
	local sk = L.seek
	if sk.x1 - sk.x0 > 2 then
		local top, bottom = sk.track_y - sk.track_h / 2, sk.track_y + sk.track_h / 2
		local span = sk.x1 - sk.x0
		local buffered = tonumber(state.buffered_end)
		if buffered and dur > 0 then
			local bfrac = clamp(buffered / dur, 0, 1)
			if bfrac > frac then
				local bx = sk.x0 + span * bfrac
				add_round(ev, theme.color.buffered, nil, sk.x0, top, bx, bottom, sk.track_h / 2)
			end
		end
		if frac > 0 then
			local px = sk.x0 + math.max(span * frac, sk.track_h)
			add_round(ev, theme.color.played, nil, sk.x0, top, px, bottom, sk.track_h / 2)
		end
		local knob = (state.hover == "seekbar" or state.scrub) and L.knob_hover or L.knob
		local kx = sk.x0 + span * frac
		local ky = sk.track_y
		add_round(
			ev,
			theme.color.knob,
			nil,
			kx - knob / 2,
			ky - knob / 2,
			kx + knob / 2,
			ky + knob / 2,
			knob / 2
		)
	end

	-- Icons and labels.
	local label_y = cy + math.max(1, math.floor(L.font.label * 0.06))
	for _, b in ipairs(L.buttons) do
		local path, str
		local color = theme.color.text
		if b.id == "play" then
			path = state.pause and icon_play(b.cx, b.cy, L.icon) or icon_pause(b.cx, b.cy, L.icon)
		elseif b.id == "back" then
			str = "-10"
		elseif b.id == "forward" then
			str = "+10"
		elseif b.id == "mute" then
			path = icon_speaker(b.cx, b.cy, L.icon, state.mute)
			if state.mute then
				color = theme.color.muted
			end
		elseif b.id == "volume" then
			local v = L.vol
			local vfrac = clamp((tonumber(state.volume) or 0) / 100, 0, 1)
			local fill_color = theme.color.played
			if state.mute or vfrac <= 0 then
				fill_color = theme.color.track
			end
			if vfrac > 0 then
				local x1 = v.x0 + (v.x1 - v.x0) * vfrac
				add_round(ev, fill_color, nil, v.x0, v.y - v.h / 2, x1, v.y + v.h / 2, v.h / 2)
			end
		elseif b.id == "speed" then
			str = render.speed_label(state.speed)
		elseif b.id == "playlist" then
			path = icon_list(b.cx, b.cy, L.icon)
			if state.panel_mode == "playlist" then
				color = theme.color.accent
			end
		elseif b.id == "fx" then
			str = "FX"
			if state.panel_mode == "shaders" then
				color = theme.color.accent
			end
		elseif b.id == "fullscreen" then
			path = icon_fullscreen(b.cx, b.cy, L.icon, state.fullscreen)
		end
		if path then
			add_shape(ev, color, nil, path)
		elseif str then
			local clip = { b.x0, b.y0, b.x1, b.y1 }
			ev[#ev + 1] = text_event(b.cx, label_y, 5, str, L.font.label, color, nil, clip)
		end
	end

	-- Time read-out (current / total).
	local txt = render.fmt_time(pos) .. " / " .. render.fmt_time(dur)
	local tx = L.time.x1 - math.max(2, math.floor(L.font.small * 0.2))
	local tclip = { L.time.x0, L.time.y0, L.time.x1, L.time.y1 }
	ev[#ev + 1] = text_event(tx, cy, 6, txt, L.font.small, theme.color.text, nil, tclip)

	-- Title line, top-left, with the playlist counter.
	local title = render.sanitize(state.title)
	if title ~= "" then
		local count = tonumber(state.playlist_count) or 0
		local ppos = tonumber(state.playlist_pos) or -1
		if count > 1 and ppos >= 0 then
			title = title .. string.format("   %d/%d", ppos + 1, count)
		end
		local ty = L.title.y0 + math.floor(L.font.title * 0.15)
		local clip = { L.title.x0, L.title.y0, L.title.x1, L.title.y1 }
		ev[#ev + 1] =
			text_event(L.title.x0, ty, 7, title, L.font.title, theme.color.text_dim, nil, clip)
	end

	return table.concat(ev, "\n")
end

-- Side panel: playlist rows or shader rows.  Drawn only when the list,
-- selection, scroll offset, mode or geometry changes.
function render.panel(L, state)
	local p = L.panel
	if not p or p.visible <= 0 then
		return ""
	end
	local ev = {}
	add_rect(ev, theme.color.panel, theme.alpha.panel, p.x0, 0, p.x1, p.y1)
	local sep_w = math.max(1, math.floor(L.s * 2))
	add_rect(ev, theme.color.track, nil, p.x0, 0, p.x0 + sep_w, p.y1)

	local shader_mode = state.panel_mode == "shaders"
	local labels, active_index, count, header
	if shader_mode then
		local rows = state.shader_rows or {}
		count = #rows
		labels = {}
		for i, row in ipairs(rows) do
			labels[i] = row.name
			if row.active then
				active_index = i - 1
			end
		end
		header = "SHADERS"
	else
		labels = state.playlist_labels or {}
		count = #labels
		active_index = tonumber(state.playlist_pos) or -1
		header = "PLAYLIST"
	end
	header = header .. (count > 0 and ("   " .. count) or "")
	local hclip = { p.x0, 0, p.x1 - p.pad, p.header_h }
	ev[#ev + 1] =
		text_event(p.x0 + p.pad, p.pad, 7, header, L.font.small, theme.color.text_dim, nil, hclip)

	local num_w = shader_mode and 0 or math.max(18, math.floor(L.font.small * 2.2))
	local first = math.max(0, tonumber(state.panel_scroll) or 0)
	for slot = 1, p.visible do
		local idx = first + slot - 1
		if idx >= count then
			break
		end
		local y0 = p.rows_y0 + (slot - 1) * p.row_h
		local y1 = y0 + p.row_h
		local is_active = idx == active_index
		if is_active then
			add_rect(ev, theme.color.panel_row, nil, p.x0 + 1, y0 + 1, p.x1, y1 - 1)
		end
		local cy = (y0 + y1) / 2
		local num_color = theme.color.text_dim
		local num = tostring(idx + 1)
		if shader_mode then
			num = is_active and ">" or " "
			if is_active then
				num_color = theme.color.accent
			end
		end
		local nclip = { p.x0, y0, p.x0 + p.pad + num_w + 2, y1 }
		local nx = p.x0 + p.pad + num_w
		if num_w > 0 or shader_mode then
			ev[#ev + 1] = text_event(nx, cy, 6, num, L.font.small, num_color, nil, nclip)
		end
		local label = render.sanitize(labels[idx + 1])
		local lclip = { p.x0 + p.pad + num_w, y0, p.x1 - p.pad, y1 }
		local lx = p.x0 + p.pad + num_w + math.floor(L.font.small * 0.6)
		local label_color = is_active and theme.color.accent or theme.color.text
		ev[#ev + 1] = text_event(lx, cy, 4, label, L.font.row, label_color, nil, lclip)
	end

	return table.concat(ev, "\n")
end

-- Transient layer: seek / volume tooltip and toast messages.
function render.transient(L, tooltip, toast)
	local ev = {}
	if tooltip and tooltip.text and tooltip.text ~= "" then
		local size = L.font.tooltip
		local pad_x = math.max(3, math.floor(size * 0.45))
		local pad_y = math.max(2, math.floor(size * 0.3))
		local box_w = math.floor(#tooltip.text * size * 0.6 + pad_x * 2)
		local box_h = size + pad_y * 2
		local cx, box_cy
		if tooltip.kind == "volume" then
			local v = L.vol
			cx = clamp(tooltip.x, v.x0 + box_w / 2, v.x1 - box_w / 2)
			box_cy = v.y - v.h / 2 - math.max(4, math.floor(size * 0.5)) - box_h / 2
		else
			local sk = L.seek
			cx = clamp(tooltip.x, sk.x0 + box_w / 2, sk.x1 - box_w / 2)
			box_cy = sk.y0 - math.max(4, math.floor(size * 0.5)) - box_h / 2
		end
		local x0, y0 = cx - box_w / 2, box_cy - box_h / 2
		local x1, y1 = cx + box_w / 2, box_cy + box_h / 2
		add_round(
			ev,
			theme.color.tooltip,
			theme.alpha.tooltip,
			x0,
			y0,
			x1,
			y1,
			math.floor(box_h / 3)
		)
		ev[#ev + 1] =
			text_event(cx, box_cy, 5, tooltip.text, size, theme.color.text, nil, { x0, y0, x1, y1 })
	end
	if toast and toast.text and toast.text ~= "" then
		local size = L.font.tooltip
		local text = render.sanitize(toast.text)
		local pad_x = math.max(4, math.floor(size * 0.6))
		local pad_y = math.max(2, math.floor(size * 0.35))
		local box_w = math.floor(#text * size * 0.55 + pad_x * 2)
		local box_h = size + pad_y * 2
		local cx = L.w / 2
		local box_cy = L.margin + math.max(10, math.floor(size * 2.2)) + box_h / 2
		local x0, y0 = cx - box_w / 2, box_cy - box_h / 2
		local x1, y1 = cx + box_w / 2, box_cy + box_h / 2
		add_round(
			ev,
			theme.color.tooltip,
			theme.alpha.tooltip,
			x0,
			y0,
			x1,
			y1,
			math.floor(box_h / 3)
		)
		ev[#ev + 1] =
			text_event(cx, box_cy, 5, text, size, theme.color.accent, nil, { x0, y0, x1, y1 })
	end
	return table.concat(ev, "\n")
end

return render
