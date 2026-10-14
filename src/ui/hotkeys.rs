//! Every hotkey OBS exposes, grouped and searchable, plus a favorites section.
//!
//! OBS registers some hotkeys once per source (mute, show/hide item, select scene...), so the
//! same name shows up several times in GetHotkeyList. Those tiles open a chooser to pick the
//! source, since TriggerHotkeyByName needs the context name to target the right one.
//!
//! The same listing doubles as a picker (see [`HotkeysPage::present_picker`]) for the panel.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::{Rc, Weak};

use adw::prelude::*;
use gtk::glib;

use super::{Ctx, TextAnswer, ask_text, grid_child, on_hold_or_secondary, section_title, sheet, tile_grid};
use crate::config::{Favorite, alias_key};
use crate::hotkey_names;
use crate::obs::Command;

/// Hold-to-use hotkeys: TriggerHotkeyByName presses and releases instantly, so they do nothing useful.
const PRESS_AND_HOLD: &[&str] = &["libobs.push-to-mute", "libobs.push-to-talk"];

/// Called with (hotkey name, context) when a hotkey is picked.
pub type OnPick = Rc<dyn Fn(String, Option<String>)>;

/// Picker mode: what to call, and the picker dialog to close afterwards.
#[derive(Clone)]
struct Pick {
    on_pick: OnPick,
    dialog: glib::WeakRef<adw::Dialog>,
}

impl Pick {
    fn pick(&self, name: String, context: Option<String>) {
        (self.on_pick)(name, context);
        if let Some(dialog) = self.dialog.upgrade() {
            dialog.close();
        }
    }
}

pub struct HotkeysPage {
    pub widget: gtk::Box,
    search: gtk::SearchEntry,
    content: gtk::Box,
    ctx: Rc<Ctx>,
    hotkeys: RefCell<Vec<String>>,
    scenes: RefCell<Vec<String>>,
    inputs: RefCell<Vec<String>>,
    audio: RefCell<Vec<String>>,
}

impl HotkeysPage {
    pub fn new(ctx: Rc<Ctx>) -> Rc<Self> {
        let search = search_entry();
        let search_bar = adw::Clamp::builder().maximum_size(720).child(&search).build();
        search_bar.set_margin_top(12);
        search_bar.set_margin_start(12);
        search_bar.set_margin_end(12);

        let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
        content.add_css_class("page-content");
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&content)
            .vexpand(true)
            .build();

        let widget = gtk::Box::new(gtk::Orientation::Vertical, 0);
        widget.append(&search_bar);
        widget.append(&scroll);

        let this = Rc::new(Self {
            widget,
            search,
            content,
            ctx,
            hotkeys: RefCell::default(),
            scenes: RefCell::default(),
            inputs: RefCell::default(),
            audio: RefCell::default(),
        });
        let weak = Rc::downgrade(&this);
        this.search.connect_search_changed(move |_| {
            if let Some(this) = weak.upgrade() {
                this.rebuild();
            }
        });
        // Aliases may have been edited elsewhere (e.g. the panel); refresh when shown.
        let weak = Rc::downgrade(&this);
        this.widget.connect_map(move |_| {
            if let Some(this) = weak.upgrade() {
                this.rebuild();
            }
        });
        this.rebuild();
        this
    }

    pub fn set_hotkeys(self: &Rc<Self>, list: Vec<String>) {
        *self.hotkeys.borrow_mut() = list;
        self.rebuild();
    }

    pub fn set_scenes(&self, list: Vec<String>) {
        *self.scenes.borrow_mut() = list;
    }

    pub fn set_inputs(&self, list: Vec<String>) {
        *self.inputs.borrow_mut() = list;
    }

    pub fn set_audio_inputs(&self, list: Vec<String>) {
        *self.audio.borrow_mut() = list;
    }

    pub fn exists(&self, name: &str) -> bool {
        self.hotkeys.borrow().iter().any(|h| h == name)
    }

    /// Display title for a hotkey: user alias, else the friendly default label.
    pub fn title(&self, name: &str, context: Option<&str>) -> String {
        self.ctx
            .config
            .borrow()
            .aliases
            .get(&alias_key(name, context))
            .cloned()
            .unwrap_or_else(|| hotkey_names::label(name))
    }

    fn rebuild(self: &Rc<Self>) {
        let query = self.search.text();
        self.populate(&self.content, &query, None);
    }

    /// Opens the full hotkey listing as a searchable dialog; tapping a tile picks it.
    pub fn present_picker(self: &Rc<Self>, on_pick: OnPick) {
        let search = search_entry();
        search.set_margin_start(12);
        search.set_margin_end(12);
        search.set_margin_bottom(6);
        let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
        body.add_css_class("page-content");
        let dialog = sheet("Scegli una scorciatoia", &body, Some(search.upcast_ref()));

        let pick = Pick { on_pick, dialog: dialog.downgrade() };
        self.populate(&body, "", Some(&pick));
        let weak = Rc::downgrade(self);
        search.connect_search_changed(move |entry| {
            if let Some(this) = weak.upgrade() {
                this.populate(&body, &entry.text(), Some(&pick));
            }
        });
        dialog.present(self.ctx.window().as_ref());
    }

    fn populate(self: &Rc<Self>, container: &gtk::Box, query: &str, pick: Option<&Pick>) {
        while let Some(child) = container.first_child() {
            container.remove(&child);
        }

        let query = query.to_lowercase();
        let matches = |texts: &[&str]| query.is_empty() || texts.iter().any(|t| t.to_lowercase().contains(&query));

        // Favorites
        let (favorites, aliases) = {
            let cfg = self.ctx.config.borrow();
            (cfg.favorites.clone(), cfg.aliases.clone())
        };
        let alias_of = |name: &str, context: Option<&str>| {
            aliases.get(&alias_key(name, context)).map(String::as_str).unwrap_or_default()
        };
        let fav_grid = tile_grid();
        let mut fav_count = 0;
        for fav in favorites {
            let label = hotkey_names::label(&fav.name);
            let ctx_name = fav.context.as_deref().unwrap_or_default();
            if !matches(&[&label, &fav.name, ctx_name, alias_of(&fav.name, fav.context.as_deref())]) {
                continue;
            }
            fav_grid.append(&self.tile(&fav.name, fav.context.as_deref(), false, pick));
            fav_count += 1;
        }
        if fav_count > 0 {
            container.append(&section_title("★ Preferiti"));
            container.append(&fav_grid);
        }

        // Count duplicates, keep first-seen order.
        let hotkeys = self.hotkeys.borrow();
        let mut counts: HashMap<&str, usize> = HashMap::new();
        let mut unique: Vec<&str> = Vec::new();
        for name in hotkeys.iter().filter(|n| !PRESS_AND_HOLD.contains(&n.as_str())) {
            let count = counts.entry(name).or_insert(0);
            if *count == 0 {
                unique.push(name);
            }
            *count += 1;
        }

        // Group: "OBS" first, then alphabetical.
        let mut groups: BTreeMap<(u8, String), Vec<&str>> = BTreeMap::new();
        for name in unique {
            let label = hotkey_names::label(name);
            if !matches(&[&label, name, alias_of(name, None)]) {
                continue;
            }
            let group = hotkey_names::group(name);
            let key = (u8::from(group != "OBS"), group);
            groups.entry(key).or_default().push(name);
        }

        for ((_, group), names) in groups {
            container.append(&section_title(&group));
            let grid = tile_grid();
            for name in names {
                grid.append(&self.tile(name, None, counts[name] > 1, pick));
            }
            container.append(&grid);
        }

        if container.first_child().is_none() {
            let empty = adw::StatusPage::builder()
                .icon_name("input-keyboard-symbolic")
                .title(if query.is_empty() { "Nessuna scorciatoia" } else { "Nessun risultato" })
                .vexpand(true)
                .build();
            container.append(&empty);
        }
    }

    /// A hotkey tile. `multi` hotkeys exist once per source and open the source chooser.
    /// In picker mode tiles pick instead of triggering, with no star or rename.
    fn tile(self: &Rc<Self>, name: &str, context: Option<&str>, multi: bool, pick: Option<&Pick>) -> gtk::FlowBoxChild {
        let key = alias_key(name, context);
        let default_label = hotkey_names::label(name);
        let alias = self.ctx.config.borrow().aliases.get(&key).cloned();

        let mut sub_parts: Vec<&str> = Vec::new();
        if alias.is_some() {
            sub_parts.push(&default_label);
        }
        match (context, multi) {
            (_, true) => sub_parts.push("Scegli sorgente…"),
            (Some(c), false) => sub_parts.push(c),
            (None, false) if alias.is_none() => sub_parts.push(name),
            _ => {}
        }
        let title = alias.as_deref().unwrap_or(&default_label);
        let fav = Favorite { name: name.to_owned(), context: context.map(str::to_owned) };
        let star = (!multi && pick.is_none()).then(|| (self.ctx.clone(), Rc::downgrade(self), fav.clone()));
        let tile = build_tile(title, &sub_parts.join(" · "), multi, star);

        let weak = Rc::downgrade(self);
        let pick = pick.cloned();
        let is_picker = pick.is_some();
        tile.button.connect_clicked(move |_| {
            let Some(this) = weak.upgrade() else { return };
            match (&pick, multi) {
                (_, true) => this.choose_source(&fav.name, pick.clone()),
                (Some(pick), false) => pick.pick(fav.name.clone(), fav.context.clone()),
                (None, false) => this.ctx.send(Command::TriggerHotkey {
                    name: fav.name.clone(),
                    context: fav.context.clone(),
                }),
            }
        });

        if !is_picker {
            let weak = Rc::downgrade(self);
            on_hold_or_secondary(&tile.button, move || {
                if let Some(this) = weak.upgrade() {
                    this.rename(&key, &default_label, alias.as_deref());
                }
            });
        }

        grid_child(&tile.root)
    }

    /// Lets the user give a tile its own name (e.g. a plugin hotkey OBS only exposes by its
    /// internal name). Empty or "Ripristina" goes back to the default label.
    fn rename(self: &Rc<Self>, key: &str, default_label: &str, current: Option<&str>) {
        let weak = Rc::downgrade(self);
        let key = key.to_owned();
        ask_text(
            &self.ctx,
            "Rinomina riquadro",
            &format!("Nome originale: {default_label}"),
            current.unwrap_or(default_label),
            current.is_some(),
            move |answer| {
                let Some(this) = weak.upgrade() else { return };
                {
                    let mut cfg = this.ctx.config.borrow_mut();
                    match answer {
                        TextAnswer::Set(text) => cfg.aliases.insert(key.clone(), text),
                        TextAnswer::Reset => cfg.aliases.remove(&key),
                    };
                }
                this.ctx.save_config();
                this.rebuild();
            },
        );
    }

    fn candidates(&self, name: &str) -> Vec<(&'static str, Vec<String>)> {
        let scenes = self.scenes.borrow().clone();
        if name == "OBSBasic.SelectScene" || name.starts_with("libobs.show_scene_item") || name.starts_with("libobs.hide_scene_item") {
            return vec![("Scene", scenes)];
        }
        if name == "libobs.mute" || name == "libobs.unmute" {
            return vec![("Sorgenti audio", self.audio.borrow().clone())];
        }
        vec![("Sorgenti", self.inputs.borrow().clone()), ("Scene", scenes)]
    }

    /// Dialog listing the sources a per-source hotkey can target.
    fn choose_source(self: &Rc<Self>, name: &str, pick: Option<Pick>) {
        let body = gtk::Box::new(gtk::Orientation::Vertical, 12);
        body.add_css_class("page-content");
        let dialog = sheet(&self.title(name, None), &body, None);

        for (title, sources) in self.candidates(name) {
            if sources.is_empty() {
                continue;
            }
            body.append(&section_title(title));
            let grid = tile_grid();
            for source in sources {
                let fav = Favorite { name: name.to_owned(), context: Some(source.clone()) };
                let star = pick.is_none().then(|| (self.ctx.clone(), Rc::downgrade(self), fav.clone()));
                let tile = build_tile(&source, "", false, star);
                let ctx = self.ctx.clone();
                let pick = pick.clone();
                tile.button.connect_clicked(glib::clone!(
                    #[weak]
                    dialog,
                    move |_| {
                        match &pick {
                            Some(pick) => pick.pick(fav.name.clone(), fav.context.clone()),
                            None => ctx.send(Command::TriggerHotkey {
                                name: fav.name.clone(),
                                context: fav.context.clone(),
                            }),
                        }
                        dialog.close();
                    }
                ));
                grid.append(&grid_child(&tile.root));
            }
            body.append(&grid);
        }

        dialog.present(self.ctx.window().as_ref());
    }
}

fn search_entry() -> gtk::SearchEntry {
    gtk::SearchEntry::builder()
        .placeholder_text("Cerca scorciatoia…")
        .hexpand(true)
        .build()
}

struct Tile {
    root: gtk::Overlay,
    button: gtk::Button,
}

fn build_tile(label: &str, sub: &str, multi: bool, star: Option<(Rc<Ctx>, Weak<HotkeysPage>, Favorite)>) -> Tile {
    let title = gtk::Label::builder()
        .label(label)
        .wrap(true)
        .wrap_mode(gtk::pango::WrapMode::WordChar)
        .lines(2)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .xalign(0.0)
        .build();
    title.add_css_class("hotkey-label");

    let content = gtk::Box::new(gtk::Orientation::Vertical, 4);
    content.set_valign(gtk::Align::Center);
    content.append(&title);
    if !sub.is_empty() {
        let sub = gtk::Label::builder()
            .label(sub)
            .ellipsize(gtk::pango::EllipsizeMode::Middle)
            .xalign(0.0)
            .build();
        sub.add_css_class("hotkey-sub");
        content.append(&sub);
    }

    let button = gtk::Button::builder().child(&content).tooltip_text(label).build();
    button.add_css_class("hotkey-tile");
    if multi {
        button.add_css_class("multi");
    }

    let root = gtk::Overlay::new();
    root.set_child(Some(&button));

    if let Some((ctx, page, fav)) = star {
        let active = ctx.config.borrow().is_favorite(&fav);
        let star = gtk::ToggleButton::builder()
            .icon_name(if active { "starred-symbolic" } else { "non-starred-symbolic" })
            .active(active)
            .halign(gtk::Align::End)
            .valign(gtk::Align::Start)
            .tooltip_text("Preferito")
            .build();
        star.add_css_class("flat");
        star.add_css_class("circular");
        star.add_css_class("star-button");
        // Leave room on the right so the label never runs under the star.
        content.set_margin_end(36);
        star.connect_toggled(move |btn| {
            btn.set_icon_name(if btn.is_active() { "starred-symbolic" } else { "non-starred-symbolic" });
            ctx.config.borrow_mut().toggle_favorite(fav.clone());
            ctx.save_config();
            // Rebuild after the signal returns: this button is about to be destroyed.
            let page = page.clone();
            glib::idle_add_local_once(move || {
                if let Some(page) = page.upgrade() {
                    page.rebuild();
                }
            });
        });
        root.add_overlay(&star);
    }

    Tile { root, button }
}
