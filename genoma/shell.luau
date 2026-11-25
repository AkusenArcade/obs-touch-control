--!strict
-- OBS Touch Control on Genoma: OBS Studio driven from a touch screen through its
-- WebSocket (protocol v5, OBS 30.2 and later). The GTK version's pages and
-- settings, in Bioma's look (docs/genoma-port-plan.md).
--
--   genoma genoma/                          (GENOMA_IPC=obs-touch-control)
--   genoma ipc obs-touch-control page scenes
local g = require("@genoma")
local app = require("core/app")
local config = require("core/config")
local notice = require("core/notice")
local obs = require("core/obs")
local look = require("ui/look")
local ui = require("ui/controls")
local audio_page = require("ui/audio_page")
local hotkeys_page = require("ui/hotkeys_page")
local outputs = require("ui/outputs")
local panel_page = require("ui/panel_page")
local scenes_page = require("ui/scenes_page")
local settings_cell = require("ui/settings_cell")
local sheet = require("ui/sheet")

obs.failed = notice.say
config.failed = function(why: string) notice.say("Impossibile salvare la configurazione: " .. why) end

local E, GAP, H = look.margin_edge, look.gap, look.touch

local function area(): any return app.area.value end

-- ---- Above: the pages, and what the one shown does ------------------------------------

local PAGES = {
    { key = "panel", label = "Pannello", glyph = "grid" },
    { key = "scenes", label = "Scene", glyph = "scenes" },
    { key = "hotkeys", label = "Scorciatoie", glyph = "keyboard" },
    { key = "audio", label = "Audio", glyph = "volume" },
}
local function bare_pages(): boolean return area().w < 720 end
local SEARCH = 280
local function search_w(): number
    return math.min(SEARCH, area().w - E * 2 - (if bare_pages() then 4 * 54 + 14 else 520) - GAP)
end

local top = g.box {
    overlay = true,
    attach = "corner",
    offset_x = E,
    offset_y = E,
    width = function() return area().w - E * 2 end,
    height = H,
    direction = "row",
    align = "center",
    justify = "between",
    ui.segmented {
        id = "page",
        options = PAGES,
        current = function() return app.page.value end,
        on_choose = function(key: string)
            app.page.value = key
            app.field.value = ""
        end,
        bare = bare_pages,
        size = look.font_action,
    },
    g.box {
        direction = "row",
        align = "center",
        gap = 8,
        ui.action {
            id = "edit",
            label = function() return if app.editing.value then "Fine" else "Modifica" end,
            present = function() return app.page.value == "panel" and (#config.get("panel") > 0 or app.editing.value) end,
            lit = function() return app.editing.value end,
            on_click = function() app.editing.value = not g.untracked(function() return app.editing.value end) end,
        },
        ui.field {
            id = "search",
            key = "search",
            present = function() return app.page.value == "hotkeys" end,
            width = search_w,
            glyph = "search",
            placeholder = "Cerca scorciatoia",
            text = function() return app.search.value end,
            on_change = function(text: string) app.search.value = text end,
            on_clear = function() app.search.value = "" end,
        },
    },
}

-- ---- Below: the outputs, and the settings' corner --------------------------------------

local foot_h = g.signal(look.foot_height)
local function foot_w(): number return area().w - E * 2 - look.foot_height - GAP end
local foot = g.box {
    overlay = true,
    attach = "corner",
    present = obs.connected,
    offset_x = E,
    offset_y = function() return area().h - E - foot_h.value end,
    outputs.new(foot_w, function(h: number) foot_h.value = math.max(look.foot_height, h) end),
}

-- ---- The page -------------------------------------------------------------------------

local function page_y(): number return E + H + GAP end
local function page_w(): number return area().w - E * 2 end
local function page_h(): number return math.max(80, area().h - page_y() - E - foot_h.value - GAP) end

local BUILDERS: { [string]: any } = {
    panel = panel_page.new,
    scenes = scenes_page.new,
    hotkeys = hotkeys_page.new,
    audio = audio_page.new,
}
local pages: { [any]: any } = {
    overlay = true,
    attach = "corner",
    present = obs.connected,
    offset_x = E,
    offset_y = page_y,
    width = page_w,
    height = page_h,
}
for _, p in PAGES do
    local function shown(): boolean return app.page.value == p.key end
    table.insert(pages, g.box {
        overlay = true,
        attach = "corner",
        present = shown,
        opacity = function() return if shown() then 1 else 0 end,
        transition = { opacity = "page_in" },
        BUILDERS[p.key](page_w, page_h),
    })
end
local content = g.box(pages)

-- ---- Not connected ----------------------------------------------------------------------

local offline = g.box {
    overlay = true,
    attach = "corner",
    present = function() return not obs.connected() end,
    width = function() return area().w end,
    height = function() return area().h end,
    direction = "column",
    align = "center",
    justify = "center",
    gap = 18,
    ui.glyph("offline", 56, function() return obs.state.value == "connecting" end, look.text_faint),
    g.text {
        text = function() return if obs.state.value == "connecting" then "Connessione a OBS…" else "Non connesso a OBS" end,
        color = look.text,
        font = look.expressive,
        size = 24,
        weight = 600,
    },
    g.text {
        text = function(): string
            local why = obs.reason.value
            if why == nil then return "In OBS abilita Strumenti → Impostazioni server WebSocket, poi connettiti." end
            return if obs.retrying.value or obs.state.value == "connecting" then why .. "\nNuovo tentativo automatico in corso…" else why
        end,
        max_width = function() return math.min(460, area().w - 48) end,
        wrap = true,
        text_align = "center",
        color = look.text_muted,
        font = look.expressive,
        size = look.font_label,
    },
    g.box { height = 6 },
    g.box {
        direction = "row",
        align = "center",
        gap = 10,
        ui.action {
            id = "offline-settings",
            label = "Impostazioni",
            on_click = function() settings_cell.open.value = true end,
        },
        ui.action {
            id = "offline-connect",
            label = "Connetti",
            kind = "filled",
            disabled = function() return obs.state.value == "connecting" end,
            on_click = settings_cell.connect,
        },
    },
}

-- ---- What has to be said once ------------------------------------------------------------

local said = g.capsule {
    overlay = true,
    attach = "corner",
    present = function() return notice.now.value ~= "" end,
    offset_x = function() return (area().w - math.min(560, area().w - E * 2)) / 2 end,
    offset_y = function() return area().h - E - foot_h.value - GAP - H end,
    width = function() return math.min(560, area().w - E * 2) end,
    height = H,
    radius = look.round(H / 2),
    padding_x = 20,
    direction = "row",
    align = "center",
    justify = "center",
    fill = look.glass_over,
    rim_top = look.rim,
    rim_bottom = look.line,
    backdrop_blur = look.glass_blur,
    on_press = function() end,
    on_click = function() notice.now.value = "" end,
    g.text {
        text = function() return notice.now.value end,
        max_width = function() return math.min(560, area().w - E * 2) - 40 end,
        ellipsize = "end",
        color = look.text,
        font = look.expressive,
        size = look.font_label,
    },
}

-- ---- Keys ------------------------------------------------------------------------------------

local function key(name: string, _: string?, mods: any)
    if mods.logo then return end
    if name == "F11" then
        app.fullscreen.value = not g.untracked(function() return app.fullscreen.value end)
    elseif name == "F5" then
        if g.untracked(obs.connected) then obs.refresh() end
    elseif name == "Escape" then
        if g.untracked(sheet.is_open) then sheet.close()
        elseif g.untracked(function() return settings_cell.open.value end) then settings_cell.open.value = false
        elseif g.untracked(function() return app.field.value end) ~= "" then app.field.value = ""
        elseif g.untracked(function() return app.editing.value end) then app.editing.value = false
        elseif g.untracked(function() return app.page.value == "hotkeys" and app.search.value ~= "" end) then app.search.value = ""
        elseif g.untracked(function() return app.fullscreen.value end) then app.fullscreen.value = false
        end
    elseif name == "Tab" or name == "ISO_Left_Tab" then
        settings_cell.next_field(name == "ISO_Left_Tab" or mods.shift)
    elseif mods.ctrl and string.lower(name) == "f" and g.untracked(obs.connected) then
        app.page.value = "hotkeys"
        app.field.value = "search"
    elseif mods.ctrl and name >= "1" and name <= "4" and #name == 1 and g.untracked(obs.connected) then
        app.page.value = PAGES[tonumber(name) :: number].key
    end
end

-- ---- From outside ----------------------------------------------------------------------------

g.ipc("obs-touch-control", {
    page = function(name: string): string
        app.page.value = name
        return "ok"
    end,
    state = function(): string
        return g.untracked(function() return `{obs.state.value} {obs.reason.value or ""}` end)
    end,
    connect = function(): string settings_cell.connect() return "ok" end,
    disconnect = function(): string obs.disconnect() return "ok" end,
    settings = function(): string
        settings_cell.open.value = not g.untracked(function() return settings_cell.open.value end)
        return "ok"
    end,
    edit = function(): string
        app.editing.value = not g.untracked(function() return app.editing.value end)
        return "ok"
    end,
    search = function(...: string): string
        app.search.value = table.concat({ ... }, " ")
        return "ok"
    end,
    fullscreen = function(): string
        app.fullscreen.value = not g.untracked(function() return app.fullscreen.value end)
        return "ok"
    end,
    -- What a hotkey keybinding of the compositor's may want.
    scene = function(...: string): string obs.show(table.concat({ ... }, " ")) return "ok" end,
    hotkey = function(name: string, ...: string): string
        local context = table.concat({ ... }, " ")
        obs.press(name, if context ~= "" then context else nil)
        return "ok"
    end,
    stream = function(): string obs.toggle_stream() return "ok" end,
    record = function(): string obs.toggle_record() return "ok" end,
    mute = function(...: string): string obs.toggle_mute(table.concat({ ... }, " ")) return "ok" end,
    key = function(name: string, mod: string?): string
        key(name, nil, { ctrl = mod == "ctrl", shift = mod == "shift", alt = mod == "alt", logo = false })
        return "ok"
    end,
})

-- ---- The window --------------------------------------------------------------------------------

local window = g.window {
    title = "OBS Touch Control",
    app_id = "io.github.akusen.ObsTouchControl",
    width = 1100,
    height = 760,
    min = { 360, 400 },
    fullscreen = function() return app.fullscreen.value end,
    on_fullscreen = function(on: boolean) app.fullscreen.value = on end,
    g.capsule {
        grow = 1,
        radius = 0,
        blur = true,
        -- Opaque: how much of the desktop shows through a window is the
        -- compositor's to say.
        fill = look.background,
        rim_top = look.CLEAR,
        rim_bottom = look.CLEAR,
        catch = true,
        on_key = key,
        on_press = function() app.field.value = "" end,
        on_size = function(w: number, h: number) app.area.value = { w = w, h = h } end,
        offline,
        content,
        g.box {
            overlay = true,
            attach = "corner",
            present = obs.connected,
            top,
        },
        foot,
        said,
        settings_cell.new(),
        sheet.new(),
    },
}

-- Out of the page it was on, it is not being put together any more.
g.watch(function() return app.page.value end, function() app.editing.value = false end)

if config.peek("auto_connect") then
    settings_cell.connect()
else
    g.after(0.3, function() settings_cell.open.value = true end)
end

return window
