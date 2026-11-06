//! Start-App (Paket 6/7 des Plans *Docker-Installer für Freunde*). Fenster, Symbol in Menüleiste bzw. neben
//! der Uhr und Anmeldestart; alle Prüfungen und Änderungen liegen in `lifeagents-desktop-core`.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

use std::time::Duration;

use lifeagents_desktop_core::autostart::AUTOSTART_ARG;
use lifeagents_desktop_core::host::RealHost;
use lifeagents_desktop_core::journal::{Journal, Status};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, WindowEvent, Wry};

/// Bildschirm, den das Fenster beim Öffnen über das Symbol zeigen soll (`ui/app.js` hört auf `show-screen`).
fn show(app: &AppHandle, screen: &str) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
    if !screen.is_empty() {
        let _ = app.emit("show-screen", screen.to_string());
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<MenuItem<Wry>> {
    let status = MenuItem::with_id(app, "status", "Wird geprüft …", false, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Fenster öffnen", true, None::<&str>)?;
    let telegram = MenuItem::with_id(app, "telegram", "Telegram öffnen", true, None::<&str>)?;
    let power = MenuItem::with_id(app, "power-restore", "Dauerbetrieb zurückstellen", true, None::<&str>)?;
    let report = MenuItem::with_id(app, "report", "Fehlerbericht", true, None::<&str>)?;
    let uninstall = MenuItem::with_id(app, "uninstall", "Deinstallieren", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Beenden", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&status, &sep1, &open, &telegram, &power, &report, &sep2, &uninstall, &quit])?;
    let mut tray =
        TrayIconBuilder::with_id("main").menu(&menu).tooltip("lifeagents").show_menu_on_left_click(true).on_menu_event(|app, event| {
            match event.id.as_ref() {
                "open" => show(app, ""),
                "telegram" => {
                    let _ = commands::open_link(app.clone(), "telegram".into());
                }
                "power-restore" => show(app, "power-restore"),
                "report" => show(app, "report"),
                "uninstall" => show(app, "uninstall"),
                "quit" => app.exit(0),
                _ => {}
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(status)
}

/// Hält die Status-Zeile im Menü aktuell: „Läuft“ oder „Docker ist aus“.
fn watch_status(status: MenuItem<Wry>) {
    std::thread::spawn(move || loop {
        let text = if commands::docker_running() { "Läuft" } else { "Docker ist aus" };
        let _ = status.set_text(text);
        std::thread::sleep(Duration::from_secs(60));
    });
}

fn main() {
    let autostart = std::env::args().any(|a| a == AUTOSTART_ARG);
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(commands::AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::startup,
            commands::check_system,
            commands::check_docker,
            commands::fetch_docker,
            commands::start_docker,
            commands::wait_docker,
            commands::start_core,
            commands::open_wizard,
            commands::wizard_status,
            commands::power_info,
            commands::power_apply,
            commands::power_answer,
            commands::power_restore,
            commands::finish_setup,
            commands::rollback,
            commands::uninstall_plan,
            commands::uninstall_run,
            commands::error_report,
            commands::open_link,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            let status = build_tray(&handle)?;
            watch_status(status);
            if autostart {
                // Bei der Anmeldung: nur das Symbol, kein Fenster, kein Dock-Eintrag.
                #[cfg(target_os = "macos")]
                app.set_activation_policy(tauri::ActivationPolicy::Accessory);
                std::thread::spawn(move || commands::autostart_bring_up(&handle));
            } else if let Some(w) = app.get_webview_window("main") {
                w.show()?;
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Nach der Einrichtung schließt das Fenster nur; die App bleibt im Symbol und hält den Bot am Laufen. Solange
            // der Fragebogen offen ist, versteckt es sich ebenfalls: Es fragt danach nach dem Dauerbetrieb.
            if let WindowEvent::CloseRequested { api, .. } = event {
                let complete = Journal::load(&RealHost).map(|j| j.status() == Status::Complete).unwrap_or(false);
                let wizard_open = window.app_handle().get_webview_window("wizard").is_some();
                if window.label() == "main" && (complete || wizard_open) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("lifeagents konnte nicht starten");
}
