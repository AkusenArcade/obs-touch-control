--!strict
-- What has to be said once: an error of OBS's, a button added.
local g = require("@genoma")

local M = {}

local STAYS = 4

M.now = g.signal("")
local quiet: any = nil
function M.say(text: string)
    if quiet then quiet:stop() end
    M.now.value = text
    quiet = g.after(STAYS, function()
        quiet = nil
        M.now.value = ""
    end)
end

return M
