--!strict
-- What OBS sends and writes: the stream, the recording, the virtual camera, the
-- replay buffer, Studio Mode. Their names while there is room, else their drawings
-- alone; what is going on is always said.
local g = require("@genoma")
local config = require("core/config")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local sheet = require("ui/sheet")

local M = {}

local H, PAD, GLYPH, GAP, BETWEEN = look.foot_height, 18, 24, 10, 8

local function clock(seconds: number): string
    return string.format("%02d:%02d:%02d", seconds // 3600, seconds // 60 % 60, seconds % 60)
end

-- `tone()`: "off", "alert" (on air), "held" (paused, reconnecting), "on".
-- `says()`: what is going on, when something is.
type Output = {
    id: string,
    label: string,
    glyph: () -> string,
    tone: () -> string,
    says: () -> string,
    busy: (() -> boolean)?,
    present: (() -> boolean)?,
    disabled: (() -> boolean)?,
    act: (origin: any) -> (),
}

-- Starting is at once; stopping asks first, if it was asked to.
local function guarded(phase: () -> string, origin: any, t: { [string]: any }, toggle: () -> ())
    if g.untracked(function() return obs.active(phase()) end) and config.peek("confirm_stop") then
        sheet.confirm(origin, {
            title = t.title,
            body = t.body,
            accept = t.accept,
            -- Stopped from elsewhere, there is nothing left to ask.
            valid = function() return obs.connected() and obs.active(phase()) end,
            on_accept = toggle,
        })
    else
        toggle()
    end
end

local function busy(phase: string): boolean return phase == "starting" or phase == "stopping" end
local function constant(text: string): () -> string
    return function() return text end
end
local function nothing(): string return "" end
local function on_or_off(s: any): () -> string
    return function() return if obs.active(s.value) then "on" else "off" end
end

local function stream(): string return obs.stream.value end
local function record(): string return obs.record.value end

local list: { Output } = {
    {
        id = "stream",
        label = "Diretta",
        glyph = constant("action-stream"),
        tone = function()
            local p = stream()
            return if p == "off" then "off" elseif p == "reconnecting" then "held" else "alert"
        end,
        says = function()
            local p = stream()
            if p == "starting" then return "Avvio…" end
            if p == "stopping" then return "Arresto…" end
            if p == "reconnecting" then return "Riconnessione…" end
            local t = obs.stream_time.value
            return if p == "on" then (if t then clock(t) else "In onda") else ""
        end,
        busy = function() return busy(stream()) end,
        act = function(origin)
            guarded(stream, origin, { title = "Fermare la diretta?", body = "La trasmissione verrà interrotta.", accept = "Ferma diretta" }, obs.toggle_stream)
        end,
    },
    {
        id = "record",
        label = "Registra",
        glyph = constant("record"),
        tone = function()
            return if record() == "off" then "off" elseif obs.paused.value then "held" else "alert"
        end,
        says = function()
            local p = record()
            if p == "starting" then return "Avvio…" end
            if p == "stopping" then return "Arresto…" end
            if p == "off" then return "" end
            if obs.paused.value then return "In pausa" end
            local t = obs.record_time.value
            return if t then clock(t) else "REC"
        end,
        busy = function() return busy(record()) end,
        act = function(origin)
            guarded(record, origin, { title = "Fermare la registrazione?", body = "Il file verrà chiuso.", accept = "Ferma registrazione" }, obs.toggle_record)
        end,
    },
    {
        id = "pause",
        label = "Pausa",
        glyph = function() return if obs.paused.value then "play" else "pause" end,
        tone = function() return if obs.paused.value then "held" else "off" end,
        says = function() return if obs.paused.value then "Riprendi" else "" end,
        -- Nothing to pause while nothing is recorded.
        present = function() return obs.active(record()) end,
        act = obs.toggle_pause,
    },
    {
        id = "virtual-cam",
        label = "Cam virtuale",
        glyph = constant("camera"),
        tone = on_or_off(obs.virtual_cam),
        says = nothing,
        present = function() return obs.virtual_cam.value ~= nil end,
        act = obs.toggle_virtual_cam,
    },
    {
        id = "replay",
        label = "Replay",
        glyph = constant("replay"),
        tone = on_or_off(obs.replay),
        says = nothing,
        present = function() return obs.replay.value ~= nil end,
        act = obs.toggle_replay,
    },
    {
        id = "save-replay",
        label = "Salva replay",
        glyph = constant("save"),
        tone = constant("off"),
        says = nothing,
        present = function() return obs.active(obs.replay.value) end,
        act = obs.save_replay,
    },
    {
        id = "studio",
        label = "Studio Mode",
        glyph = constant("studio"),
        tone = function() return if obs.studio.value then "on" else "off" end,
        says = nothing,
        act = function() obs.set_studio(not g.untracked(function() return obs.studio.value end)) end,
    },
    {
        id = "transition",
        label = "Transizione",
        glyph = constant("skip-next"),
        tone = constant("off"),
        says = nothing,
        present = function() return obs.studio.value end,
        act = obs.transition,
    },
}

local function word_w(text: string): number
    return math.ceil(g.text_width { text = string.upper(text), font = look.technical(), size = look.font_action, weight = 700, tracking = 0.04 })
end
local function says_w(text: string): number
    if text == "" then return 0 end
    -- A clock is as wide whatever the time.
    local wide = if string.match(text, "^%d") then "00:00:00" else text
    return math.ceil(g.text_width { text = string.upper(wide), font = look.technical(), size = look.font_action, weight = 700, tracking = 0.04, tabular = true }) + 1
end
local function worded_w(o: Output): number
    return PAD * 2 + GLYPH + GAP + math.max(word_w(o.label), says_w(o.says()))
end

local function button(o: Output, bare: () -> boolean): any
    local over, down = g.signal(false), g.signal(false)
    local function width(): number
        if not bare() then return worded_w(o) end
        local said = o.says()
        return if said ~= "" then PAD * 2 + GLYPH + GAP + says_w(said) else H
    end
    local press, origin = ui.place(width, function() return H end)
    local function filled(): boolean return o.tone() == "alert" or o.tone() == "on" end
    local function hue(): string return if o.tone() == "alert" then look.alert() else look.primary() end
    local function ink(strength: number?): string
        if filled() then return g.colour.alpha(look.background(), strength or 1) end
        return g.colour.alpha(if o.tone() == "held" then look.alert() else look.text(), strength or 1)
    end
    local function edge(): string
        if filled() then return look.CLEAR end
        if o.tone() == "held" then return look.alert() end
        return if over.value or down.value then look.primary() else look.node()
    end
    local function under(): string
        if filled() then return look.gradient_bottom(hue()) end
        return if down.value then look.chosen() else look.CLEAR
    end
    return g.capsule {
        id = "output-" .. o.id,
        role = "button",
        name = o.label,
        present = o.present,
        width = width,
        height = H,
        radius = look.round(H / 2),
        clip = true,
        fill = function() return if filled() then look.gradient_top(hue()) else under() end,
        fill_bottom = under,
        rim_top = edge,
        rim_bottom = edge,
        opacity = function() return if o.busy and o.busy() then 0.7 elseif filled() and down.value then 0.8 else 1 end,
        transition = { width = "cell_open", fill = "ui_change", fill_bottom = "ui_change", rim_top = "ui_change", rim_bottom = "ui_change", opacity = "ui_change" },
        on_hover = function(on: boolean)
            over.value = on
            if not on then down.value = false end
        end,
        on_press = function(b: number, x: number, y: number)
            press(x, y)
            down.value = b == ui.LEFT
        end,
        on_release = function() down.value = false end,
        on_click = function(b: number)
            down.value = false
            if b == ui.LEFT then o.act(origin()) end
        end,
        g.box {
            overlay = true,
            attach = "corner",
            offset_x = function() return if bare() and o.says() == "" then (H - GLYPH) / 2 else PAD end,
            height = H,
            direction = "row",
            align = "center",
            gap = GAP,
            transition = { offset_x = "cell_open" },
            ui.glyph(o.glyph, GLYPH, function() return false end, function() return ink() end),
            g.box {
                direction = "column",
                align = "start",
                justify = "center",
                gap = 3,
                g.text {
                    present = function() return not bare() end,
                    text = string.upper(o.label),
                    color = function() return ink() end,
                    font = look.technical,
                    size = look.font_action,
                    weight = function() return if filled() then 700 else 500 end,
                    tracking = 0.04,
                },
                g.text {
                    present = function() return o.says() ~= "" end,
                    text = function() return string.upper(o.says()) end,
                    color = function() return ink(if bare() then 1 else 0.8) end,
                    font = look.technical,
                    size = look.font_action,
                    weight = 700,
                    tracking = 0.04,
                    tabular = true,
                },
            },
        },
    }
end

-- `width()`: the room. `on_height(h)`: how tall it came out.
function M.new(width: () -> number, on_height: (number) -> ()): any
    local bare = g.computed(function(): boolean
        local total = -BETWEEN
        for _, o in list do
            if o.present == nil or o.present() then total += worded_w(o) + BETWEEN end
        end
        return total > width()
    end)
    local node: { [any]: any } = {
        width = width,
        direction = "row",
        align = "center",
        flow = true,
        gap = BETWEEN,
        gap_lines = BETWEEN,
        on_size = function(_: number, h: number) on_height(h) end,
    }
    for _, o in list do table.insert(node, button(o, function() return bare.value end)) end
    return g.box(node)
end

return M
