--!strict
-- What the window is showing: its size, its page, which field has the keys.
local g = require("@genoma")
local config = require("core/config")

local M = {}

M.area = g.signal({ w = 1100, h = 760 })
-- "panel", "scenes", "hotkeys" or "audio".
M.page = g.signal("panel")
-- The panel being put together.
M.editing = g.signal(false)
-- What the hotkeys are looked for by.
M.search = g.signal("")
-- The name of the field that has the keys.
M.field = g.signal("")
M.fullscreen = g.signal(config.peek("start_fullscreen"))

-- As wide as a phone: smaller tiles, so there are at least two across.
local COMPACT = 640
function M.compact(): boolean return M.area.value.w < COMPACT end

function M.has_keys(field: string): () -> boolean
    return function(): boolean return M.field.value == field end
end
function M.take_keys(field: string): () -> ()
    return function() M.field.value = field end
end

-- A tile's least width, its height and the size of its name, by what it is and
-- how big tiles were asked to be.
local SIZES: { [string]: { [string]: { number } } } = {
    scene = {
        compact = { 110, 84, 16 },
        small = { 150, 90, 16 },
        medium = { 200, 120, 19 },
        large = { 270, 160, 23 },
    },
    hotkey = {
        compact = { 110, 72, 15 },
        small = { 150, 72, 15 },
        medium = { 200, 84, 16 },
        large = { 270, 104, 18 },
    },
    audio = {
        compact = { 240, 124, 15 },
        small = { 280, 124, 15 },
        medium = { 340, 124, 16 },
        large = { 420, 136, 18 },
    },
}
function M.size(kind: string): (number, number, number)
    local s = SIZES[kind][if M.compact() then "compact" else config.get("tile_size")]
    return s[1], s[2], s[3]
end

return M
