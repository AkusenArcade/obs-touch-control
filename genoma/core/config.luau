--!strict
-- What the person chose: ~/.config/obs-touch-control/config.json, the file and
-- the keys of the GTK version. It holds the WebSocket's password, so it is the
-- person's alone (0600).
local g = require("@genoma")

local M = {}

local dir = (g.env("XDG_CONFIG_HOME") or ((g.env("HOME") or "") .. "/.config")) .. "/obs-touch-control"
M.path = dir .. "/config.json"

export type Favorite = { name: string, context: string? }
-- `type`: "scene" (name), "hotkey" (name, context), "mute" (input).
export type PanelItem = { type: string, name: string?, context: string?, input: string?, label: string? }

M.defaults = {
    host = "localhost",
    port = 4455,
    password = "",
    auto_connect = false,
    start_fullscreen = false,
    confirm_stop = true,
    -- How big the tiles are: bigger ones, fewer columns.
    tile_size = "medium",
    favorites = {},
    -- The person's own names for hotkeys, by M.alias_key.
    aliases = {},
    panel = {},
} :: { [string]: any }

local LISTS = { favorites = true, panel = true }

-- A hotkey of one source is that source's, not its name's alone.
function M.alias_key(name: string, context: string?): string
    return if context then `{name}@{context}` else name
end

local file = g.file { path = M.path, watch = false }

local function valid(key: string, value: any): boolean
    if type(value) ~= type(M.defaults[key]) then return false end
    if key == "tile_size" then return value == "small" or value == "medium" or value == "large" end
    if key == "port" then return value >= 1 and value <= 65535 and value % 1 == 0 end
    return true
end

-- What was read and is not ours stays in the file.
local kept: { [string]: any } = {}
local signals: { [string]: any } = {}
do
    if file.text then
        local ok, parsed = pcall(g.parse_json, file.text)
        if ok and type(parsed) == "table" then kept = parsed end
    end
    for key, default in M.defaults do
        local value = kept[key]
        signals[key] = g.signal(if valid(key, value) then value else default)
    end
end

function M.get(key: string): any return signals[key].value end
function M.peek(key: string): any
    return g.untracked(function() return signals[key].value end)
end

-- What went wrong writing it, told by who can say it.
M.failed = function(_: string) end

local function save()
    local out = table.clone(kept)
    for k, s in signals do
        local v = g.untracked(function() return s.value end)
        out[k] = if LISTS[k] then g.array(table.clone(v)) else v
    end
    local ok, why = pcall(function() file:write(g.to_json(out, true), { mode = "600" }) end)
    if not ok then M.failed(tostring(why)) end
end

function M.set(key: string, value: any)
    M.change { [key] = value }
end

-- Several at once, one write.
function M.change(values: { [string]: any })
    local changed = false
    g.batch(function()
        for key, value in values do
            if valid(key, value) and M.peek(key) ~= value then
                signals[key].value = value
                changed = true
            end
        end
    end)
    if changed then save() end
end

-- ---- Favourites and names -------------------------------------------------------

local function same(a: Favorite, b: Favorite): boolean return a.name == b.name and a.context == b.context end

function M.is_favorite(f: Favorite): boolean
    for _, o in M.get("favorites") do
        if same(o, f) then return true end
    end
    return false
end

function M.toggle_favorite(f: Favorite)
    local list, found = {}, false
    for _, o in M.peek("favorites") do
        if same(o, f) then found = true else table.insert(list, o) end
    end
    if not found then table.insert(list, { name = f.name, context = f.context }) end
    M.set("favorites", list)
end

function M.alias(name: string, context: string?): string?
    return M.get("aliases")[M.alias_key(name, context)]
end

-- nil: back to the name it has by itself.
function M.name_hotkey(name: string, context: string?, alias: string?)
    local all = table.clone(M.peek("aliases"))
    all[M.alias_key(name, context)] = alias
    M.set("aliases", all)
end

-- The panel, changed by `f` on a copy of it.
function M.edit_panel(f: ({ PanelItem }) -> ())
    local list = {}
    for _, item in M.peek("panel") do table.insert(list, table.clone(item)) end
    f(list)
    M.set("panel", list)
end

return M
