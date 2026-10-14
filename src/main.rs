mod config;
mod hotkey_names;
mod obs;
mod ui;

use adw::prelude::*;
use gtk::{gdk, glib};

const APP_ID: &str = "io.github.akusen.ObsTouchControl";

fn main() -> glib::ExitCode {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("failed to start tokio runtime");
    let handle = runtime.handle().clone();

    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_startup(|_| {
        load_css();
        gtk::Window::set_default_icon_name(APP_ID);
    });
    app.connect_activate(move |app| {
        // Single window: a second launch just raises the existing one.
        if let Some(win) = app.active_window() {
            win.present();
            return;
        }
        ui::build(app, &handle);
    });
    app.run()
}

fn load_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(include_str!("style.css"));
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().expect("no display"),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}
