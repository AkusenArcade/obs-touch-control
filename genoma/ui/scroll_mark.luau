--!strict
-- What a list longer than its room says (Bioma's components/scroller): its
-- foot fades while there is more below, and a mark down its side shows while
-- it moves. At rest, nothing else.
local g = require("@genoma")
local look = require("ui/look")

local M = {}

local FADE, WIDTH, REST = 28, 3, 0.5

-- `t`: height() the view's, x() where the mark stands, room() how far it can
-- be scrolled (what follow() was last told, when not given). Gives `follow(offset,
-- room)` for the scroller's on_scroll, `fade()` for its fade_bottom, `offset()`
-- and `mark`, to place beside it.
function M.new(t: { [string]: any }): any
    local at = g.signal({ offset = 0, room = 0 })
    local moving = g.signal(false)
    local rest: any = nil
    local function follow(offset: number, room: number)
        local before = g.untracked(function() return at.value end)
        at.value = { offset = offset, room = room }
        if before.offset == offset then return end
        moving.value = true
        if rest then rest:stop() end
        rest = g.after(REST, function() moving.value = false end)
    end
    local function room(): number return if t.room then t.room() else at.value.room end
    local function length(): number
        local h = t.height()
        return math.max(WIDTH * 4, h * h / math.max(1, h + room()))
    end
    return {
        follow = follow,
        offset = function(): number return at.value.offset end,
        fade = function(): number return if room() - at.value.offset > 0.5 then FADE else 0 end,
        mark = g.capsule {
            overlay = true,
            attach = "corner",
            present = function() return room() > 0.5 end,
            offset_x = t.x,
            offset_y = function()
                local r = room()
                local along = if r > 0 then math.clamp(at.value.offset / r, 0, 1) else 0
                return along * (t.height() - length())
            end,
            width = WIDTH,
            height = length,
            radius = WIDTH / 2,
            fill = look.line,
            rim_top = look.CLEAR,
            rim_bottom = look.CLEAR,
            opacity = function() return if moving.value then 1 else 0 end,
            transition = { opacity = "page_in" },
        },
    }
end

return M
