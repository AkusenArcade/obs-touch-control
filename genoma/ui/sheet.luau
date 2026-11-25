--!strict
-- What opens over the window: a question, a name to write, something to choose.
-- One at a time; it grows from what was pressed, and what one leads to takes its
-- place. A press beside it puts it away.
local g = require("@genoma")
local app = require("core/app")
local look = require("ui/look")
local ui = require("ui/controls")
local scroll_mark = require("ui/scroll_mark")

local M = {}

local PAD, GAP = 22, 16

-- `content(width)`: its nodes, `width()` what they may take. `head(width)`: what
-- stays above while the rest scrolls. `tall`: as tall as it can be, whatever is
-- in it. `valid()`: it goes by itself once this is not so.
type Sheet = {
    key: number,
    name: string,
    width: number,
    tall: boolean?,
    head: ((() -> number) -> any)?,
    content: (() -> number) -> any,
    valid: (() -> boolean)?,
}
local shown = g.signal(nil :: Sheet?)
local grown = g.signal(false)
local from = g.signal({ x = 0, y = 0, w = 44, h = 44 })
local going: any = nil
local count = 0

function M.is_open(): boolean return shown.value ~= nil and grown.value end

function M.close()
    if not g.untracked(function() return grown.value end) then return end
    grown.value = false
    app.field.value = ""
    if going then going:stop() end
    going = g.after(look.CLOSE, function()
        going = nil
        shown.value = nil
    end)
end

-- Opened from `origin`; with one open already, in its place.
function M.open(origin: any, t: any)
    if going then going:stop() end
    going = nil
    count += 1
    local sheet = table.clone(t)
    sheet.key = count
    local was = g.untracked(M.is_open)
    g.batch(function()
        app.field.value = t.field or ""
        if not was then
            from.value = origin
            grown.value = false
        end
        shown.value = sheet
    end)
    if not was then g.after(0, function() grown.value = true end) end
end

g.watch(function(): boolean
    local s = shown.value
    return s == nil or s.valid == nil or s.valid()
end, function(good: boolean) if not good then M.close() end end)

-- ---- What is asked most ---------------------------------------------------------

local function row(...: any): any
    return g.box { direction = "row", align = "center", justify = "end", gap = 10, ... }
end
M.row = row

function M.title(text: string, width: () -> number): any
    return g.text {
        text = text,
        max_width = width,
        wrap = true,
        color = look.text,
        font = look.expressive,
        size = 19,
        weight = 600,
    }
end

-- t: title, body, accept (the button's word), valid(), on_accept.
function M.confirm(origin: any, t: { [string]: any })
    M.open(origin, {
        name = t.title,
        width = 400,
        valid = t.valid,
        content = function(width: () -> number): any
            return g.box {
                direction = "column",
                align = "stretch",
                gap = GAP,
                M.title(t.title, width),
                ui.says(t.body, width),
                row(
                    ui.action { id = "sheet-no", label = "Annulla", on_click = M.close },
                    ui.action {
                        id = "sheet-yes",
                        label = t.accept,
                        kind = "alert",
                        on_click = function()
                            M.close()
                            t.on_accept()
                        end,
                    }
                ),
            }
        end,
    })
end

-- A short text. t: title, note, text, can_reset, on_done(text, nil to go back to
-- the name it has by itself).
function M.write(origin: any, t: { [string]: any })
    local typed = g.signal(t.text)
    local function done(text: string?)
        M.close()
        t.on_done(text)
    end
    local function save()
        local text = string.match(g.untracked(function() return typed.value end), "^%s*(.-)%s*$") or ""
        done(if text ~= "" then text else nil)
    end
    M.open(origin, {
        name = t.title,
        width = 440,
        field = "write",
        content = function(width: () -> number): any
            return g.box {
                direction = "column",
                align = "stretch",
                gap = GAP,
                M.title(t.title, width),
                if t.note then ui.says(t.note, width) else g.box {},
                ui.field {
                    id = "sheet-field",
                    key = "write",
                    width = width,
                    select = "all",
                    text = function() return typed.value end,
                    on_change = function(text: string) typed.value = text end,
                    on_submit = save,
                },
                row(
                    ui.action { id = "sheet-no", label = "Annulla", on_click = M.close },
                    ui.action { id = "sheet-reset", label = "Ripristina", present = function() return t.can_reset end, on_click = function() done(nil) end },
                    ui.action { id = "sheet-yes", label = "Salva", kind = "filled", on_click = save }
                ),
            }
        end,
    })
end

-- ---- The sheet ------------------------------------------------------------------

function M.new(): any
    local E = look.margin_edge
    local content_h, head_h = g.signal(200), g.signal(0)
    local function area(): any return app.area.value end
    local function width(): number return math.min(if shown.value then shown.value.width else 400, area().w - E * 2) end
    local function most(): number return area().h - E * 2 end
    local function tall(): number
        local s = shown.value
        return if s and s.tall then math.min(640, most()) else math.min(content_h.value + head_h.value, most())
    end
    local function inner(): number return width() - PAD * 2 end
    local function timing(): string return if grown.value then "cell_open" else "cell_close" end
    local function body_h(): number return math.max(0, tall() - head_h.value) end
    local scroller = scroll_mark.new {
        height = body_h,
        x = function() return width() - 6 end,
        room = function() return math.max(0, content_h.value - body_h()) end,
    }
    local function sheets(): { Sheet } return if shown.value then { shown.value } else {} end
    local function key(s: Sheet): number return s.key end
    return g.box {
        overlay = true,
        attach = "corner",
        present = function() return shown.value ~= nil end,
        width = function() return area().w end,
        height = function() return area().h end,
        g.capsule {
            overlay = true,
            attach = "corner",
            width = function() return area().w end,
            height = function() return area().h end,
            radius = 0,
            fill = function() return g.colour.alpha(look.background(), 0.55) end,
            rim_top = look.CLEAR,
            rim_bottom = look.CLEAR,
            opacity = function() return if grown.value then 1 else 0 end,
            transition = { opacity = timing },
            on_press = function() end,
            on_click = function() M.close() end,
        },
        g.capsule {
            id = "sheet",
            overlay = true,
            attach = "corner",
            offset_x = function() return if grown.value then (area().w - width()) / 2 else from.value.x end,
            offset_y = function() return if grown.value then (area().h - tall()) / 2 else from.value.y end,
            width = function() return if grown.value then width() else from.value.w end,
            height = function() return if grown.value then tall() else from.value.h end,
            radius = look.round(look.radius_panel),
            opacity = function() return if grown.value then 1 else 0 end,
            clip = true,
            fill = look.glass_over,
            rim_top = look.rim,
            rim_bottom = look.line,
            backdrop_blur = look.glass_blur,
            transition = { offset_x = timing, offset_y = timing, width = timing, height = timing, opacity = timing },
            on_press = function() app.field.value = "" end,
            on_click = function() end,
            g.box {
                overlay = true,
                attach = "corner",
                width = width,
                height = tall,
                opacity = function() return if grown.value then 1 else 0 end,
                transition = { opacity = function() return if grown.value then "content_in" else "content_out" end },
                g.box {
                    overlay = true,
                    attach = "corner",
                    direction = "column",
                    align = "stretch",
                    width = width,
                    on_size = function(_: number, h: number) head_h.value = h end,
                    g.each {
                        direction = "column",
                        align = "stretch",
                        items = sheets,
                        key = key,
                        row = function(item: () -> Sheet): any
                            local s = g.untracked(item)
                            if s.head == nil then return g.box { height = 0 } end
                            return g.box { direction = "column", align = "stretch", padding_x = PAD, padding_y = PAD - 4, s.head(inner) }
                        end,
                    },
                },
                g.box {
                    overlay = true,
                    attach = "corner",
                    offset_y = function() return head_h.value end,
                    width = width,
                    height = body_h,
                    scroll = "y",
                    clip = true,
                    direction = "column",
                    align = "start",
                    justify = "start",
                    fade_bottom = scroller.fade,
                    on_scroll = function(_: number, y: number) scroller.follow(y, 0) end,
                    g.box {
                        width = width,
                        direction = "column",
                        align = "stretch",
                        on_size = function(_: number, h: number) if h > 1 then content_h.value = h end end,
                        g.each {
                            direction = "column",
                            align = "stretch",
                            items = sheets,
                            key = key,
                            row = function(item: () -> Sheet): any
                                local s = g.untracked(item)
                                return g.box {
                                    direction = "column",
                                    align = "stretch",
                                    padding_x = PAD,
                                    padding_y = if s.head then 4 else PAD,
                                    s.content(inner),
                                    if s.tall then g.box { height = PAD } else g.box {},
                                }
                            end,
                        },
                    },
                    },
                g.box {
                    overlay = true,
                    attach = "corner",
                    offset_y = function() return head_h.value end,
                    scroller.mark,
                },
            },
        },
    }
end

return M
