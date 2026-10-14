//! Custom panel: big buttons the user picks and orders freely — scenes, hotkeys and
//! audio mute toggles mixed together. Layout and labels are stored in the config.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;

use super::hotkeys::HotkeysPage;
use super::{Ctx, TextAnswer, ask_text, grid_child, section_title, sheet, tile_grid};
use crate::config::{PanelAction, PanelItem};
use crate::obs::Command;

/// (title, icon, names, how to build the action for a name) in the add dialog.
type AddSection = (&'static str, &'static str, Vec<String>, fn(String) -> PanelAction);

struct PanelTile {
    action: PanelAction,
    button: gtk::Button,
    icon: gtk::Image,
    sub: gtk::Label,
}

pub struct PanelPage {
    pub widget: gtk::Box,
    stack: gtk::Stack,
    grid: gtk::FlowBox,
    edit: gtk::ToggleButton,
    ctx: Rc<Ctx>,
    hotkeys: Rc<HotkeysPage>,
    tiles: RefCell<Vec<PanelTile>>,
    scenes: RefCell<Vec<String>>,
    program: RefCell<Option<String>>,
    preview: RefCell<Option<String>>,
    studio: Cell<bool>,
    /// Audio input name -> muted.
    audio: RefCell<HashMap<String, bool>>,
}

impl PanelPage {
    pub fn new(ctx: Rc<Ctx>, hotkeys: Rc<HotkeysPage>) -> Rc<Self> {
        let edit = gtk::ToggleButton::builder().label("Modifica").build();
        edit.add_css_class("pill");
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        bar.set_halign(gtk::Align::End);
        bar.set_margin_top(12);
        bar.set_margin_end(16);
        bar.append(&edit);

        let grid = tile_grid();
        grid.add_css_class("page-content");
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&grid)
            .vexpand(true)
            .build();

        let add_first = gtk::Button::with_label("Aggiungi pulsanti");
        add_first.add_css_class("pill");
        add_first.add_css_class("suggested-action");
        add_first.add_css_class("big-button");
        add_first.set_halign(gtk::Align::Center);
        let empty = adw::StatusPage::builder()
            .icon_name("view-app-grid-symbolic")
            .title("Il tuo pannello è vuoto")
            .description("Componi una schermata con scene, scorciatoie e controlli audio nell'ordine che preferisci.")
            .child(&add_first)
            .vexpand(true)
            .build();

        let stack = gtk::Stack::new();
        stack.add_named(&empty, Some("empty"));
        stack.add_named(&scroll, Some("grid"));

        let widget = gtk::Box::new(gtk::Orientation::Vertical, 0);
        widget.append(&bar);
        widget.append(&stack);

        let this = Rc::new(Self {
            widget,
            stack,
            grid,
            edit,
            ctx,
            hotkeys,
            tiles: RefCell::default(),
            scenes: RefCell::default(),
            program: RefCell::default(),
            preview: RefCell::default(),
            studio: Cell::new(false),
            audio: RefCell::default(),
        });

        let weak = Rc::downgrade(&this);
        this.edit.connect_toggled(move |btn| {
            btn.set_label(if btn.is_active() { "Fine" } else { "Modifica" });
            if btn.is_active() {
                btn.add_css_class("suggested-action");
            } else {
                btn.remove_css_class("suggested-action");
            }
            if let Some(this) = weak.upgrade() {
                this.rebuild();
            }
        });
        let weak = Rc::downgrade(&this);
        add_first.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.present_add();
            }
        });
        // Hotkey aliases can change on the Scorciatoie page; refresh titles when shown.
        let weak = Rc::downgrade(&this);
        this.widget.connect_map(move |_| {
            if let Some(this) = weak.upgrade() {
                this.rebuild();
            }
        });

        this.rebuild();
        this
    }

    // ---- State from OBS ----

    pub fn set_scenes(self: &Rc<Self>, list: Vec<String>) {
        *self.scenes.borrow_mut() = list;
        self.restyle();
    }

    pub fn set_program(&self, name: Option<String>) {
        *self.program.borrow_mut() = name;
        self.restyle();
    }

    pub fn set_preview(&self, name: Option<String>) {
        *self.preview.borrow_mut() = name;
        self.restyle();
    }

    pub fn set_studio(&self, on: bool) {
        self.studio.set(on);
        self.restyle();
    }

    pub fn set_audio(&self, inputs: impl IntoIterator<Item = (String, bool)>) {
        *self.audio.borrow_mut() = inputs.into_iter().collect();
        self.restyle();
    }

    pub fn set_muted(&self, name: &str, muted: bool) {
        if let Some(m) = self.audio.borrow_mut().get_mut(name) {
            *m = muted;
        }
        self.restyle();
    }

    /// Hotkey list changed: titles/availability may differ.
    pub fn hotkeys_changed(self: &Rc<Self>) {
        self.rebuild();
    }

    // ---- Layout ----

    fn editing(&self) -> bool {
        self.edit.is_active()
    }

    fn rebuild(self: &Rc<Self>) {
        self.grid.remove_all();
        let items = self.ctx.config.borrow().panel.clone();
        let editing = self.editing();

        let mut tiles = Vec::with_capacity(items.len());
        for (index, item) in items.iter().enumerate() {
            let (child, tile) = self.build_tile(index, item, items.len(), editing);
            self.grid.append(&child);
            tiles.push(tile);
        }
        if editing {
            self.grid.append(&self.add_tile());
        }

        self.edit.set_visible(!items.is_empty() || editing);
        self.stack.set_visible_child_name(if items.is_empty() && !editing { "empty" } else { "grid" });
        *self.tiles.borrow_mut() = tiles;
        self.restyle();
    }

    fn default_title(&self, action: &PanelAction) -> String {
        match action {
            PanelAction::Scene { name } => name.clone(),
            PanelAction::Mute { input } => input.clone(),
            PanelAction::Hotkey { name, context } => self.hotkeys.title(name, context.as_deref()),
        }
    }

    fn build_tile(self: &Rc<Self>, index: usize, item: &PanelItem, count: usize, editing: bool) -> (gtk::FlowBoxChild, PanelTile) {
        let title_text = item.label.clone().unwrap_or_else(|| self.default_title(&item.action));

        let icon = gtk::Image::new();
        icon.set_pixel_size(28);
        icon.add_css_class("tile-icon");
        let title = gtk::Label::builder()
            .label(&title_text)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .justify(gtk::Justification::Center)
            .lines(3)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let sub = gtk::Label::new(None);
        sub.add_css_class("badge");
        sub.set_ellipsize(gtk::pango::EllipsizeMode::End);

        let content = gtk::Box::new(gtk::Orientation::Vertical, 6);
        content.set_valign(gtk::Align::Center);
        content.append(&icon);
        content.append(&title);
        content.append(&sub);

        let button = gtk::Button::builder().child(&content).tooltip_text(&title_text).build();
        button.add_css_class("scene-tile");
        button.add_css_class("panel-tile");

        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&button));

        if editing {
            button.add_css_class("editing");
            // Leave room for the edit bar at the bottom.
            content.set_margin_bottom(44);
            overlay.add_overlay(&self.edit_bar(index, count, &title_text, item.label.is_some()));
            let weak = Rc::downgrade(self);
            let current = title_text.clone();
            let has_label = item.label.is_some();
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.rename(index, &current, has_label);
                }
            });
        } else {
            let weak = Rc::downgrade(self);
            let action = item.action.clone();
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.run(&action);
                }
            });
        }

        let tile = PanelTile { action: item.action.clone(), button, icon, sub };
        (grid_child(&overlay), tile)
    }

    fn edit_bar(self: &Rc<Self>, index: usize, count: usize, title: &str, has_label: bool) -> gtk::Box {
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        bar.add_css_class("edit-bar");
        bar.set_halign(gtk::Align::Center);
        bar.set_valign(gtk::Align::End);
        bar.set_margin_bottom(8);

        let mk = |icon: &str, tip: &str, enabled: bool| {
            let b = gtk::Button::from_icon_name(icon);
            b.set_tooltip_text(Some(tip));
            b.add_css_class("circular");
            b.add_css_class("osd");
            b.set_sensitive(enabled);
            bar.append(&b);
            b
        };
        let left = mk("go-previous-symbolic", "Sposta prima", index > 0);
        let rename = mk("document-edit-symbolic", "Rinomina", true);
        let right = mk("go-next-symbolic", "Sposta dopo", index + 1 < count);
        let remove = mk("user-trash-symbolic", "Rimuovi", true);
        remove.add_css_class("destructive-action");

        let weak = Rc::downgrade(self);
        left.connect_clicked(glib::clone!(#[strong] weak, move |_| {
            if let Some(this) = weak.upgrade() {
                this.edit_items(|items| items.swap(index, index - 1));
            }
        }));
        right.connect_clicked(glib::clone!(#[strong] weak, move |_| {
            if let Some(this) = weak.upgrade() {
                this.edit_items(|items| items.swap(index, index + 1));
            }
        }));
        remove.connect_clicked(glib::clone!(#[strong] weak, move |_| {
            if let Some(this) = weak.upgrade() {
                this.edit_items(|items| {
                    items.remove(index);
                });
            }
        }));
        let title = title.to_owned();
        rename.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.rename(index, &title, has_label);
            }
        });
        bar
    }

    fn add_tile(self: &Rc<Self>) -> gtk::FlowBoxChild {
        let icon = gtk::Image::from_icon_name("list-add-symbolic");
        icon.set_pixel_size(36);
        let label = gtk::Label::new(Some("Aggiungi"));
        let content = gtk::Box::new(gtk::Orientation::Vertical, 6);
        content.set_valign(gtk::Align::Center);
        content.append(&icon);
        content.append(&label);
        let button = gtk::Button::builder().child(&content).build();
        button.add_css_class("scene-tile");
        button.add_css_class("add-tile");
        let weak = Rc::downgrade(self);
        button.connect_clicked(move |_| {
            if let Some(this) = weak.upgrade() {
                this.present_add();
            }
        });
        grid_child(&button)
    }

    /// Updates live state (on air, muted, missing) without rebuilding widgets.
    fn restyle(&self) {
        let scenes = self.scenes.borrow();
        let program = self.program.borrow();
        let preview = self.preview.borrow();
        let studio = self.studio.get();
        let audio = self.audio.borrow();
        let editing = self.editing();

        for tile in self.tiles.borrow().iter() {
            for c in ["program", "preview", "muted", "missing"] {
                tile.button.remove_css_class(c);
            }
            let (class, sub, icon, available): (Option<&str>, String, &str, bool) = match &tile.action {
                PanelAction::Scene { name } => {
                    let exists = scenes.contains(name);
                    if program.as_deref() == Some(name.as_str()) {
                        (Some("program"), "● IN ONDA".into(), "view-grid-symbolic", true)
                    } else if studio && preview.as_deref() == Some(name.as_str()) {
                        (Some("preview"), "ANTEPRIMA".into(), "view-grid-symbolic", true)
                    } else if exists {
                        (None, "SCENA".into(), "view-grid-symbolic", true)
                    } else {
                        (Some("missing"), "Scena non trovata".into(), "view-grid-symbolic", false)
                    }
                }
                PanelAction::Mute { input } => match audio.get(input) {
                    Some(true) => (Some("muted"), "SILENZIATO".into(), "audio-volume-muted-symbolic", true),
                    Some(false) => (None, "AUDIO ATTIVO".into(), "audio-volume-high-symbolic", true),
                    None => (Some("missing"), "Sorgente non trovata".into(), "audio-volume-muted-symbolic", false),
                },
                PanelAction::Hotkey { name, context } => {
                    if self.hotkeys.exists(name) {
                        let sub = context.clone().unwrap_or_else(|| "SCORCIATOIA".into());
                        (None, sub, "input-keyboard-symbolic", true)
                    } else {
                        (Some("missing"), "Non disponibile".into(), "input-keyboard-symbolic", false)
                    }
                }
            };
            if let Some(class) = class {
                tile.button.add_css_class(class);
            }
            tile.sub.set_text(&sub);
            tile.icon.set_icon_name(Some(icon));
            // Missing targets stay editable (to remove them) but cannot be fired.
            tile.button.set_sensitive(available || editing);
        }
    }

    // ---- Actions ----

    fn run(&self, action: &PanelAction) {
        let cmd = match action {
            PanelAction::Scene { name } if self.studio.get() => Command::SetPreviewScene(name.clone()),
            PanelAction::Scene { name } => Command::SetProgramScene(name.clone()),
            PanelAction::Hotkey { name, context } => Command::TriggerHotkey { name: name.clone(), context: context.clone() },
            PanelAction::Mute { input } => Command::ToggleMute(input.clone()),
        };
        self.ctx.send(cmd);
    }

    fn edit_items(self: &Rc<Self>, f: impl FnOnce(&mut Vec<PanelItem>)) {
        f(&mut self.ctx.config.borrow_mut().panel);
        self.ctx.save_config();
        // Defer: the clicked button is destroyed by the rebuild.
        let this = self.clone();
        glib::idle_add_local_once(move || this.rebuild());
    }

    fn add(self: &Rc<Self>, action: PanelAction) {
        self.edit_items(|items| items.push(PanelItem { action, label: None }));
        self.ctx.toast("Pulsante aggiunto al pannello");
    }

    fn rename(self: &Rc<Self>, index: usize, current: &str, has_label: bool) {
        let weak = Rc::downgrade(self);
        ask_text(&self.ctx, "Rinomina pulsante", "", current, has_label, move |answer| {
            let Some(this) = weak.upgrade() else { return };
            this.edit_items(|items| {
                if let Some(item) = items.get_mut(index) {
                    item.label = match answer {
                        TextAnswer::Set(text) => Some(text),
                        TextAnswer::Reset => None,
                    };
                }
            });
        });
    }

    /// Dialog to add a scene, a hotkey or a mute toggle.
    fn present_add(self: &Rc<Self>) {
        let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
        body.add_css_class("page-content");
        let dialog = sheet("Aggiungi pulsante", &body, None);

        let choice = |label: &str, sub: &str, icon: &str| {
            let image = gtk::Image::from_icon_name(icon);
            image.set_pixel_size(24);
            let title = gtk::Label::builder()
                .label(label)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .justify(gtk::Justification::Center)
                .build();
            let content = gtk::Box::new(gtk::Orientation::Vertical, 4);
            content.set_valign(gtk::Align::Center);
            content.append(&image);
            content.append(&title);
            if !sub.is_empty() {
                let sub = gtk::Label::new(Some(sub));
                sub.add_css_class("badge");
                content.append(&sub);
            }
            let button = gtk::Button::builder().child(&content).build();
            button.add_css_class("hotkey-tile");
            button
        };

        // Hotkeys: hand over to the full searchable picker.
        body.append(&section_title("Scorciatoie"));
        let grid = tile_grid();
        let pick_hotkey = choice("Scegli una scorciatoia…", "", "input-keyboard-symbolic");
        let weak = Rc::downgrade(self);
        pick_hotkey.connect_clicked(glib::clone!(#[weak] dialog, move |_| {
            let Some(this) = weak.upgrade() else { return };
            dialog.close();
            let weak = Rc::downgrade(&this);
            this.hotkeys.present_picker(Rc::new(move |name, context| {
                if let Some(this) = weak.upgrade() {
                    this.add(PanelAction::Hotkey { name, context });
                }
            }));
        }));
        grid.append(&grid_child(&pick_hotkey));
        body.append(&grid);

        let sections: [AddSection; 2] = [
            ("Scene", "view-grid-symbolic", self.scenes.borrow().clone(), |name| PanelAction::Scene { name }),
            ("Audio: muto / riattiva", "audio-volume-high-symbolic", {
                let mut names: Vec<String> = self.audio.borrow().keys().cloned().collect();
                names.sort();
                names
            }, |input| PanelAction::Mute { input }),
        ];
        for (title, icon, names, make) in sections {
            body.append(&section_title(title));
            if names.is_empty() {
                let none = gtk::Label::builder().label("Nessuna disponibile (connettiti a OBS)").xalign(0.0).build();
                none.add_css_class("dim-label");
                body.append(&none);
                continue;
            }
            let grid = tile_grid();
            for name in names {
                let button = choice(&name, "", icon);
                let weak = Rc::downgrade(self);
                button.connect_clicked(glib::clone!(#[weak] dialog, move |_| {
                    if let Some(this) = weak.upgrade() {
                        this.add(make(name.clone()));
                    }
                    dialog.close();
                }));
                grid.append(&grid_child(&button));
            }
            body.append(&grid);
        }

        // Adding from the empty state should leave the user in edit mode to arrange things.
        self.edit.set_active(true);
        dialog.present(self.ctx.window().as_ref());
    }
}
