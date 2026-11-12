//! Befehle des App-Fensters. Jede Prüfung und Änderung steckt in `lifeagents_desktop_core`; hier wird nur
//! verbunden: Journal laden, Kern rufen, Fehler auf feste Codes abbilden (Fehlerbericht), Fortschritt melden.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use lifeagents_desktop_core::changes::{self, ChangeList};
use lifeagents_desktop_core::contract::{COMPOSE_FILE, PORT_VAR};
use lifeagents_desktop_core::core_start::{self, CorePaths, WizardPhase, WizardStatus};
use lifeagents_desktop_core::detect::{self, Finding, Verdict};
use lifeagents_desktop_core::docker::Docker;
use lifeagents_desktop_core::docker_desktop::{self, FetchError};
use lifeagents_desktop_core::host::{join, Host, Os, RealHost};
use lifeagents_desktop_core::inventory::{self, Deviation, OwnObjects, Snapshot};
use lifeagents_desktop_core::journal::{self, Journal, Status, Step};
use lifeagents_desktop_core::power::{self, FileVault, PowerError, PowerResult};
use lifeagents_desktop_core::system::{self, Location, SystemReport};
use lifeagents_desktop_core::uninstall::{self, Choices, Outcome, Plan};
use lifeagents_desktop_core::{autostart, backup, cleanup, lang, report, texts};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_opener::OpenerExt;

/// Hilfe-Seite der Projekt-Doku (Paket 8 ergänzt dort die App-Seiten).
pub const HELP_URL: &str = "https://dennisbaerlin.github.io/n8n-life-agents/docs/installation.html";
/// Wie lange die App auf ein startendes Docker wartet.
const DOCKER_WAIT: Duration = Duration::from_secs(240);

#[derive(Default)]
pub struct AppState {
    pub last_error: Mutex<String>,
    pub bot: Mutex<String>,
    /// Eigene Adresse des App-Fensters (beim Start gemerkt), Ziel der Rückkehr aus dem Fragebogen.
    pub app_url: Mutex<Option<tauri::Url>>,
}

fn fail(app: &AppHandle, code: &str) -> String {
    if let Some(s) = app.try_state::<AppState>() {
        *s.last_error.lock().unwrap() = code.to_string();
    }
    code.to_string()
}

fn journal_or_err(app: &AppHandle) -> Result<Journal, String> {
    Journal::load(&RealHost).map_err(|_| fail(app, "journal-unreadable"))
}

fn compose_path(app: &AppHandle) -> Option<String> {
    let dir = app.path().resource_dir().ok()?;
    let p = dir.join(COMPOSE_FILE);
    p.exists().then(|| p.to_string_lossy().to_string())
}

fn core_paths(app: &AppHandle) -> Option<CorePaths> {
    compose_path(app).map(|c| core_start::paths(&RealHost, &c))
}

/// n8n-Port aus der `--env-file` der App (einmal gewählt, danach fest), für die Seite „Das wird geändert“.
fn saved_port() -> Option<u16> {
    let p = join(RealHost.os(), &[&journal::dir(&RealHost), "app.env"]);
    core_start::env_value(&RealHost.read_file(&p)?, PORT_VAR).and_then(|v| v.parse().ok())
}

/// Docker nur dann, wenn eine frische Erkennung „läuft und reicht“ meldet.
fn docker_if_ready() -> Option<Docker> {
    let f = detect::detect(&RealHost);
    match (&f.verdict, f.docker) {
        (Verdict::Ready { .. }, Some(d)) => Some(d),
        _ => None,
    }
}

fn ready_docker(app: &AppHandle) -> Result<Docker, String> {
    docker_if_ready().ok_or_else(|| fail(app, "docker-start-timeout"))
}

fn exe_path() -> String {
    std::env::current_exe().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
}

// ------------------------------------------------------------------------------------------------- Start

#[derive(Serialize)]
pub struct Startup {
    os: Os,
    location: Location,
    journal: Option<Status>,
    version: String,
    compose_ready: bool,
    /// Name der geladenen Datei im Download-Ordner, nur wenn genau eine passt („Download wegräumen“).
    download: Option<String>,
    /// Sprache der Seiten (`de`/`en`/`ko`): gemerkte Wahl aus dem Fragebogen, sonst Systemsprache.
    lang: &'static str,
}

#[tauri::command(async)]
pub fn startup(app: AppHandle) -> Startup {
    let location = system::install_location(RealHost.os(), &exe_path());
    // Läuft die App aus dem Programme-Ordner, braucht es die DMG nicht mehr: auswerfen (ohne Zwang).
    if location == Location::Installed {
        cleanup::eject_dmgs(&RealHost);
    }
    let download =
        cleanup::find_download(&RealHost).and_then(|p| std::path::Path::new(&p).file_name().map(|n| n.to_string_lossy().to_string()));
    Startup {
        os: RealHost.os(),
        location,
        journal: Journal::load(&RealHost).ok().map(|j| j.status()),
        version: app.package_info().version.to_string(),
        compose_ready: compose_path(&app).is_some(),
        download,
        lang: lang::current(&RealHost),
    }
}

/// Knopf „Download wegräumen“: die eine geladene Datei in den Papierkorb.
#[tauri::command(async)]
pub fn trash_download() -> Result<(), String> {
    cleanup::trash_download(&RealHost).map(|_| ())
}

#[tauri::command(async)]
pub fn check_system() -> SystemReport {
    system::check_system(&RealHost)
}

#[derive(Serialize)]
pub struct DockerOverview {
    finding: Finding,
    programs: Vec<String>,
    own: Option<OwnObjects>,
    port: Option<u16>,
    changes: Option<ChangeList>,
}

#[tauri::command(async)]
pub fn check_docker() -> DockerOverview {
    let h = RealHost;
    let finding = detect::detect(&h);
    let (mut programs, mut own) = (Vec::new(), None);
    if let (Verdict::Ready { .. }, Some(d)) = (&finding.verdict, &finding.docker) {
        programs = inventory::take(&h, d).map(|s| inventory::running_programs(&s)).unwrap_or_default();
        own = inventory::own_objects(&h, d).ok();
    }
    let port = saved_port().or_else(|| inventory::free_port(&h));
    let changes = port.and_then(|p| changes::plan(h.os(), &finding, &programs, p));
    DockerOverview { finding, programs, own, port, changes }
}

// ---------------------------------------------------------------------------------------- Docker holen

#[derive(Clone, Serialize)]
struct FetchProgress {
    stage: &'static str,
    done_mb: u64,
    total_mb: u64,
}

fn fetch_code(e: &FetchError) -> &'static str {
    match e {
        FetchError::NotMissing => "docker-unsupported",
        FetchError::Download(_) => "download-failed",
        FetchError::Signature(_) => "signature-failed",
        FetchError::Cancelled => "install-cancelled",
        FetchError::Install(_) => "install-failed",
    }
}

/// Nur bei „fehlt“: laden, Unterschrift prüfen, installieren (System-Passwort), Download löschen, starten.
#[tauri::command(async)]
pub fn fetch_docker(app: AppHandle) -> Result<(), String> {
    let h = RealHost;
    let f = detect::detect(&h);
    docker_desktop::guard_install(&f).map_err(|e| fail(&app, fetch_code(&e)))?;
    let total_mb = match h.os() {
        Os::Mac => docker_desktop::APPROX_MB_MAC,
        Os::Windows => docker_desktop::APPROX_MB_WIN,
    };
    let emit = |stage: &'static str, done_mb: u64| {
        let _ = app.emit("fetch-progress", FetchProgress { stage, done_mb, total_mb });
    };
    let dest = docker_desktop::download_path(&h);
    // Fortschritt über die Dateigröße, in einem eigenen Faden, solange `curl` lädt.
    let stop = Arc::new(AtomicBool::new(false));
    let watcher = {
        let (stop, app, dest) = (stop.clone(), app.clone(), dest.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                let done_mb = RealHost.file_size(&dest).unwrap_or(0) / (1024 * 1024);
                let _ = app.emit("fetch-progress", FetchProgress { stage: "download", done_mb, total_mb });
                std::thread::sleep(Duration::from_millis(500));
            }
        })
    };
    emit("download", 0);
    let downloaded = docker_desktop::download(&h, &dest);
    stop.store(true, Ordering::Relaxed);
    let _ = watcher.join();
    downloaded.map_err(|e| fail(&app, fetch_code(&e)))?;

    emit("verify", total_mb);
    let mut j = journal_or_err(&app)?;
    let result = (|| -> Result<(), FetchError> {
        match h.os() {
            Os::Mac => {
                let app_in_dmg = docker_desktop::verify_mac(&h, &dest)?;
                emit("password", total_mb);
                let seq = j.begin(&h, Step::DockerInstalled).map_err(FetchError::Install)?;
                match docker_desktop::install_mac(&h, &app_in_dmg) {
                    Ok(()) => j.done(&h, seq, None).map_err(FetchError::Install),
                    Err(FetchError::Cancelled) => {
                        let _ = j.abandon(&h, seq);
                        Err(FetchError::Cancelled)
                    }
                    Err(e) => Err(e),
                }
            }
            Os::Windows => {
                docker_desktop::verify_windows(&h, &dest)?;
                emit("password", total_mb);
                let seq = j.begin(&h, Step::DockerInstalled).map_err(FetchError::Install)?;
                match docker_desktop::install_windows(&h, &dest) {
                    Ok(()) => j.done(&h, seq, None).map_err(FetchError::Install),
                    Err(FetchError::Cancelled) => {
                        let _ = j.abandon(&h, seq);
                        Err(FetchError::Cancelled)
                    }
                    Err(e) => Err(e),
                }
            }
        }
    })();
    let _ = h.remove_file(&dest);
    result.map_err(|e| fail(&app, fetch_code(&e)))?;
    emit("start", total_mb);
    start_docker_inner(&app, &mut j)
}

fn start_docker_inner(app: &AppHandle, j: &mut Journal) -> Result<(), String> {
    let h = RealHost;
    let seq = j.begin(&h, Step::DockerStarted).map_err(|_| fail(app, "journal-unreadable"))?;
    // `done` setzt erst `wait_docker`, wenn Docker antwortet: Ein beendetes Docker Desktop hat nichts gestartet.
    if docker_desktop::start(&h).is_err() {
        let _ = j.abandon(&h, seq);
        return Err(fail(app, "docker-start-timeout"));
    }
    Ok(())
}

fn settle_docker_started(done: bool) {
    let h = RealHost;
    if let Ok(mut j) = Journal::load(&h) {
        let _ = j.settle(&h, |s| *s == Step::DockerStarted, done);
    }
}

/// Docker Desktop war aus: nach dem Ja starten (nichts installieren).
#[tauri::command(async)]
pub fn start_docker(app: AppHandle) -> Result<(), String> {
    let f = detect::detect(&RealHost);
    if f.verdict != Verdict::DesktopStopped {
        return Err(fail(&app, "docker-unsupported"));
    }
    let mut j = journal_or_err(&app)?;
    start_docker_inner(&app, &mut j)
}

/// Wartet, bis Docker antwortet (oder ein anderer Befund feststeht), höchstens vier Minuten.
#[tauri::command(async)]
pub fn wait_docker(app: AppHandle) -> Result<Finding, String> {
    let start = Instant::now();
    let mut watch = docker_desktop::StartWatch::default();
    loop {
        let f = detect::detect(&RealHost);
        if !matches!(f.verdict, Verdict::DesktopStopped | Verdict::Missing) {
            settle_docker_started(true);
            return Ok(f);
        }
        if watch.closed(&RealHost) {
            settle_docker_started(false);
            return Err(fail(&app, "docker-closed"));
        }
        if start.elapsed() > DOCKER_WAIT {
            settle_docker_started(false);
            return Err(fail(&app, "docker-start-timeout"));
        }
        std::thread::sleep(Duration::from_secs(3));
    }
}

// ------------------------------------------------------------------------------- Verbund und Fragebogen

fn inventory_file(name: &str) -> String {
    join(RealHost.os(), &[&journal::dir(&RealHost), name])
}

/// Nach dem Ja auf der Seite „Das wird geändert“: Bestandsaufnahme, Port, `anchor` + `master` starten.
#[tauri::command(async)]
pub fn start_core(app: AppHandle) -> Result<u16, String> {
    let h = RealHost;
    let paths = core_paths(&app).ok_or_else(|| fail(&app, "compose-missing"))?;
    let d = ready_docker(&app)?;
    if let Ok(OwnObjects::Foreign { .. }) = inventory::own_objects(&h, &d) {
        return Err(fail(&app, "foreign-objects"));
    }
    let mut j = journal_or_err(&app)?;
    if !j.has_done(|s| matches!(s, Step::Inventory { .. })) {
        let snap = inventory::take(&h, &d).map_err(|_| fail(&app, "docker-start-timeout"))?;
        let file = inventory_file("inventory-before.json");
        h.write_file(&file, &serde_json::to_string_pretty(&snap).unwrap_or_default()).map_err(|_| fail(&app, "journal-unreadable"))?;
        let seq = j.begin(&h, Step::Inventory { file }).map_err(|_| fail(&app, "journal-unreadable"))?;
        j.done(&h, seq, None).map_err(|_| fail(&app, "journal-unreadable"))?;
    }
    // Gemerkte Ports nur behalten, wenn unser Verbund schon lief (dann hält er sie selbst) oder sie noch frei sind.
    let started = j.has_done(|s| matches!(s, Step::CoreStarted { .. }));
    let ports = core_start::saved_ports(&h, &paths)
        .filter(|p| started || (h.port_free(p.edge) && h.port_free(p.wizard)))
        .or_else(|| match inventory::free_ports(&h, 2).as_slice() {
            [edge, wizard] => Some(core_start::Ports { edge: *edge, wizard: *wizard }),
            _ => None,
        })
        .ok_or_else(|| fail(&app, "no-free-port"))?;
    core_start::start_first(&h, &mut j, &d, &paths, ports).map_err(|e| fail(&app, core_start::error_code(&e)))?;
    Ok(ports.edge)
}

/// Lädt den Fragebogen im App-Fenster (fremde Adresse ohne App-Rechte). `false` = noch nicht verfügbar.
#[tauri::command(async)]
pub fn open_wizard(app: AppHandle) -> Result<bool, String> {
    let d = ready_docker(&app)?;
    let paths = core_paths(&app).ok_or_else(|| fail(&app, "compose-missing"))?;
    let ports = core_start::saved_ports(&RealHost, &paths).ok_or_else(|| fail(&app, "start-failed"))?;
    // Vorschläge (Heimnetz, FritzBox, Name, Sprache) als flüchtige Datei im master; ohne sie bleiben Felder leer.
    let _ = core_start::send_hints(&RealHost, &d);
    let Ok(url) = core_start::wizard_url(&RealHost, &d, ports.wizard) else {
        fail(&app, "wizard-unavailable");
        return Ok(false);
    };
    let parsed: tauri::Url = url.parse().map_err(|_| fail(&app, "wizard-unavailable"))?;
    let w = app.get_webview_window("main").ok_or_else(|| fail(&app, "wizard-unavailable"))?;
    // Owner-Entscheid: ein Fenster. Die Fragebogen-Seite ist eine fremde Adresse und bekommt keine App-Rechte
    // (Capability ohne `remote`, Test in main.rs). Zurück zur App holt sie dieser Faden, nicht die Seite selbst.
    let back = w.url().map_err(|_| fail(&app, "wizard-unavailable"))?;
    w.navigate(parsed).map_err(|_| fail(&app, "wizard-unavailable"))?;
    let handle = app.clone();
    std::thread::spawn(move || watch_wizard(handle, d, back));
    Ok(true)
}

/// Fragt den Fragebogen alle 3 s nach seinem Stand. Bei `handoff` lädt die App ihre eigene Seite wieder und zeigt
/// „Dauerbetrieb“ (`#power`). Hört nach 6 Stunden auf; die App lässt sich dann über das Symbol neu öffnen.
fn watch_wizard(app: AppHandle, d: Docker, mut back: tauri::Url) {
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(6 * 3600) {
        std::thread::sleep(Duration::from_secs(3));
        let s = core_start::wizard_status(&RealHost, &d);
        remember(&app, &s);
        if s.phase == WizardPhase::Handoff {
            back.set_fragment(Some("power"));
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.navigate(back);
                let _ = w.show();
                let _ = w.set_focus();
            }
            return;
        }
    }
}

#[tauri::command(async)]
pub fn wizard_status(app: AppHandle) -> WizardStatus {
    let Some(d) = docker_if_ready() else {
        return WizardStatus::unavailable();
    };
    let s = core_start::wizard_status(&RealHost, &d);
    remember(&app, &s);
    s
}

/// Bot-Name und im Fragebogen gewählte Sprache merken (Sprache dauerhaft: Menü und App-Seiten danach).
fn remember(app: &AppHandle, s: &WizardStatus) {
    if !s.bot.is_empty() {
        *app.state::<AppState>().bot.lock().unwrap() = s.bot.clone();
    }
    if let Some(l) = s.lang {
        let _ = lang::save(&RealHost, l);
    }
}

// ---------------------------------------------------------------------------------------- Dauerbetrieb

#[derive(Serialize)]
pub struct PowerInfo {
    os: Os,
    laptop: bool,
    filevault: FileVault,
    changed: bool,
}

#[tauri::command(async)]
pub fn power_info() -> PowerInfo {
    let h = RealHost;
    let j = Journal::load(&h).unwrap_or_default();
    PowerInfo {
        os: h.os(),
        laptop: system::check_system(&h).laptop,
        filevault: power::filevault(&h),
        changed: j.last_done(|s| matches!(s, Step::PowerChanged { .. })).is_some(),
    }
}

/// Nach „Ja, er soll durchlaufen“: Sicherung ins Journal, dann setzen (System-Passwort) und nachlesen.
#[tauri::command(async)]
pub fn power_apply(app: AppHandle) -> Result<PowerResult, String> {
    let h = RealHost;
    let mut j = journal_or_err(&app)?;
    let prepared = power::prepare(&h).map_err(|_| fail(&app, "power-failed"))?;
    let seq = j.begin(&h, Step::PowerChanged { backup: prepared.clone() }).map_err(|_| fail(&app, "journal-unreadable"))?;
    match power::apply(&h, &prepared) {
        Ok(r) => {
            j.done(&h, seq, Some(Step::PowerChanged { backup: r.backup.clone() })).map_err(|_| fail(&app, "journal-unreadable"))?;
            Ok(r)
        }
        Err(PowerError::Cancelled) => {
            let _ = j.abandon(&h, seq);
            Err(fail(&app, "power-cancelled"))
        }
        // Windows räumt selbst auf. Auf dem Mac ist der Stand unklar: alte Werte zurückstellen; klappt das nicht, bleibt
        // der Eintrag „begonnen“ für den Rückweg.
        Err(_) => {
            if h.os() == Os::Windows || power::restore(&h, &prepared).is_ok() {
                let _ = j.abandon(&h, seq);
            }
            Err(fail(&app, "power-failed"))
        }
    }
}

/// Dauerbetrieb entschieden: Der Fragebogen löscht seinen Fortschritt und endet (`ctl.js power-done`). Ohne Fragebogen still.
#[tauri::command(async)]
pub fn power_answer() {
    // Der Fragebogen braucht nur das Ende, nicht die Antwort; sie steht im Journal der App.
    if let Some(d) = docker_if_ready() {
        let _ = core_start::power_done(&RealHost, &d);
    }
}

/// Menüpunkt „Dauerbetrieb zurückstellen“.
#[tauri::command(async)]
pub fn power_restore(app: AppHandle) -> Result<(), String> {
    let h = RealHost;
    let mut j = journal_or_err(&app)?;
    let Some(e) = j.last_done(|s| matches!(s, Step::PowerChanged { .. })).cloned() else { return Ok(()) };
    if let Step::PowerChanged { backup } = &e.step {
        power::restore(&h, backup)
            .map_err(|err| fail(&app, if err == PowerError::Cancelled { "power-cancelled" } else { "power-failed" }))?;
    }
    j.mark_undone(&h, e.seq).map_err(|_| fail(&app, "journal-unreadable"))
}

// ---------------------------------------------------------------------------------------------- Abschluss

#[derive(Serialize)]
pub struct Finished {
    autostart: bool,
    deviations: Vec<Deviation>,
}

/// Fragebogen fertig: Anmeldestart eintragen, Einrichtung als fertig markieren, Fremdes vergleichen (Nr. 16).
#[tauri::command(async)]
pub fn finish_setup(app: AppHandle) -> Result<Finished, String> {
    let h = RealHost;
    let mut j = journal_or_err(&app)?;
    let mut autostart_ok = autostart::is_installed(&h);
    if !autostart_ok && system::install_location(h.os(), &exe_path()) == Location::Installed {
        let seq =
            j.begin(&h, Step::AutostartInstalled { entry: placeholder_autostart(&h) }).map_err(|_| fail(&app, "journal-unreadable"))?;
        match autostart::install(&h, &exe_path()) {
            Ok(entry) => {
                j.done(&h, seq, Some(Step::AutostartInstalled { entry })).map_err(|_| fail(&app, "journal-unreadable"))?;
                autostart_ok = true;
            }
            Err(_) => {
                let _ = j.abandon(&h, seq);
            }
        }
    }
    if !j.has_done(|s| *s == Step::SetupComplete) {
        let seq = j.begin(&h, Step::SetupComplete).map_err(|_| fail(&app, "journal-unreadable"))?;
        j.done(&h, seq, None).map_err(|_| fail(&app, "journal-unreadable"))?;
    }
    Ok(Finished { autostart: autostart_ok, deviations: compare_with_before(&j).unwrap_or_default() })
}

/// Eintrag, der vor dem Schreiben im Journal steht (gleicher Ort wie danach).
fn placeholder_autostart(h: &RealHost) -> autostart::Autostart {
    match h.os() {
        Os::Mac => autostart::Autostart::MacLaunchAgent { path: autostart::launch_agent_path(h) },
        Os::Windows => autostart::Autostart::WindowsRun { key: autostart::WIN_RUN_KEY.into(), value: autostart::WIN_VALUE.into() },
    }
}

fn compare_with_before(j: &Journal) -> Option<Vec<Deviation>> {
    let h = RealHost;
    let file = j.entries.iter().find_map(|e| match &e.step {
        Step::Inventory { file } => Some(file.clone()),
        _ => None,
    })?;
    let before: Snapshot = serde_json::from_str(&h.read_file(&file)?).ok()?;
    let d = detect::detect(&h).docker?;
    let after = inventory::take(&h, &d).ok()?;
    let ignore: Vec<String> = j
        .entries
        .iter()
        .filter_map(|e| match &e.step {
            Step::PowerChanged { backup: power::PowerBackup::Mac { ac } } => Some(ac.keys().cloned().collect::<Vec<_>>()),
            Step::PowerChanged { .. } => Some(vec!["active-scheme".to_string()]),
            _ => None,
        })
        .flatten()
        .collect();
    Some(inventory::compare(&before, &after, &ignore))
}

// ------------------------------------------------------------------------------- Sicherung (core/src/backup.rs)

#[derive(Serialize)]
pub struct KitSaved {
    /// Dateiname in Downloads (der Schlüssel selbst geht nie ans Fenster).
    file: String,
}

pub fn setup_done() -> bool {
    Journal::load(&RealHost).map(|j| j.has_done(|s| *s == Step::SetupComplete)).unwrap_or(false)
}

/// Notfallblatt als neue Datei in Downloads (Fertig-Seite, Startseite, Menüpunkt). Fehler nur als fester Code.
#[tauri::command(async)]
pub fn save_backup_kit(app: AppHandle) -> Result<KitSaved, String> {
    let d = docker_if_ready().ok_or_else(|| fail(&app, backup::KIT_UNAVAILABLE))?;
    let base = texts::text(lang::current(&RealHost), "core.desktop.kit.file_name");
    let path = backup::save_kit(&RealHost, &d, &base).map_err(|c| fail(&app, c))?;
    let file = path.rsplit(['/', '\\']).next().unwrap_or_default().to_string();
    Ok(KitSaved { file })
}

/// Haken „ausgedruckt oder sicher gespeichert“ (bis dahin zeigt die Startseite den Schritt weiter).
#[tauri::command]
pub fn kit_status() -> serde_json::Value {
    serde_json::json!({ "setup": setup_done(), "confirmed": backup::kit_confirmed(&RealHost) })
}

#[tauri::command]
pub fn confirm_kit(app: AppHandle) -> Result<(), String> {
    backup::confirm_kit(&RealHost).map_err(|_| fail(&app, "journal-unreadable"))
}

/// Menüpunkt „Sicherungsordner ändern …“: dieselbe Fragebogen-Seite im Änderungs-Modus im App-Fenster; nach „Fertig“
/// beendet sich der Fragebogen, dann holt dieser Faden die Startseite zurück.
#[tauri::command(async)]
pub fn change_backup_folder(app: AppHandle) -> Result<bool, String> {
    if !setup_done() {
        // Kein Fehler (kein Bericht-Code): das Menü war nur noch nicht neu eingefärbt, die UI zeigt die Startseite.
        return Err("setup-incomplete".into());
    }
    let d = docker_if_ready().ok_or_else(|| fail(&app, "backup-dir-unavailable"))?;
    let paths = core_paths(&app).ok_or_else(|| fail(&app, "compose-missing"))?;
    let ports = core_start::saved_ports(&RealHost, &paths).ok_or_else(|| fail(&app, "backup-dir-unavailable"))?;
    let url = backup::open_backup_dir(&RealHost, &d, ports.wizard, 20).map_err(|_| fail(&app, "backup-dir-unavailable"))?;
    let parsed: tauri::Url = url.parse().map_err(|_| fail(&app, "backup-dir-unavailable"))?;
    let w = app.get_webview_window("main").ok_or_else(|| fail(&app, "backup-dir-unavailable"))?;
    let back = app.state::<AppState>().app_url.lock().unwrap().clone().or_else(|| w.url().ok());
    w.navigate(parsed).map_err(|_| fail(&app, "backup-dir-unavailable"))?;
    if let Some(back) = back {
        let handle = app.clone();
        std::thread::spawn(move || watch_backup_dir(handle, d, back));
    }
    Ok(true)
}

/// Solange der Änderungs-Modus antwortet, wartet die App; endet er (Fertig oder Leerlauf), lädt sie ihre Startseite.
fn watch_backup_dir(app: AppHandle, d: Docker, mut back: tauri::Url) {
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(3600) {
        std::thread::sleep(Duration::from_secs(2));
        if core_start::wizard_status(&RealHost, &d).phase == WizardPhase::Unavailable {
            break;
        }
    }
    back.set_fragment(None);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.navigate(back);
    }
}

// ---------------------------------------------------------------------------------- Rückweg und Entfernen

/// Prüfliste Nr. 2/18: abgebrochene Einrichtung Schritt für Schritt zurücknehmen.
#[tauri::command(async)]
pub fn rollback(app: AppHandle) -> Result<(), String> {
    let mut j = journal_or_err(&app)?;
    let d = detect::detect(&RealHost).docker;
    journal::rollback(&RealHost, &mut j, d.as_ref()).map_err(|_| fail(&app, "rollback-failed"))
}

#[tauri::command(async)]
pub fn uninstall_plan(app: AppHandle) -> Result<Plan, String> {
    let j = journal_or_err(&app)?;
    let d = detect::detect(&RealHost).docker;
    Ok(uninstall::plan(&RealHost, &j, d.as_ref()))
}

#[tauri::command(async)]
pub fn uninstall_run(app: AppHandle, choices: Choices) -> Result<Outcome, String> {
    let mut j = journal_or_err(&app)?;
    let d = detect::detect(&RealHost).docker;
    let p = uninstall::plan(&RealHost, &j, d.as_ref());
    let o = uninstall::run(&RealHost, &mut j, d.as_ref(), &p, choices);
    if !o.deviations.is_empty() {
        fail(&app, "deviation");
    }
    Ok(o)
}

// ------------------------------------------------------------------------------------------------- Hilfe

#[tauri::command(async)]
pub fn error_report(app: AppHandle) -> String {
    let h = RealHost;
    let sys = system::check_system(&h);
    let f = detect::detect(&h);
    let j = Journal::load(&h).unwrap_or_default();
    let last = app.state::<AppState>().last_error.lock().unwrap().clone();
    report::build(&app.package_info().version.to_string(), &sys, Some(&f), &j, power::filevault(&h), &last).to_text()
}

/// Nur feste Ziele; die Oberfläche kann keine beliebige Adresse öffnen.
#[tauri::command]
pub fn open_link(app: AppHandle, target: String) -> Result<(), String> {
    let url = match target.as_str() {
        "docker-terms" => docker_desktop::TERMS_URL.to_string(),
        "help" => HELP_URL.to_string(),
        "telegram" => {
            let bot = app.state::<AppState>().bot.lock().unwrap().clone();
            if bot.is_empty() {
                "https://t.me/".to_string()
            } else {
                format!("https://t.me/{bot}")
            }
        }
        _ => return Err("unbekanntes Ziel".into()),
    };
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

/// Docker-Status für das Symbol: `true` = Verbund läuft (Docker bereit).
/// `--self-test`: alle lesenden Prüfungen gegen das echte System, ohne Fenster und ohne Änderung.
pub fn self_test() -> serde_json::Value {
    let h = RealHost;
    let sys = system::check_system(&h);
    let finding = detect::detect(&h);
    let route = lifeagents_desktop_core::network::default_route(&h);
    serde_json::json!({
        "system": sys,
        "docker": finding,
        "power": power::snapshot(&h),
        "filevault": power::filevault(&h),
        "location": system::install_location(h.os(), &exe_path()),
        "journal": Journal::load(&h).map(|j| serde_json::to_value(j.status()).unwrap_or_default()).unwrap_or_else(|e| serde_json::json!({"error": e})),
        "autostart": autostart::is_installed(&h),
        "mounted_dmgs": cleanup::mounted_dmgs(&h).len(),
        "download_found": cleanup::find_download(&h).is_some(),
        "free_port": inventory::free_port(&h),
        "lan_ip_found": route.is_some(),
        "gateway_found": route.as_ref().is_some_and(|r| r.gateway.is_some()),
        // Vorschläge sind privat: nur ob etwas gefunden wurde, nie der Wert (CI-Protokolle sind öffentlich).
        "fritz_name_found": route.as_ref().and_then(|r| lifeagents_desktop_core::suggest::fritz_box_name(&h, r)).is_some(),
        "myfritz_found": lifeagents_desktop_core::suggest::myfritz_zone(&h).is_some(),
        "host_name_candidates": lifeagents_desktop_core::suggest::hostname_candidates(&h).len(),
        "user_fullname_found": lifeagents_desktop_core::suggest::user_fullname(&h).is_some(),
        "user_lang_found": lifeagents_desktop_core::suggest::user_lang(&h).is_some(),
    })
}

pub fn docker_running() -> bool {
    matches!(detect::detect(&RealHost).verdict, Verdict::Ready { .. })
}

/// Anmeldestart (`--autostart`): Docker hochbringen, dann den Verbund starten. Ohne Fenster.
pub fn autostart_bring_up(app: &AppHandle) {
    let h = RealHost;
    let Ok(j) = Journal::load(&h) else { return };
    if j.status() != Status::Complete {
        return;
    }
    if detect::detect(&h).verdict == Verdict::DesktopStopped {
        let _ = docker_desktop::start(&h);
    }
    let start = Instant::now();
    while start.elapsed() < DOCKER_WAIT {
        if let Some(d) = docker_if_ready() {
            if let Some(p) = core_paths(app) {
                if core_start::start_after_login(&h, &d, &p).is_err() {
                    fail(app, "start-failed");
                }
            }
            return;
        }
        std::thread::sleep(Duration::from_secs(5));
    }
    fail(app, "docker-start-timeout");
}
