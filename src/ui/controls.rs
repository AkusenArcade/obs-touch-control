//! Output controls (stream, record, virtual cam, replay buffer, studio mode) as a responsive
//! tile strip that wraps onto more rows when the window gets narrow.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;

use super::{Ctx, grid_child, tile_grid};
use crate::obs::{Command, Phase};

struct Tile {
    button: gtk::Button,
    icon: gtk::Image,
    sub: gtk::Label,
    child: gtk::FlowBoxChild,
}

impl Tile {
    fn new(grid: &gtk::FlowBox, icon_name: &str, title: &str, sub: &str) -> Self {
        let icon = gtk::Image::from_icon_name(icon_name);
        icon.set_pixel_size(28);
        let title = gtk::Label::new(Some(title));
        title.add_css_class("tile-title");
        title.set_ellipsize(gtk::pango::EllipsizeMode::End);
        let sub = gtk::Label::new(Some(sub));
        sub.add_css_class("tile-sub");
        sub.set_ellipsize(gtk::pango::EllipsizeMode::End);

        let content = gtk::Box::new(gtk::Orientation::Vertical, 2);
        content.set_valign(gtk::Align::Center);
        content.append(&icon);
        content.append(&title);
        content.append(&sub);

        let button = gtk::Button::builder().child(&content).build();
        button.add_css_class("control-tile");
        let child = grid_child(&button);
        grid.append(&child);
        Self { button, icon, sub, child }
    }

    fn set_classes(&self, classes: &[&str]) {
        for c in ["live", "recording", "paused", "on", "busy"] {
            self.button.remove_css_class(c);
        }
        for c in classes {
            self.button.add_css_class(c);
        }
    }
}

pub struct Controls {
    pub widget: gtk::FlowBox,
    ctx: Rc<Ctx>,
    stream: Tile,
    record: Tile,
    pause: Tile,
    vcam: Tile,
    replay: Tile,
    save_replay: Tile,
    studio: Tile,
    transition: Tile,
    stream_phase: Cell<Phase>,
    record_phase: Cell<Phase>,
    studio_on: Cell<bool>,
}

impl Controls {
    pub fn new(ctx: Rc<Ctx>) -> Rc<Self> {
        let grid = tile_grid();
        grid.add_css_class("controls");
        grid.set_column_spacing(8);
        grid.set_row_spacing(8);

        let this = Rc::new(Self {
            stream: Tile::new(&grid, "network-transmit-receive-symbolic", "Diretta", "Avvia"),
            record: Tile::new(&grid, "media-record-symbolic", "Registra", "Avvia"),
            pause: Tile::new(&grid, "media-playback-pause-symbolic", "Pausa", "Registrazione"),
            vcam: Tile::new(&grid, "camera-web-symbolic", "Cam virtuale", "Spenta"),
            replay: Tile::new(&grid, "media-seek-backward-symbolic", "Replay", "Spento"),
            save_replay: Tile::new(&grid, "document-save-symbolic", "Salva replay", ""),
            studio: Tile::new(&grid, "view-dual-symbolic", "Studio Mode", "Off"),
            transition: Tile::new(&grid, "media-skip-forward-symbolic", "Transizione", "Anteprima → Live"),
            widget: grid,
            ctx,
            stream_phase: Cell::new(Phase::Off),
            record_phase: Cell::new(Phase::Off),
            studio_on: Cell::new(false),
        });
        this.connect();
        this.set_record(Phase::Off, false);
        this.set_vcam(None);
        this.set_replay(None);
        this.set_studio(false);
        this
    }

    fn connect(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.stream.button.connect_clicked(glib::clone!(
            #[strong]
            weak,
            move |_| {
                let Some(this) = weak.upgrade() else { return };
                this.toggle_guarded(
                    this.stream_phase.get().is_active(),
                    "Fermare la diretta?",
                    "La trasmissione verrà interrotta.",
                    "Ferma diretta",
                    Command::ToggleStream,
                );
            }
        ));
        self.record.button.connect_clicked(glib::clone!(
            #[strong]
            weak,
            move |_| {
                let Some(this) = weak.upgrade() else { return };
                this.toggle_guarded(
                    this.record_phase.get().is_active(),
                    "Fermare la registrazione?",
                    "Il file verrà chiuso.",
                    "Ferma registrazione",
                    Command::ToggleRecord,
                );
            }
        ));
        self.on_click(&self.pause, || Command::ToggleRecordPause);
        self.on_click(&self.vcam, || Command::ToggleVirtualCam);
        self.on_click(&self.replay, || Command::ToggleReplayBuffer);
        self.on_click(&self.save_replay, || Command::SaveReplay);
        self.on_click(&self.transition, || Command::Transition);
        self.studio.button.connect_clicked(glib::clone!(
            #[strong]
            weak,
            move |_| {
                if let Some(this) = weak.upgrade() {
                    this.ctx.send(Command::SetStudioMode(!this.studio_on.get()));
                }
            }
        ));
    }

    fn on_click(&self, tile: &Tile, cmd: impl Fn() -> Command + 'static) {
        let ctx = self.ctx.clone();
        tile.button.connect_clicked(move |_| ctx.send(cmd()));
    }

    /// Starting is immediate; stopping asks first when the user enabled confirmations.
    fn toggle_guarded(&self, active: bool, heading: &str, body: &str, accept: &str, cmd: Command) {
        if active && self.ctx.config.borrow().confirm_stop {
            let ctx = self.ctx.clone();
            let cmd = std::cell::RefCell::new(Some(cmd));
            self.ctx.confirm(heading, body, accept, move || {
                if let Some(cmd) = cmd.take() {
                    ctx.send(cmd);
                }
            });
        } else {
            self.ctx.send(cmd);
        }
    }

    pub fn set_stream(&self, phase: Phase) {
        self.stream_phase.set(phase);
        let (sub, classes): (&str, &[&str]) = match phase {
            Phase::Off => ("Avvia", &[]),
            Phase::Starting => ("Avvio…", &["live", "busy"]),
            Phase::On => ("IN ONDA", &["live"]),
            Phase::Stopping => ("Arresto…", &["live", "busy"]),
            Phase::Reconnecting => ("Riconnessione…", &["paused"]),
        };
        self.stream.sub.set_text(sub);
        self.stream.set_classes(classes);
    }

    pub fn set_record(&self, phase: Phase, paused: bool) {
        self.record_phase.set(phase);
        let (sub, classes): (&str, &[&str]) = match (phase, paused) {
            (Phase::Off, _) => ("Avvia", &[]),
            (Phase::Starting, _) => ("Avvio…", &["recording", "busy"]),
            (Phase::Stopping, _) => ("Arresto…", &["recording", "busy"]),
            (_, true) => ("IN PAUSA", &["paused"]),
            _ => ("REC", &["recording"]),
        };
        self.record.sub.set_text(sub);
        self.record.set_classes(classes);

        let active = phase.is_active();
        self.pause.button.set_sensitive(active);
        self.pause.set_classes(if paused { &["paused"] } else { &[] });
        self.pause.icon.set_icon_name(Some(if paused {
            "media-playback-start-symbolic"
        } else {
            "media-playback-pause-symbolic"
        }));
        self.pause.sub.set_text(if paused { "Riprendi" } else { "Registrazione" });
    }

    pub fn set_vcam(&self, phase: Option<Phase>) {
        self.vcam.child.set_visible(phase.is_some());
        let on = phase.is_some_and(Phase::is_active);
        self.vcam.sub.set_text(if on { "Attiva" } else { "Spenta" });
        self.vcam.set_classes(if on { &["on"] } else { &[] });
    }

    pub fn set_replay(&self, phase: Option<Phase>) {
        self.replay.child.set_visible(phase.is_some());
        self.save_replay.child.set_visible(phase.is_some());
        let on = phase.is_some_and(Phase::is_active);
        self.replay.sub.set_text(if on { "Attivo" } else { "Spento" });
        self.replay.set_classes(if on { &["on"] } else { &[] });
        self.save_replay.button.set_sensitive(on);
    }

    pub fn set_studio(&self, on: bool) {
        self.studio_on.set(on);
        self.studio.sub.set_text(if on { "On" } else { "Off" });
        self.studio.set_classes(if on { &["on"] } else { &[] });
        self.transition.child.set_visible(on);
    }

    pub fn set_timecodes(&self, stream: Option<Duration>, record: Option<Duration>) {
        if let (Some(d), Phase::On) = (stream, self.stream_phase.get()) {
            self.stream.sub.set_text(&format_duration(d));
        }
        if let (Some(d), Phase::On) = (record, self.record_phase.get()) {
            // Keep "IN PAUSA" visible while paused; OBS keeps reporting the frozen time.
            if !self.record.button.has_css_class("paused") {
                self.record.sub.set_text(&format_duration(d));
            }
        }
    }
}

fn format_duration(d: Duration) -> String {
    let s = d.as_secs();
    format!("{:02}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
}
