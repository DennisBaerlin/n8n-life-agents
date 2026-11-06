//! Seite „Das wird geändert“ (Prüfliste Nr. 8): Was die App nach dem Ja ändert und was bleibt. Erst nach den
//! lesenden Prüfungen 1–7; ohne Ja startet weder Docker noch ein Image oder Container. Codes statt Sätze, die
//! Texte stehen in der Oberfläche.

use crate::detect::{Engine, Finding, Verdict};
use crate::docker_desktop::{APPROX_MB_MAC, APPROX_MB_WIN};
use crate::host::Os;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Change {
    /// Docker Desktop kommt dazu (nur bei „fehlt“), direkt vom Hersteller.
    InstallDocker { size_mb: u64 },
    /// Docker wird gestartet (war aus oder frisch installiert); nennt die Engine.
    StartDocker { engine: Engine },
    /// Zwei kleine Container für den Wizard, Port nur auf diesem Rechner.
    WizardContainers { port: u16 },
    /// Die App merkt sich ihre Schritte in einer kleinen Datei, damit sie alles zurücknehmen kann.
    Journal,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Keep {
    /// Programme, die schon in Docker laufen, bleiben, wie sie sind.
    RunningPrograms { names: Vec<String> },
    /// Docker selbst wird nicht aktualisiert, nicht neu gestartet, nicht umgestellt.
    DockerItself,
    /// Energie-Einstellungen erst, wenn du am Ende Ja sagst.
    Power,
    /// Festplatten-Verschlüsselung und deine Dateien.
    FilesAndEncryption,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ChangeList {
    pub changes: Vec<Change>,
    pub keeps: Vec<Keep>,
}

/// `None`, wenn bei diesem Fund gar nichts geändert werden darf (Hilfe-Seite statt Zustimmung).
pub fn plan(os: Os, f: &Finding, programs: &[String], port: u16) -> Option<ChangeList> {
    let mut changes = Vec::new();
    let mut keeps = Vec::new();
    match &f.verdict {
        Verdict::Missing => {
            let size_mb = if os == Os::Mac { APPROX_MB_MAC } else { APPROX_MB_WIN };
            changes.push(Change::InstallDocker { size_mb });
            changes.push(Change::StartDocker { engine: Engine::DockerDesktop });
        }
        Verdict::DesktopStopped => {
            changes.push(Change::StartDocker { engine: Engine::DockerDesktop });
            keeps.push(Keep::DockerItself);
        }
        Verdict::Ready { .. } => {
            keeps.push(Keep::DockerItself);
            keeps.push(Keep::RunningPrograms { names: programs.to_vec() });
        }
        _ => return None,
    }
    changes.push(Change::WizardContainers { port });
    changes.push(Change::Journal);
    keeps.push(Keep::Power);
    keeps.push(Keep::FilesAndEncryption);
    Some(ChangeList { changes, keeps })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(v: Verdict) -> Finding {
        Finding { installed: vec![], docker: None, endpoint: None, running: None, verdict: v }
    }

    #[test]
    fn missing_docker_names_install_and_start() {
        let l = plan(Os::Mac, &f(Verdict::Missing), &[], 5880).unwrap();
        assert_eq!(l.changes[0], Change::InstallDocker { size_mb: 573 });
        assert!(l.changes.contains(&Change::StartDocker { engine: Engine::DockerDesktop }));
        assert!(!l.keeps.contains(&Keep::DockerItself));
    }

    #[test]
    fn stopped_docker_is_started_not_installed() {
        let l = plan(Os::Windows, &f(Verdict::DesktopStopped), &[], 5880).unwrap();
        assert!(!l.changes.iter().any(|c| matches!(c, Change::InstallDocker { .. })));
        assert!(l.changes.contains(&Change::StartDocker { engine: Engine::DockerDesktop }));
    }

    #[test]
    fn running_docker_lists_neighbours_and_changes_only_our_part() {
        let v = Verdict::Ready { engine: Engine::DockerDesktop, tested: true, containers_running: 3 };
        let l = plan(Os::Mac, &f(v), &["paperless".into()], 5881).unwrap();
        assert_eq!(l.changes, vec![Change::WizardContainers { port: 5881 }, Change::Journal]);
        assert!(l.keeps.contains(&Keep::RunningPrograms { names: vec!["paperless".into()] }));
        assert!(l.keeps.contains(&Keep::Power));
    }

    #[test]
    fn no_consent_page_where_nothing_may_change() {
        for v in [
            Verdict::TooOld { api: "1.44".into(), need: "1.45".into() },
            Verdict::LowMemory { free_mb: 1, need_mb: 2 },
            Verdict::OtherStopped { engine: Engine::OrbStack },
            Verdict::Unsupported { engine: Engine::Podman },
            Verdict::RemoteContext { endpoint: "ssh://x".into() },
        ] {
            assert_eq!(plan(Os::Mac, &f(v), &[], 5880), None);
        }
    }
}
