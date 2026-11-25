--!strict
-- Bioma's controls (genoma/components there: segmented, switch, choice), as far
-- as they serve here, on ui/look and to a finger's measure.
local g = require("@genoma")
local app = require("core/app")
local look = require("ui/look")

local M = {}

local CLEAR = look.CLEAR
M.LEFT, M.RIGHT = 272, 273

-- A drawing of the app's own, tinted as Bioma tints its glyphs. `lit()`:
-- in the primary's light; otherwise in one quiet colour.
function M.glyph(name: string | () -> string, size: number, lit: (() -> boolean)?, quiet: (() -> string)?): any
    local faint = quiet or look.text_muted
    local function on(): boolean return lit == nil or (lit :: any)() end
    local function drawn(n: string): any
        return g.svg {
            width = size,
            height = size,
            src = g.dir .. "/icons/" .. n .. ".svg",
            gradient_top = function() return if on() then look.primary_top() else faint() end,
            gradient_bottom = function() return if on() then look.primary_bottom() else faint() end,
        }
    end
    if type(name) == "string" then return drawn(name) end
    -- A drawing that changes is another drawing.
    return g.each {
        width = size,
        height = size,
        items = function() return { (name :: () -> string)() } end,
        key = function(n: string) return n end,
        row = function(n: () -> string) return drawn(g.untracked(n)) end,
    }
end

-- Upper-case, technical, spaced.
function M.label(text: string | () -> string, colour: (() -> string)?, size: number?): any
    return g.text {
        text = function()
            return string.upper(if type(text) == "function" then text() else text)
        end,
        color = colour or look.text,
        font = look.technical,
        size = size or look.font_meta,
        weight = 500,
        tracking = look.label_tracking,
    }
end

-- A sentence.
function M.says(text: string | () -> string, width: (number | () -> number)?, colour: (() -> string)?, props: any?): any
    local node: { [any]: any } = {
        text = text,
        max_width = width,
        wrap = true,
        color = colour or look.text_muted,
        font = look.expressive,
        size = look.font_label,
    }
    for k, v in props or {} do node[k] = v end
    return g.text(node)
end

-- Where what is pressed is drawn: what opens from it grows from there.
-- `w`, `h`: its size. Gives `press(x, y)` for on_press and `origin()`.
function M.place(w: () -> number, h: () -> number): (( number, number) -> (), () -> any)
    local at = { x = 0, y = 0 }
    return function(x: number, y: number)
        local px, py = g.pressed_at()
        at = { x = px - x, y = py - y }
    end, function(): any
        return { x = at.x, y = at.y, w = g.untracked(w), h = g.untracked(h) }
    end
end

-- The cell that opens from the window's corner: its button.
function M.round(t: { [string]: any }): any
    local size = t.size or look.foot_height
    local over = g.signal(false)
    local function lit(): boolean return t.lit ~= nil and t.lit() end
    local node: { [any]: any } = {
        id = t.id,
        role = "button",
        name = t.name,
        present = t.present,
        width = size,
        height = size,
        radius = look.round(size / 2),
        align = "center",
        justify = "center",
        fill = function()
            if lit() then return look.chosen() end
            return if over.value then look.cell() else look.glass()
        end,
        rim_top = function() return if lit() then look.primary() else look.rim() end,
        rim_bottom = function() return if lit() then look.primary() else look.line() end,
        transition = { fill = "ui_change", rim_top = "ui_change", rim_bottom = "ui_change" },
        on_hover = function(on: boolean) over.value = on end,
        on_press = function() end,
        on_click = function(button: number) if button == M.LEFT then t.on_click() end end,
        M.glyph(t.glyph, t.glyph_size or 24, t.glyph_lit, look.text_faint),
    }
    for k, v in t.props or {} do node[k] = v end
    return g.capsule(node)
end

-- One of a few: a track, the choice in a pill of the primary that slides.
-- t: id, options { { key, label, glyph } }, current(), on_choose(key), height,
-- size of the words, bare() (the glyphs alone).
function M.segmented(t: { [string]: any }): any
    local SIZE, PAD, GAP, H = t.size or 11, 4, 2, (t.height or look.touch) - 8
    local GLYPH = 20
    local function bare(): boolean return t.bare ~= nil and t.bare() end
    local function width_of(o: any): number
        local words = if bare() then 0 else g.text_width { text = string.upper(o.label), font = look.technical(), size = SIZE, weight = 700, tracking = 0.04 }
        local glyph = if o.glyph then GLYPH + (if bare() then 0 else 8) else 0
        return math.max(H, math.ceil(words) + glyph + (if bare() then 24 else 32))
    end
    local function selection(): (number, number)
        local x = 0
        for _, o in t.options do
            local w = width_of(o)
            if o.key == t.current() then return x, w end
            x += w + GAP
        end
        return 0, 0
    end
    local function track_width(): number
        local w = 0
        for i, o in t.options do w += width_of(o) + (if i > 1 then GAP else 0) end
        return w + PAD * 2
    end
    local items: { [any]: any } = { overlay = true, attach = "corner", offset_x = PAD, offset_y = PAD, direction = "row", gap = GAP }
    for _, o in t.options do
        local function chosen(): boolean return o.key == t.current() end
        local function ink(): string return if chosen() then look.background() else look.text_muted() end
        table.insert(items, g.box {
            id = if t.id then `{t.id}-{o.key}` else nil,
            role = "button",
            name = o.label,
            width = function() return width_of(o) end,
            height = H,
            direction = "row",
            align = "center",
            justify = "center",
            gap = 8,
            on_press = function() end,
            on_click = function() t.on_choose(o.key) end,
            if o.glyph then M.glyph(o.glyph, GLYPH, function() return false end, ink) else g.box {},
            g.text {
                present = function() return not bare() end,
                text = string.upper(o.label),
                color = ink,
                font = look.technical,
                size = SIZE,
                weight = 700,
                tracking = 0.04,
                transition = { color = "ui_change" },
            },
        })
    end
    return g.capsule {
        role = "group",
        width = track_width,
        height = H + PAD * 2,
        radius = look.round((H + PAD * 2) / 2),
        fill = function() return g.colour.alpha(look.cell(), 0.5) end,
        rim_top = look.node,
        rim_bottom = look.node,
        g.capsule {
            overlay = true,
            attach = "corner",
            present = function() local _, w = selection() return w > 0 end,
            offset_x = function() local x = selection() return PAD + x end,
            offset_y = PAD,
            width = function() local _, w = selection() return w end,
            height = H,
            radius = look.round(H / 2),
            fill = look.primary_top,
            fill_bottom = look.primary_bottom,
            rim_top = CLEAR,
            rim_bottom = CLEAR,
            transition = { offset_x = "ui_change", width = "ui_change" },
        },
        g.box(items),
    }
end

-- t: id, name, on(), on_toggle(on).
function M.switch(t: { [string]: any }): any
    local W, H, KNOB = 42, 24, 16
    local INSET = (H - KNOB) / 2
    return g.box {
        id = t.id,
        role = "button",
        name = t.name,
        width = W + 8,
        height = look.touch,
        align = "center",
        justify = "center",
        on_press = function() end,
        on_click = function() t.on_toggle(not g.untracked(t.on)) end,
        g.capsule {
            width = W,
            height = H,
            radius = look.round(H / 2),
            fill = function() return if t.on() then look.primary_top() else g.colour.alpha(look.background(), 0.9) end,
            fill_bottom = function() return if t.on() then look.primary_bottom() else g.colour.alpha(look.background(), 0.9) end,
            rim_top = function() return if t.on() then CLEAR else look.node() end,
            rim_bottom = function() return if t.on() then CLEAR else look.node() end,
            transition = { fill = "ui_change", fill_bottom = "ui_change", rim_top = "ui_change", rim_bottom = "ui_change" },
            g.capsule {
                overlay = true,
                attach = "corner",
                width = KNOB,
                height = KNOB,
                radius = look.round(KNOB / 2),
                offset_x = function() return if t.on() then W - KNOB - INSET else INSET end,
                offset_y = INSET,
                fill = function() return if t.on() then look.background() else g.colour.alpha(look.text(), 0.45) end,
                rim_top = CLEAR,
                rim_bottom = CLEAR,
                transition = { offset_x = "ui_change", fill = "ui_change" },
            },
        },
    }
end

-- What does one thing: Bioma's buttons. "outline" is the plain one, "filled"
-- the one that does what is asked, "dashed" the one that makes something new,
-- "alert" the one that stops or takes away.
-- t: id, name, label, glyph, kind, lit(), disabled(), present(), bare(),
-- on_click, on_at(origin) instead of it for what opens from here.
function M.action(t: { [string]: any }): any
    local over = g.signal(false)
    local H = look.touch
    local dashed = t.kind == "dashed"
    local size = g.signal({ w = H, h = H })
    local press, origin = M.place(function() return size.value.w end, function() return size.value.h end)
    local function off(): boolean return t.disabled ~= nil and t.disabled() end
    local function filled(): boolean return t.kind == "filled" or t.kind == "alert" or (t.lit ~= nil and t.lit()) end
    local function hue(): string return if t.kind == "alert" then look.alert() else look.primary() end
    local function worded(): boolean return t.label ~= nil and not (t.bare ~= nil and t.bare()) end
    local function ink(): string
        if filled() then return look.background() end
        return if dashed and over.value and not off() then look.primary() else look.text()
    end
    local function edge(): string
        if filled() then return CLEAR end
        if over.value and not off() then return look.primary() end
        return if dashed then g.colour.alpha(look.node(), 0.7) else look.node()
    end
    local node: { [any]: any } = {
        id = t.id,
        role = "button",
        name = t.name or (if type(t.label) == "string" then t.label else t.id),
        present = t.present,
        height = H,
        min_width = H,
        padding_x = function() return if worded() then 18 else 0 end,
        radius = look.round(H / 2),
        direction = "row",
        align = "center",
        justify = "center",
        gap = 8,
        fill = function() return if filled() then look.gradient_top(hue()) else CLEAR end,
        fill_bottom = function() return if filled() then look.gradient_bottom(hue()) else CLEAR end,
        rim_top = edge,
        rim_bottom = edge,
        opacity = function() return if off() then 0.45 else 1 end,
        transition = { fill = "ui_change", fill_bottom = "ui_change", rim_top = "ui_change", rim_bottom = "ui_change", opacity = "ui_change" },
        on_hover = function(on: boolean) over.value = on end,
        on_size = function(w: number, h: number) size.value = { w = w, h = h } end,
        on_press = function(_: number, x: number, y: number) press(x, y) end,
        on_click = function(button: number)
            if button ~= M.LEFT or g.untracked(off) then return end
            if t.on_at then t.on_at(origin()) else t.on_click() end
        end,
    }
    if dashed then
        node.dash, node.dash_gap = 3, 3
    end
    if t.glyph then table.insert(node, M.glyph(t.glyph, 20, function() return false end, ink)) end
    if t.label then
        table.insert(node, g.text {
            present = worded,
            text = function() return string.upper(if type(t.label) == "function" then t.label() else t.label) end,
            color = ink,
            font = look.technical,
            size = look.font_action,
            weight = function() return if filled() then 700 else 500 end,
            tracking = 0.04,
        })
    end
    return g.capsule(node)
end

-- A well to write in. t: id, key (what app.field calls it), text(),
-- on_change(text), on_submit(), width, placeholder, secret, select, font.
function M.field(t: { [string]: any }): any
    local H = look.touch
    local has = app.has_keys(t.key)
    return g.capsule {
        present = t.present,
        width = t.width,
        height = H,
        radius = look.round(look.radius_well),
        padding_x = 14,
        direction = "row",
        align = "center",
        gap = 10,
        clip = true,
        fill = function() return g.colour.alpha(look.background(), 0.8) end,
        rim_top = function() return if has() then look.primary() else look.node() end,
        rim_bottom = function() return if has() then look.primary() else look.node() end,
        transition = { rim_top = "ui_change", rim_bottom = "ui_change" },
        on_press = app.take_keys(t.key),
        on_click = function() end,
        if t.glyph then M.glyph(t.glyph, 18, has, look.text_faint) else g.box {},
        g.field {
            id = t.id,
            width = function()
                local w = if type(t.width) == "function" then t.width() else t.width
                return w - 28 - (if t.glyph then 28 else 0) - (if t.on_clear then 30 else 0)
            end,
            size = look.font_label,
            font = look.expressive,
            color = look.text,
            caret_color = look.primary,
            selection_color = look.chosen,
            placeholder = t.placeholder,
            secret = t.secret,
            select = t.select or "none",
            on_press = app.take_keys(t.key),
            focused = has,
            text = t.text,
            on_change = t.on_change,
            on_submit = function() if t.on_submit then t.on_submit() end end,
        },
        if t.on_clear then g.box {
            id = t.id .. "-clear",
            role = "button",
            name = "Cancella",
            present = function() return t.text() ~= "" end,
            width = 30,
            height = H,
            align = "center",
            justify = "center",
            on_press = function() end,
            on_click = function() t.on_clear() end,
            M.glyph("close", 16, function() return false end, look.text_muted),
        } else g.box {},
    }
end

return M
