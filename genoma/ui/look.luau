--!strict
-- Bioma's look, so the window reads as part of the shell: the colours
-- derived as Bioma derives them (genoma/core/theme.luau there) from the
-- desktop theme the kit follows, its two voices and its measures.
local g = require("@genoma")
local kit = require("@genoma/kit")

local theme = kit.theme

local M = {}

M.CLEAR = "#00000000"

function M.background(): string return theme.get("background") end
function M.text(): string return theme.get("text") end
function M.primary(): string return theme.get("accent") end
-- On air, recording, muted; what stops something.
function M.alert(): string return theme.get("danger") end

function M.is_dark(): boolean
    local d = theme.desktop()
    if d and type(d.dark) == "boolean" then return d.dark end
    return g.colour.luma(M.background()) < 0.5
end

-- Technical: what the machine measures. Expressive: names, what comes from
-- a person.
function M.technical(): string
    local d = theme.desktop()
    return (d and d.fonts and d.fonts.technical) or "Orbitron"
end
function M.expressive(): string
    local d = theme.desktop()
    return (d and d.fonts and d.fonts.expressive) or "Spectral"
end

local function lift(hex: string, amount: number): string
    return g.colour.lift(hex, amount, M.is_dark())
end

-- The outline's family: three lightnesses of the background's hue, never
-- the primary's.
local function structural(lightness: number): string
    local bg, accent = M.background(), M.primary()
    local bh, bs = g.colour.hsl(bg)
    if bh < 0 or bs <= 0 then
        return g.colour.hsla(0, 0, lightness, 1)
    end
    local _, as = g.colour.hsl(accent)
    local s = math.max(math.min(bs + 0.04, 0.40), math.min(as * 0.33, 0.28))
    return g.colour.hsla(bh, s, lightness, 1)
end

function M.cell(): string return lift(M.background(), 0.075) end
function M.line(): string return structural(if M.is_dark() then 0.32 else 0.72) end
function M.node(): string return structural(if M.is_dark() then 0.43 else 0.62) end
function M.rim(): string return structural(if M.is_dark() then 0.55 else 0.50) end
function M.text_muted(): string return g.colour.alpha(M.text(), 0.70) end
function M.text_faint(): string return g.colour.alpha(M.text(), 0.54) end

-- One light, from above: lighter at the top, darker at the bottom.
function M.gradient_top(hex: string): string
    local h, s, l, a = g.colour.hsl(hex)
    return g.colour.hsla(math.max(0, h), math.min(1, s + 0.14), math.min(1, l + 0.16), a)
end
function M.gradient_bottom(hex: string): string
    local h, s, l, a = g.colour.hsl(hex)
    return g.colour.hsla(math.max(0, h), math.max(0, s - 0.15), math.max(0, l - 0.15), a)
end
function M.primary_top(): string return M.gradient_top(M.primary()) end
function M.primary_bottom(): string return M.gradient_bottom(M.primary()) end

-- A cell's glass (cell.opacity 0.72 in Bioma), and one that floats over
-- names, which must not be read through it.
function M.glass(): string return g.colour.alpha(M.cell(), 0.72) end
function M.glass_over(): string return g.colour.alpha(M.cell(), 0.94) end
-- What is under the pointer, what the keys stand on.
function M.hovered(): string return g.colour.alpha(M.text(), 0.06) end
function M.chosen(): string return g.colour.alpha(M.primary(), 0.16) end

-- How round the desktop is: Bioma's RADIUS, 0 to 1, of every surface's own
-- radius (Akusen, 2026-11-25). The file says what a control 32 tall takes; with
-- no desktop to follow, all of it.
local CONTROL = 16
function M.roundness(): number
    local d = theme.desktop()
    local r = d and d.sizes and d.sizes.radius
    return if type(r) == "number" then math.clamp(r / CONTROL, 0, 1) else 1
end
function M.shaped(radius: number): number return radius * M.roundness() end
-- For a node's `radius`; and for what lies inside a panel, concentric with it.
function M.round(radius: number): () -> number
    return function(): number return M.shaped(radius) end
end
function M.within(inset: number): () -> number
    return function(): number return math.max(0, M.shaped(M.radius_panel) - inset) end
end
-- The window's own corners, as Bioma gives them to its compositors; and what
-- stands in one of them, `inset` from its edges, concentric with it (Akusen,
-- 2026-11-25).
local WINDOW = 20
function M.in_corner(inset: number): () -> number
    return function(): number return math.max(0, M.shaped(WINDOW) - inset) end
end

-- A finger's measures: nothing to be touched is under 44.
M.touch = 44
M.foot_height = 56
M.radius_panel = 20
M.radius_well = 10
M.radius_tile = 18
M.margin_edge = 8
M.gap = 12
M.font_label = 15
M.font_text = 14
M.font_menu = 13
M.font_action = 12
M.font_secondary = 13
M.font_meta = 11
M.label_tracking = 0.06
M.glass_blur = 14

-- The one place a duration is written.
g.timing {
    ui_change = { duration = 0.18, curve = { 0.2, 0, 0, 1 } },
    cell_open = { duration = 0.25, curve = { 0.2, 0.9, 0.3, 1 } },
    cell_close = { duration = 0.15, curve = { 0.5, 0, 0.9, 0.5 } },
    content_in = { duration = 0.12, delay = 0.12, curve = { 0.2, 0, 0, 1 } },
    content_out = { duration = 0.06, curve = { 0.4, 0, 1, 1 } },
    -- Put where it is to grow from, before it is seen.
    placed = { duration = 0, curve = { 0, 0, 1, 1 } },
    page_in = { duration = 0.16, curve = { 0.2, 0, 0, 1 } },
}
M.CLOSE = 0.16

return M
