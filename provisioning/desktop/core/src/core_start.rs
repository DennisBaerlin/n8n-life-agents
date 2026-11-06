//! Erster Start des Verbunds nach der Zustimmung (Paket-1-Ablauf: Konfig prüfen, Volumes mit Label anlegen,
//! `up -d anchor postgres master edge`), danach bei jeder Anmeldung nur `start`; Schnittstelle zum Wizard (Paket 4).
//! Namen und Befehle kommen aus `contract`.

use crate::contract::{self, MasterCmd, PG_PASSWORD_VAR, PORT_VAR, PROJECT, WIZARD_ORIGIN_VAR};
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

/// Env-Datei schreiben. Das Datenbank-Passwort entsteht einmal und bleibt danach gleich: Compose muss bei jedem
/// Aufruf dieselben Werte sehen, sonst legt es Container neu an.
pub fn write_env(host: &dyn Host, p: &CorePaths, port: u16) -> Result<(), String> {
    let old = host.read_file(&p.env_file).unwrap_or_default();
    let pw = match env_value(&old, PG_PASSWORD_VAR) {
        Some(pw) => pw,
        None => host.random_hex(32)?,
    };
    let text = format!("{PORT_VAR}={port}\n{PG_PASSWORD_VAR}={pw}\n{WIZARD_ORIGIN_VAR}=http://127.0.0.1:{port}\n");
    host.write_file(&p.env_file, &text)
}

/// Images aus der Compose-Datei (`image: …`-Zeilen), ohne YAML-Bibliothek: Die Datei schreibt Paket 1 mit
/// Digest-Pins, eine Zeile je Image.
pub fn compose_images(compose_text: &str) -> Vec<String> {
    let mut out: Vec<String> = compose_text
        .lines()
        .filter_map(|l| l.trim().strip_prefix("image:"))
        .map(|v| v.trim().trim_matches(['"', '\'']).to_string())
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

/// Erste Zustimmung (Nr. 8 bestätigt). Reihenfolge: Env-Datei, Konfig prüfen (nichts angelegt), fehlende Volumes
/// und Images ins Journal, dann anlegen und starten.
pub fn start_first(host: &dyn Host, j: &mut Journal, d: &Docker, p: &CorePaths, port: u16) -> Result<(), String> {
    write_env(host, p, port)?;
    let cfg = d.call(host, DockerCall::ComposeConfig { file: &p.compose_file, env_file: &p.env_file })?;
    if !cfg.success() {
        return Err(format!("Compose-Datei ungültig ({})", cfg.code));
    }
    let text = host.read_file(&p.compose_file).ok_or("Compose-Datei fehlt")?;
    let new_volumes = volumes_to_create(host, d)?;
    let missing = missing_images(host, d, &compose_images(&text))?;
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
    let seq_img = if missing.is_empty() { None } else { Some(j.begin(host, Step::ImagesPulled { refs: missing })?) };
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
}

pub fn wizard_status(host: &dyn Host, d: &Docker) -> WizardStatus {
    let Ok(v) = master_json(host, d, MasterCmd::WizardStatus) else {
        return WizardStatus { phase: WizardPhase::Unavailable, bot: String::new() };
    };
    let phase = match v.get("phase").and_then(|p| p.as_str()) {
        Some("questions" | "installing" | "failed" | "pairing" | "connected") => WizardPhase::Running,
        Some("handoff") => WizardPhase::Handoff,
        _ => WizardPhase::Unavailable,
    };
    let bot = v.get("bot").and_then(|b| b.as_str()).unwrap_or("").to_string();
    // Telegram-Benutzernamen: 5–32 Zeichen, Buchstaben, Ziffern, Unterstrich.
    let bot = if bot.len() <= 32 && bot.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') { bot } else { String::new() };
    WizardStatus { phase, bot }
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
    use crate::host::{CmdOut, FakeHost};

    fn d() -> Docker {
        Docker { bin: "docker".into(), context: "desktop-linux".into() }
    }
    fn cmd(call: DockerCall) -> String {
        format!("docker {}", d().args(&call).join(" "))
    }

    const COMPOSE: &str = "name: lifeagents\nservices:\n  anchor:\n    image: busybox:1.37@sha256:aaaa\n  master:\n    image: ${LA_MASTER_IMAGE:?}\n  postgres:\n    image: \"postgres:17@sha256:bbbb\"\n";

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
    }

    #[test]
    fn images_from_compose_skip_variables() {
        assert_eq!(compose_images(COMPOSE), vec!["busybox:1.37@sha256:aaaa", "postgres:17@sha256:bbbb"]);
    }

    #[test]
    fn first_start_follows_package_1() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        let mut j = Journal::default();
        start_first(&h, &mut j, &d(), &p, 5881).unwrap();
        let env = h.read_file(&p.env_file).unwrap();
        assert_eq!(env_value(&env, "LA_EDGE_PORT").as_deref(), Some("5881"));
        assert_eq!(env_value(&env, "WIZARD_PUBLIC_ORIGIN").as_deref(), Some("http://127.0.0.1:5881"));
        assert_eq!(env_value(&env, "LA_PG_SUPERPW").map(|v| v.len()), Some(64));
        let steps: Vec<Step> = j.entries.iter().map(|e| e.step.clone()).collect();
        assert_eq!(steps[0], Step::VolumesCreated { names: contract::state_volume_names() });
        assert_eq!(steps[1], Step::ImagesPulled { refs: vec!["postgres:17@sha256:bbbb".into()] });
        assert!(matches!(steps[2], Step::CoreStarted { .. }));
        assert!(j.entries.iter().all(|e| e.state == journal::State::Done));
        // Reihenfolge: Konfig vor jeder Änderung, Volumes vor dem Start.
        let calls = h.calls.borrow().clone();
        let pos = |s: &str| calls.iter().position(|c| c.contains(s)).unwrap();
        assert!(pos("config --quiet") < pos("volume create"));
        assert!(pos("volume create") < pos(" up --detach"));
    }

    #[test]
    fn password_stays_the_same_on_a_second_start() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        h.write_file(&p.env_file, "LA_EDGE_PORT=5880\nLA_PG_SUPERPW=ab12\n").unwrap();
        write_env(&h, &p, 5882).unwrap();
        let env = h.read_file(&p.env_file).unwrap();
        assert_eq!(env_value(&env, "LA_PG_SUPERPW").as_deref(), Some("ab12"));
        assert_eq!(env_value(&env, "LA_EDGE_PORT").as_deref(), Some("5882"));
    }

    #[test]
    fn foreign_volume_with_our_name_aborts_before_any_change() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        h.set(&cmd(DockerCall::VolumeLabel("lifeagents_pgdata")), CmdOut::ok("\n"));
        let mut j = Journal::default();
        let e = start_first(&h, &mut j, &d(), &p, 5881).unwrap_err();
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
        start_first(&h, &mut j, &d(), &p, 5881).unwrap();
        assert!(h.calls_starting("docker --context desktop-linux volume create").is_empty());
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
        assert!(start_first(&h, &mut j, &d(), &p, 5881).is_err());
        assert!(j.entries.is_empty());
    }

    #[test]
    fn unclear_image_query_never_counts_as_missing() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        fresh(&h, &p);
        h.set(&cmd(DockerCall::ImageInspect("busybox:1.37@sha256:aaaa")), CmdOut::fail(1, "Cannot connect to the Docker daemon"));
        let mut j = Journal::default();
        assert!(start_first(&h, &mut j, &d(), &p, 5880).is_err());
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
        assert!(start_first(&h, &mut j, &d(), &p, 5880).is_err());
        assert!(matches!(j.status(), journal::Status::Interrupted { .. }));
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
}
