//! Start von `anchor` + `master` nach der ersten Zustimmung, danach nur noch `start`; Schnittstelle zum Wizard.
//! Namen und Befehle kommen aus `contract` (Attrappe bis Paket 1/4/5 stehen).

use crate::contract::{MasterCmd, PORT_VAR};
use crate::docker::{Docker, DockerCall};
use crate::host::{join, Host};
use crate::journal::{self, Journal, Step};

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct CorePaths {
    /// Compose-Datei aus dem Ressourcen-Ordner der App (Paket 1 liefert sie).
    pub compose_file: String,
    /// `--env-file` neben dem Journal: nur der Port, keine Geheimnisse.
    pub env_file: String,
}

pub fn paths(host: &dyn Host, compose_file: &str) -> CorePaths {
    CorePaths { compose_file: compose_file.to_string(), env_file: join(host.os(), &[&journal::dir(host), "app.env"]) }
}

/// Images aus der Compose-Datei (`image: …`-Zeilen), ohne YAML-Bibliothek: Die Datei schreibt Paket 1 mit
/// Digest-Pins, eine Zeile je Image.
pub fn compose_images(compose_text: &str) -> Vec<String> {
    let mut out: Vec<String> = compose_text
        .lines()
        .filter_map(|l| l.trim().strip_prefix("image:"))
        .map(|v| v.trim().trim_matches(['"', '\'']).to_string())
        .filter(|v| !v.is_empty())
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

/// Erste Zustimmung (Nr. 8 bestätigt): Port festhalten, fehlende Images ins Journal, `anchor` + `master` starten.
pub fn start_first(host: &dyn Host, j: &mut Journal, d: &Docker, p: &CorePaths, port: u16) -> Result<(), String> {
    host.write_file(&p.env_file, &format!("{PORT_VAR}={port}\n"))?;
    let text = host.read_file(&p.compose_file).ok_or("Compose-Datei fehlt")?;
    let missing = missing_images(host, d, &compose_images(&text))?;
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
    Running,
    /// Wizard steht bei „Dauerbetrieb“: Die App fragt selbst (System-Passwort).
    Power,
    Done,
    /// `master` antwortet nicht oder kennt den Befehl nicht (Paket 4 noch nicht da): Platzhalter-Seite.
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
        Some("running") => WizardPhase::Running,
        Some("power") => WizardPhase::Power,
        Some("done") => WizardPhase::Done,
        _ => WizardPhase::Unavailable,
    };
    let bot = v.get("bot").and_then(|b| b.as_str()).unwrap_or("").to_string();
    // Telegram-Benutzernamen: 5–32 Zeichen, Buchstaben, Ziffern, Unterstrich.
    let bot = if bot.len() <= 32 && bot.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') { bot } else { String::new() };
    WizardStatus { phase, bot }
}

pub fn power_done(host: &dyn Host, d: &Docker, yes: bool) -> Result<(), String> {
    let out = d.call(host, DockerCall::Master(MasterCmd::PowerDone(yes)))?;
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

    const COMPOSE: &str = "name: lifeagents\nservices:\n  anchor:\n    image: busybox:1.37@sha256:aaaa\n  master:\n    image: \"ghcr.io/example/lifeagents-master@sha256:bbbb\"\n  n8n:\n    image: n8nio/n8n:2.45.4@sha256:cccc\n";

    #[test]
    fn images_from_compose() {
        assert_eq!(
            compose_images(COMPOSE),
            vec!["busybox:1.37@sha256:aaaa", "ghcr.io/example/lifeagents-master@sha256:bbbb", "n8nio/n8n:2.45.4@sha256:cccc"]
        );
    }

    #[test]
    fn first_start_journals_before_it_acts() {
        let h = FakeHost::mac();
        let p = paths(&h, "/Applications/lifeagents.app/Contents/Resources/compose.yml");
        h.write_file(&p.compose_file, COMPOSE).unwrap();
        h.set(&cmd(DockerCall::ImageInspect("busybox:1.37@sha256:aaaa")), CmdOut::ok("sha256:aaaa\n"));
        h.set(&cmd(DockerCall::ImageInspect("ghcr.io/example/lifeagents-master@sha256:bbbb")), CmdOut::fail(1, "No such image"));
        h.set(&cmd(DockerCall::ImageInspect("n8nio/n8n:2.45.4@sha256:cccc")), CmdOut::fail(1, "No such image"));
        h.set(&cmd(DockerCall::ComposeUpFirst { file: &p.compose_file, env_file: &p.env_file }), CmdOut::ok(""));
        let mut j = Journal::default();
        start_first(&h, &mut j, &d(), &p, 5881).unwrap();
        assert_eq!(h.read_file(&p.env_file).unwrap(), "LIFEAGENTS_HTTP_PORT=5881\n");
        assert_eq!(
            j.entries.iter().map(|e| e.step.clone()).collect::<Vec<_>>(),
            vec![
                Step::ImagesPulled {
                    refs: vec!["ghcr.io/example/lifeagents-master@sha256:bbbb".into(), "n8nio/n8n:2.45.4@sha256:cccc".into()]
                },
                Step::CoreStarted { compose_file: p.compose_file.clone(), env_file: p.env_file.clone() },
            ]
        );
        assert!(j.entries.iter().all(|e| e.state == journal::State::Done));
    }

    #[test]
    fn unclear_image_query_never_counts_as_missing() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        h.write_file(&p.compose_file, "services:\n  anchor:\n    image: busybox:1.37@sha256:aaaa\n").unwrap();
        h.set(&cmd(DockerCall::ImageInspect("busybox:1.37@sha256:aaaa")), CmdOut::fail(1, "Cannot connect to the Docker daemon"));
        let mut j = Journal::default();
        assert!(start_first(&h, &mut j, &d(), &p, 5880).is_err());
        assert!(j.entries.is_empty(), "nichts notiert, nichts gestartet");
        assert!(h.calls_starting("docker --context desktop-linux compose").is_empty());
    }

    #[test]
    fn failed_start_stays_begun_for_the_way_back() {
        let h = FakeHost::mac();
        let p = paths(&h, "/x/compose.yml");
        h.write_file(&p.compose_file, "services: {}\n").unwrap();
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
    fn wizard_status_without_master_is_placeholder() {
        let h = FakeHost::mac();
        assert_eq!(wizard_status(&h, &d()).phase, WizardPhase::Unavailable);
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"power\",\"bot\":\"erika_helfer_bot\"}\n"));
        assert_eq!(wizard_status(&h, &d()), WizardStatus { phase: WizardPhase::Power, bot: "erika_helfer_bot".into() });
        h.set(&cmd(DockerCall::Master(MasterCmd::WizardStatus)), CmdOut::ok("{\"phase\":\"done\",\"bot\":\"x/../evil\"}\n"));
        assert_eq!(wizard_status(&h, &d()).bot, "");
    }
}
