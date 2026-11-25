# OBS Touch Control on Genoma — port plan

Status: phases 1 to 8 built, 2026-11-25 (`genoma/`); phase 9 (packaging) open.
Draft 2026-11-18. Source: the GTK4 + libadwaita version at commit
`cec0ef5` (~3000 lines of Rust: `src/obs.rs`, `src/config.rs`,
`src/hotkey_names.rs`, `src/ui/*`, `src/style.css`).

## 1. Goal

The same app — Panel, Scenes, Controls, Hotkeys, Audio, settings — drawn by
Genoma as a normal `g.window` (`app_id = "io.github.akusen.ObsTouchControl"`),
in Luau with the kit, with Bioma's look rather than Adwaita's. Feature parity
with the GTK version first; nothing new until parity is reached.

## 2. Theme: follows Bioma, as GTK apps do

GTK apps follow Bioma because GTK reads `gtk.css` by convention and Bioma
writes it (the gtk3/gtk4 matugen templates). A Genoma app needs the same
arrangement, and it belongs to the toolkit, not to each app:

- **Genoma** defines a well-known file, `$XDG_CONFIG_HOME/genoma/theme.json`
  (roles, light/dark, radius and the other kit sizes, fonts). The kit
  follows it by itself when it exists — `kit.theme` watches it with `g.file`
  and every change is a crossing, so the app retints live, animated — and
  falls back to its own tokens when it does not. An app can opt out.
- **Bioma** writes that file whenever its effective theme changes: the
  roles at rest from `core/theme.luau` (manual palette or matugen), the mode,
  and the Appearance settings that map onto kit tokens. Nothing in Genoma
  names Bioma; any shell built on Genoma can write the same file.
- The app does nothing beyond using the kit and `kit.theme.get(...)` for its
  own colours. The visual area of Sinestesia stays black by design.

A prerequisite (§6).

## 3. The blocker: OBS speaks WebSocket over TCP

Genoma has no TCP or WebSocket client: `g.socket` is a Unix socket read as
lines, `g.process` is a child with stdin (`p:write`) and stdout (`on_line`).
OBS's protocol v5 also needs SHA-256 + base64 for authentication.

**Decision (2026-11-18): add `g.websocket` to Genoma; the app is pure Luau.**

A Rust sidecar reusing `obs.rs` was the alternative. It was dropped: it is a
second binary to build and package, and the same primitive gives Bioma an
OBS cell (present only while recording or streaming) and future WebSocket
integrations (Home Assistant, live chats, local apps).

- `g.websocket { url, headers, on_open, on_message, on_close }` →
  `ws:send(text)`, `ws:close()`; its own thread, as PipeWire's; `ws://` and
  `wss://` (rustls, system certificates); reconnection decided in Luau.
- `g.sha256` and `g.base64`, for OBS's authentication
  (base64(sha256(base64(sha256(password + salt)) + challenge))).
- While there: `g.socket` also on TCP (`host:port`), for line protocols.

The OBS protocol v5 is rewritten in Luau (`obs.luau`, one service module):
Hello → Identify (with auth) → Identified; requests with ids answered by
RequestResponse; events subscribed by mask. `src/obs.rs` is the reference
for which requests and events are used, `src/hotkey_names.rs` is ported as
a table.

Config: `~/.config/obs-touch-control/config.json`, same file and keys. It
holds the WebSocket password and must stay `0600`; `g.file:write` writes
through a temporary file and a rename, so check the mode it leaves and, if
it is not kept, add a `mode` option to `g.file:write` (part of phase 0).

## 4. Mapping GTK → Genoma

| GTK version | Genoma |
|---|---|
| `adw::ApplicationWindow` | `g.window { app_id, title, size, min }` |
| `adw::ViewStack` + `ViewSwitcher` (top, wide) | kit `tabs`; in compact mode moved to the bottom |
| `GtkFlowBox` homogeneous, columns = width ÷ min tile width | `g.box { flow = true }` with the tile width computed in Luau from `on_size` (columns = ⌊(w + gap) ÷ (min + gap)⌋, tile = (w − gaps) ÷ columns) |
| `style.css` densities (small/medium/large) | three tile-size tables in a Luau `style` module |
| `compact` below 640 sp | a `compact` computed from the root's `on_size` width |
| `GtkScrolledWindow` | `scroll = "y"` |
| `GestureLongPress` (rename) + right click | `on_long_press` + right button in `on_click` |
| `gtk::Scale` (dB fader) | kit `slider`, mapped dB ↔ position as `src/ui/audio.rs` does |
| `gtk::SearchEntry` (hotkeys) | `g.field` with `on_change` |
| `adw::Dialog` sheets, `adw::AlertDialog`, `PreferencesDialog` | kit `dialog` |
| `adw::Toast` | a small toast overlay (an `overlay` + `g.after`), written once |
| Live timers on stream/record | `g.timer` at 1 s while an output is active, nothing otherwise |
| F11 fullscreen, F5 refresh | `on_key`; F11 needs a Genoma addition (§5) |
| Icons (`*-symbolic`) | `g.icon` from the icon theme, or drawn SVGs in `assets/` |

Touch: Genoma treats the first finger as the pointer, so a tile press, a
fader drag and a long press all work. Two fingers on two faders at once do
not — acceptable for a control surface, but note it.

## 5. Phases

Each phase ends with the app usable up to that point, and is verified before
the next starts.

0. **Genoma.** Fullscreen request, the shared theme file (§2),
   `g.websocket`, `g.sha256`, `g.base64`, TCP `g.socket`, `g.file` mode.
1. **OBS service.** `obs.luau` speaking v5 over `g.websocket`, verified
   headlessly against a running OBS (a scratch dir printing scenes,
   outputs, hotkeys, inputs and events as they change), with reconnection.
2. **Skeleton.** `genoma/` app dir: `shell.luau`, a window, the service's
   signals, connection status shown. Tabs with empty pages.
3. **Tile grid + responsiveness.** The shared grid component (flow, computed
   columns, three densities, compact mode). Verify with `genoma snapshot
   --size` at 480, 800, 1280 and 1920 widths.
4. **Scenes + Controls.** Program/preview colours, Studio Mode, transition,
   outputs with timers and the optional stop confirmation.
5. **Audio.** Faders and mute, dB mapping identical to the GTK version.
6. **Hotkeys.** Groups, search, favourites (★), the per-source picker dialog,
   rename by long press.
7. **Panel.** The personal page: edit mode, add (+), move (◀ ▶), rename (✎),
   remove, live state on each tile.
8. **Settings + toasts + keys.** Settings dialog (host, port, password as a
   `secret` field, density, start fullscreen, confirm stop), toasts for
   OBS errors, F5/F11.
9. **Packaging.** `install.sh` installs the app dir into `~/.local/share/obs-touch-control`, and the `.desktop` with
   `Exec=genoma ~/.local/share/obs-touch-control`. The GTK version stays
   buildable until the Genoma one has replaced it in daily use.

Verification throughout: `genoma snapshot` with `--mock` replacing the OBS
service with fixed state (no OBS needed), then a live run against OBS on the touchscreen.

## 6. What Genoma needs first

| Need | Why | Size |
|---|---|---|
| A window asking for fullscreen (`xdg_toplevel.set_fullscreen`) from Luau | F11 and "start fullscreen" | small |
| The shared theme file, followed by the kit; Bioma writing it | follows Bioma's theme live (§2) | small–medium |
| `g.websocket` (`ws://`, `wss://`), `g.sha256`, `g.base64` | OBS protocol v5 | medium |
| `g.socket` on TCP | not for this app; cheap while there | small |
| `g.file:write` keeping a `0600` mode | the password in the config | small |

Everything else is already in Genoma: windows, flow layout, `on_size`,
scroll, long press, sliders, fields, dialogs.

## 7. Decisions and open questions

- Decided 2026-11-18: Bioma's look, not Adwaita's; Genoma prerequisites
  first.
- Decided 2026-11-18: `g.websocket` in Genoma, no bridge (§3).
- Decided 2026-11-18: the app follows Bioma's theme live, as GTK apps do (§2).
- Once the Genoma version replaces the GTK one: drop the GTK code, or keep it
  as the version for people without Genoma?

## 8. As built (2026-11-25)

Run it from the checkout: `GENOMA_IPC=obs-touch-control genoma genoma/`.
Same config file and keys as the GTK version, written 0600; a file written by
one is read by the other (checked against `src/config.rs`).

- `core/obs.luau`: protocol v5 in Luau. Hello → Identify (auth) → Identified,
  then one RequestBatch for the whole state and one for the inputs' mute and
  volume. Events subscribed: General, Config, Scenes, Inputs, Outputs, Ui.
  Tried again every 3 s while wanted; a wrong password (close 4009) is not
  retried, since it would be refused again. OBS still loading a collection
  (207) is asked again after 1 s. Timers polled once a second only while
  something is sent or written.
- `core/config.luau`, `core/hotkeys.luau` (the names and groups of
  `src/hotkey_names.rs`), `core/app.luau` (page, size, which field has the
  keys, tile sizes from `style.css`), `core/notice.luau` (the toasts).
- `ui/`: Bioma's look (`look`, `controls`), `tiles` (the grid: columns =
  ⌊(w + gap) ÷ (min + gap)⌋), `sheet` (every dialog, grown from what was
  pressed), one module per page, `outputs`, `settings_cell`, `corner_cell`.

Layout, following the rules the other Genoma apps settled (Rizoma, Sinestesia):
the pages as a segmented control at the top (their drawings alone under 720
wide) with the page's own action at the right (MODIFICA, the hotkey search);
the outputs as Bioma buttons in the foot, worded while they fit and their
drawings alone when not, wrapping on narrow windows; the settings in a cell
that grows from the corner button, whose drawing is lit while OBS is reached.

Changed from the GTK version, on purpose:

- **The fader follows the finger from where it is**: a touch that lands on
  it changes nothing, and the wheel scrolls the page rather than the volume.
  Moves are sent one at a time, the latest only.
- **At rest nothing is said**: no "Avvia", "Spenta", "SCENA", "AUDIO
  ATTIVO" under the tiles; words appear for a state (on air, preview, muted,
  paused, reconnecting, a timer, a missing target).
- The connection settings are saved with SALVA E CONNETTI; the switches and
  the tile size at once.
- Keys: F11, F5, Escape, Ctrl+F (search), Ctrl+1…4 (pages).
- IPC (`genoma ipc obs-touch-control …`): page, state, connect, disconnect,
  settings, edit, search, fullscreen, scene, hotkey, stream, record, mute —
  a compositor keybinding can drive OBS through it.

Verified against a private OBS 33 (its own config, port and password, in a
headless Umbriel): authentication, wrong password, refused connection,
reconnection after OBS quits, scenes, Studio Mode and transition, recording
with pause and timer, replay buffer, mute, volume, hotkeys with and without a
source, rename, favourites, search, the panel's add / move / rename / remove,
the stop confirmation; 0 CPU ticks in 10 s connected at rest, 115 MB RSS.
Not tested: streaming (no server), the virtual camera (it would take the
system's v4l2loopback), touch on a real screen.
