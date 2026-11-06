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
    let argv: Vec<String> = std::env::args().collect();
    // `--self-test [<datei>]`: Pruefungen gegen das echte System, nur lesen, Ergebnis als JSON (CI auf macOS- und
    // Windows-Rechnern, Handliste). Ohne Fenster. Datei statt stdout, weil eine Windows-App ohne Konsole startet.
    if let Some(i) = argv.iter().position(|a| a == "--self-test") {
        let json = serde_json::to_string_pretty(&commands::self_test()).unwrap_or_default();
        match argv.get(i + 1) {
            Some(path) => std::fs::write(path, json).expect("Selbsttest-Datei nicht schreibbar"),
            None => println!("{json}"),
        }
        return;
    }
    let autostart = argv.iter().any(|a| a == AUTOSTART_ARG);
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(commands::AppState::default())
        .invoke_handler(tauri::generate_handler![
            commands::startup,
            commands::trash_download,
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
            // Nach der Einrichtung schließt das Fenster nur; die App bleibt im Symbol und hält den Bot am Laufen.
            if let WindowEvent::CloseRequested { api, .. } = event {
                let complete = Journal::load(&RealHost).map(|j| j.status() == Status::Complete).unwrap_or(false);
                if window.label() == "main" && complete {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("lifeagents konnte nicht starten");
}

/// Owner-Entscheid „ein Fenster“: Die Fragebogen-Seite (fremde Adresse auf 127.0.0.1) läuft im App-Fenster, darf aber
/// keinen App-Befehl erreichen. Tauri 2 gibt Capabilities nur dem eigenen App-Inhalt; eine fremde Adresse bekäme
/// Zugriff nur über einen `remote`-Eintrag (https://v2.tauri.app/security/capabilities/). Der Test schickt denselben
/// Befehl einmal von der App-Adresse und einmal von der Fragebogen-Adresse durch die echte Rechte-Prüfung.
#[cfg(test)]
mod acl_tests {
    use tauri::ipc::{CallbackFn, InvokeBody};
    use tauri::test::{get_ipc_response, mock_builder, INVOKE_KEY};
    use tauri::webview::InvokeRequest;
    use tauri::Manager;

    /// Gleicher Name wie der echte Befehl: Die Rechte-Prüfung hängt am Namen, nicht an der Umsetzung.
    #[tauri::command]
    fn startup() -> &'static str {
        "ok"
    }

    fn request(url: &str) -> InvokeRequest {
        InvokeRequest {
            cmd: "startup".into(),
            callback: CallbackFn(0),
            error: CallbackFn(1),
            url: url.parse().unwrap(),
            body: InvokeBody::default(),
            headers: Default::default(),
            invoke_key: INVOKE_KEY.to_string(),
        }
    }

    #[test]
    fn wizard_address_reaches_no_app_command() {
        let app = mock_builder()
            .invoke_handler(tauri::generate_handler![startup])
            .build(tauri::generate_context!("tauri.conf.json", test = true))
            .expect("App ließ sich nicht bauen");
        let w = match app.get_webview_window("main") {
            Some(w) => w,
            None => tauri::WebviewWindowBuilder::new(&app, "main", Default::default()).build().unwrap(),
        };
        let local = if cfg!(windows) { "http://tauri.localhost/index.html" } else { "tauri://localhost/index.html" };
        assert!(get_ipc_response(&w, request(local)).is_ok(), "App-Seite muss den Befehl erreichen (Gegenprobe)");
        for wizard in ["http://127.0.0.1:5880/start?t=0123", "http://localhost:5880/", "https://example.com/"] {
            assert!(get_ipc_response(&w, request(wizard)).is_err(), "{wizard} darf keinen App-Befehl erreichen");
        }
    }

    #[test]
    fn no_capability_opens_remote_access() {
        for f in std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/capabilities")).unwrap() {
            let text = std::fs::read_to_string(f.unwrap().path()).unwrap();
            assert!(!text.contains("\"remote\""), "Capability mit remote-Eintrag gefunden");
        }
        let conf = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tauri.conf.json")).unwrap();
        assert!(!conf.contains("dangerous"), "gefährliche Tauri-Option in tauri.conf.json");
    }
}
