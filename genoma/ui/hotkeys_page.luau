--!strict
-- Every hotkey OBS has, in groups, the favourites first. Those OBS has one of for
-- each source ask which. The same listing is what the panel picks from.
local g = require("@genoma")
local app = require("core/app")
local config = require("core/config")
local hotkeys = require("core/hotkeys")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local sheet = require("ui/sheet")
local tiles = require("ui/tiles")

local M = {}

local STAR = 44

-- What to do with the one chosen; nil: it is pressed.
type Pick = ((name: string, context: string?) -> ())?

local function min_w(): number return (app.size("hotkey")) end
local function tall(): number return (select(2, app.size("hotkey"))) end

local function star(name: string, context: string?, ink: (number?) -> string, w: () -> number): any
    local favorite = { name = name, context = context }
    local function on(): boolean return config.is_favorite(favorite) end
    return g.box {
        overlay = true,
        attach = "corner",
        offset_x = function() return w() - STAR end,
        role = "button",
        name = "Preferito",
        width = STAR,
        height = STAR,
        align = "center",
        justify = "center",
        on_press = function() end,
        on_click = function(button: number) if button == ui.LEFT then config.toggle_favorite(favorite) end end,
        on_long_press = function(): boolean return true end,
        ui.glyph(function() return if on() then "star-filled" else "star" end, 18, on, function() return ink(0.4) end),
    }
end

-- `sub()`: what is under its name.
local function tile(t: { [string]: any }): any
    local function size(): number
        local _, _, s = app.size("hotkey")
        return s
    end
    local function room(): number return t.w() - 28 - (if t.starred then 28 else 0) end
    return tiles.tile({
        name = t.title,
        w = t.w,
        h = t.h,
        dashed = function() return t.multi end,
        on_click = t.on_click,
        on_hold = t.on_hold,
    }, function(ink)
        local out: { any } = {
            g.box {
                overlay = true,
                attach = "corner",
                offset_x = 14,
                height = t.h,
                direction = "column",
                align = "start",
                justify = "center",
                gap = 3,
                g.text {
                    text = function() return tiles.fit(t.title(), room(), size(), 600, 2) end,
                    max_width = room,
                    wrap = true,
                    color = function() return ink() end,
                    font = look.expressive,
                    size = size,
                    weight = 600,
                },
                g.text {
                    present = function() return t.sub() ~= "" end,
                    text = t.sub,
                    max_width = room,
                    ellipsize = "middle",
                    color = function() return ink(0.6) end,
                    font = look.expressive,
                    size = look.font_secondary,
                },
            },
        }
        if t.starred then table.insert(out, star(t.entry.name, t.entry.context, ink, t.w)) end
        return out
    end)
end

-- The person's own name for one.
local function rename(origin: any, e: hotkeys.Entry)
    local alias = g.untracked(function() return config.alias(e.name, e.context) end)
    sheet.write(origin, {
        title = "Rinomina riquadro",
        note = `Nome originale: {hotkeys.label(e.name)}`,
        text = alias or hotkeys.label(e.name),
        can_reset = alias ~= nil,
        on_done = function(text: string?) config.name_hotkey(e.name, e.context, text) end,
    })
end

-- Which source a hotkey is for.
function M.choose_source(origin: any, name: string, pick: Pick)
    sheet.open(origin, {
        name = "Scegli la sorgente",
        width = 760,
        head = function(width: () -> number): any return sheet.title(g.untracked(function() return hotkeys.title(name) end), width) end,
        content = function(width: () -> number): any
            local sections: { [any]: any } = { direction = "column", align = "stretch", gap = 12 }
            for _, c in hotkeys.candidates(name) do
                if #c.names > 0 then
                    table.insert(sections, tiles.title(c.title))
                    table.insert(sections, tiles.grid {
                        width = width,
                        min = min_w,
                        height = tall,
                        items = function() return c.names end,
                        key = function(n: string) return n end,
                        row = function(item: () -> string, w: () -> number, h: () -> number): any
                            local source = g.untracked(item)
                            return tile {
                                title = function() return source end,
                                sub = function() return "" end,
                                w = w,
                                h = h,
                                starred = pick == nil,
                                entry = { name = name, context = source },
                                on_click = function()
                                    sheet.close()
                                    if pick then pick(name, source) else obs.press(name, source) end
                                end,
                            }
                        end,
                    })
                end
            end
            return g.box(sections)
        end,
    })
end

-- `query()`, and `pick` as above.
local function listing(width: () -> number, query: () -> string, pick: Pick): any
    local sections = g.computed(function() return hotkeys.sections(query()) end)
    return g.box {
        direction = "column",
        align = "start",
        width = width,
        g.each {
            direction = "column",
            align = "start",
            gap = 12,
            items = function() return sections.value end,
            key = function(s: hotkeys.Section) return s.key end,
            row = function(section: () -> hotkeys.Section): any
                return g.box {
                    direction = "column",
                    align = "start",
                    gap = 8,
                    tiles.title(g.untracked(section).title),
                    tiles.grid {
                        width = width,
                        min = min_w,
                        height = tall,
                        items = function() return section().entries end,
                        key = function(e: hotkeys.Entry) return `{config.alias_key(e.name, e.context)}:{e.multi}` end,
                        row = function(item: () -> hotkeys.Entry, w: () -> number, h: () -> number): any
                            local e = g.untracked(item)
                            return tile {
                                title = function() return hotkeys.title(e.name, e.context) end,
                                sub = function(): string
                                    local parts: { string } = {}
                                    local alias = config.alias(e.name, e.context)
                                    if alias then table.insert(parts, hotkeys.label(e.name)) end
                                    if e.multi then
                                        table.insert(parts, "Scegli sorgente…")
                                    elseif e.context then
                                        table.insert(parts, e.context)
                                    end
                                    return table.concat(parts, " · ")
                                end,
                                w = w,
                                h = h,
                                multi = e.multi,
                                starred = not e.multi and pick == nil,
                                entry = e,
                                on_click = function(origin: any)
                                    if e.multi then
                                        M.choose_source(origin, e.name, pick)
                                    elseif pick then
                                        sheet.close()
                                        pick(e.name, e.context)
                                    else
                                        obs.press(e.name, e.context)
                                    end
                                end,
                                on_hold = if pick == nil then function(origin: any) rename(origin, e) end else nil,
                            }
                        end,
                    },
                }
            end,
        },
        g.box { height = 16 },
    }
end

-- One chosen for something else.
function M.pick(origin: any, pick: (name: string, context: string?) -> ())
    local query = g.signal("")
    sheet.open(origin, {
        name = "Scegli una scorciatoia",
        width = 760,
        tall = true,
        head = function(width: () -> number): any
            return g.box {
                direction = "column",
                align = "stretch",
                gap = 12,
                sheet.title("Scegli una scorciatoia", width),
                ui.field {
                    id = "pick-search",
                    key = "pick",
                    width = width,
                    glyph = "search",
                    placeholder = "Cerca scorciatoia",
                    text = function() return query.value end,
                    on_change = function(text: string) query.value = text end,
                    on_clear = function() query.value = "" end,
                },
            }
        end,
        content = function(width: () -> number): any return listing(width, function() return query.value end, pick) end,
    })
end

function M.new(width: () -> number, height: () -> number): any
    local function query(): string return app.search.value end
    local none = g.computed(function() return #hotkeys.sections(query()) == 0 end)
    return g.box {
        width = width,
        height = height,
        tiles.nothing(width, height, function() return none.value end, "keyboard", function()
            return if query() == "" then "Nessuna scorciatoia" else "Nessun risultato"
        end),
        g.box {
            present = function() return not none.value end,
            tiles.scroller(width, height, function(inner: () -> number): any return listing(inner, query, nil) end),
        },
    }
end

return M
