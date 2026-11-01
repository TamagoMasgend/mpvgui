-- Pointer interaction: hit testing, hover state and the drag state machine.
--
-- Why no mp.set_mouse_area() here: mouse areas only gate *section* bindings
-- that mpv's input system enables; the forced bindings this script uses
-- ("input_forced_<script>" section, flags=force) are dispatched regardless of
-- any area (verified on mpv 0.41.0 by clicking outside a set area).  So the
-- script owns click routing itself: every forced binding hit-tests into the
-- geometry below, and everything outside the GUI falls back to mpv's default
-- behaviour (see main.lua).

local layout = require("layout")

local interact = {}
interact.__index = interact

-- Hit test. Returns (id, index).  `scroll` is the panel's first visible row.
function interact.hit(L, x, y, scroll)
	if not L or not x or not y or x < 0 or y < 0 or x >= L.w or y >= L.h then
		return nil
	end
	if L.panel and x >= L.panel.x0 then
		local slot = layout.row_at(L, y)
		if slot then
			return "row", (tonumber(scroll) or 0) + slot
		end
		return "panel"
	end
	for _, b in ipairs(L.buttons) do
		if x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1 then
			return b.id
		end
	end
	local sk = L.seek
	if x >= sk.x0 and x < sk.x1 and y >= sk.y0 and y < sk.y1 then
		return "seekbar"
	end
	if y >= L.bar.y0 and y < L.bar.y1 then
		return "bar"
	end
	return "video"
end

-- Ids that trigger an action on press.
local ACTIVATABLE = {
	row = true,
	play = true,
	back = true,
	forward = true,
	mute = true,
	speed = true,
	playlist = true,
	fx = true,
	fullscreen = true,
}

local function fraction(L, kind, x)
	if kind == "seekbar" then
		return layout.seek_fraction(L, x)
	end
	return layout.volume_fraction(L, x)
end

function interact.new(callbacks)
	return setmetatable({
		cb = callbacks or {},
		lay = nil,
		scroll = 0,
		hover = nil,
		drag = nil,
	}, interact)
end

function interact:set_layout(L, scroll)
	self.lay = L
	self.scroll = tonumber(scroll) or 0
end

function interact:set_scroll(scroll)
	self.scroll = tonumber(scroll) or 0
end

function interact:set_hover(id)
	if self.hover ~= id then
		self.hover = id
		if self.cb.on_hover then
			self.cb.on_hover(id)
		end
	end
end

-- Recompute hover from a pointer position; while dragging only the drag value
-- follows the pointer.
function interact:move(x, y)
	if not self.lay then
		return
	end
	if self.drag then
		local f = fraction(self.lay, self.drag.kind, x)
		if math.abs(f - self.drag.fraction) > 0.0005 then
			self.drag.fraction = f
			if self.cb.on_drag then
				self.cb.on_drag(self.drag.kind, f)
			end
		end
		return
	end
	local id = interact.hit(self.lay, x, y, self.scroll)
	self:set_hover(id)
end

function interact:down(x, y)
	if not self.lay then
		return
	end
	local id, index = interact.hit(self.lay, x, y, self.scroll)
	if id == "seekbar" or id == "volume" then
		self.drag = { kind = id, fraction = fraction(self.lay, id, x) }
		self:set_hover(id)
		if self.cb.on_drag then
			self.cb.on_drag(id, self.drag.fraction)
		end
	elseif ACTIVATABLE[id] then
		if self.cb.on_activate then
			self.cb.on_activate(id, index)
		end
	end
end

function interact:up(x, y)
	if not self.drag then
		return
	end
	local kind = self.drag.kind
	local f = self.drag.fraction
	if x and x >= 0 then
		f = fraction(self.lay, kind, x)
	end
	self.drag = nil
	if self.cb.on_commit then
		self.cb.on_commit(kind, f)
	end
	self:set_hover(interact.hit(self.lay, x, y, self.scroll))
end

-- A synthetic single click (mpv `mouse x y 0`, or a click that never reports
-- a release): press and release in one go.
function interact:press(x, y)
	if not self.lay then
		return
	end
	local id = interact.hit(self.lay, x, y, self.scroll)
	if id == "seekbar" or id == "volume" then
		self:down(x, y)
		self:up(x, y)
	else
		self:down(x, y)
		self:set_hover(id)
	end
end

-- Returns "panel", "volume" or "default" so main can apply mpv's defaults
-- outside the GUI.
function interact:wheel(x, y, dir)
	if not self.lay then
		return "default"
	end
	local id = interact.hit(self.lay, x, y, self.scroll)
	if self.lay.panel and (id == "panel" or id == "row") then
		return "panel", dir
	elseif id == "volume" or id == "mute" then
		return "volume", dir
	end
	return "default", dir
end

function interact:cancel()
	self.drag = nil
	self:set_hover(nil)
end

return interact
