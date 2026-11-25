--!strict
-- A button in the window's corner, and the cell that grows from it, above it.
local g = require("@genoma")
local look = require("ui/look")

local M = {}

local BUTTON, GAP_UP = look.foot_height, 10
M.BUTTON = BUTTON

-- `t`: id, name, area() the window's { w, h }, x() the button's, open (a
-- signal), width, content, button (its node, placed by this), outside (whether
-- a press beside it puts it away). `present()` whether it is there at all.
function M.new(t: { [string]: any }): any
    local open = t.open
    local content_h = g.signal(280)
    local there = g.signal(false)
    local grown = g.signal(false)
    local putting_away: any = nil
    g.watch(function() return open.value end, function(on: boolean)
        if putting_away then putting_away:stop() end
        putting_away = nil
        if on then
            there.value = true
            g.after(0, function() grown.value = g.untracked(function() return open.value end) end)
        else
            grown.value = false
            putting_away = g.after(look.CLOSE, function()
                putting_away = nil
                there.value = false
            end)
        end
    end)
    local function timing(): string return if grown.value then "cell_open" else "cell_close" end
    local E = look.margin_edge
    local area = t.area
    local function width(): number return math.min(t.width, area().w - E * 2) end
    local bx = t.x
    local function by(): number return area().h - E - BUTTON end
    local function tall(): number return math.min(content_h.value, by() - GAP_UP - E) end
    -- Its right edge the window's, or as far as it has to reach.
    local function px(): number return math.max(E, math.min(area().w - E, bx() + width()) - width()) end

    local panel = g.capsule {
        id = t.id .. "-cell",
        name = t.name,
        overlay = true,
        attach = "corner",
        present = function() return there.value end,
        offset_x = function() return if grown.value then px() else bx() end,
        offset_y = function() return if grown.value then by() - GAP_UP - tall() else by() end,
        width = function() return if grown.value then width() else BUTTON end,
        height = function() return if grown.value then tall() else BUTTON end,
        radius = function() return look.shaped(if grown.value then look.radius_panel else BUTTON / 2) end,
        opacity = function() return if grown.value then 1 else 0 end,
        clip = true,
        fill = look.glass_over,
        rim_top = look.rim,
        rim_bottom = look.line,
        backdrop_blur = look.glass_blur,
        transition = { offset_x = timing, offset_y = timing, width = timing, height = timing, radius = timing, opacity = timing },
        on_press = function() end,
        on_click = function() end,
        g.box {
            overlay = true,
            attach = "corner",
            width = width,
            height = tall,
            scroll = "y",
            clip = true,
            opacity = function() return if grown.value then 1 else 0 end,
            transition = { opacity = function() return if grown.value then "content_in" else "content_out" end },
            g.box {
                width = width,
                direction = "column",
                align = "stretch",
                on_size = function(_: number, h: number) content_h.value = h end,
                t.content,
            },
        },
    }
    return g.box {
        overlay = true,
        attach = "corner",
        width = function() return area().w end,
        height = function() return area().h end,
        if t.outside then g.box {
            overlay = true,
            attach = "corner",
            present = function() return open.value end,
            width = function() return area().w end,
            height = function() return area().h end,
            on_press = function() end,
            on_click = function() open.value = false end,
        } else g.box {},
        panel,
        t.button(bx, by),
    }
end

return M
