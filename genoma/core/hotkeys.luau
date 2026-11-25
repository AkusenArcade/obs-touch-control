--!strict
-- Readable names and groups for the hotkeys OBS exposes by their internal
-- names: the WebSocket does not give the descriptions OBS shows.
local g = require("@genoma")
local config = require("core/config")
local obs = require("core/obs")

local M = {}

-- Pressed and released at once by the WebSocket, they do nothing useful.
local HELD = { ["libobs.push-to-mute"] = true, ["libobs.push-to-talk"] = true }

local KNOWN: { [string]: string } = {
    ["OBSBasic.StartStreaming"] = "Avvia diretta",
    ["OBSBasic.StopStreaming"] = "Ferma diretta",
    ["OBSBasic.ForceStopStreaming"] = "Forza stop diretta",
    ["OBSBasic.StartRecording"] = "Avvia registrazione",
    ["OBSBasic.StopRecording"] = "Ferma registrazione",
    ["OBSBasic.PauseRecording"] = "Pausa registrazione",
    ["OBSBasic.UnpauseRecording"] = "Riprendi registrazione",
    ["OBSBasic.SplitFile"] = "Dividi file registrazione",
    ["OBSBasic.AddChapterMarker"] = "Aggiungi capitolo",
    ["OBSBasic.StartReplayBuffer"] = "Avvia replay buffer",
    ["OBSBasic.StopReplayBuffer"] = "Ferma replay buffer",
    ["OBSBasic.StartVirtualCam"] = "Avvia camera virtuale",
    ["OBSBasic.StopVirtualCam"] = "Ferma camera virtuale",
    ["OBSBasic.EnablePreview"] = "Abilita anteprima",
    ["OBSBasic.DisablePreview"] = "Disabilita anteprima",
    ["OBSBasic.EnablePreviewProgram"] = "Attiva Studio Mode",
    ["OBSBasic.DisablePreviewProgram"] = "Disattiva Studio Mode",
    ["OBSBasic.ShowContextBar"] = "Mostra barra sorgente",
    ["OBSBasic.HideContextBar"] = "Nascondi barra sorgente",
    ["OBSBasic.Transition"] = "Transizione",
    ["OBSBasic.ResetStats"] = "Azzera statistiche",
    ["OBSBasic.Screenshot"] = "Screenshot",
    ["OBSBasic.SelectedSourceScreenshot"] = "Screenshot sorgente selezionata",
    ["OBSBasic.SelectScene"] = "Passa alla scena",
    ["OBSBasic.QuickTransition"] = "Transizione rapida",
    ["libobs.mute"] = "Silenzia",
    ["libobs.unmute"] = "Riattiva audio",
    ["libobs.push-to-mute"] = "Push-to-mute",
    ["libobs.push-to-talk"] = "Push-to-talk",
    ["ReplayBuffer.Save"] = "Salva replay",
    ["MediaSource.Restart"] = "Riavvia media",
    ["MediaSource.Play"] = "Riproduci media",
    ["MediaSource.Pause"] = "Pausa media",
    ["MediaSource.Stop"] = "Ferma media",
    ["ObsBrowser.Refresh"] = "Aggiorna browser",
}

local function starts(text: string, prefix: string): string?
    return if string.sub(text, 1, #prefix) == prefix then string.sub(text, #prefix + 1) else nil
end

-- "SelectedSourceScreenshot", "push_to_talk" → "Selected source screenshot",
-- "Push to talk". What is all capitals ("OBS", "NDI") stays so.
local function humanize(raw: string): string
    local words: { string } = {}
    local current = ""
    local prev_lower = false
    for c in string.gmatch(raw, utf8.charpattern) do
        local split = c == "_" or c == "-" or c == " "
        local upper = string.match(c, "^%u$") ~= nil
        if (split or (upper and prev_lower)) and current ~= "" then
            table.insert(words, current)
            current = ""
        end
        if not split then current ..= c end
        prev_lower = string.match(c, "^[%l%d]$") ~= nil
    end
    if current ~= "" then table.insert(words, current) end
    for i, w in words do
        if string.match(w, "%l") then
            local first = string.sub(w, 1, 1)
            words[i] = (if i == 1 then string.upper(first) else string.lower(first)) .. string.sub(w, 2)
        end
    end
    return table.concat(words, " ")
end

-- Advanced Scene Switcher's have bare names, without a dot.
local function scene_switcher(name: string): boolean
    return starts(name, "macro_") ~= nil or string.match(name, "SwitcherHotkey$") ~= nil
end

function M.group(name: string): string
    local prefix = string.match(name, "^([^%.]*)%.")
    if prefix == "OBSBasic" then return "OBS" end
    if prefix == "libobs" then return "Sorgenti" end
    if prefix then return humanize(prefix) end
    if scene_switcher(name) then return "Advanced Scene Switcher" end
    if starts(name, "VerticalCanvasDock") then return "Canvas verticale" end
    return "Altro"
end

function M.label(name: string): string
    local known = KNOWN[name]
    if known then return known end
    local rest = starts(name, "macro_condition_hotkey_")
    if rest then return rest end
    for _, p in {
        { "macro_pause_hotkey_", "Pausa macro" },
        { "macro_unpause_hotkey_", "Riprendi macro" },
        { "macro_toggle_pause_hotkey_", "Pausa/riprendi macro" },
    } do
        rest = starts(name, p[1])
        if rest then return `{p[2]} {rest}` end
    end
    rest = starts(name, "VerticalCanvasDock")
    if rest then return "Verticale: " .. string.lower(humanize(rest)) end
    rest = starts(name, "libobs.show_scene_item.")
    if rest then return `Mostra «{rest}»` end
    rest = starts(name, "libobs.hide_scene_item.")
    if rest then return `Nascondi «{rest}»` end
    return humanize(string.match(name, "([^%.]*)$") or name)
end

-- The person's name for it, else its readable one.
function M.title(name: string, context: string?): string
    return config.alias(name, context) or M.label(name)
end

local known_now = g.computed(function(): { [string]: boolean }
    local out = {}
    for _, name in obs.hotkeys.value do out[name] = true end
    return out
end)
function M.exists(name: string): boolean return known_now.value[name] == true end

-- `multi`: OBS has one of it for each source, so it wants to be told which.
export type Entry = { name: string, context: string?, multi: boolean }
export type Section = { key: string, title: string, entries: { Entry } }

-- The favourites, then the groups, OBS's own first, as far as they say `query`.
function M.sections(query: string): { Section }
    local q = string.lower(query)
    local function matches(...: string?): boolean
        if q == "" then return true end
        for i = 1, select("#", ...) do
            local text = select(i, ...)
            if text and string.find(string.lower(text), q, 1, true) then return true end
        end
        return false
    end
    local out: { Section } = {}

    local favourites: { Entry } = {}
    for _, f in config.get("favorites") do
        if matches(M.label(f.name), f.name, f.context, config.alias(f.name, f.context)) then
            table.insert(favourites, { name = f.name, context = f.context, multi = false })
        end
    end
    if #favourites > 0 then table.insert(out, { key = "favourites", title = "Preferiti", entries = favourites }) end

    -- The same name more than once: in the order first seen.
    local counts: { [string]: number } = {}
    local unique: { string } = {}
    for _, name in obs.hotkeys.value do
        if not HELD[name] then
            if counts[name] == nil then table.insert(unique, name) end
            counts[name] = (counts[name] or 0) + 1
        end
    end
    local groups: { [string]: { Entry } } = {}
    local names: { string } = {}
    for _, name in unique do
        if matches(M.label(name), name, config.alias(name)) then
            local group = M.group(name)
            if groups[group] == nil then
                groups[group] = {}
                table.insert(names, group)
            end
            table.insert(groups[group], { name = name, context = nil, multi = counts[name] > 1 })
        end
    end
    table.sort(names, function(a, b)
        if (a == "OBS") ~= (b == "OBS") then return a == "OBS" end
        return a < b
    end)
    for _, group in names do
        table.insert(out, { key = "group:" .. group, title = group, entries = groups[group] })
    end
    return out
end

-- What a hotkey that wants a source can be given.
function M.candidates(name: string): { { title: string, names: { string } } }
    local scenes = { title = "Scene", names = obs.scenes.value }
    if name == "OBSBasic.SelectScene" or starts(name, "libobs.show_scene_item") or starts(name, "libobs.hide_scene_item") then
        return { scenes }
    end
    if name == "libobs.mute" or name == "libobs.unmute" then
        local audio: { string } = {}
        for _, a in obs.audio.value do table.insert(audio, a.name) end
        return { { title = "Sorgenti audio", names = audio } }
    end
    return { { title = "Sorgenti", names = obs.inputs.value }, scenes }
end

return M
