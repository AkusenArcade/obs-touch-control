use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;

use super::Ctx;
use crate::config::TileSize;
use crate::obs::Command;

pub fn present(ctx: &Rc<Ctx>) {
    let cfg = ctx.config.borrow().clone();

    let host = adw::EntryRow::builder().title("Indirizzo (host)").text(&cfg.host).build();
    let port = adw::SpinRow::with_range(1.0, 65535.0, 1.0);
    port.set_title("Porta");
    port.set_value(cfg.port.into());
    let password = adw::PasswordEntryRow::builder().title("Password").text(&cfg.password).build();

    let connection = adw::PreferencesGroup::builder()
        .title("Connessione a OBS")
        .description("Dati in OBS: Strumenti → Impostazioni server WebSocket → Mostra informazioni di connessione")
        .build();
    connection.add(&host);
    connection.add(&port);
    connection.add(&password);

    let auto_connect = adw::SwitchRow::builder()
        .title("Connetti all'avvio")
        .active(cfg.auto_connect)
        .build();
    let fullscreen = adw::SwitchRow::builder()
        .title("Avvia a schermo intero")
        .subtitle("Utile per pannelli touch dedicati")
        .active(cfg.start_fullscreen)
        .build();
    let confirm = adw::SwitchRow::builder()
        .title("Conferma prima di fermare diretta o registrazione")
        .subtitle("Evita stop accidentali con un tocco")
        .active(cfg.confirm_stop)
        .build();

    let labels: Vec<&str> = TileSize::ALL.iter().map(|t| t.label()).collect();
    let tile_size = adw::ComboRow::builder()
        .title("Dimensione riquadri")
        .subtitle("Riquadri più grandi = meno colonne")
        .model(&gtk::StringList::new(&labels))
        .selected(TileSize::ALL.iter().position(|t| *t == cfg.tile_size).unwrap_or(1) as u32)
        .build();
    // Live preview: grids reflow while the dialog is open.
    tile_size.connect_selected_notify(glib::clone!(
        #[strong]
        ctx,
        move |row| {
            if let Some(size) = TileSize::ALL.get(row.selected() as usize) {
                ctx.config.borrow_mut().tile_size = *size;
                ctx.apply_tile_size();
                ctx.save_config();
            }
        }
    ));

    let behaviour = adw::PreferencesGroup::builder().title("Comportamento").build();
    behaviour.add(&tile_size);
    behaviour.add(&auto_connect);
    behaviour.add(&fullscreen);
    behaviour.add(&confirm);

    let save = gtk::Button::with_label("Salva e connetti");
    save.add_css_class("pill");
    save.add_css_class("suggested-action");
    save.add_css_class("big-button");
    let disconnect = gtk::Button::with_label("Disconnetti");
    disconnect.add_css_class("pill");
    disconnect.add_css_class("big-button");

    let buttons = gtk::Box::new(gtk::Orientation::Vertical, 12);
    buttons.set_halign(gtk::Align::Center);
    buttons.append(&save);
    buttons.append(&disconnect);
    let actions = adw::PreferencesGroup::new();
    actions.add(&buttons);

    let page = adw::PreferencesPage::new();
    page.add(&connection);
    page.add(&behaviour);
    page.add(&actions);

    let dialog = adw::PreferencesDialog::builder()
        .title("Impostazioni")
        .content_width(560)
        .build();
    dialog.add(&page);

    save.connect_clicked(glib::clone!(
        #[strong]
        ctx,
        #[weak]
        dialog,
        move |_| {
            {
                let mut cfg = ctx.config.borrow_mut();
                cfg.host = host.text().trim().to_owned();
                cfg.port = port.value() as u16;
                cfg.password = password.text().to_string();
                cfg.auto_connect = auto_connect.is_active();
                cfg.start_fullscreen = fullscreen.is_active();
                cfg.confirm_stop = confirm.is_active();
            }
            ctx.save_config();
            ctx.connect();
            dialog.close();
        }
    ));
    disconnect.connect_clicked(glib::clone!(
        #[strong]
        ctx,
        #[weak]
        dialog,
        move |_| {
            ctx.send(Command::Disconnect);
            dialog.close();
        }
    ));

    dialog.present(ctx.window().as_ref());
}
