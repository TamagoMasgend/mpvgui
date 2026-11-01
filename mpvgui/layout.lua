-- Pure geometry for the OSD overlay.
--
-- Coordinates are OSD pixels (the ASS PlayRes is set to the OSD size, so one
-- ASS unit is one surface pixel).  Nothing here touches mp.*, so the whole
-- module is trivially unit-testable.
--
-- Layout of the bottom bar, left to right:
--   [menu] [play] [-10] [+10] [ 0:12 / 1:00 ] [==== seekbar ====] [1x] [FX] [list] [volume] [vol] [fs]
-- The side panel (playlist, shaders or the menu) takes the right edge; the bar
-- shrinks so no control is ever hidden behind it.

local theme = require("theme")

local layout = {}

local function round(v)
	return math.floor(v + 0.5)
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

function layout.compute(w, h, panel_open, scale)
	scale = tonumber(scale) or 1
	local s = clamp((h / theme.ref_height) * scale, 0.2, 4)
	local mode = nil
	if type(panel_open) == "string" then
		mode = panel_open
	elseif panel_open then
		mode = "playlist"
	end
	local L = { w = w, h = h, s = s, panel_open = mode ~= nil, panel_mode = mode }

	local margin = math.max(2, round(theme.margin * s))
	local bar_h = math.max(10, round(theme.bar_height * s))
	local btn = math.max(8, round(theme.btn * s))
	local pad = math.max(2, round(6 * s))

	L.margin = margin
	L.radius = math.max(2, round(theme.radius * s))
	L.btn_radius = math.max(2, round(theme.btn_radius * s))
	L.icon = math.max(4, round(theme.icon * s))
	L.knob = math.max(3, round(theme.knob * s))
	L.knob_hover = math.max(3, round(theme.knob_hover * s))
	L.font = {
		label = math.max(6, round(theme.font.label * s)),
		small = math.max(5, round(theme.font.small * s)),
		title = math.max(6, round(theme.font.title * s)),
		row = math.max(6, round(theme.font.row * s)),
		tooltip = math.max(6, round(theme.font.tooltip * s)),
	}

	-- Playlist panel ------------------------------------------------------
	local panel_w = 0
	if panel_open then
		panel_w = round(math.min(w * theme.panel_ratio, theme.panel_max * s))
		panel_w = clamp(panel_w, 0, math.max(0, w - margin * 2))
	end
	if panel_w > 0 then
		local row_ref = (mode == "menu") and theme.row_h_menu or theme.row_h
		local row_h = math.max(10, round(row_ref * s))
		local p = {
			x0 = w - panel_w,
			x1 = w,
			y0 = 0,
			y1 = h,
			pad = math.max(4, round(theme.panel_pad * s)),
			header_h = math.max(10, round(theme.header_h * s)),
			row_h = row_h,
		}
		p.rows_y0 = p.y0 + p.header_h
		p.rows_y1 = p.y1 - margin
		p.visible = math.max(0, math.floor((p.rows_y1 - p.rows_y0) / row_h))
		L.panel = p
	end

	-- Bottom bar ----------------------------------------------------------
	local bar_y1 = h - margin
	local bar_y0 = bar_y1 - bar_h
	local right = w - margin - (L.panel and (panel_w + margin) or 0)
	right = math.max(margin + btn, right)
	L.bar = { x0 = margin, y0 = bar_y0, x1 = right, y1 = bar_y1 }

	local cy = round((bar_y0 + bar_y1) / 2)
	L.buttons = {}
	L.by_id = {}

	local x = L.bar.x0
	local function add(id, width)
		local bw = round(width or btn)
		local b =
			{ id = id, x0 = x, y0 = bar_y0, x1 = x + bw, y1 = bar_y1, cx = x + bw / 2, cy = cy }
		L.buttons[#L.buttons + 1] = b
		L.by_id[id] = b
		x = x + bw
	end

	add("menu")
	add("play")
	add("back")
	add("forward")

	L.time = { x0 = x, x1 = x + round(theme.time_w * s), y0 = bar_y0, y1 = bar_y1 }
	x = L.time.x1

	-- Right-hand side, laid out from the right edge inwards.  The volume
	-- slider ends up at the right end of the bar (speaker icon next to it),
	-- which is where users - and the test harness - look for it.
	local rx = L.bar.x1
	local function radd(id, width)
		local bw = round(width)
		rx = rx - bw
		local b =
			{ id = id, x0 = rx, y0 = bar_y0, x1 = rx + bw, y1 = bar_y1, cx = rx + bw / 2, cy = cy }
		L.buttons[#L.buttons + 1] = b
		L.by_id[id] = b
	end

	radd("fullscreen", btn)
	radd("mute", btn)
	radd("volume", round(theme.vol_w * s))
	radd("playlist", btn)
	radd("fx", btn)
	radd("speed", round(theme.speed_w * s))

	local seek_x0 = x + pad
	local seek_x1 = rx - pad
	if seek_x1 < seek_x0 then
		seek_x0 = x
		seek_x1 = math.max(x, rx)
	end
	local track_h = math.max(2, round(theme.seek_track * s))
	L.seek = {
		x0 = seek_x0,
		x1 = seek_x1,
		y0 = bar_y0,
		y1 = bar_y1,
		track_y = cy,
		track_h = track_h,
	}

	-- Volume slider track (inside the volume button) and mute button.
	local vb = L.by_id.volume
	local vol_h = math.max(2, round(theme.vol_track * s))
	L.vol = {
		x0 = vb.x0 + pad,
		x1 = math.max(vb.x0 + pad + 1, vb.x1 - pad),
		y = cy,
		h = vol_h,
	}

	-- Title line, top-left, clipped so it never runs under the panel.
	local title_x1 =
		math.min(round(w * theme.title_max_ratio), L.panel and (L.panel.x0 - margin) or w)
	L.title = {
		x0 = margin,
		y0 = margin,
		x1 = math.max(margin + 8, title_x1),
		y1 = margin + math.max(10, round(40 * s)),
	}

	return L
end

-- Button rect for an id, or nil.
function layout.button(L, id)
	return L and L.by_id and L.by_id[id] or nil
end

function layout.seek_fraction(L, x)
	local sk = L.seek
	local span = sk.x1 - sk.x0
	if span <= 0 then
		return 0
	end
	return clamp((x - sk.x0) / span, 0, 1)
end

function layout.volume_fraction(L, x)
	local v = L.vol
	local span = v.x1 - v.x0
	if span <= 0 then
		return 0
	end
	return clamp((x - v.x0) / span, 0, 1)
end

-- 0-based visible row slot at y, or nil when outside the rows area.
function layout.row_at(L, y)
	local p = L.panel
	if not p then
		return nil
	end
	if y < p.rows_y0 or y >= p.rows_y0 + p.visible * p.row_h then
		return nil
	end
	return math.floor((y - p.rows_y0) / p.row_h)
end

function layout.panel_rows(L)
	return L.panel and L.panel.visible or 0
end

function layout.clamp_scroll(L, scroll, count)
	local rows = layout.panel_rows(L)
	local max_scroll = math.max(0, count - rows)
	return clamp(round(scroll), 0, max_scroll)
end

return layout
