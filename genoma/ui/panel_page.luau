--!strict
-- The person's own page: big buttons they pick and order as they like, scenes,
-- hotkeys and mutes together.
local g = require("@genoma")
local app = require("core/app")
local config = require("core/config")
local hotkeys = require("core/hotkeys")
local notice = require("core/notice")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local hotkeys_page = require("ui/hotkeys_page")
local scenes_page = require("ui/scenes_page")
local sheet = require("ui/sheet")
local tiles = require("ui/tiles")

local M = {}

type Item = config.PanelItem

local function audio(name: string): obs.Audio?
    for _, a in obs.audio.value do
        if a.name == name then return a end
    end
    return nil
end

-- What it is, as drawn: its tone, what there is to say under its name, its
-- drawing.
local function state(item: Item): (string, string, string)
    if item.type == "scene" then
        if table.find(obs.scenes.value, item.name or "") == nil then return "gone", "Scena non trovata", "scenes" end
        local tone = scenes_page.tone(item.name or "")
        return tone, scenes_page.badge(tone), "scenes"
    elseif item.type == "mute" then
        local a = audio(item.input or "")
        if a == nil then return "gone", "Sorgente non trovata", "volume-off" end
        if a.muted.value then return "live", "Silenziato", "volume-off" end
        return "plain", "", "volume"
    end
    if not hotkeys.exists(item.name or "") then return "gone", "Non disponibile", "keyboard" end
    return "plain", item.context or "", "keyboard"
end

local function title(item: Item): string
    if item.label then return item.label end
    if item.type == "scene" then return item.name or "" end
    if item.type == "mute" then return item.input or "" end
    return hotkeys.title(item.name or "", item.context)
end

local function run(item: Item)
    if (g.untracked(function() return (state(item)) end)) == "gone" then return end
    if item.type == "scene" then obs.show(item.name or "")
    elseif item.type == "mute" then obs.toggle_mute(item.input or "")
    else obs.press(item.name or "", item.context)
    end
end

-- ---- Putting it together ---------------------------------------------------------

local function add(item: Item)
    config.edit_panel(function(list) table.insert(list, item) end)
    notice.say("Pulsante aggiunto al pannello")
end

local function rename(origin: any, index: number, item: Item)
    sheet.write(origin, {
        title = "Rinomina pulsante",
        text = g.untracked(function() return title(item) end),
        can_reset = item.label ~= nil,
        on_done = function(text: string?)
            config.edit_panel(function(list)
                if list[index] then list[index].label = text end
            end)
        end,
    })
end

local function move(index: number, by: number)
    config.edit_panel(function(list)
        local to = index + by
        if list[index] and list[to] then list[index], list[to] = list[to], list[index] end
    end)
end

-- What can be added.
function M.add(origin: any)
    app.editing.value = true
    local function choice(name: string, glyph: string, w: () -> number, h: () -> number, on_click: (any) -> (), dashed: boolean?): any
        return tiles.tile({
            name = name,
            w = w,
            h = h,
            dashed = function() return dashed == true end,
            on_click = on_click,
        }, function(ink)
            return {
                g.box {
                    overlay = true,
                    attach = "corner",
                    offset_x = 14,
                    height = h,
                    direction = "row",
                    align = "center",
                    gap = 12,
                    ui.glyph(glyph, 22, function() return false end, function() return ink(0.7) end),
                    g.text {
                        text = function()
                            local _, _, s = app.size("hotkey")
                            return tiles.fit(name, w() - 62, s, 600, 2)
                        end,
                        max_width = function() return w() - 62 end,
                        wrap = true,
                        color = function() return ink() end,
                        font = look.expressive,
                        size = function()
                            local _, _, s = app.size("hotkey")
                            return s
                        end,
                        weight = 600,
                    },
                },
            }
        end)
    end
    local function section(width: () -> number, name: string, glyph: string, names: { string }, make: (string) -> Item): any
        return g.box {
            direction = "column",
            align = "stretch",
            gap = 8,
            tiles.title(name),
            if #names == 0 then ui.says("Nessuna disponibile", width) else tiles.grid {
                width = width,
                min = function() return (app.size("hotkey")) end,
                height = function() return (select(2, app.size("hotkey"))) end,
                items = function() return names end,
                key = function(n: string) return n end,
                row = function(item: () -> string, w: () -> number, h: () -> number): any
                    local n = g.untracked(item)
                    return choice(n, glyph, w, h, function()
                        sheet.close()
                        add(make(n))
                    end)
                end,
            },
        }
    end
    sheet.open(origin, {
        name = "Aggiungi pulsante",
        width = 760,
        tall = true,
        head = function(width: () -> number): any return sheet.title("Aggiungi pulsante", width) end,
        content = function(width: () -> number): any
            local sounds: { string } = {}
            for _, a in g.untracked(function() return obs.audio.value end) do table.insert(sounds, a.name) end
            return g.box {
                direction = "column",
                align = "stretch",
                gap = 20,
                g.box {
                    direction = "column",
                    align = "stretch",
                    gap = 8,
                    tiles.title("Scorciatoie"),
                    tiles.grid {
                        width = width,
                        min = function() return (app.size("hotkey")) end,
                        height = function() return (select(2, app.size("hotkey"))) end,
                        items = function() return { "pick" } end,
                        key = function(k: string) return k end,
                        row = function(_: any, w: () -> number, h: () -> number): any
                            return choice("Scegli una scorciatoia…", "keyboard", w, h, function(at: any)
                                hotkeys_page.pick(at, function(name: string, context: string?)
                                    add { type = "hotkey", name = name, context = context }
                                end)
                            end, true)
                        end,
                    },
                },
                section(width, "Scene", "scenes", g.untracked(function() return obs.scenes.value end), function(n: string): Item return { type = "scene", name = n } end),
                section(width, "Audio: muto e riattiva", "volume", sounds, function(n: string): Item return { type = "mute", input = n } end),
            }
        end,
    })
end

-- ---- Its tiles --------------------------------------------------------------------

local BAR, BUTTON = 52, 44

local function bar(index: () -> number, item: () -> Item, w: () -> number, h: () -> number, ink: (number?) -> string): any
    local function button(glyph: string, name: string, act: (any) -> (), off: (() -> boolean)?, hue: (() -> string)?): any
        local press, origin = ui.place(function() return BUTTON end, function() return BUTTON end)
        local function idle(): boolean return off ~= nil and off() end
        return g.box {
            role = "button",
            name = name,
            width = BUTTON,
            height = BUTTON,
            align = "center",
            justify = "center",
            opacity = function() return if idle() then 0.3 else 1 end,
            on_press = function(_: number, x: number, y: number) press(x, y) end,
            on_click = function(b: number)
                if b == ui.LEFT and not g.untracked(idle) then act(origin()) end
            end,
            ui.glyph(glyph, 20, function() return false end, hue or function() return ink(0.85) end),
        }
    end
    return g.box {
        overlay = true,
        attach = "corner",
        present = function() return app.editing.value end,
        offset_y = function() return h() - BAR end,
        width = w,
        height = BAR,
        direction = "row",
        align = "start",
        justify = "center",
        gap = 0,
        button("chevron-left", "Sposta prima", function() move(g.untracked(index), -1) end, function() return index() == 1 end),
        button("edit", "Rinomina", function(origin: any) rename(origin, g.untracked(index), g.untracked(item)) end),
        button("chevron-right", "Sposta dopo", function() move(g.untracked(index), 1) end, function() return index() == #config.get("panel") end),
        button("trash", "Rimuovi", function()
            local i = g.untracked(index)
            config.edit_panel(function(list) table.remove(list, i) end)
        end, nil, look.alert),
    }
end

local function tile(entry: () -> any, w: () -> number, h: () -> number): any
    local function item(): Item return entry().item end
    local function index(): number return entry().index end
    return tiles.tile({
        name = function() return title(item()) end,
        w = w,
        h = h,
        tone = function(): string
            local tone = state(item())
            -- What is gone can still be taken away.
            return if app.editing.value then "plain" else tone
        end,
        dashed = function() return app.editing.value end,
        on_click = function(origin: any)
            if g.untracked(function() return app.editing.value end) then
                rename(origin, g.untracked(index), g.untracked(item))
            else
                run(g.untracked(item))
            end
        end,
    }, function(ink)
        local function badge(): string return (select(2, state(item()))) end
        return {
            g.box {
                overlay = true,
                attach = "corner",
                width = w,
                height = function() return h() - (if app.editing.value then BAR else 0) end,
                direction = "column",
                align = "center",
                justify = "center",
                gap = 8,
                g.box {
                    present = function() return h() >= 110 and not app.editing.value end,
                    ui.glyph(function() return (select(3, state(item()))) end, 26, function() return false end, function() return ink(0.7) end),
                },
                scenes_page.words(function() return title(item()) end, badge, w, ink, 2),
            },
            bar(index, item, w, h, ink),
        }
    end)
end

local function add_tile(w: () -> number, h: () -> number): any
    return tiles.tile({
        name = "Aggiungi",
        w = w,
        h = h,
        dashed = function() return true end,
        on_click = M.add,
    }, function(ink)
        return {
            g.box {
                overlay = true,
                attach = "center",
                direction = "column",
                align = "center",
                gap = 8,
                ui.glyph("plus", 30, function() return false end, function() return ink(0.85) end),
                ui.label("Aggiungi", function() return ink(0.85) end, look.font_action),
            },
        }
    end)
end

function M.new(width: () -> number, height: () -> number): any
    local function entries(): { any }
        local out: { any } = {}
        -- The same twice is two.
        local seen: { [string]: number } = {}
        for i, item in config.get("panel") do
            local key = `{item.type}:{item.name or item.input or ""}:{item.context or ""}`
            seen[key] = (seen[key] or 0) + 1
            table.insert(out, { key = `{key}:{seen[key]}`, item = item, index = i })
        end
        if app.editing.value then table.insert(out, { key = "+" }) end
        return out
    end
    local function empty(): boolean return #config.get("panel") == 0 and not app.editing.value end
    return g.box {
        width = width,
        height = height,
        tiles.nothing(width, height, empty, "grid", function()
            return "Il tuo pannello è vuoto: componilo con scene, scorciatoie e muto, nell'ordine che preferisci."
        end, ui.action { id = "add-first", label = "Aggiungi pulsanti", kind = "filled", on_at = M.add }),
        g.box {
            present = function() return not empty() end,
            tiles.scroller(width, height, function(inner: () -> number): any
                return tiles.grid {
                    width = inner,
                    min = function()
                        local w = (app.size("scene"))
                        return if app.editing.value then math.max(w, BUTTON * 4 + 8) else w
                    end,
                    height = function()
                        local _, h = app.size("scene")
                        return if app.editing.value then math.max(h, BAR + 72) else h
                    end,
                    items = entries,
                    key = function(e: any) return e.key end,
                    row = function(entry: () -> any, w: () -> number, h: () -> number): any
                        if g.untracked(entry).key == "+" then return add_tile(w, h) end
                        return tile(entry, w, h)
                    end,
                }
            end),
        },
    }
end

return M
