//! Start-App (Paket 6/7 des Plans *Docker-Installer für Freunde*). Fenster, Symbol in Menüleiste bzw. neben
//! der Uhr und Anmeldestart; alle Prüfungen und Änderungen liegen in `lifeagents-desktop-core`.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;

use std::time::Duration;

use lifeagents_desktop_core::autostart::AUTOSTART_ARG;
use lifeagents_desktop_core::host::RealHost;
use lifeagents_desktop_core::journal::{Journal, Status};
use lifeagents_desktop_core::{lang, texts};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, WindowEvent, Wry};

/// Bildschirm, den das Fenster beim Öffnen über das Symbol zeigen soll (`ui/app.js` hört auf `show-screen`). Steht
/// gerade der Fragebogen (fremde Seite ohne App-Rechte) im Fenster, hört dort niemand zu: dann die eigene Seite mit
/// dem Bildschirm als `#…` neu laden.
fn show(app: &AppHandle, screen: &str) {
    let Some(w) = app.get_webview_window("main") else { return };
    let _ = w.show();
    let _ = w.unminimize();
    let _ = w.set_focus();
    if screen.is_empty() {
        return;
    }
    let foreign = w.url().map(|u| u.host_str() == Some("127.0.0.1")).unwrap_or(false);
    let own = app.state::<commands::AppState>().app_url.lock().unwrap().clone();
    match own {
        Some(mut url) if foreign => {
            url.set_fragment(Some(screen));
            let _ = w.navigate(url);
        }
        _ => {
            let _ = app.emit("show-screen", screen.to_string());
        }
    }
}

/// Einträge des Menüs mit ihrem Katalog-Schlüssel (`texts::TRAY_KEYS`); die Status-Zeile steht vorn.
struct Tray {
    status: MenuItem<Wry>,
    items: Vec<(MenuItem<Wry>, &'static str)>,
    /// Notfallblatt, Sicherungsordner und Wiederherstellen gibt es erst nach der Einrichtung (vorher kein Schlüssel, kein Ordner).
    after_setup: Vec<MenuItem<Wry>>,
    /// „Sicherung wiederherstellen …“: während eines Laufs gesperrt, die Status-Zeile sagt es.
    restore: MenuItem<Wry>,
}

impl Tray {
    /// Texte in der aktuellen Sprache (nach einer Wahl im Fragebogen ändert sie sich).
    fn relabel(&self, lang: &str, running: bool) {
        for (item, key) in &self.items {
            let _ = item.set_text(texts::text(lang, key));
        }
        let ready = commands::setup_done();
        for item in &self.after_setup {
            let _ = item.set_enabled(ready);
        }
        let restoring = ready && running && commands::restore_running();
        let _ = self.restore.set_enabled(ready && !restoring);
        let key = if restoring {
            "core.desktop.tray.restoring"
        } else if running {
            "core.desktop.tray.running"
        } else {
            "core.desktop.tray.stopped"
        };
        let _ = self.status.set_text(texts::text(lang, key));
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<Tray> {
    let lang = lang::current(&RealHost);
    let item = |id: &str, key: &'static str, enabled: bool| MenuItem::with_id(app, id, texts::text(lang, key), enabled, None::<&str>);
    let status = item("status", "core.desktop.tray.checking", false)?;
    let open = item("open", "core.desktop.tray.open", true)?;
    let telegram = item("telegram", "core.desktop.tray.telegram", true)?;
    let power = item("power-restore", "core.desktop.tray.power_restore", true)?;
    let report = item("report", "core.desktop.tray.report", true)?;
    let ready = commands::setup_done();
    let kit = item("backup-kit", "core.desktop.tray.backup_kit", ready)?;
    let folder = item("backup-dir", "core.desktop.tray.backup_dir", ready)?;
    let restore = item("backup-restore", "core.desktop.tray.backup_restore", ready)?;
    let uninstall = item("uninstall", "core.desktop.tray.uninstall", true)?;
    let quit = item("quit", "core.desktop.tray.quit", true)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let menu =
        Menu::with_items(app, &[&status, &sep1, &open, &telegram, &power, &report, &kit, &folder, &restore, &sep2, &uninstall, &quit])?;
    let mut tray =
        TrayIconBuilder::with_id("main").menu(&menu).tooltip("lifeagents").show_menu_on_left_click(true).on_menu_event(|app, event| {
            match event.id.as_ref() {
                "open" => show(app, ""),
                "telegram" => {
                    let _ = commands::open_link(app.clone(), "telegram".into());
                }
                "power-restore" => show(app, "power-restore"),
                "report" => show(app, "report"),
                "backup-kit" => show(app, "backup-kit"),
                "backup-dir" => show(app, "backup-dir"),
                "backup-restore" => show(app, "backup-restore"),
                "uninstall" => show(app, "uninstall"),
                "quit" => app.exit(0),
                _ => {}
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(Tray {
        status,
        items: vec![
            (open, "core.desktop.tray.open"),
            (telegram, "core.desktop.tray.telegram"),
            (power, "core.desktop.tray.power_restore"),
            (report, "core.desktop.tray.report"),
            (kit.clone(), "core.desktop.tray.backup_kit"),
            (folder.clone(), "core.desktop.tray.backup_dir"),
            (restore.clone(), "core.desktop.tray.backup_restore"),
            (uninstall, "core.desktop.tray.uninstall"),
            (quit, "core.desktop.tray.quit"),
        ],
        after_setup: vec![kit, folder],
        restore,
    })
}

/// Hält das Menü aktuell: Status-Zeile „läuft“ oder „Docker ist aus“, Sprache wie zuletzt im Fragebogen gewählt.
/// Die Systemsprache nur einmal lesen (unter Windows ein PowerShell-Aufruf), die gemerkte Wahl jede Minute.
fn watch_status(tray: Tray) {
    std::thread::spawn(move || {
        let system = lang::system(&RealHost);
        loop {
            let l = lang::saved(&RealHost).unwrap_or(system);
            tray.relabel(l, commands::docker_running());
            std::thread::sleep(Duration::from_secs(60));
        }
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
        // Nur aus Rust benutzt (Datei wählen beim Wiederherstellen); das Fenster bekommt kein `dialog:`-Recht.
        .plugin(tauri_plugin_dialog::init())
        .manage(commands::AppState::default())
        .manage(std::sync::Mutex::new(commands::RestoreState::default()))
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
            commands::save_backup_kit,
            commands::kit_status,
            commands::confirm_kit,
            commands::change_backup_folder,
            commands::restore_list,
            commands::restore_dismiss_card,
            commands::restore_select,
            commands::restore_pick_file,
            commands::restore_pick_sheet,
            commands::restore_type_sheet,
            commands::restore_forget,
            commands::restore_plan,
            commands::restore_run,
            commands::restore_status,
            commands::restore_seen,
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
            // Eigene Adresse des App-Fensters merken (tauri://localhost bzw. http://tauri.localhost), für die Rückkehr.
            if let Some(w) = app.get_webview_window("main") {
                *app.state::<commands::AppState>().app_url.lock().unwrap() = w.url().ok();
            }
            let tray = build_tray(&handle)?;
            watch_status(tray);
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
            // Datei-Dialog und Dateizugriff nur aus Rust (Wiederherstellen): das Fenster selbst bekommt keins von beiden.
            assert!(!text.contains("dialog:") && !text.contains("fs:"), "Dialog- oder Datei-Recht fürs Fenster gefunden");
        }
        let conf = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tauri.conf.json")).unwrap();
        assert!(!conf.contains("dangerous"), "gefährliche Tauri-Option in tauri.conf.json");
    }
}
