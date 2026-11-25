--!strict
-- OBS, spoken to over its WebSocket (protocol v5): what it is doing, as signals,
-- and what can be asked of it. The connection is kept, or tried again, as long
-- as it is wanted.
local g = require("@genoma")

local M = {}

local RETRY = 3
-- From opening the socket to being let in.
local PATIENCE = 10
-- What is asked while OBS is loading a collection is refused; asked again.
local NOT_READY, NOT_READY_WAIT = 207, 1
local AUTH_FAILED = 4009
-- The faders' floor: there and below it is silence.
M.MIN_DB = -60

-- General, Config, Scenes, Inputs, Outputs, Ui.
local EVENTS = 1 + 2 + 4 + 8 + 64 + 1024

export type Phase = "off" | "starting" | "on" | "stopping" | "reconnecting"
export type Audio = { name: string, muted: any, db: any, held: boolean, sending: boolean, next: number? }

-- "off", "connecting" or "connected".
M.state = g.signal("off")
-- Why there is no connection, when there is a reason; whether it will be tried
-- again by itself.
M.reason = g.signal(nil :: string?)
M.retrying = g.signal(false)
M.version = g.signal("")

M.scenes = g.signal({} :: { string })
M.program = g.signal(nil :: string?)
M.preview = g.signal(nil :: string?)
M.studio = g.signal(false)
M.stream = g.signal("off")
M.record = g.signal("off")
M.paused = g.signal(false)
-- nil: OBS has none (not installed, not enabled).
M.virtual_cam = g.signal(nil :: string?)
M.replay = g.signal(nil :: string?)
-- Seconds, while they are active.
M.stream_time = g.signal(nil :: number?)
M.record_time = g.signal(nil :: number?)
M.hotkeys = g.signal({} :: { string })
M.inputs = g.signal({} :: { string })
M.audio = g.signal({} :: { Audio })

-- What OBS refused, told by who can say it.
M.failed = function(_: string) end

function M.connected(): boolean return M.state.value == "connected" end
function M.active(phase: string?): boolean
    return phase == "on" or phase == "reconnecting" or phase == "stopping"
end

local function peek(s: any): any
    return g.untracked(function() return s.value end)
end

-- ---- The wire ---------------------------------------------------------------------

type Params = { host: string, port: number, password: string }

local params: Params? = nil
local socket: any = nil
-- Every connection has a number: what an earlier one still says is not heard.
local epoch = 0
local let_in = false
local pending: { [string]: (any) -> () } = {}
local asked = 0
local retry: any, patience: any = nil, nil

local open: () -> ()

local function send(op: number, d: any)
    if socket and socket.state == "open" then socket:send(g.to_json { op = op, d = d }) end
end

local function stop(timer: any): any
    if timer then timer:stop() end
    return nil
end

local function lost(reason: string?, again: boolean)
    epoch += 1
    let_in = false
    pending = {}
    patience = stop(patience)
    retry = stop(retry)
    if socket and socket.state ~= "closed" then
        local s = socket
        pcall(function() s:close() end)
    end
    socket = nil
    for _, a in peek(M.audio) do
        a.sending = false
        a.next = nil
    end
    again = again and params ~= nil
    g.batch(function()
        M.state.value = "off"
        M.reason.value = reason
        M.retrying.value = again
        M.stream_time.value = nil
        M.record_time.value = nil
    end)
    if again then
        retry = g.after(RETRY, function()
            retry = nil
            open()
        end)
    end
end

local function why(status: any): string
    local comment, code = status.comment, status.code
    return if comment then `{comment} ({code})` else `Errore OBS: {code}`
end

-- `done(data)` with what OBS answers; what it refuses goes to `refused`, or is
-- said.
local function ask(kind: string, data: any?, done: ((any) -> ())?, refused: ((any) -> ())?)
    if not let_in then return end
    asked += 1
    local id = tostring(asked)
    pending[id] = function(d: any)
        local status = d.requestStatus
        if status and status.result then
            if done then done(d.responseData or {}) end
        elseif refused then
            refused(status or {})
        else
            M.failed(why(status or {}))
        end
    end
    send(6, { requestType = kind, requestId = id, requestData = data })
end

-- Several at once; `done(results)`, in their order, nil where refused, and the
-- statuses.
local function ask_all(requests: { { kind: string, data: any? } }, done: ({ [number]: any }, { any }) -> ())
    if not let_in then return end
    if #requests == 0 then
        done({}, {})
        return
    end
    asked += 1
    local id = tostring(asked)
    pending[id] = function(d: any)
        local out: { [number]: any }, statuses: { any } = {}, {}
        for i = 1, #requests do
            local r = d.results and d.results[i]
            local status = r and r.requestStatus or {}
            statuses[i] = status
            if status.result then out[i] = r.responseData or {} end
        end
        done(out, statuses)
    end
    local list = {}
    for _, r in requests do table.insert(list, { requestType = r.kind, requestData = r.data }) end
    send(8, { requestId = id, haltOnFailure = false, requests = list })
end

-- ---- What it is doing ---------------------------------------------------------------

local function from_active(on: any): string return if on then "on" else "off" end
local STATES: { [string]: string } = {
    OBS_WEBSOCKET_OUTPUT_STARTING = "starting",
    OBS_WEBSOCKET_OUTPUT_STOPPING = "stopping",
    OBS_WEBSOCKET_OUTPUT_STOPPED = "off",
    OBS_WEBSOCKET_OUTPUT_RECONNECTING = "reconnecting",
}
local function from_state(state: any): string return STATES[state] or "on" end

-- As OBS shows them: the WebSocket's order is upside down.
local function take_scenes(d: any)
    local list = table.clone(d.scenes or {})
    table.sort(list, function(a, b) return (a.sceneIndex or 0) > (b.sceneIndex or 0) end)
    local names = {}
    for _, s in list do table.insert(names, s.sceneName) end
    M.scenes.value = names
    M.program.value = d.currentProgramSceneName
    M.preview.value = d.currentPreviewSceneName
end

local function floor_db(db: number?, mul: number?): number
    -- Silence is -inf, which JSON does not have.
    if type(db) ~= "number" then
        db = if type(mul) == "number" and mul > 0 then 20 * math.log10(mul) else M.MIN_DB
    end
    return math.max(M.MIN_DB, db :: number)
end

local function audio_of(name: string): Audio?
    for _, a in peek(M.audio) do
        if a.name == name then return a end
    end
    return nil
end

-- The inputs, and which of them have a sound: those that can be muted.
local function take_inputs(d: any)
    local names, requests = {}, {}
    for _, i in d.inputs or {} do
        table.insert(names, i.inputName)
        table.insert(requests, { kind = "GetInputMute", data = { inputName = i.inputName } })
        table.insert(requests, { kind = "GetInputVolume", data = { inputName = i.inputName } })
    end
    M.inputs.value = names
    ask_all(requests, function(results)
        local list: { Audio } = {}
        g.batch(function()
            for i, name in names do
                local mute, volume = results[i * 2 - 1], results[i * 2]
                if mute then
                    local a: Audio = audio_of(name) or { name = name, muted = g.signal(false), db = g.signal(0), held = false, sending = false, next = nil }
                    a.muted.value = mute.inputMuted == true
                    if volume and not a.held then a.db.value = floor_db(volume.inputVolumeDb, volume.inputVolumeMul) end
                    table.insert(list, a)
                end
            end
            M.audio.value = list
        end)
    end)
end

local function take_hotkeys(d: any) M.hotkeys.value = d.hotkeys or {} end

local function refresh()
    local now = epoch
    ask_all({
        { kind = "GetVersion" },
        { kind = "GetSceneList" },
        { kind = "GetStudioModeEnabled" },
        { kind = "GetStreamStatus" },
        { kind = "GetRecordStatus" },
        -- These two may be refused: OBS has none.
        { kind = "GetVirtualCamStatus" },
        { kind = "GetReplayBufferStatus" },
        { kind = "GetHotkeyList" },
        { kind = "GetInputList" },
    }, function(r, statuses)
        for _, i in { 1, 2, 3, 4, 5, 8, 9 } do
            if r[i] == nil then
                if statuses[i].code == NOT_READY then
                    patience = stop(patience)
                    g.after(NOT_READY_WAIT, function() if epoch == now then refresh() end end)
                else
                    M.failed(why(statuses[i]))
                    if peek(M.state) ~= "connected" then lost(why(statuses[i]), true) end
                end
                return
            end
        end
        patience = stop(patience)
        g.batch(function()
            M.version.value = r[1].obsVersion or ""
            take_scenes(r[2])
            M.studio.value = r[3].studioModeEnabled == true
            M.stream.value = if r[4].outputReconnecting then "reconnecting" else from_active(r[4].outputActive)
            M.record.value = from_active(r[5].outputActive)
            M.paused.value = r[5].outputPaused == true
            M.virtual_cam.value = if r[6] then from_active(r[6].outputActive) else nil
            M.replay.value = if r[7] then from_active(r[7].outputActive) else nil
            take_hotkeys(r[8])
            M.state.value = "connected"
            M.reason.value = nil
            M.retrying.value = false
        end)
        take_inputs(r[9])
    end)
end

-- ---- What it says -------------------------------------------------------------------

local function scenes_changed()
    ask("GetSceneList", nil, function(d) g.batch(function() take_scenes(d) end) end)
    ask("GetHotkeyList", nil, take_hotkeys)
end
local function inputs_changed()
    ask("GetInputList", nil, function(d) g.batch(function() take_inputs(d) end) end)
    ask("GetHotkeyList", nil, take_hotkeys)
end
-- Several of these come together.
local told: { [any]: boolean } = {}
local function soon(f: () -> ())
    if told[f] then return end
    told[f] = true
    local now = epoch
    g.after(0.05, function()
        told[f] = nil
        if epoch == now then f() end
    end)
end

local HEARD: { [string]: (any) -> () } = {
    CurrentProgramSceneChanged = function(d) M.program.value = d.sceneName end,
    CurrentPreviewSceneChanged = function(d) M.preview.value = d.sceneName end,
    SceneListChanged = function() soon(scenes_changed) end,
    SceneCreated = function() soon(scenes_changed) end,
    SceneRemoved = function() soon(scenes_changed) end,
    SceneNameChanged = function() soon(scenes_changed) end,
    StudioModeStateChanged = function(d)
        local on = d.studioModeEnabled == true
        M.studio.value = on
        if not on then
            M.preview.value = nil
            return
        end
        ask("GetCurrentPreviewScene", nil, function(p)
            M.preview.value = p.sceneName or p.currentPreviewSceneName
        end, function() end)
    end,
    StreamStateChanged = function(d) M.stream.value = from_state(d.outputState) end,
    RecordStateChanged = function(d)
        M.paused.value = d.outputState == "OBS_WEBSOCKET_OUTPUT_PAUSED"
        M.record.value = from_state(d.outputState)
    end,
    VirtualcamStateChanged = function(d) M.virtual_cam.value = from_state(d.outputState) end,
    ReplayBufferStateChanged = function(d) M.replay.value = from_state(d.outputState) end,
    InputMuteStateChanged = function(d)
        local a = audio_of(d.inputName)
        if a then a.muted.value = d.inputMuted == true end
    end,
    InputVolumeChanged = function(d)
        local a = audio_of(d.inputName)
        -- The echo of one's own hand would pull the fader back.
        if a and not a.held and not a.sending then a.db.value = floor_db(d.inputVolumeDb, d.inputVolumeMul) end
    end,
    InputCreated = function() soon(inputs_changed) end,
    InputRemoved = function() soon(inputs_changed) end,
    InputNameChanged = function() soon(inputs_changed) end,
    CurrentSceneCollectionChanged = function() refresh() end,
    CurrentProfileChanged = function() refresh() end,
    ExitStarted = function() lost("OBS ha chiuso la connessione", true) end,
}

-- ---- Coming in ------------------------------------------------------------------------

local function secret(password: string, auth: any): string
    local key = g.base64.encode(g.sha256(password .. auth.salt))
    return g.base64.encode(g.sha256(key .. auth.challenge))
end

local function hear(text: string)
    local ok, message = pcall(g.parse_json, text)
    if not ok or type(message) ~= "table" then return end
    local op, d = message.op, message.d or {}
    if op == 0 then
        local auth = d.authentication
        send(1, {
            rpcVersion = 1,
            eventSubscriptions = EVENTS,
            authentication = if auth and params then secret(params.password, auth) else nil,
        })
    elseif op == 2 then
        let_in = true
        refresh()
    elseif op == 5 then
        local f = HEARD[d.eventType]
        if f then g.batch(function() f(d.eventData or {}) end) end
    elseif op == 7 or op == 9 then
        local f = pending[d.requestId]
        if f then
            pending[d.requestId] = nil
            f(d)
        end
    end
end

function open()
    local p = params
    if p == nil then return end
    retry = stop(retry)
    epoch += 1
    local now = epoch
    g.batch(function()
        M.state.value = "connecting"
        M.retrying.value = false
    end)
    local host = if string.find(p.host, ":", 1, true) and string.sub(p.host, 1, 1) ~= "[" then `[{p.host}]` else p.host
    local ok, opened = pcall(function()
        return g.websocket {
            url = `ws://{host}:{p.port}`,
            on_message = function(data: string, binary: boolean)
                if epoch == now and not binary then hear(data) end
            end,
            on_close = function(code: number, reason: string)
                if epoch ~= now then return end
                if code == AUTH_FAILED then
                    -- The same password would be refused again.
                    lost("Autenticazione fallita: controlla la password", false)
                elseif peek(M.state) == "connected" then
                    lost("OBS ha chiuso la connessione", true)
                elseif code == 1006 then
                    lost("Impossibile connettersi: OBS è aperto e il server WebSocket è attivo?", true)
                else
                    lost(if reason ~= "" then reason else `Connessione chiusa ({code})`, true)
                end
            end,
        }
    end)
    if not ok then
        lost("Indirizzo non valido", false)
        return
    end
    socket = opened
    patience = stop(patience)
    patience = g.after(PATIENCE, function()
        patience = nil
        if epoch == now then lost("Timeout: OBS non risponde", true) end
    end)
end

function M.connect(p: Params)
    lost(nil, false)
    params = p
    open()
end

function M.disconnect()
    params = nil
    lost(nil, false)
end

-- ---- How long -------------------------------------------------------------------------

-- Asked once a second, and only while something is being sent or written.
local ticking: any = nil
local function measure()
    local requests, which = {}, {}
    if M.active(peek(M.stream)) then
        table.insert(requests, { kind = "GetStreamStatus" })
        table.insert(which, M.stream_time)
    end
    if M.active(peek(M.record)) then
        table.insert(requests, { kind = "GetRecordStatus" })
        table.insert(which, M.record_time)
    end
    ask_all(requests, function(results)
        g.batch(function()
            for i, s in which do
                local r = results[i]
                s.value = if r and type(r.outputDuration) == "number" then math.floor(r.outputDuration / 1000) else nil
            end
        end)
    end)
end
g.watch(function(): boolean
    return M.connected() and (M.active(M.stream.value) or M.active(M.record.value))
end, function(on: boolean)
    ticking = stop(ticking)
    if on then
        measure()
        ticking = g.timer { every = 1, on_tick = measure }
    end
end)
g.watch(function() return M.active(M.stream.value) end, function(on: boolean) if not on then M.stream_time.value = nil end end)
g.watch(function() return M.active(M.record.value) end, function(on: boolean) if not on then M.record_time.value = nil end end)

-- ---- What can be asked of it ------------------------------------------------------------

function M.refresh() refresh() end

-- In Studio Mode a scene is prepared, otherwise it goes on air.
function M.show(scene: string)
    if peek(M.studio) then
        ask("SetCurrentPreviewScene", { sceneName = scene })
    else
        ask("SetCurrentProgramScene", { sceneName = scene })
    end
end
function M.transition() ask("TriggerStudioModeTransition") end
function M.set_studio(on: boolean) ask("SetStudioModeEnabled", { studioModeEnabled = on }) end
function M.toggle_stream() ask("ToggleStream") end
function M.toggle_record() ask("ToggleRecord") end
function M.toggle_pause() ask("ToggleRecordPause") end
function M.toggle_virtual_cam() ask("ToggleVirtualCam") end
function M.toggle_replay() ask("ToggleReplayBuffer") end
function M.save_replay() ask("SaveReplayBuffer") end
function M.press(hotkey: string, context: string?)
    ask("TriggerHotkeyByName", { hotkeyName = hotkey, contextName = context })
end
function M.toggle_mute(input: string) ask("ToggleInputMute", { inputName = input }) end

-- A fader's moves: the latest, one at a time.
local function send_volume(a: Audio, db: number)
    if not let_in then
        a.sending = false
        a.next = nil
        return
    end
    a.sending = true
    local data: { [string]: any } = { inputName = a.name }
    if db <= M.MIN_DB then data.inputVolumeMul = 0 else data.inputVolumeDb = db end
    local function done()
        a.sending = false
        local more = a.next
        a.next = nil
        if more then send_volume(a, more) end
    end
    ask("SetInputVolume", data, done, function(status)
        M.failed(why(status))
        done()
    end)
end
function M.set_volume(a: Audio, db: number)
    db = math.clamp(db, M.MIN_DB, 0)
    a.db.value = db
    if a.sending then a.next = db else send_volume(a, db) end
end

return M
