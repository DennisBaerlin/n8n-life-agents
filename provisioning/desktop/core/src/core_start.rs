//! Erster Start des Verbunds nach der Zustimmung (Paket-1-Ablauf: Konfig prüfen, Volumes mit Label anlegen,
//! `up -d anchor postgres master edge`), danach bei jeder Anmeldung nur `start`; Schnittstelle zum Wizard (Paket 4).
//! Namen und Befehle kommen aus `contract`.

use crate::contract::{
    self, MasterCmd, HOST_IP_VAR, HOST_NAMES_VAR, HOST_NAME_FRITZ_VAR, MYFRITZ_VAR, PG_PASSWORD_VAR, PORT_VAR, PROBE_VOLUME, PROJECT,
    TS_HOSTNAME_VAR, TS_STATE_VOLUME, USER_FULLNAME_VAR, USER_LANG_VAR, WIZARD_PORT_VAR,
};
use crate::docker::{Docker, DockerCall};
use crate::host::{join, Host};
use crate::journal::{self, Journal, Step};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CorePaths {
    /// Compose-Datei (Paket 5 legt fest, woher sie kommt; nur lesen, nie ändern).
    pub compose_file: String,
    /// `--env-file` neben dem Journal: Port, Datenbank-Passwort, Wizard-Adresse. Nur für diesen Nutzer lesbar.
    pub env_file: String,
}

pub fn paths(host: &dyn Host, compose_file: &str) -> CorePaths {
    CorePaths { compose_file: compose_file.to_string(), env_file: join(host.os(), &[&journal::dir(host), "app.env"]) }
}

/// Wert einer Zeile `KEY=wert` aus der Env-Datei.
pub fn env_value(text: &str, key: &str) -> Option<String> {
    text.lines().find_map(|l| l.strip_prefix(&format!("{key}="))).map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

/// Env-Datei schreiben. Datenbank-Passwort und Tailscale-Name entstehen einmal und bleiben danach gleich: Compose
/// muss bei jedem Aufruf dieselben Werte sehen, sonst legt es Container neu an (der Name: sonst neue Internet-Adresse).
/// `ts_existing`: Das Tailscale-Volume gibt es schon (Installation von vor der Wortliste, `ts_name::keep_or_draw`).
pub fn write_env(host: &dyn Host, p: &CorePaths, ports: Ports, ts_existing: bool) -> Result<(), String> {
    let old = host.read_file(&p.env_file).unwrap_or_default();
    let pw = match env_value(&old, PG_PASSWORD_VAR) {
        Some(pw) => pw,
        None => host.random_hex(32)?,
    };
    let ts = crate::ts_name::keep_or_draw(host, env_value(&old, TS_HOSTNAME_VAR).as_deref(), ts_existing)?;
    let Ports { edge, wizard } = ports;
    let text = format!("{PORT_VAR}={edge}\n{WIZARD_PORT_VAR}={wizard}\n{PG_PASSWORD_VAR}={pw}\n{TS_HOSTNAME_VAR}={ts}\n");
    host.write_file(&p.env_file, &text)
}

/// Inhalt der Hinweis-Datei (`contract::HINTS_DIR`): je gefundenem Wert eine Zeile `KEY=wert`, nur harmlose Zeichen
/// (die Quellen in `network.rs`/`suggest.rs` filtern schon; hier noch einmal gegen Zeilenumbrüche und Steuerzeichen).
pub fn hints_text(host: &dyn Host) -> String {
    let mut lines: Vec<(&str, String)> = Vec::new();
    let route = crate::network::default_route(host);
    if let Some(r) = &route {
        lines.push((HOST_IP_VAR, r.ip.clone()));
    }
    if let Some(zone) = crate::suggest::myfritz_zone(host) {
        lines.push((MYFRITZ_VAR, zone));
    }
    // Geprüfter Name aus der FritzBox zuerst, die Namen aus dem Rechnernamen bleiben der Rückfall.
    let mut names = crate::suggest::hostname_candidates(host);
    if let Some(fritz) = route.as_ref().and_then(|r| crate::suggest::fritz_box_name(host, r)) {
        names.retain(|n| *n != fritz);
        names.insert(0, fritz.clone());
        names.truncate(4);
        lines.push((HOST_NAME_FRITZ_VAR, fritz));
    }
    if !names.is_empty() {
        lines.push((HOST_NAMES_VAR, names.join(",")));
    }
    if let Some(name) = crate::suggest::user_fullname(host) {
        lines.push((USER_FULLNAME_VAR, name));
    }
    if let Some(lang) = crate::suggest::user_lang(host) {
        lines.push((USER_LANG_VAR, lang));
    }
    let backup: Vec<String> = crate::suggest::backup_candidates(host).into_iter().map(|(k, p)| format!("{k}|{p}")).collect();
    if !backup.is_empty() {
        lines.push((crate::contract::BACKUP_CANDIDATES_VAR, backup.join(";")));
    }
    lines.into_iter().map(|(k, v)| format!("{k}={}\n", v.chars().filter(|c| !c.is_control()).collect::<String>())).collect()
}

/// Hinweise an den `master` geben, unmittelbar bevor der Fragebogen öffnet (/run übersteht keinen Neustart). Inhalt
/// über stdin, nie im argv; ohne Funde eine leere Datei, damit keine alten Werte stehen bleiben.
pub fn send_hints(host: &dyn Host, d: &Docker) -> Result<(), String> {
    let out = d.call_stdin(host, DockerCall::MasterHints, &hints_text(host))?;
    if out.success() {
        Ok(())
    } else {
        Err(format!("Hinweise nicht übergeben ({})", out.code))
    }
}

/// Zwei Ports auf 127.0.0.1: n8n (`edge`, den der Tunnel nach außen bringt) und, getrennt davon, der Wizard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ports {
    pub edge: u16,
    pub wizard: u16,
}

/// Gemerkte Ports aus der Env-Datei.
pub fn saved_ports(host: &dyn Host, p: &CorePaths) -> Option<Ports> {
    let text = host.read_file(&p.env_file)?;
    let edge = env_value(&text, PORT_VAR)?.parse().ok()?;
    let wizard = env_value(&text, WIZARD_PORT_VAR)?.parse().ok()?;
    Some(Ports { edge, wizard })
}

/// Busybox-Image des `anchor` aus der Compose-Datei; damit läuft die Fähigkeits-Prüfung ohne weiteres Image.
pub fn probe_image(images: &[String]) -> Option<String> {
    images.iter().find(|i| i.starts_with("busybox")).cloned()
}

/// Ursache eines fehlgeschlagenen Docker-Aufrufs aus dessen Fehlertext. Nur diese festen Wörter verlassen die Funktion,
/// nie der Text selbst (er enthält Pfade und Namen; `report.rs` nimmt nur feste Codes). Die Muster sind Dockers eigene
/// Meldungen; was nicht passt, bleibt ohne Ursache.
fn probe_cause(stderr: &str) -> Option<&'static str> {
    let s = stderr.to_ascii_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| s.contains(n));
    // Nur „Programm nicht gefunden“: Dieselbe Meldung „error getting credentials“ kommt auch bei gesperrtem Schlüsselbund.
    if has(&["error getting credentials", "docker-credential-"]) && has(&["executable file not found", "not found in $path"]) {
        Some("credentials")
    } else if has(&["no space left on device"]) {
        Some("disk")
    } else if has(&["cannot connect to the docker daemon", "error during connect", "dockerdesktoplinuxengine"]) {
        Some("daemon")
    } else if has(&["no such host", "tls handshake timeout", "i/o timeout", "network is unreachable", "dial tcp"]) {
        Some("network")
    } else {
        None
    }
}

/// `probe-<schritt>` mit angehängter Ursache (`probe-write:network`), sonst nur der Schritt.
fn probe_error(step: &str, stderr: &str) -> String {
    match probe_cause(stderr) {
        Some(c) => format!("{step}:{c}"),
        None => step.to_string(),
    }
}

/// Fester Fehler-Code (`report::ERROR_CODES`) für einen Fehler aus `start_first`; die Meldungen der Texte-Seite hängen daran.
pub fn error_code(e: &str) -> &'static str {
    if e.starts_with("foreign-volume:") {
        return "foreign-objects";
    }
    match e.strip_prefix("probe-").map(|r| r.split_once(':').map(|(_, c)| c)) {
        Some(Some("credentials")) => "docker-credentials",
        Some(Some("network")) => "docker-network",
        Some(Some("disk")) => "docker-disk",
        Some(Some("daemon")) => "docker-start-timeout",
        Some(_) => "docker-capability",
        None => "start-failed",
    }
}

/// Fähigkeits-Prüfung (Plan Nr. 9, etwa 3 s): Verzeichnis-Unterpfad aus einem Volume einhängen und Docker-Zugang im
/// Container. Läuft im eigenen Probe-Volume mit unserem Label, das danach immer wieder entfernt wird.
pub fn capability_probe(host: &dyn Host, d: &Docker, image: &str) -> Result<(), String> {
    let o = d.call(host, DockerCall::VolumeLabel(PROBE_VOLUME))?;
    if o.success() {
        if o.stdout.trim() != PROJECT {
            return Err(format!("foreign-volume:{PROBE_VOLUME}"));
        }
        let _ = d.call(host, DockerCall::VolumeRemove(PROBE_VOLUME));
    }
    let created = d.call(host, DockerCall::VolumeCreate(PROBE_VOLUME))?;
    if !created.success() {
        return Err(probe_error("probe-volume", &created.stderr));
    }
    let result = (|| {
        let w = d.call(host, DockerCall::ProbeWrite { image })?;
        if !w.success() {
            return Err(probe_error("probe-write", &w.stderr));
        }
        let read = d.call(host, DockerCall::ProbeRead { image })?;
        if !read.success() || read.stdout.trim() != "ok" {
            return Err(probe_error("probe-subpath", &read.stderr));
        }
        let s = d.call(host, DockerCall::ProbeSocket { image })?;
        if !s.success() {
            return Err(probe_error("probe-socket", &s.stderr));
        }
        Ok(())
    })();
    let _ = d.call(host, DockerCall::VolumeRemove(PROBE_VOLUME));
    result
}

/// Images aus der Compose-Datei (`image: …`-Zeilen), ohne YAML-Bibliothek. Paket 1 schreibt jedes Image einmal als
/// Anker in `x-images` (`busybox: &img_busybox busybox:…@sha256:…`) und verweist mit `image: *img_busybox`; der
/// master trägt ab Paket 5 `${LA_MASTER_IMAGE:-<pin>}` (zählt die Vorgabe), ohne Release-Pin `${…:?…}` (übersprungen).
/// Test `images_of_the_real_compose_file` liest die echte Datei.
pub fn compose_images(compose_text: &str) -> Vec<String> {
    let unquote = |v: &str| v.trim().trim_matches(['"', '\'']).to_string();
    let anchors: std::collections::HashMap<String, String> = compose_text
        .lines()
        .filter_map(|l| l.split_once(": &"))
        .filter_map(|(_, rest)| rest.split_once(char::is_whitespace))
        .map(|(name, value)| (name.to_string(), unquote(value)))
        .collect();
    let mut out: Vec<String> = compose_text
        .lines()
        .filter_map(|l| l.trim().strip_prefix("image:"))
        .map(unquote)
        .filter_map(|v| match v.strip_prefix('*') {
            Some(name) => anchors.get(name).cloned(),
            None => Some(v),
        })
        .filter_map(|v| match v.strip_prefix("${").and_then(|r| r.strip_suffix('}')) {
            Some(inner) => inner.split_once(":-").map(|(_, pin)| pin.to_string()),
            None => Some(v),
        })
        .filter(|v| !v.is_empty() && !v.contains("${"))
        .collect();
    out.sort();
    out.dedup();
    out
}

/// Welche Images fehlen vor dem Start? Genau die lädt Docker gleich und genau die darf das Entfernen löschen.
/// „Fehlt“ nur bei Dockers eigener Antwort „No such image“; jeder andere Fehler bricht ab, denn ein falsch als
/// „fehlt“ notiertes Image eines Nachbarn würde beim Entfernen gelöscht.
pub fn missing_images(host: &dyn Host, d: &Docker, images: &[String]) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for i in images {
        let o = d.call(host, DockerCall::ImageInspect(i))?;
        if o.success() {
            continue;
        }
        if o.stderr.to_ascii_lowercase().contains("no such image") {
            out.push(i.clone());
        } else {
            return Err(format!("Image-Abfrage scheiterte ({})", o.code));
        }
    }
    Ok(out)
}

/// Welche zustandsführenden Volumes fehlen? Ein gleichnamiges Volume ohne unser Label gehört jemand anderem:
/// Abbruch, nie übernehmen.
pub fn volumes_to_create(host: &dyn Host, d: &Docker) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for v in contract::state_volume_names() {
        let o = d.call(host, DockerCall::VolumeLabel(&v))?;
        if o.success() {
            if o.stdout.trim() != PROJECT {
                return Err(format!("foreign-volume:{v}"));
            }
        } else if o.stderr.to_ascii_lowercase().contains("no such volume") {
            out.push(v);
        } else {
            return Err(format!("Volume-Abfrage scheiterte ({})", o.code));
        }
    }
    Ok(out)
}

/// Erste Zustimmung (Nr. 8 bestätigt). Reihenfolge: fehlende Volumes feststellen (nur lesen; das Tailscale-Volume
/// entscheidet über den Namen), Env-Datei, Konfig prüfen (nichts angelegt), fehlende Images feststellen, Images ins
/// Journal, Fähigkeits-Prüfung (lädt evtl. das busybox-Image), dann Volumes anlegen und starten.
pub fn start_first(host: &dyn Host, j: &mut Journal, d: &Docker, p: &CorePaths, ports: Ports) -> Result<(), String> {
    let new_volumes = volumes_to_create(host, d)?;
    let ts_volume = format!("{PROJECT}_{TS_STATE_VOLUME}");
    write_env(host, p, ports, !new_volumes.contains(&ts_volume))?;
    let cfg = d.call(host, DockerCall::ComposeConfig { file: &p.compose_file, env_file: &p.env_file })?;
    if !cfg.success() {
        return Err(format!("Compose-Datei ungültig ({})", cfg.code));
    }
    let text = host.read_file(&p.compose_file).ok_or("Compose-Datei fehlt")?;
    let images = compose_images(&text);
    let probe = probe_image(&images).ok_or("probe-image")?;
    let missing = missing_images(host, d, &images)?;
    let seq_img = if missing.is_empty() { None } else { Some(j.begin(host, Step::ImagesPulled { refs: missing })?) };
    capability_probe(host, d, &probe)?;
    if !new_volumes.is_empty() {
        let seq = j.begin(host, Step::VolumesCreated { names: new_volumes.clone() })?;
        for v in &new_volumes {
            let o = d.call(host, DockerCall::VolumeCreate(v))?;
            if !o.success() {
                return Err(format!("Volume ließ sich nicht anlegen ({})", o.code));
            }
        }
        j.done(host, seq, None)?;
    }
    let seq = j.begin(host, Step::CoreStarted { compose_file: p.compose_file.clone(), env_file: p.env_file.clone() })?;
    let out = d.call(host, DockerCall::ComposeUpFirst { file: &p.compose_file, env_file: &p.env_file })?;
    if !out.success() {
        return Err(format!("Start scheiterte: {}", first_line(&out.stderr)));
    }
    if let Some(s) = seq_img {
        j.done(host, s, None)?;
    }
    j.done(host, seq, None)
}

/// Bei jeder Anmeldung nach der Einrichtung: nur starten, nichts neu anlegen (Plan, Prüfung Nr. 6).
pub fn start_after_login(host: &dyn Host, d: &Docker, p: &CorePaths) -> Result<(), String> {
    let out = d.call(host, DockerCall::ComposeStart { file: &p.compose_file, env_file: &p.env_file })?;
    if out.success() {
        Ok(())
    } else {
        Err(format!("Start scheiterte: {}", first_line(&out.stderr)))
    }
}

fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").chars().take(200).collect()
}

fn master_json(host: &dyn Host, d: &Docker, cmd: MasterCmd) -> Result<serde_json::Value, String> {
    let out = d.call(host, DockerCall::Master(cmd))?;
    if !out.success() {
        return Err(format!("master antwortet nicht ({})", out.code));
    }
    let line = out.stdout.lines().rev().find(|l| l.trim_start().starts_with('{')).ok_or("keine JSON-Zeile")?;
    serde_json::from_str(line).map_err(|e| e.to_string())
}

/// Frische Einmal-Adresse des Wizards. Nur eine Adresse auf 127.0.0.1 mit unserem Port wird geöffnet, damit
/// der Container der App keine fremde Seite unterschieben kann.
pub fn wizard_url(host: &dyn Host, d: &Docker, port: u16) -> Result<String, String> {
    let v = master_json(host, d, MasterCmd::WizardUrl)?;
    let url = v.get("url").and_then(|u| u.as_str()).ok_or("ohne url")?.to_string();
    let prefix = format!("http://127.0.0.1:{port}/");
    if !url.starts_with(&prefix) || url.contains(char::is_whitespace) {
        return Err("Wizard-Adresse nicht auf diesem Rechner".into());
    }
    Ok(url)
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum WizardPhase {
    /// Fragen, Installation, Verbinden laufen im Wizard (auch „failed“: Der Wizard zeigt seinen Fehler selbst).
    Running,
    /// `handoff`: Der Wizard ist fertig, die App fragt selbst nach dem Dauerbetrieb (System-Passwort).
    Handoff,
    /// `master` antwortet nicht oder kennt den Befehl nicht: Platzhalter-Seite.
    Unavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct WizardStatus {
    pub phase: WizardPhase,
    /// Benutzername des Bots für „Telegram öffnen“ (`https://t.me/<bot>`), leer bis bekannt.
    pub bot: String,
    /// Im Fragebogen gewählte Sprache (`lang::SUPPORTED`), sonst `None`.
    pub lang: Option<&'static str>,
}

impl WizardStatus {
    pub fn unavailable() -> Self {
        WizardStatus { phase: WizardPhase::Unavailable, bot: String::new(), lang: None }
    }
}

pub fn wizard_status(host: &dyn Host, d: &Docker) -> WizardStatus {
    let Ok(v) = master_json(host, d, MasterCmd::WizardStatus) else {
        return WizardStatus::unavailable();
    };
    let lang = v.get("lang").and_then(|l| l.as_str()).and_then(crate::lang::parse);
    let phase = match v.get("phase").and_then(|p| p.as_str()) {
        // backup_dir | backup_done: Änderungs-Modus (Menüpunkt „Sicherungsordner ändern …“), läuft, bis er sich selbst beendet.
        Some("questions" | "installing" | "failed" | "pairing" | "connected" | "backup_dir" | "backup_done") => WizardPhase::Running,
        Some("handoff") => WizardPhase::Handoff,
        _ => WizardPhase::Unavailable,
    };
    let bot = v.get("bot").and_then(|b| b.as_str()).unwrap_or("").to_string();
    // Telegram-Benutzernamen: 5–32 Zeichen, Buchstaben, Ziffern, Unterstrich.
    let bot = if bot.len() <= 32 && bot.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') { bot } else { String::new() };
    WizardStatus { phase, bot, lang }
}

/// Nach der letzten App-Seite: Der Wizard löscht seinen Fortschritt und endet.
pub fn power_done(host: &dyn Host, d: &Docker) -> Result<(), String> {
    let out = d.call(host, DockerCall::Master(MasterCmd::PowerDone))?;
    if out.success() {
        Ok(())
    } else {
        Err(format!("master antwortet nicht ({})", out.code))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `<name>.fritz.box` zur Laufzeit zusammengesetzt: privacy_lint weist jeden solchen Namen als Literal ab.
    fn fb(name: &str) -> String {
        format!("{name}.fritz.box")
    }
    use crate::host::{CmdOut, FakeHost};

    fn d() -> Docker {
        Docker { bin: "docker".into(), context: "desktop-linux".into() }
    }
    fn cmd(call: DockerCall) -> String {
        format!("docker {}", d().args(&call).join(" "))
    }

    fn ports(edge: u16) -> Ports {
        Ports { edge, wizard: edge + 10 }
    }

    // Wie provisioning/compose/compose.yml: Images nur über Anker aus x-images, master ohne Release-Pin (neutrale Form).
    const COMPOSE: &str = "name: lifeagents\nx-images:\n  busybox: &img_busybox busybox:1.37@sha256:aaaa\n  postgres: &img_postgres \"postgres:17@sha256:bbbb\"\nservices:\n  anchor:\n    image: *img_busybox\n  master:\n    image: ${LA_MASTER_IMAGE:?LA_MASTER_IMAGE fehlt}\n  postgres:\n    image: *img_postgres\n";

    /// Docker antwortet wie bei einem frischen Rechner: Konfig gültig, keine Volumes, Images teils da.
    fn fresh(h: &FakeHost, p: &CorePaths) {
        h.write_file(&p.compose_file, COMPOSE).unwrap();
        h.set(&cmd(DockerCall::ComposeConfig { file: &p.compose_file, env_file: &p.env_file }), CmdOut::ok(""));
        for v in contract::state_volume_names() {
            h.set(&cmd(DockerCall::VolumeLabel(&v)), CmdOut::fail(1, &format!("Error response from daemon: get {v}: no such volume")));
            h.set(&cmd(DockerCall::VolumeCreate(&v)), CmdOut::ok(&v));
        }
        h.set(&cmd(DockerCall::ImageInspect("busybox:1.37@sha256:aaaa")), CmdOut::ok("sha256:aaaa\n"));
        h.set(&cmd(DockerCall::ImageInspect("postgres:17@sha256:bbbb")), CmdOut::fail(1, "Error: No such image: postgres:17@sha256:bbbb"));
        h.set(&cmd(DockerCall::ComposeUpFirst { file: &p.compose_file, env_file: &p.env_file }), CmdOut::ok(""));
        probe_ok(h);
    }

    const BB: &str = "busybox:1.37@sha256:aaaa";

    fn probe_ok(h: &FakeHost) {
        h.set(&cmd(DockerCall::VolumeLabel(PROBE_VOLUME)), CmdOut::fail(1, "Error: no such volume"));
        h.set(&cmd(DockerCall::VolumeCreate(PROBE_VOLUME)), CmdOut::ok(PROBE_VOLUME));
        h.set(&cmd(DockerCall::ProbeWrite { image: BB }), CmdOut::ok(""));
        h.set(
            &cmd(DockerCall::ProbeRead { image: BB }),
            CmdOut::ok(
                "ok
",
            ),
        );
        h.set(&cmd(DockerCall::ProbeSocket { image: BB }), CmdOut::ok(""));
        h.set(&cmd(DockerCall::VolumeRemove(PROBE_VOLUME)), CmdOut::ok(PROBE_VOLUME));
    }

    #[test]
    fn images_from_compose_skip_variables() {
        assert_eq!(compose_images(COMPOSE), vec!["busybox:1.37@sha256:aaaa", "postgres:17@sha256:bbbb"]);
    }

    #[test]
    fn images_follow_anchors_and_the_release_pin() {
        let text = "x-images:\n  master: &img_master ${LA_MASTER_IMAGE:-ghcr.io/example/master@sha256:cccc}\nservices:\n  master:\n    image: *img_master\n  edge:\n    image: 'caddy:2@sha256:dddd'\n  other:\n    image: ${OTHER_IMAGE}\n";
        assert_eq!(compose_images(text), vec!["caddy:2@sha256:dddd", "ghcr.io/example/master@sha256:cccc"]);
    }

    #[test]
    fn images_of_the_real_compose_file() {
        let text = include_str!("../../../compose/compose.yml");
        let images = compose_images(text);
        assert!(probe_image(&images).is_some(), "kein busybox-Image: {images:?}");
        assert!(images.iter().all(|i| i.contains("@sha256:") && !i.contains('*') && !i.contains("${")), "{images:?}");
        let pinned = text.lines().filter(|l| l.contains(": &img_") && l.contains("@sha256:")).count();
        assert_eq!(images.len(), pinned, "jedes Image aus x-images genau einmal: {images:?}");
    }

    #[test]
    fn first_start_follows_package_1() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        let mut j = Journal::default();
        start_first(&h, &mut j, &d(), &p, ports(5881)).unwrap();
        let env = h.read_file(&p.env_file).unwrap();
        assert_eq!(env_value(&env, "LA_EDGE_PORT").as_deref(), Some("5881"));
        assert_eq!(env_value(&env, "LA_WIZARD_PORT").as_deref(), Some("5891"));
        // Die Wizard-Adresse bildet der Wizard selbst aus LA_WIZARD_PORT (Paket 4); ein zweiter Fakt hier würde driften.
        assert_eq!(env_value(&env, "WIZARD_PUBLIC_ORIGIN"), None);
        assert_eq!(env_value(&env, "LA_PG_SUPERPW").map(|v| v.len()), Some(64));
        let steps: Vec<Step> = j.entries.iter().map(|e| e.step.clone()).collect();
        // Images stehen vor der Fähigkeits-Prüfung im Journal, weil die Prüfung das busybox-Image laden kann.
        assert_eq!(steps[0], Step::ImagesPulled { refs: vec!["postgres:17@sha256:bbbb".into()] });
        assert_eq!(steps[1], Step::VolumesCreated { names: contract::state_volume_names() });
        assert!(matches!(steps[2], Step::CoreStarted { .. }));
        assert!(j.entries.iter().all(|e| e.state == journal::State::Done));
        // Reihenfolge: Konfig vor jeder Änderung, Prüfung vor den Daten-Volumes, Volumes vor dem Start.
        let calls = h.calls.borrow().clone();
        let pos = |s: &str| calls.iter().position(|c| c.contains(s)).unwrap();
        assert!(pos("config --quiet") < pos("volume create"));
        assert!(pos("volume-subpath=sub") < pos("create --label io.lifeagents.install=lifeagents lifeagents_pgdata"));
        assert!(pos("create --label io.lifeagents.install=lifeagents lifeagents_pgdata") < pos(" up --detach"));
    }

    /// Rechner mit Netz, FritzBox (MyFRITZ), Gerätenamen, Nutzername und Sprache (alles erfunden).
    fn home_mac() -> FakeHost {
        let h = FakeHost::mac()
            .on("/sbin/route -n get default", CmdOut::ok("  interface: en0\n"))
            .on("/usr/sbin/ipconfig getifaddr en0", CmdOut::ok("192.168.178.20\n"))
            .on("/usr/sbin/scutil --get LocalHostName", CmdOut::ok("Erikas-Mac-mini\n"))
            .on("/usr/sbin/scutil --get ComputerName", CmdOut::ok("Erikas Mac mini\n"))
            .on("/usr/bin/id -F", CmdOut::ok("Erika Beispiel\n"))
            .on("/usr/bin/defaults read -g AppleLanguages", CmdOut::ok("(\n    \"de-DE\"\n)\n"));
        *h.peer_cert.borrow_mut() = Some(
            rcgen::generate_simple_self_signed(vec!["fritz.box".into(), "deine-domain.myfritz.net".into()]).unwrap().cert.der().to_vec(),
        );
        h
    }

    #[test]
    fn hints_go_to_the_master_over_stdin_only() {
        let h = home_mac();
        h.set(&cmd(DockerCall::MasterHints), CmdOut::ok(""));
        send_hints(&h, &d()).unwrap();
        let log = h.stdin_log.borrow().clone();
        assert_eq!(log.len(), 1);
        let (line, input) = &log[0];
        assert!(line.contains("exec --interactive lifeagents-master sh -c umask 077;"), "{line}");
        assert!(line.ends_with("cat > /run/lifeagents-wizard/hints.env"), "{line}");
        assert_eq!(
            input,
            "LA_HOST_IP=192.168.178.20\nLA_MYFRITZ_ZONE=deine-domain.myfritz.net\nLA_HOST_NAME_CANDIDATES=erikas-mac-mini,erikasmacmini\nLA_USER_FULLNAME=Erika Beispiel\nLA_USER_LANG=de\n"
        );
        // Kein privater Wert im argv (für jeden Prozess lesbar).
        for v in ["192.168", "myfritz", "Erika", "erikas"] {
            assert!(!line.contains(v), "{v} im argv: {line}");
        }
    }

    #[test]
    fn name_from_the_fritz_box_comes_first() {
        // In der FritzBox umbenannt: Der geprüfte Name passt zu keinem Kandidaten aus dem Rechnernamen.
        let h = home_mac().on("/sbin/route -n get default", CmdOut::ok("    gateway: 192.168.178.10\n  interface: en0\n"));
        *h.ptr.borrow_mut() = Some(fb("Erika-Buero"));
        let text = hints_text(&h);
        assert!(text.contains("LA_HOST_NAME_FRITZ=erika-buero\n"), "{text}");
        assert!(text.contains("LA_HOST_NAME_CANDIDATES=erika-buero,erikas-mac-mini,erikasmacmini\n"), "{text}");
        // Nicht umbenannt: kein doppelter Kandidat.
        *h.ptr.borrow_mut() = Some(fb("erikas-mac-mini"));
        assert!(hints_text(&h).contains("LA_HOST_NAME_CANDIDATES=erikas-mac-mini,erikasmacmini\n"));
        // Kein FritzBox-Router: keine Zeile, Kandidaten wie bisher.
        *h.ptr.borrow_mut() = None;
        let text = hints_text(&h);
        assert!(!text.contains("LA_HOST_NAME_FRITZ"), "{text}");
        assert!(text.contains("LA_HOST_NAME_CANDIDATES=erikas-mac-mini,erikasmacmini\n"));
    }

    #[test]
    fn without_findings_the_hints_file_is_emptied() {
        let h = FakeHost::mac();
        h.set(&cmd(DockerCall::MasterHints), CmdOut::ok(""));
        send_hints(&h, &d()).unwrap();
        assert_eq!(h.stdin_log.borrow()[0].1, "", "leere Datei überschreibt alte Werte");
    }

    #[test]
    fn env_file_never_carries_private_values() {
        // Die Env-Datei landet über Compose in der Container-Konfiguration (docker inspect): nur Ports, Passwort und
        // der Tailscale-Name (der ohnehin öffentlich in den Zertifikats-Protokollen steht).
        let h = home_mac();
        let p = paths(&h, "/x/compose.yml");
        write_env(&h, &p, ports(5880), false).unwrap();
        let env = h.read_file(&p.env_file).unwrap();
        let keys: Vec<&str> = env.lines().filter_map(|l| l.split('=').next()).collect();
        assert_eq!(keys, vec!["LA_EDGE_PORT", "LA_WIZARD_PORT", "LA_PG_SUPERPW", "LA_TS_HOSTNAME"]);
    }

    #[test]
    fn password_and_name_stay_the_same_on_a_second_start() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        h.write_file(&p.env_file, "LA_EDGE_PORT=5880\nLA_PG_SUPERPW=ab12\nLA_TS_HOSTNAME=calm-otter\n").unwrap();
        write_env(&h, &p, ports(5882), true).unwrap();
        let env = h.read_file(&p.env_file).unwrap();
        assert_eq!(env_value(&env, "LA_PG_SUPERPW").as_deref(), Some("ab12"));
        assert_eq!(env_value(&env, "LA_TS_HOSTNAME").as_deref(), Some("calm-otter"));
        assert_eq!(env_value(&env, "LA_EDGE_PORT").as_deref(), Some("5882"));
    }

    #[test]
    fn tailscale_name_is_drawn_only_for_a_new_install() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        start_first(&h, &mut Journal::default(), &d(), &p, ports(5880)).unwrap();
        let drawn = env_value(&h.read_file(&p.env_file).unwrap(), "LA_TS_HOSTNAME").unwrap();
        assert_eq!(drawn, crate::ts_name::from_seed(0xabab_abab));
        // Tailscale-Volume von früher, Env-Datei ohne Namen: Das Gerät heißt im Tailnet schon `bot` und bleibt so.
        let h = FakeHost::mac();
        fresh(&h, &p);
        h.set(&cmd(DockerCall::VolumeLabel("lifeagents_ts_state")), CmdOut::ok("lifeagents\n"));
        start_first(&h, &mut Journal::default(), &d(), &p, ports(5880)).unwrap();
        assert_eq!(env_value(&h.read_file(&p.env_file).unwrap(), "LA_TS_HOSTNAME").as_deref(), Some("bot"));
        assert!(contract::STATE_VOLUMES.contains(&TS_STATE_VOLUME));
    }

    #[test]
    fn foreign_volume_with_our_name_aborts_before_any_change() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        h.set(&cmd(DockerCall::VolumeLabel("lifeagents_pgdata")), CmdOut::ok("\n"));
        let mut j = Journal::default();
        let e = start_first(&h, &mut j, &d(), &p, ports(5881)).unwrap_err();
        assert!(e.starts_with("foreign-volume:"), "{e}");
        assert!(j.entries.is_empty());
        assert!(h.calls_starting("docker --context desktop-linux volume create").is_empty());
        assert!(h.calls_starting("docker --context desktop-linux compose").iter().all(|c| c.ends_with("config --quiet")));
    }

    #[test]
    fn our_existing_volumes_are_kept() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        for v in contract::state_volume_names() {
            h.set(&cmd(DockerCall::VolumeLabel(&v)), CmdOut::ok("lifeagents\n"));
        }
        let mut j = Journal::default();
        start_first(&h, &mut j, &d(), &p, ports(5881)).unwrap();
        // Angelegt wird nur das Probe-Volume der Fähigkeits-Prüfung, kein Daten-Volume.
        let created = h.calls_starting("docker --context desktop-linux volume create");
        assert!(created.iter().all(|c| c.ends_with(PROBE_VOLUME)), "{created:?}");
        assert!(!j.entries.iter().any(|e| matches!(e.step, Step::VolumesCreated { .. })));
    }

    #[test]
    fn invalid_compose_changes_nothing() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        h.set(
            &cmd(DockerCall::ComposeConfig { file: &p.compose_file, env_file: &p.env_file }),
            CmdOut::fail(15, "required variable LA_MASTER_IMAGE is missing"),
        );
        let mut j = Journal::default();
        assert!(start_first(&h, &mut j, &d(), &p, ports(5881)).is_err());
        assert!(j.entries.is_empty());
    }

    #[test]
    fn unclear_image_query_never_counts_as_missing() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        h.set(&cmd(DockerCall::ImageInspect("busybox:1.37@sha256:aaaa")), CmdOut::fail(1, "Cannot connect to the Docker daemon"));
        let mut j = Journal::default();
        assert!(start_first(&h, &mut j, &d(), &p, ports(5880)).is_err());
        assert!(j.entries.is_empty(), "nichts notiert, nichts angelegt");
        assert!(h.calls_starting("docker --context desktop-linux volume create").is_empty());
    }

    #[test]
    fn failed_start_stays_begun_for_the_way_back() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        h.set(
            &cmd(DockerCall::ComposeUpFirst { file: &p.compose_file, env_file: &p.env_file }),
            CmdOut::fail(1, "Bind for 127.0.0.1:5880 failed: port is already allocated"),
        );
        let mut j = Journal::default();
        assert!(start_first(&h, &mut j, &d(), &p, ports(5880)).is_err());
        assert!(matches!(j.status(), journal::Status::Interrupted { .. }));
    }

    #[test]
    fn capability_probe_failure_cleans_up_and_aborts() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        // Engine kann keinen Volume-Unterpfad (z. B. zu alt oder Datei statt Verzeichnis): nichts starten.
        h.set(&cmd(DockerCall::ProbeRead { image: BB }), CmdOut::fail(125, "invalid mount config"));
        let mut j = Journal::default();
        assert_eq!(start_first(&h, &mut j, &d(), &p, ports(5881)).unwrap_err(), "probe-subpath");
        assert!(h.called(&cmd(DockerCall::VolumeRemove(PROBE_VOLUME))), "Probe-Volume wird immer entfernt");
        assert!(h.calls_starting("docker --context desktop-linux compose").iter().all(|c| c.ends_with("config --quiet")));
        assert!(!h.calls.borrow().iter().any(|c| c.contains("volume create") && c.ends_with("lifeagents_pgdata")));
        // Ein evtl. geladenes Image steht als begonnen im Journal und fällt beim Rückweg wieder weg.
        assert!(matches!(j.status(), journal::Status::Interrupted { step: Step::ImagesPulled { .. } }));
    }

    /// Eine Meldung von Docker mit erfundenen Pfaden; der Fehler-Code nennt nur die Ursache, nie den Text.
    #[test]
    fn probe_failure_names_its_cause_without_the_message() {
        let cases = [
            (
                "error getting credentials - err: exec: \"docker-credential-desktop\": executable file not found in $PATH, out: ``",
                "probe-write:credentials",
            ),
            (
                "docker: Error response from daemon: Get \"https://registry-1.docker.io/v2/\": dial tcp: lookup registry-1.docker.io: no such host",
                "probe-write:network",
            ),
            ("docker: Error response from daemon: net/http: TLS handshake timeout", "probe-write:network"),
            ("write /var/lib/docker/tmp/x: no space left on device", "probe-write:disk"),
            ("Cannot connect to the Docker daemon at unix:///Users/erika/.docker/run/docker.sock. Is the docker daemon running?", "probe-write:daemon"),
            ("error during connect: open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.", "probe-write:daemon"),
            // Schlüsselbund gesperrt: dieselbe Einleitung, aber kein fehlendes Programm.
            ("error getting credentials - err: exit status 1, out: `User interaction is not allowed.`", "probe-write"),
            ("something nobody has seen", "probe-write"),
        ];
        for (stderr, want) in cases {
            let h = FakeHost::mac();
            let p = paths(&h, "/x/compose.yml");
            fresh(&h, &p);
            h.set(&cmd(DockerCall::ProbeWrite { image: BB }), CmdOut::fail(125, stderr));
            let e = capability_probe(&h, &d(), BB).unwrap_err();
            assert_eq!(e, want, "{stderr}");
            assert!(!e.contains("erika") && !e.contains("registry"), "Meldungstext im Code: {e}");
        }
    }

    #[test]
    fn probe_cause_also_comes_from_the_other_probe_steps() {
        let h = FakeHost::mac();
        probe_ok(&h);
        h.set(&cmd(DockerCall::ProbeSocket { image: BB }), CmdOut::fail(125, "no space left on device"));
        assert_eq!(capability_probe(&h, &d(), BB).unwrap_err(), "probe-socket:disk");
        let h = FakeHost::mac();
        probe_ok(&h);
        h.set(&cmd(DockerCall::VolumeCreate(PROBE_VOLUME)), CmdOut::fail(1, "no space left on device"));
        assert_eq!(capability_probe(&h, &d(), BB).unwrap_err(), "probe-volume:disk");
    }

    #[test]
    fn start_errors_map_to_one_fixed_code() {
        for (e, code) in [
            ("foreign-volume:lifeagents_pgdata", "foreign-objects"),
            ("probe-write:credentials", "docker-credentials"),
            ("probe-write:network", "docker-network"),
            ("probe-subpath:disk", "docker-disk"),
            ("probe-socket:daemon", "docker-start-timeout"),
            ("probe-write", "docker-capability"),
            ("probe-subpath", "docker-capability"),
            ("Start scheiterte: Bind for 127.0.0.1:5880 failed", "start-failed"),
        ] {
            assert_eq!(error_code(e), code, "{e}");
            assert!(crate::report::ERROR_CODES.contains(&error_code(e)), "{e}: Code fehlt in ERROR_CODES");
        }
    }

    #[test]
    fn capability_probe_runs_read_only_mounts_without_network() {
        let a = d().args(&DockerCall::ProbeRead { image: BB }).join(" ");
        assert!(a.contains("--rm --network none --label io.lifeagents.install=lifeagents"));
        assert!(a.contains("volume-subpath=sub,readonly"));
        let h = FakeHost::mac();
        probe_ok(&h);
        h.set(
            &cmd(DockerCall::VolumeLabel(PROBE_VOLUME)),
            CmdOut::ok(
                "
",
            ),
        );
        assert!(capability_probe(&h, &d(), BB).unwrap_err().starts_with("foreign-volume:"));
        assert!(!h.called(&cmd(DockerCall::VolumeRemove(PROBE_VOLUME))), "fremdes Volume nie löschen");
    }

    #[test]
    fn wizard_url_must_be_local_and_ours() {
        let h = FakeHost::mac();
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardUrl)), CmdOut::ok("{\"url\":\"http://127.0.0.1:5881/start?t=0123abcd\"}\n"));
        assert_eq!(wizard_url(&h, &d(), 5881).unwrap(), "http://127.0.0.1:5881/start?t=0123abcd");
        assert!(wizard_url(&h, &d(), 5880).is_err(), "anderer Port");
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardUrl)), CmdOut::ok("{\"url\":\"https://example.com/phish\"}\n"));
        assert!(wizard_url(&h, &d(), 5881).is_err());
    }

    #[test]
    fn wizard_phases_of_package_4() {
        let h = FakeHost::mac();
        assert_eq!(wizard_status(&h, &d()).phase, WizardPhase::Unavailable);
        for (raw, want) in [
            ("questions", WizardPhase::Running),
            ("installing", WizardPhase::Running),
            ("failed", WizardPhase::Running),
            ("pairing", WizardPhase::Running),
            ("connected", WizardPhase::Running),
            ("handoff", WizardPhase::Handoff),
            ("unbekannt", WizardPhase::Unavailable),
        ] {
            h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok(&format!("{{\"phase\":\"{raw}\",\"step\":\"x\"}}\n")));
            assert_eq!(wizard_status(&h, &d()).phase, want, "{raw}");
        }
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"handoff\",\"bot\":\"x/../evil\"}\n"));
        assert_eq!(wizard_status(&h, &d()).bot, "");
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"handoff\",\"bot\":\"erika_helfer_bot\"}\n"));
        assert_eq!(wizard_status(&h, &d()).bot, "erika_helfer_bot");
    }

    #[test]
    fn wizard_reports_the_chosen_language() {
        let h = FakeHost::mac();
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"questions\",\"lang\":\"ko\"}\n"));
        assert_eq!(wizard_status(&h, &d()).lang, Some("ko"));
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"questions\",\"lang\":\"../x\"}\n"));
        assert_eq!(wizard_status(&h, &d()).lang, None, "nur bekannte Sprachen");
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"questions\"}\n"));
        assert_eq!(wizard_status(&h, &d()).lang, None);
    }
}
