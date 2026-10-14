//! Scene grid. Tap switches the program scene, or the preview scene in Studio Mode.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use adw::prelude::*;

use super::{Ctx, grid_child, tile_grid};
use crate::obs::Command;

struct SceneTile {
    name: String,
    button: gtk::Button,
    badge: gtk::Label,
}

pub struct ScenesPage {
    pub widget: gtk::Stack,
    grid: gtk::FlowBox,
    ctx: Rc<Ctx>,
    tiles: RefCell<Vec<SceneTile>>,
    program: RefCell<Option<String>>,
    preview: RefCell<Option<String>>,
    studio: Cell<bool>,
}

impl ScenesPage {
    pub fn new(ctx: Rc<Ctx>) -> Rc<Self> {
        let grid = tile_grid();
        grid.add_css_class("page-content");

        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .child(&grid)
            .vexpand(true)
            .build();

        let empty = adw::StatusPage::builder()
            .icon_name("view-grid-symbolic")
            .title("Nessuna scena")
            .build();

        let widget = gtk::Stack::new();
        widget.add_named(&empty, Some("empty"));
        widget.add_named(&scroll, Some("grid"));

        Rc::new(Self {
            widget,
            grid,
            ctx,
            tiles: RefCell::default(),
            program: RefCell::default(),
            preview: RefCell::default(),
            studio: Cell::new(false),
        })
    }

    pub fn set_scenes(self: &Rc<Self>, names: Vec<String>) {
        self.grid.remove_all();
        let mut tiles = Vec::with_capacity(names.len());
        for name in names {
            let label = gtk::Label::builder()
                .label(&name)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .justify(gtk::Justification::Center)
                .lines(3)
                .ellipsize(gtk::pango::EllipsizeMode::End)
                .build();
            let badge = gtk::Label::new(None);
            badge.add_css_class("badge");

            let content = gtk::Box::new(gtk::Orientation::Vertical, 6);
            content.set_valign(gtk::Align::Center);
            content.append(&label);
            content.append(&badge);

            let button = gtk::Button::builder().child(&content).tooltip_text(&name).build();
            button.add_css_class("scene-tile");
            let weak = Rc::downgrade(self);
            let scene = name.clone();
            button.connect_clicked(move |_| {
                if let Some(this) = weak.upgrade() {
                    this.activate(&scene);
                }
            });

            self.grid.append(&grid_child(&button));
            tiles.push(SceneTile { name, button, badge });
        }
        self.widget.set_visible_child_name(if tiles.is_empty() { "empty" } else { "grid" });
        *self.tiles.borrow_mut() = tiles;
        self.restyle();
    }

    fn activate(&self, scene: &str) {
        let cmd = if self.studio.get() {
            Command::SetPreviewScene(scene.to_owned())
        } else {
            Command::SetProgramScene(scene.to_owned())
        };
        self.ctx.send(cmd);
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

    fn restyle(&self) {
        let program = self.program.borrow();
        let preview = self.preview.borrow();
        let studio = self.studio.get();
        for tile in self.tiles.borrow().iter() {
            let is_program = program.as_deref() == Some(tile.name.as_str());
            let is_preview = studio && !is_program && preview.as_deref() == Some(tile.name.as_str());
            tile.button.remove_css_class("program");
            tile.button.remove_css_class("preview");
            if is_program {
                tile.button.add_css_class("program");
                tile.badge.set_text("● IN ONDA");
            } else if is_preview {
                tile.button.add_css_class("preview");
                tile.badge.set_text("ANTEPRIMA");
            } else {
                tile.badge.set_text("");
            }
            tile.badge.set_visible(is_program || is_preview);
        }
    }
}
