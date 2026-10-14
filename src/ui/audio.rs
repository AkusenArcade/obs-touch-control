//! Audio mixer: one card per audio input with a volume fader and a big mute button.
//! Cards live in a responsive grid, so wide screens show several mixer columns.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;

use super::{Ctx, grid_child, tile_grid};
use crate::obs::{AudioInput, Command, MIN_DB};

struct AudioRow {
    mute: gtk::Button,
    scale: gtk::Scale,
    db_label: gtk::Label,
    /// Set while applying a value coming from OBS, so it is not echoed back.
    syncing: Rc<Cell<bool>>,
}

pub struct AudioPage {
    pub widget: gtk::Stack,
    grid: gtk::FlowBox,
    ctx: Rc<Ctx>,
    rows: RefCell<HashMap<String, AudioRow>>,
}

impl AudioPage {
    pub fn new(ctx: Rc<Ctx>) -> Rc<Self> {
        let grid = tile_grid();
        grid.add_css_class("page-content");
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&grid)
            .vexpand(true)
            .build();
        let empty = adw::StatusPage::builder()
            .icon_name("audio-speakers-symbolic")
            .title("Nessuna sorgente audio")
            .build();

        let widget = gtk::Stack::new();
        widget.add_named(&empty, Some("empty"));
        widget.add_named(&scroll, Some("grid"));

        Rc::new(Self { widget, grid, ctx, rows: RefCell::default() })
    }

    pub fn set_inputs(&self, inputs: Vec<AudioInput>) {
        self.grid.remove_all();
        let mut rows = HashMap::new();
        for input in &inputs {
            let (card, row) = self.build_row(input);
            self.grid.append(&grid_child(&card));
            rows.insert(input.name.clone(), row);
        }
        self.widget.set_visible_child_name(if inputs.is_empty() { "empty" } else { "grid" });
        *self.rows.borrow_mut() = rows;
    }

    fn build_row(&self, input: &AudioInput) -> (gtk::Box, AudioRow) {
        let name = gtk::Label::builder()
            .label(&input.name)
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .tooltip_text(&input.name)
            .build();
        name.add_css_class("audio-name");
        let db_label = gtk::Label::builder().xalign(1.0).build();
        db_label.add_css_class("db-label");
        db_label.add_css_class("dim-label");

        let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        header.append(&name);
        header.append(&db_label);

        let scale = gtk::Scale::with_range(gtk::Orientation::Horizontal, MIN_DB.into(), 0.0, 0.5);
        scale.set_hexpand(true);
        scale.set_draw_value(false);
        scale.add_mark(-20.0, gtk::PositionType::Bottom, None);
        scale.add_mark(-10.0, gtk::PositionType::Bottom, None);

        let mute = gtk::Button::new();
        mute.add_css_class("mute-button");
        mute.set_valign(gtk::Align::Center);

        let controls = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        controls.append(&scale);
        controls.append(&mute);

        let card = gtk::Box::new(gtk::Orientation::Vertical, 4);
        card.add_css_class("card");
        card.add_css_class("audio-row");
        card.append(&header);
        card.append(&controls);

        let row = AudioRow { mute, scale, db_label, syncing: Rc::new(Cell::new(false)) };
        apply_volume(&row, input.volume_db);
        apply_mute(&row, input.muted);

        let ctx = self.ctx.clone();
        let input_name = input.name.clone();
        row.mute.connect_clicked(move |_| ctx.send(Command::ToggleMute(input_name.clone())));

        let ctx = self.ctx.clone();
        let input_name = input.name.clone();
        let syncing = row.syncing.clone();
        let label = row.db_label.clone();
        row.scale.connect_value_changed(move |scale| {
            let db = scale.value() as f32;
            label.set_text(&format_db(db));
            if !syncing.get() {
                ctx.send(Command::SetVolume(input_name.clone(), db));
            }
        });

        (card, row)
    }

    pub fn set_muted(&self, name: &str, muted: bool) {
        if let Some(row) = self.rows.borrow().get(name) {
            apply_mute(row, muted);
        }
    }

    pub fn set_volume(&self, name: &str, db: f32) {
        if let Some(row) = self.rows.borrow().get(name) {
            apply_volume(row, db);
        }
    }
}

fn apply_mute(row: &AudioRow, muted: bool) {
    if muted {
        row.mute.add_css_class("muted");
        row.mute.set_icon_name("audio-volume-muted-symbolic");
        row.mute.set_tooltip_text(Some("Riattiva audio"));
    } else {
        row.mute.remove_css_class("muted");
        row.mute.set_icon_name("audio-volume-high-symbolic");
        row.mute.set_tooltip_text(Some("Silenzia"));
    }
}

fn apply_volume(row: &AudioRow, db: f32) {
    let db = if db.is_finite() { db.max(MIN_DB) } else { MIN_DB };
    // Skip echoes of our own fader moves so dragging stays smooth.
    if (row.scale.value() as f32 - db).abs() < 0.1 && !row.db_label.text().is_empty() {
        return;
    }
    row.syncing.set(true);
    row.scale.set_value(db.into());
    row.syncing.set(false);
    row.db_label.set_text(&format_db(db));
}

fn format_db(db: f32) -> String {
    if db <= MIN_DB { "-∞ dB".into() } else { format!("{db:.1} dB") }
}
