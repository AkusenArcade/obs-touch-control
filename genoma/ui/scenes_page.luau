--!strict
-- The scenes. A press puts one on air, or in Studio Mode prepares it.
local g = require("@genoma")
local app = require("core/app")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local tiles = require("ui/tiles")

local M = {}

-- "live", "preview" or "plain".
function M.tone(name: string): string
    if obs.program.value == name then return "live" end
    if obs.studio.value and obs.preview.value == name then return "preview" end
    return "plain"
end
function M.badge(tone: string): string
    return if tone == "live" then "In onda" elseif tone == "preview" then "Anteprima" else ""
end

-- A name and, when there is something to say, a word under it.
function M.words(name: () -> string, badge: () -> string, w: () -> number, ink: (number?) -> string, lines: number?): any
    local function size(): number
        local _, _, s = app.size("scene")
        return s
    end
    return g.box {
        direction = "column",
        align = "center",
        gap = 6,
        g.text {
            text = function() return tiles.fit(name(), w() - 24, size(), 600, lines or 3) end,
            max_width = function() return w() - 24 end,
            wrap = true,
            text_align = "center",
            color = function() return ink() end,
            font = look.expressive,
            size = size,
            weight = 600,
        },
        g.text {
            present = function() return badge() ~= "" end,
            text = function() return string.upper(badge()) end,
            max_width = function() return w() - 24 end,
            color = function() return ink(0.85) end,
            font = look.technical,
            size = look.font_meta,
            weight = 700,
            tracking = 0.1,
        },
    }
end

function M.new(width: () -> number, height: () -> number): any
    return g.box {
        width = width,
        height = height,
        tiles.nothing(width, height, function() return #obs.scenes.value == 0 end, "scenes", function() return "Nessuna scena" end),
        g.box {
            present = function() return #obs.scenes.value > 0 end,
            tiles.scroller(width, height, function(inner: () -> number): any
                return tiles.grid {
                    width = inner,
                    min = function() return (app.size("scene")) end,
                    height = function() return (select(2, app.size("scene"))) end,
                    items = function() return obs.scenes.value end,
                    key = function(name: string) return name end,
                    row = function(item: () -> string, w: () -> number, h: () -> number): any
                        local function tone(): string return M.tone(item()) end
                        return tiles.tile({
                            name = item,
                            w = w,
                            h = h,
                            tone = tone,
                            on_click = function() obs.show(g.untracked(item)) end,
                        }, function(ink)
                            return {
                                g.box {
                                    overlay = true,
                                    attach = "center",
                                    M.words(item, function() return M.badge(tone()) end, w, ink),
                                },
                            }
                        end)
                    end,
                }
            end),
        },
    }
end

return M
