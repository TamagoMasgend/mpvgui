-- refgui/main.lua — HARNESS SELF-TEST TARGET, not the product.
--
-- A deliberately small uosc-flavoured Lua-OSD GUI that implements exactly the
-- interactions the harness scenarios assert:
--   * a bottom bar: play/pause button, seekbar with progress+knob, volume box
--   * left-click hit-testing (complex MBTN_LEFT binding: down / up events)
--   * drag-to-seek while the button is down (mouse-pos observation)
--   * wheel over the volume box changes volume
--   * Tab opens a 5-row playlist panel; clicking a row selects it
--   * redraw on osd-dimensions change (mandatory: mpv clears the OSD on resize)
--   * user-data/mpvgui/{updates,updates-visible,updates-idle,visible,...}
--     with *idle suppression*: while the bar is hidden and nothing changes,
--     no updates are produced at all.
--
-- It exists so `run.sh --all` can validate the harness itself before the real
-- GUI is written. Nothing here is a spec for the real implementation.

local mp = require 'mp'

------------------------------------------------------------------ user-data
local UD = 'user-data/mpvgui/'
local function ud_set(k, v) mp.set_property_native(UD .. k, v) end
local function ud_get(k) return mp.get_property_native(UD .. k) end
local function bump(k) ud_set(k, (ud_get(k) or 0) + 1) end

for _, k in ipairs({ 'updates', 'updates-visible', 'updates-idle', 'draws' }) do
    ud_set(k, 0)
end
ud_set('visible', true)
ud_set('panel', false)
ud_set('last-action', 'init')

--------------------------------------------------------------------- layout
local VIEW = { w = 0, h = 0 }
local HIDE_AFTER = 2.0

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function compute_layout()
    local d = mp.get_property_native('osd-dimensions')
    if not d or (d.w or 0) <= 0 or (d.h or 0) <= 0 then return nil end
    VIEW.w, VIEW.h = d.w, d.h
    local bar_h = clamp(math.floor(VIEW.h * 0.10), 36, 120)
    local bar_y0 = VIEW.h - bar_h
    local pad = 8
    local btn = bar_h - 2 * pad
    local play = { x0 = pad, y0 = bar_y0 + pad, x1 = pad + btn, y1 = bar_y0 + pad + btn }
    local vol_w = 110
    local seek = {
        x0 = play.x1 + 16,
        y0 = bar_y0 + math.floor(bar_h * 0.35),
        x1 = VIEW.w - vol_w,
        y1 = bar_y0 + math.floor(bar_h * 0.65),
    }
    seek.yc = math.floor((seek.y0 + seek.y1) / 2)
    local vol = { x0 = VIEW.w - vol_w + 8, y0 = bar_y0 + pad, x1 = VIEW.w - pad, y1 = VIEW.h - pad }
    local panel = {
        x0 = math.floor(VIEW.w * 0.52),
        x1 = VIEW.w - 16,
        y0 = 24,
        rows = 5,
        row_h = 44,
    }
    panel.y1 = panel.y0 + panel.rows * panel.row_h
    return { bar_h = bar_h, bar_y0 = bar_y0, play = play, seek = seek, vol = vol, panel = panel }
end

local L = nil -- current layout

local function inside(r, x, y)
    return r and x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1
end

local state = { visible = true, panel = false, dragging = false }

--------------------------------------------------------------------- drawing
local COL = {
    bar = '\\1c&H151515&',
    play = '\\1c&H40E0FF&',
    track = '\\1c&H3A3A3A&',
    fill = '\\1c&H20A0FF&',
    knob = '\\1c&HFFFFFF&',
    vol = '\\1c&H60D040&',
    panelbg = '\\1c&H0A0A0A&',
    rowon = '\\1c&HFF7030&',
    rowoff = '\\1c&H282828&',
}

-- One ASS *event* per shape, each with a single \pos(0,0) and absolute drawing
-- coordinates.  Splitting shapes differently does NOT work in mpv 0.41.0
-- (measured, surface 960x540, shapes requested at y=100/200/300):
--   * one event, two \p1..\p0 segments      -> only the first shape renders
--   * one event, shapes joined with \N      -> later shapes get +40px per line
--                                              and any per-line \pos is ignored
--   * separate events split by a real "\n"  -> exact pixels (this variant)
local function rect(x0, y0, x1, y1, col)
    return string.format(
        '{\\pos(0,0)\\an7\\blur0\\bord0\\shad0%s\\p1}m %d %d l %d %d %d %d %d %d{\\p0}',
        col, x0, y0, x1, y0, x1, y1, x0, y1
    )
end

local function progress_ratio()
    local t = mp.get_property_number('time-pos') or 0
    local d = mp.get_property_number('duration') or 0
    if d <= 0 then return 0 end
    return clamp(t / d, 0, 1)
end

local function assemble()
    local parts = {}
    local function add(x0, y0, x1, y1, col)
        parts[#parts + 1] = rect(x0, y0, x1, y1, col)
    end

    if state.panel and L then
        local p = L.panel
        add(p.x0, p.y0, p.x1, p.y1, COL.panelbg)
        local pos = mp.get_property_number('playlist-pos') or 0
        for i = 0, p.rows - 1 do
            local y0 = p.y0 + i * p.row_h
            local col = (i == pos) and COL.rowon or COL.rowoff
            add(p.x0 + 6, y0 + 4, p.x1 - 6, y0 + p.row_h - 4, col)
        end
        add(p.x0 + 6, p.y0 + (pos + 1) * p.row_h - 8, p.x0 + 40, p.y0 + (pos + 1) * p.row_h - 4, COL.knob)
    end

    if state.visible and L then
        add(0, L.bar_y0, VIEW.w, VIEW.h, COL.bar)
        -- play / pause glyph
        local pb = L.play
        add(pb.x0, pb.y0, pb.x1, pb.y1, COL.play)
        if mp.get_property_native('pause') then
            add(pb.x0 + 6, pb.y0 + 6, pb.x0 + 14, pb.y1 - 6, COL.bar)
            add(pb.x1 - 14, pb.y0 + 6, pb.x1 - 6, pb.y1 - 6, COL.bar)
        else
            add(pb.x0 + 8, pb.y0 + 6, pb.x1 - 6, pb.y1 - 6, COL.bar)
        end
        -- seekbar
        local s = L.seek
        add(s.x0, s.y0, s.x1, s.y1, COL.track)
        local r = progress_ratio()
        local kx = s.x0 + math.floor((s.x1 - s.x0) * r)
        if kx > s.x0 then add(s.x0, s.y0, kx, s.y1, COL.fill) end
        add(clamp(kx - 3, s.x0, s.x1 - 6), s.y0 - 4, clamp(kx + 3, s.x0 + 6, s.x1), s.y1 + 4, COL.knob)
        -- volume box: width proportional to volume
        local v = mp.get_property_number('volume') or 100
        local vol = L.vol
        local vw = math.floor((vol.x1 - vol.x0) * clamp(v / 100, 0, 1))
        add(vol.x0, vol.y0, vol.x1, vol.y1, COL.track)
        if vw > 0 then add(vol.x0, vol.y0, vol.x0 + vw, vol.y1, COL.vol) end
    end

    return table.concat(parts, '\n')
end

local function draw(reason)
    L = compute_layout()
    if not L then return false end
    if not state.visible and not state.panel then
        mp.set_osd_ass(0, 0, '')
        return false
    end
    mp.set_osd_ass(VIEW.w, VIEW.h, assemble())
    bump('draws')
    return true
end

-- Counters ---------------------------------------------------------------
-- `updates`   : every UI update the GUI performs (the perf contract counter)
-- `updates-visible` / `updates-idle` : split; idle must stay 0 while hidden
local function update(reason)
    local hidden = (not state.visible) and (not state.panel)
    if hidden and reason == 'time' then
        -- idle + hidden: absolutely no work, no counter movement
        return
    end
    bump('updates')
    if hidden then
        bump('updates-idle')
    else
        bump('updates-visible')
    end
    draw(reason)
end

---------------------------------------------------------------------- timers
local hide_timer = nil
local function arm_hide()
    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(HIDE_AFTER, function()
        if state.panel or state.dragging then
            arm_hide()
            return
        end
        state.visible = false
        ud_set("visible", false)
        draw("hide")
    end)
end

local function show()
    state.visible = true
    ud_set("visible", true)
    arm_hide()
    update("show")
end

-------------------------------------------------------------------- seeking
local function seek_to_x(x)
    local d = mp.get_property_number('duration') or 0
    if d <= 0 or not L then return end
    local s = L.seek
    local frac = clamp((x - s.x0) / math.max(1, (s.x1 - s.x0)), 0, 1)
    local target = frac * d
    mp.commandv('seek', target, 'absolute+exact')
    ud_set('last-seek', string.format('%.3f', target))
    bump('seeks')
    update('seek')
end

----------------------------------------------------------------- interaction
local function hit(x, y)
    if not L then return nil end
    if state.panel then
        local p = L.panel
        if inside({ x0 = p.x0, y0 = p.y0, x1 = p.x1, y1 = p.y1 }, x, y) then
            local row = math.floor((y - p.y0) / p.row_h)
            if row >= 0 and row < p.rows then return 'row', row end
        end
    end
    if inside(L.play, x, y) then return 'play' end
    if inside(L.seek, x, y) then return 'seek' end
    if inside(L.vol, x, y) then return 'vol' end
    return nil
end

local function do_click(x, y)
    local what, row = hit(x, y)
    ud_set('last-action', string.format('down:%s@%d,%d', tostring(what), x, y))
    if what == 'play' then
        local p = mp.get_property_native('pause')
        mp.set_property_native('pause', not p)
        bump('toggles')
    elseif what == 'seek' then
        state.dragging = true
        ud_set('dragging', true)
        seek_to_x(x)
    elseif what == 'row' then
        mp.set_property_native('playlist-pos', row)
        ud_set('panel-row', row)
        bump('row-clicks')
    elseif what == 'vol' then
        bump('vol-clicks')
    end
    show()
end

local function do_release()
    if state.dragging then
        state.dragging = false
        ud_set('dragging', false)
        update('release')
    end
end

mp.add_key_binding('MBTN_LEFT', 'refgui-click', function(evt)
    local pos = mp.get_property_native('mouse-pos')
    if not pos then return end
    if evt and evt.event == 'up' then
        do_release()
    else
        do_click(pos.x, pos.y)
    end
end, { complex = true })

mp.add_key_binding('WHEEL_UP', 'refgui-wheel-up', function()
    local pos = mp.get_property_native('mouse-pos')
    if not pos then return end
    if L and inside(L.vol, pos.x, pos.y) then
        mp.set_property_number('volume', math.min(200, (mp.get_property_number('volume') or 100) + 2))
        bump('wheel')
        show()
    else
        mp.commandv('seek', 5, 'relative')
        show()
    end
end)

mp.add_key_binding('WHEEL_DOWN', 'refgui-wheel-down', function()
    local pos = mp.get_property_native('mouse-pos')
    if not pos then return end
    if L and inside(L.vol, pos.x, pos.y) then
        mp.set_property_number('volume', math.max(0, (mp.get_property_number('volume') or 100) - 2))
        bump('wheel')
        show()
    else
        mp.commandv('seek', -5, 'relative')
        show()
    end
end)

mp.add_key_binding('Tab', 'refgui-panel', function()
    state.panel = not state.panel
    ud_set('panel', state.panel)
    bump('panel-toggles')
    update('panel')
    show()
end)

mp.observe_property('mouse-pos', 'native', function(_, pos)
    if not pos or not state.visible then
        if pos then show() end
        return
    end
    if state.dragging then seek_to_x(pos.x) end
end)

mp.observe_property('time-pos', 'number', function()
    update('time')
end)

mp.observe_property('osd-dimensions', 'native', function()
    L = compute_layout()
    -- mpv drops the OSD on resize: always redraw
    update('resize')
end)

mp.register_event('file-loaded', function() show() end)
mp.observe_property("playlist-pos", "number", function() update("playlist-pos") end)
mp.register_event('shutdown', function() ud_set('shutdown', 1) end)

show()
