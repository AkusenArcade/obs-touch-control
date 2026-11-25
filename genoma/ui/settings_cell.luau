--!strict
-- How it reaches OBS and how it behaves: the cell that grows from the corner. Its
-- button's drawing is lit while OBS is reached.
local g = require("@genoma")
local app = require("core/app")
local config = require("core/config")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local corner_cell = require("ui/corner_cell")

local M = {}

M.open = g.signal(false)

local PAD, LABEL_W, WIDTH = 22, 190, 500

local host = g.signal("")
local port = g.signal("")
local password = g.signal("")

-- What is written is taken from what is kept, each time it opens.
g.watch(function() return M.open.value end, function(on: boolean)
    if not on then
        if string.match(app.field.value, "^setting:") then app.field.value = "" end
        return
    end
    g.batch(function()
        host.value = config.peek("host")
        port.value = tostring(config.peek("port"))
        password.value = config.peek("password")
    end)
end)

function M.connect()
    local p = tonumber(g.untracked(function() return port.value end))
    local h = string.match(g.untracked(function() return host.value end), "^%s*(.-)%s*$") or ""
    if g.untracked(function() return M.open.value end) then
        config.change {
            host = if h ~= "" then h else config.peek("host"),
            port = if p and p >= 1 and p <= 65535 then math.floor(p) else config.peek("port"),
            password = g.untracked(function() return password.value end),
        }
    end
    obs.connect { host = config.peek("host"), port = config.peek("port"), password = config.peek("password") }
    M.open.value = false
end

-- As wide as the window lets it be.
local function cell_w(): number return math.min(WIDTH, app.area.value.w - look.margin_edge * 2) end
local function label_w(): number return math.min(LABEL_W, math.floor((cell_w() - PAD * 2) * 0.36)) end
local function field_w(): number return cell_w() - PAD * 2 - label_w() - 12 end

local function row(name: string, control: any, present: (() -> boolean)?): any
    return g.box {
        present = present,
        direction = "row",
        align = "center",
        gap = 12,
        height = look.touch,
        g.box { width = label_w, ui.says(name, label_w, look.text, { size = look.font_text }) },
        control,
    }
end

local function toggle(name: string, key: string): any
    return row(name, ui.switch {
        id = "switch-" .. key,
        name = name,
        on = function() return config.get(key) end,
        on_toggle = function(on: boolean) config.set(key, on) end,
    })
end

local function rule(): any
    return g.capsule {
        height = 1,
        crisp = true,
        radius = 0,
        fill = function() return g.colour.alpha(look.line(), 0.6) end,
        rim_top = look.CLEAR,
        rim_bottom = look.CLEAR,
    }
end

local ORDER = { "setting:host", "setting:port", "setting:password" }
-- Tab goes on to the next one.
function M.next_field(back: boolean)
    local at = table.find(ORDER, g.untracked(function() return app.field.value end))
    if at == nil then return end
    app.field.value = ORDER[(at - 1 + (if back then -1 else 1)) % #ORDER + 1]
end
function M.owns(field: string): boolean return table.find(ORDER, field) ~= nil end

function M.new(): any
    local function area(): any return app.area.value end
    local content = g.box {
        direction = "column",
        align = "stretch",
        gap = 10,
        padding = PAD,
        g.box {
            direction = "row",
            align = "center",
            justify = "between",
            height = 28,
            ui.label("Connessione a OBS", look.text_muted, look.font_action),
            ui.label(function()
                local s = obs.state.value
                return if s == "connected" then "OBS " .. obs.version.value elseif s == "connecting" then "Connessione…" else "Non connesso"
            end, function() return if obs.connected() then look.primary() else look.text_faint() end),
        },
        row("Indirizzo", ui.field {
            id = "host",
            key = "setting:host",
            width = field_w,
            text = function() return host.value end,
            on_change = function(t: string) host.value = t end,
            on_submit = M.connect,
        }),
        row("Porta", ui.field {
            id = "port",
            key = "setting:port",
            width = field_w,
            text = function() return port.value end,
            on_change = function(t: string) port.value = string.gsub(t, "%D", "") end,
            on_submit = M.connect,
        }),
        row("Password", ui.field {
            id = "password",
            key = "setting:password",
            width = field_w,
            secret = true,
            text = function() return password.value end,
            on_change = function(t: string) password.value = t end,
            on_submit = M.connect,
        }),
        ui.says("In OBS: Strumenti → Impostazioni server WebSocket → Mostra informazioni di connessione.", function() return cell_w() - PAD * 2 end, look.text_faint, { size = look.font_secondary }),
        g.box {
            direction = "row",
            align = "center",
            justify = "end",
            gap = 10,
            ui.action {
                id = "disconnect",
                label = "Disconnetti",
                present = function() return obs.state.value ~= "off" or obs.retrying.value end,
                on_click = function()
                    obs.disconnect()
                    M.open.value = false
                end,
            },
            ui.action { id = "connect", label = "Salva e connetti", kind = "filled", on_click = M.connect },
        },
        rule(),
        g.box { height = 4 },
        row("Riquadri", ui.segmented {
            id = "tiles",
            options = { { key = "small", label = "Piccoli" }, { key = "medium", label = "Medi" }, { key = "large", label = "Grandi" } },
            current = function() return config.get("tile_size") end,
            on_choose = function(key: string) config.set("tile_size", key) end,
        }),
        toggle("Connetti all'avvio", "auto_connect"),
        toggle("Avvia a schermo intero", "start_fullscreen"),
        toggle("Conferma prima di fermare", "confirm_stop"),
        rule(),
        g.box {
            direction = "row",
            align = "center",
            justify = "end",
            gap = 10,
            padding_y = 4,
            ui.action {
                id = "refresh",
                label = "Aggiorna",
                glyph = "restart",
                present = obs.connected,
                on_click = function()
                    obs.refresh()
                    M.open.value = false
                end,
            },
            ui.action {
                id = "fullscreen",
                label = "Schermo intero",
                glyph = "fullscreen",
                lit = function() return app.fullscreen.value end,
                on_click = function() app.fullscreen.value = not g.untracked(function() return app.fullscreen.value end) end,
            },
        },
    }
    return corner_cell.new {
        id = "settings",
        name = "Impostazioni",
        area = area,
        x = function() return area().w - look.margin_edge - corner_cell.BUTTON end,
        open = M.open,
        width = WIDTH,
        outside = true,
        content = content,
        button = function(bx: () -> number, by: () -> number): any
            return ui.round {
                id = "settings-button",
                name = "Impostazioni",
                glyph = "obs-touch-control",
                glyph_lit = obs.connected,
                lit = function() return M.open.value end,
                on_click = function() M.open.value = not g.untracked(function() return M.open.value end) end,
                props = {
                    overlay = true,
                    attach = "corner",
                    offset_x = bx,
                    offset_y = by,
                    backdrop_blur = look.glass_blur,
                },
            }
        end,
    }
end

return M
