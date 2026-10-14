mod audio;
mod controls;
mod hotkeys;
mod panel;
mod scenes;
mod settings;

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};

use crate::config::{Config, TileSize};
use crate::obs::{self, Command, CommandSender, ConnParams, Update};

/// Shared handles every page needs: the command channel, the config and toast output.
pub struct Ctx {
    cmd: CommandSender,
    pub config: RefCell<Config>,
    toasts: adw::ToastOverlay,
    window: glib::WeakRef<adw::ApplicationWindow>,
}

impl Ctx {
    pub fn send(&self, cmd: Command) {
        let _ = self.cmd.send(cmd);
    }

    pub fn toast(&self, msg: &str) {
        let toast = adw::Toast::new(msg);
        toast.set_timeout(3);
        self.toasts.add_toast(toast);
    }

    pub fn window(&self) -> Option<adw::ApplicationWindow> {
        self.window.upgrade()
    }

    pub fn save_config(&self) {
        if let Err(e) = self.config.borrow().save() {
            self.toast(&format!("Impossibile salvare la configurazione: {e}"));
        }
    }

    pub fn connect(&self) {
        let cfg = self.config.borrow();
        self.send(Command::Connect(ConnParams {
            host: cfg.host.clone(),
            port: cfg.port,
            password: (!cfg.password.is_empty()).then(|| cfg.password.clone()),
        }));
    }

    /// Tile density is pure CSS (min sizes per class), so changing it just swaps a window class
    /// and every grid reflows its columns on the next allocation.
    pub fn apply_tile_size(&self) {
        let Some(window) = self.window() else { return };
        let current = self.config.borrow().tile_size;
        for size in TileSize::ALL {
            window.remove_css_class(size.css_class());
        }
        window.add_css_class(current.css_class());
    }

    /// Runs `on_confirm` after the user accepts a destructive confirmation dialog.
    pub fn confirm(&self, heading: &str, body: &str, accept: &str, on_confirm: impl Fn() + 'static) {
        let dialog = adw::AlertDialog::new(Some(heading), Some(body));
        dialog.add_responses(&[("cancel", "Annulla"), ("accept", accept)]);
        dialog.set_response_appearance("accept", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        dialog.connect_response(None, move |_, response| {
            if response == "accept" {
                on_confirm();
            }
        });
        dialog.present(self.window().as_ref());
    }
}

/// A responsive tile grid: homogeneous children whose minimum width comes from CSS, so the
/// number of columns is recomputed from the available width on every resize.
pub fn tile_grid() -> gtk::FlowBox {
    gtk::FlowBox::builder()
        .homogeneous(true)
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(24)
        .column_spacing(12)
        .row_spacing(12)
        .valign(gtk::Align::Start)
        .build()
}

/// Wraps a FlowBox child so the FlowBox itself never grabs focus/activation from the button.
pub fn grid_child(widget: &impl IsA<gtk::Widget>) -> gtk::FlowBoxChild {
    let child = gtk::FlowBoxChild::new();
    child.set_focusable(false);
    child.set_child(Some(widget));
    child
}

pub fn section_title(text: &str) -> gtk::Label {
    let label = gtk::Label::builder().label(text).xalign(0.0).build();
    label.add_css_class("section-title");
    label
}

/// Scrollable dialog (bottom sheet on narrow windows). `top` goes under the header bar.
pub fn sheet(title: &str, body: &impl IsA<gtk::Widget>, top: Option<&gtk::Widget>) -> adw::Dialog {
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(body)
        .vexpand(true)
        .build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    if let Some(top) = top {
        toolbar.add_top_bar(top);
    }
    toolbar.set_content(Some(&scroll));
    adw::Dialog::builder()
        .title(title)
        .content_width(760)
        .content_height(600)
        .child(&toolbar)
        .build()
}

pub enum TextAnswer {
    Set(String),
    Reset,
}

/// Asks for a short text. Empty input counts as `Reset`.
pub fn ask_text(
    ctx: &Ctx,
    heading: &str,
    body: &str,
    initial: &str,
    can_reset: bool,
    on_answer: impl Fn(TextAnswer) + 'static,
) {
    let entry = adw::EntryRow::builder().title("Nome").text(initial).activates_default(true).build();
    let list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    list.add_css_class("boxed-list");
    list.append(&entry);

    let dialog = adw::AlertDialog::new(Some(heading), Some(body));
    dialog.set_extra_child(Some(&list));
    dialog.add_responses(&[("cancel", "Annulla"), ("reset", "Ripristina"), ("save", "Salva")]);
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
    dialog.set_response_enabled("reset", can_reset);
    dialog.set_default_response(Some("save"));
    dialog.set_close_response("cancel");

    let input = entry.clone();
    dialog.connect_response(None, move |_, response| {
        let text = input.text().trim().to_owned();
        match response {
            "save" if !text.is_empty() => on_answer(TextAnswer::Set(text)),
            "save" | "reset" => on_answer(TextAnswer::Reset),
            _ => {}
        }
    });
    dialog.present(ctx.window().as_ref());
    entry.grab_focus();
}

/// Long press (touch or mouse) or right click. Runs in the capture phase and claims the
/// sequence, so the button's own click is cancelled.
pub fn on_hold_or_secondary(button: &gtk::Button, f: impl Fn() + 'static) {
    let f = Rc::new(f);

    let hold = gtk::GestureLongPress::new();
    hold.set_propagation_phase(gtk::PropagationPhase::Capture);
    let on_hold = f.clone();
    hold.connect_pressed(move |gesture, _, _| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        on_hold();
    });
    button.add_controller(hold);

    let secondary = gtk::GestureClick::builder().button(gtk::gdk::BUTTON_SECONDARY).build();
    secondary.connect_pressed(move |gesture, _, _, _| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        f();
    });
    button.add_controller(secondary);
}

pub fn build(app: &adw::Application, rt: &tokio::runtime::Handle) {
    let (cmd, updates) = obs::spawn(rt);

    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("OBS Touch Control")
        .default_width(1100)
        .default_height(760)
        .width_request(360)
        .height_request(400)
        .build();
    let toasts = adw::ToastOverlay::new();

    let ctx = Rc::new(Ctx {
        cmd,
        config: RefCell::new(Config::load()),
        toasts: toasts.clone(),
        window: window.downgrade(),
    });

    let controls = controls::Controls::new(ctx.clone());
    let scenes = scenes::ScenesPage::new(ctx.clone());
    let hotkeys = hotkeys::HotkeysPage::new(ctx.clone());
    let audio = audio::AudioPage::new(ctx.clone());
    let panel = panel::PanelPage::new(ctx.clone(), hotkeys.clone());

    let stack = adw::ViewStack::new();
    stack.add_titled_with_icon(&panel.widget, Some("panel"), "Pannello", "view-app-grid-symbolic");
    stack.add_titled_with_icon(&scenes.widget, Some("scenes"), "Scene", "view-grid-symbolic");
    stack.add_titled_with_icon(&hotkeys.widget, Some("hotkeys"), "Scorciatoie", "input-keyboard-symbolic");
    stack.add_titled_with_icon(&audio.widget, Some("audio"), "Audio", "audio-speakers-symbolic");
    stack.set_vexpand(true);

    let main_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    main_box.append(&controls.widget);
    main_box.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    main_box.append(&stack);

    let offline = OfflinePage::new(&ctx);

    let root = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .build();
    root.add_named(&offline.widget, Some("offline"));
    root.add_named(&main_box, Some("main"));
    root.set_visible_child_name("offline");

    // Header
    let header = adw::HeaderBar::new();
    let switcher = adw::ViewSwitcher::builder()
        .stack(&stack)
        .policy(adw::ViewSwitcherPolicy::Wide)
        .build();
    header.set_title_widget(Some(&switcher));

    let status = gtk::Label::new(Some("● Non connesso"));
    status.add_css_class("status-pill");
    status.add_css_class("offline");
    header.pack_start(&status);

    let settings_btn = gtk::Button::from_icon_name("emblem-system-symbolic");
    settings_btn.set_tooltip_text(Some("Impostazioni"));
    settings_btn.set_action_name(Some("win.settings"));
    let fullscreen_btn = gtk::Button::from_icon_name("view-fullscreen-symbolic");
    fullscreen_btn.set_tooltip_text(Some("Schermo intero (F11)"));
    fullscreen_btn.set_action_name(Some("win.fullscreen"));
    let refresh_btn = gtk::Button::from_icon_name("view-refresh-symbolic");
    refresh_btn.set_tooltip_text(Some("Aggiorna da OBS"));
    refresh_btn.set_action_name(Some("win.refresh"));
    header.pack_end(&settings_btn);
    header.pack_end(&fullscreen_btn);
    header.pack_end(&refresh_btn);

    let switcher_bar = adw::ViewSwitcherBar::builder().stack(&stack).build();

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.add_bottom_bar(&switcher_bar);
    toolbar.set_content(Some(&root));
    toasts.set_child(Some(&toolbar));
    window.set_content(Some(&toasts));

    // Narrow screens: page switcher moves to the bottom bar and the `compact` class shrinks
    // tiles (see style.css), so grids keep at least two columns on phone-sized windows.
    let bp = adw::Breakpoint::new(adw::BreakpointCondition::parse("max-width: 640sp").unwrap());
    bp.add_setter(&switcher_bar, "reveal", Some(&true.to_value()));
    bp.add_setter(&header, "title-widget", Some(&None::<gtk::Widget>.to_value()));
    bp.connect_apply(glib::clone!(
        #[weak]
        window,
        move |_| window.add_css_class("compact")
    ));
    bp.connect_unapply(glib::clone!(
        #[weak]
        window,
        move |_| window.remove_css_class("compact")
    ));
    window.add_breakpoint(bp);
    ctx.apply_tile_size();

    // Window actions
    let action = gio::SimpleAction::new("settings", None);
    action.connect_activate(glib::clone!(
        #[strong]
        ctx,
        move |_, _| settings::present(&ctx)
    ));
    window.add_action(&action);

    let action = gio::SimpleAction::new("fullscreen", None);
    action.connect_activate(glib::clone!(
        #[weak]
        window,
        move |_, _| window.set_fullscreened(!window.is_fullscreen())
    ));
    window.add_action(&action);
    window.connect_fullscreened_notify(glib::clone!(
        #[weak]
        fullscreen_btn,
        move |w| fullscreen_btn.set_icon_name(if w.is_fullscreen() {
            "view-restore-symbolic"
        } else {
            "view-fullscreen-symbolic"
        })
    ));
    app.set_accels_for_action("win.fullscreen", &["F11"]);

    let refresh = gio::SimpleAction::new("refresh", None);
    refresh.set_enabled(false);
    refresh.connect_activate(glib::clone!(
        #[strong]
        ctx,
        move |_, _| ctx.send(Command::Refresh)
    ));
    window.add_action(&refresh);
    app.set_accels_for_action("win.refresh", &["F5"]);

    // Apply backend updates on the GTK main loop.
    glib::spawn_future_local(glib::clone!(
        #[strong]
        ctx,
        async move {
            while let Ok(update) = updates.recv().await {
                match update {
                    Update::Connecting => {
                        set_status(&status, "connecting", "● Connessione…");
                        offline.set_connecting(true, None);
                    }
                    Update::Connected { obs_version } => {
                        set_status(&status, "connected", &format!("● OBS {obs_version}"));
                        root.set_visible_child_name("main");
                        switcher.set_sensitive(true);
                        refresh.set_enabled(true);
                    }
                    Update::Disconnected(reason) => {
                        set_status(&status, "offline", "● Non connesso");
                        offline.set_connecting(false, reason.as_deref());
                        root.set_visible_child_name("offline");
                        switcher.set_sensitive(false);
                        refresh.set_enabled(false);
                    }
                    Update::SceneList(list) => {
                        hotkeys.set_scenes(list.clone());
                        panel.set_scenes(list.clone());
                        scenes.set_scenes(list);
                    }
                    Update::ProgramScene(name) => {
                        panel.set_program(name.clone());
                        scenes.set_program(name);
                    }
                    Update::PreviewScene(name) => {
                        panel.set_preview(name.clone());
                        scenes.set_preview(name);
                    }
                    Update::StudioMode(on) => {
                        scenes.set_studio(on);
                        panel.set_studio(on);
                        controls.set_studio(on);
                    }
                    Update::Stream(phase) => controls.set_stream(phase),
                    Update::Record { phase, paused } => controls.set_record(phase, paused),
                    Update::VirtualCam(phase) => controls.set_vcam(phase),
                    Update::ReplayBuffer(phase) => controls.set_replay(phase),
                    Update::Timecodes { stream, record } => controls.set_timecodes(stream, record),
                    Update::Hotkeys(list) => {
                        hotkeys.set_hotkeys(list);
                        panel.hotkeys_changed();
                    }
                    Update::Inputs(list) => hotkeys.set_inputs(list),
                    Update::AudioInputs(list) => {
                        hotkeys.set_audio_inputs(list.iter().map(|a| a.name.clone()).collect());
                        panel.set_audio(list.iter().map(|a| (a.name.clone(), a.muted)));
                        audio.set_inputs(list);
                    }
                    Update::InputMute(name, muted) => {
                        panel.set_muted(&name, muted);
                        audio.set_muted(&name, muted);
                    }
                    Update::InputVolume(name, db) => audio.set_volume(&name, db),
                    Update::Error(msg) => ctx.toast(&msg),
                }
            }
        }
    ));

    if ctx.config.borrow().start_fullscreen {
        window.fullscreen();
    }
    window.present();

    if ctx.config.borrow().auto_connect {
        ctx.connect();
    } else {
        settings::present(&ctx);
    }
}

fn set_status(label: &gtk::Label, class: &str, text: &str) {
    for c in ["connected", "connecting", "offline"] {
        label.remove_css_class(c);
    }
    label.add_css_class(class);
    label.set_text(text);
}

/// Shown while not connected to OBS.
struct OfflinePage {
    widget: adw::StatusPage,
    spinner: adw::Spinner,
    connect: gtk::Button,
}

impl OfflinePage {
    fn new(ctx: &Rc<Ctx>) -> Self {
        let spinner = adw::Spinner::builder().width_request(48).height_request(48).visible(false).build();

        let connect = gtk::Button::with_label("Connetti");
        connect.add_css_class("pill");
        connect.add_css_class("suggested-action");
        connect.add_css_class("big-button");
        connect.connect_clicked(glib::clone!(
            #[weak]
            ctx,
            move |_| ctx.connect()
        ));

        let settings = gtk::Button::with_label("Impostazioni connessione");
        settings.add_css_class("pill");
        settings.add_css_class("big-button");
        settings.set_action_name(Some("win.settings"));

        let buttons = gtk::Box::new(gtk::Orientation::Vertical, 12);
        buttons.set_halign(gtk::Align::Center);
        buttons.append(&spinner);
        buttons.append(&connect);
        buttons.append(&settings);

        let widget = adw::StatusPage::builder()
            .icon_name("network-offline-symbolic")
            .title("Non connesso a OBS")
            .description("In OBS abilita <b>Strumenti → Impostazioni server WebSocket</b>, poi connettiti.")
            .child(&buttons)
            .vexpand(true)
            .build();

        Self { widget, spinner, connect }
    }

    fn set_connecting(&self, connecting: bool, reason: Option<&str>) {
        self.spinner.set_visible(connecting);
        self.connect.set_sensitive(!connecting);
        if connecting {
            self.widget.set_title("Connessione a OBS…");
        } else {
            self.widget.set_title("Non connesso a OBS");
            let desc = match reason {
                Some(r) => format!("{}\n\nNuovo tentativo automatico in corso…", glib::markup_escape_text(r)),
                None => "In OBS abilita <b>Strumenti → Impostazioni server WebSocket</b>, poi connettiti.".into(),
            };
            self.widget.set_description(Some(&desc));
        }
    }
}
