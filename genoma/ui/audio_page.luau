--!strict
-- The mixer: each source that has a sound, its fader and its mute.
local g = require("@genoma")
local app = require("core/app")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local tiles = require("ui/tiles")

local M = {}

local PAD, MUTE, STEP = 16, 56, 0.5
local SPAN = -obs.MIN_DB

local function said(db: number): string
    return if db <= obs.MIN_DB then "-∞ dB" else string.format("%.1f dB", db)
end

-- It follows the finger from where it is, so a touch that only lands on it
-- changes nothing.
local function fader(a: obs.Audio, width: () -> number): any
    local TRACK, HANDLE, H = 4, 26, MUTE
    local held = g.signal(false)
    local start, base = 0, 0
    local function at(): number return math.clamp(a.db.value / SPAN + 1, 0, 1) end
    local function travel(): number return width() - HANDLE end
    local function timing(): string return if held.value then "placed" else "ui_change" end
    local function hue(): string return if a.muted.value then look.node() else look.primary() end
    local function mark(db: number): any
        return g.capsule {
            overlay = true,
            attach = "corner",
            offset_x = function() return HANDLE / 2 + travel() * (db / SPAN + 1) end,
            offset_y = H / 2 + 10,
            width = 1,
            height = 6,
            crisp = true,
            radius = 0,
            fill = look.node,
            rim_top = look.CLEAR,
            rim_bottom = look.CLEAR,
        }
    end
    local function let_go()
        held.value = false
        a.held = false
    end
    return g.box {
        role = "slider",
        name = `Volume {a.name}`,
        width = width,
        height = H,
        on_press = function(button: number, x: number)
            if button ~= ui.LEFT then return end
            start, base = x, math.clamp(g.untracked(function() return a.db.value end), obs.MIN_DB, 0)
            a.held = true
            held.value = true
        end,
        on_drag = function(x: number)
            if not a.held then return end
            local db = base + (x - start) / math.max(1, g.untracked(travel)) * SPAN
            db = math.clamp(math.floor(db / STEP + 0.5) * STEP, obs.MIN_DB, 0)
            if db ~= g.untracked(function() return a.db.value end) then obs.set_volume(a, db) end
        end,
        on_release = let_go,
        on_click = let_go,
        g.capsule {
            overlay = true,
            attach = "corner",
            offset_y = (H - TRACK) / 2,
            width = width,
            height = TRACK,
            radius = look.round(TRACK / 2),
            fill = function() return g.colour.alpha(look.line(), 0.55) end,
            rim_top = look.CLEAR,
            rim_bottom = look.CLEAR,
        },
        mark(-20),
        mark(-10),
        g.capsule {
            overlay = true,
            attach = "corner",
            offset_y = (H - TRACK) / 2,
            width = function() return HANDLE / 2 + travel() * at() end,
            height = TRACK,
            radius = look.round(TRACK / 2),
            fill = function() return look.gradient_top(hue()) end,
            fill_bottom = function() return look.gradient_bottom(hue()) end,
            rim_top = look.CLEAR,
            rim_bottom = look.CLEAR,
            transition = { width = timing, fill = "ui_change", fill_bottom = "ui_change" },
        },
        g.capsule {
            overlay = true,
            attach = "corner",
            offset_x = function() return travel() * at() end,
            offset_y = (H - HANDLE) / 2,
            width = HANDLE,
            height = HANDLE,
            radius = look.round(HANDLE / 2),
            fill = function() return look.gradient_top(hue()) end,
            fill_bottom = function() return look.gradient_bottom(hue()) end,
            rim_top = look.CLEAR,
            rim_bottom = look.CLEAR,
            transition = { offset_x = timing, fill = "ui_change", fill_bottom = "ui_change" },
        },
    }
end

local function mute(a: obs.Audio): any
    local over = g.signal(false)
    local function on(): boolean return a.muted.value end
    local function ink(): string return if on() then look.background() else look.text() end
    local function edge(): string
        if on() then return look.CLEAR end
        return if over.value then look.primary() else look.node()
    end
    return g.capsule {
        role = "button",
        name = "Silenzia o riattiva",
        width = MUTE,
        height = MUTE,
        radius = look.round(MUTE / 2),
        align = "center",
        justify = "center",
        fill = function() return if on() then look.gradient_top(look.alert()) else look.CLEAR end,
        fill_bottom = function() return if on() then look.gradient_bottom(look.alert()) else look.CLEAR end,
        rim_top = edge,
        rim_bottom = edge,
        transition = { fill = "ui_change", fill_bottom = "ui_change", rim_top = "ui_change", rim_bottom = "ui_change" },
        on_hover = function(o: boolean) over.value = o end,
        on_press = function() end,
        on_click = function(button: number) if button == ui.LEFT then obs.toggle_mute(a.name) end end,
        ui.glyph(function() return if on() then "volume-off" else "volume" end, 24, function() return false end, ink),
    }
end

local function card(a: obs.Audio, w: () -> number, h: () -> number): any
    local function size(): number
        local _, _, s = app.size("audio")
        return s
    end
    return g.capsule {
        width = w,
        height = h,
        radius = look.round(look.radius_tile),
        padding = PAD,
        direction = "column",
        align = "stretch",
        justify = "between",
        fill = look.glass,
        rim_top = look.rim,
        rim_bottom = look.line,
        g.box {
            direction = "row",
            align = "center",
            justify = "between",
            gap = 12,
            height = 24,
            g.text {
                text = a.name,
                max_width = function() return w() - PAD * 2 - 90 end,
                color = look.text,
                font = look.expressive,
                size = size,
                weight = 600,
            },
            g.text {
                text = function() return said(a.db.value) end,
                color = look.text_muted,
                font = look.technical,
                size = look.font_action,
                tabular = true,
            },
        },
        g.box {
            direction = "row",
            align = "center",
            gap = 16,
            fader(a, function() return w() - PAD * 2 - MUTE - 16 end),
            mute(a),
        },
    }
end

function M.new(width: () -> number, height: () -> number): any
    return g.box {
        width = width,
        height = height,
        tiles.nothing(width, height, function() return #obs.audio.value == 0 end, "volume", function() return "Nessuna sorgente audio" end),
        g.box {
            present = function() return #obs.audio.value > 0 end,
            tiles.scroller(width, height, function(inner: () -> number): any
                return tiles.grid {
                    width = inner,
                    min = function() return (app.size("audio")) end,
                    height = function() return (select(2, app.size("audio"))) end,
                    items = function() return obs.audio.value end,
                    key = function(a: obs.Audio) return a.name end,
                    row = function(item: () -> obs.Audio, w: () -> number, h: () -> number): any
                        return card(g.untracked(item), w, h)
                    end,
                }
            end),
        },
    }
end

return M
