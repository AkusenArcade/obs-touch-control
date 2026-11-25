--!strict
-- Tiles: big buttons, as many across as fit, each as wide as what is left over
-- lets it be.
local g = require("@genoma")
local look = require("ui/look")
local ui = require("ui/controls")

local M = {}

M.GAP = look.gap

-- `t`: width() the room, min() a tile's least width, height(), items(),
-- key(item), row(item, w, h).
function M.grid(t: { [string]: any }): any
    local GAP = M.GAP
    local function columns(): number
        return math.clamp(math.floor((t.width() + GAP) / (t.min() + GAP)), 1, 24)
    end
    local function w(): number
        local c = columns()
        return math.floor((t.width() - GAP * (c - 1)) / c)
    end
    return g.each {
        width = t.width,
        direction = "row",
        align = "start",
        flow = true,
        gap = GAP,
        gap_lines = GAP,
        items = t.items,
        key = t.key,
        row = function(item: any, index: any) return t.row(item, w, t.height, index) end,
    }
end

-- A button that does one thing. `t`: id, name, w(), h(), tone() ("plain", "live":
-- on air or muted, "preview", "gone": what it did is not there), dashed(),
-- on_click(origin), on_hold(origin) for a long press or the right button,
-- justify, and its children, given `ink(strength)`: the colour of what is written
-- on it.
function M.tile(t: { [string]: any }, children: (ink: (number?) -> string) -> { any }): any
    local over, down = g.signal(false), g.signal(false)
    local press, origin = ui.place(t.w, t.h)
    local function tone(): string return if t.tone then t.tone() else "plain" end
    local function filled(): boolean return tone() == "live" or tone() == "preview" end
    local function hue(): string return if tone() == "live" then look.alert() else look.primary() end
    local function dashed(): boolean return t.dashed ~= nil and t.dashed() end
    local function ink(strength: number?): string
        return g.colour.alpha(if filled() then look.background() else look.text(), strength or 1)
    end
    local function edge(): string
        if filled() then return look.CLEAR end
        if over.value or down.value then return look.primary() end
        return if dashed() then g.colour.alpha(look.node(), 0.7) else look.node()
    end
    local node: { [any]: any } = {
        id = t.id,
        role = "button",
        name = if type(t.name) == "function" then g.untracked(t.name) else t.name,
        width = t.w,
        height = t.h,
        radius = look.round(look.radius_tile),
        clip = true,
        fill = function()
            if filled() then return look.gradient_top(hue()) end
            return if down.value then look.chosen() elseif over.value then look.hovered() else look.CLEAR
        end,
        fill_bottom = function()
            if filled() then return look.gradient_bottom(hue()) end
            return if down.value then look.chosen() elseif over.value then look.hovered() else look.CLEAR
        end,
        rim_top = edge,
        rim_bottom = edge,
        dash = function() return if dashed() then 4 else 0 end,
        dash_gap = 4,
        opacity = function() return if tone() == "gone" then 0.45 elseif filled() and down.value then 0.8 else 1 end,
        transition = { fill = "ui_change", fill_bottom = "ui_change", rim_top = "ui_change", rim_bottom = "ui_change", opacity = "ui_change" },
        drag_threshold = 12,
        on_hover = function(on: boolean)
            over.value = on
            if not on then down.value = false end
        end,
        on_press = function(button: number, x: number, y: number)
            press(x, y)
            down.value = button == ui.LEFT
        end,
        on_release = function() down.value = false end,
        on_click = function(button: number)
            down.value = false
            if button == ui.LEFT then
                if t.on_click then t.on_click(origin()) end
            elseif button == ui.RIGHT and t.on_hold then
                t.on_hold(origin())
            end
        end,
        on_long_press = if t.on_hold then function(): boolean
            down.value = false
            t.on_hold(origin())
            return true
        end else nil,
    }
    for _, c in children(ink) do table.insert(node, c) end
    return g.capsule(node)
end

-- A name on `lines` lines at most, what does not fit lost at its end.
local fitted: { [string]: string } = {}
local held = 0
function M.fit(name: string, width: number, size: number, weight: number, lines: number): string
    local font = look.expressive()
    local key = `{width}:{size}:{lines}:{font}:{name}`
    local hit = fitted[key]
    if hit then return hit end
    local one = g.text_height { text = "X", font = font, size = size, weight = weight, width = width }
    local function fits(text: string): boolean
        return g.text_height { text = text, font = font, size = size, weight = weight, width = width } <= one * lines + 1
    end
    local out = name
    if not fits(name) then
        local letters: { string } = {}
        for _, code in utf8.codes(name) do table.insert(letters, utf8.char(code)) end
        local low, high = 1, #letters
        while low < high do
            local mid = math.ceil((low + high) / 2)
            if fits(table.concat(letters, "", 1, mid) .. "…") then low = mid else high = mid - 1 end
        end
        out = table.concat(letters, "", 1, low) .. "…"
    end
    if held > 5000 then
        fitted, held = {}, 0
    end
    fitted[key] = out
    held += 1
    return out
end

-- A section's title over its tiles.
function M.title(text: string): any
    return g.box {
        height = 28,
        direction = "row",
        align = "center",
        ui.label(text, look.text_muted, look.font_action),
    }
end

-- What there is to say where there is nothing to show.
function M.nothing(width: () -> number, height: () -> number, present: () -> boolean, glyph: string, text: () -> string, more: any?): any
    return g.box {
        present = present,
        width = width,
        height = height,
        direction = "column",
        align = "center",
        justify = "center",
        gap = 16,
        ui.glyph(glyph, 48, function() return false end, look.text_faint),
        g.text {
            text = text,
            max_width = function() return math.min(420, width() - 32) end,
            wrap = true,
            text_align = "center",
            color = look.text_muted,
            font = look.expressive,
            size = 17,
            italic = true,
        },
        more or g.box {},
    }
end

-- A page that scrolls: its foot fades while there is more, a mark shows while
-- it moves. `content(width)`: what is in it.
local scroll_mark = require("ui/scroll_mark")
function M.scroller(width: () -> number, height: () -> number, content: (() -> number) -> any): any
    local content_h = g.signal(0)
    -- The mark's own.
    local ASIDE = 8
    local function inner(): number return width() - ASIDE end
    local mark = scroll_mark.new {
        height = height,
        x = function() return width() - 3 end,
        room = function() return math.max(0, content_h.value - height()) end,
    }
    return g.box {
        width = width,
        height = height,
        g.box {
            overlay = true,
            attach = "corner",
            width = width,
            height = height,
            scroll = "y",
            clip = true,
            direction = "column",
            align = "start",
            justify = "start",
            fade_bottom = mark.fade,
            on_scroll = function(_: number, y: number) mark.follow(y, 0) end,
            g.box {
                width = width,
                direction = "column",
                align = "start",
                on_size = function(_: number, h: number) content_h.value = h end,
                content(inner),
            },
        },
        mark.mark,
    }
end

return M
