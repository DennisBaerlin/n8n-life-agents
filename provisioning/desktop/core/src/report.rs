//! Fehlerbericht aus einer Positivliste fester Felder, nie aus Log-Text (Plan, *Wizard-Sicherheit*). Keine
//! Pfade, keine Namen von Containern oder Nutzern, keine Adressen: nur Zahlen, Versionen und feste Codes.

use crate::detect::{Finding, Verdict};
use crate::journal::Journal;
use crate::power::FileVault;
use crate::system::SystemReport;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ErrorReport {
    pub app_version: String,
    pub os: String,
    pub os_version: String,
    pub arch: String,
    pub ram_gb: u64,
    pub free_gb: u64,
    pub checks: Vec<String>,
    pub docker: String,
    pub engine: String,
    pub docker_version: String,
    pub docker_api: String,
    pub journal: Vec<String>,
    pub filevault: String,
    /// Fester Code des letzten Fehlers in der App (z. B. `start-failed`), nie dessen Meldungstext.
    pub last_error: String,
}

fn code<T: serde::Serialize>(v: &T) -> String {
    match serde_json::to_value(v) {
        Ok(serde_json::Value::String(s)) => s,
        Ok(serde_json::Value::Object(m)) => m.get("kind").or_else(|| m.get("step")).and_then(|k| k.as_str()).unwrap_or("?").to_string(),
        _ => "?".into(),
    }
}

/// Versionen sehen aus wie `27.3.1` oder `15.1`; alles andere fällt weg.
fn version_only(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_digit() || *c == '.').take(16).collect()
}

/// Die festen Fehler-Codes der App. Alles andere wird zu `other`, so kann kein Meldungstext durchrutschen.
pub const ERROR_CODES: [&str; 19] = [
    "system-blocked",
    "docker-unsupported",
    "docker-remote",
    "docker-too-old",
    "download-failed",
    "signature-failed",
    "install-failed",
    "install-cancelled",
    "docker-start-timeout",
    "foreign-objects",
    "no-free-port",
    "compose-missing",
    "start-failed",
    "wizard-unavailable",
    "power-failed",
    "power-cancelled",
    "journal-unreadable",
    "rollback-failed",
    "deviation",
];

fn code_only(s: &str) -> String {
    if s.is_empty() {
        String::new()
    } else if ERROR_CODES.contains(&s) {
        s.to_string()
    } else {
        "other".into()
    }
}

pub fn build(app_version: &str, sys: &SystemReport, f: Option<&Finding>, j: &Journal, fv: FileVault, last_error: &str) -> ErrorReport {
    let running = f.and_then(|f| f.running.as_ref());
    ErrorReport {
        app_version: version_only(app_version),
        os: code(&sys.os),
        os_version: version_only(&sys.os_version),
        arch: code(&sys.arch),
        ram_gb: sys.ram_gb,
        free_gb: sys.free_gb,
        checks: sys.checks.iter().map(|c| format!("{}={}", c.id, code(&c.level))).collect(),
        docker: f.map(|f| code(&f.verdict)).unwrap_or_else(|| "not-checked".into()),
        engine: match f.map(|f| &f.verdict) {
            Some(Verdict::Ready { engine, .. }) | Some(Verdict::OtherStopped { engine }) | Some(Verdict::Unsupported { engine }) => {
                code(engine)
            }
            _ => running.map(|r| code(&r.engine)).unwrap_or_default(),
        },
        docker_version: running.map(|r| version_only(&r.version)).unwrap_or_default(),
        docker_api: running.map(|r| version_only(&r.api)).unwrap_or_default(),
        journal: j.entries.iter().map(|e| format!("{}:{}", code(&e.step), code(&e.state))).collect(),
        filevault: code(&fv),
        last_error: code_only(last_error),
    }
}

impl ErrorReport {
    /// Text zum Kopieren in eine Nachricht.
    pub fn to_text(&self) -> String {
        format!(
            "lifeagents Fehlerbericht\napp: {}\nsystem: {} {} {}\nspeicher: {} GB, frei: {} GB\npruefungen: {}\ndocker: {} {} {} (API {})\njournal: {}\nfilevault: {}\nletzter fehler: {}\n",
            self.app_version,
            self.os,
            self.os_version,
            self.arch,
            self.ram_gb,
            self.free_gb,
            self.checks.join(", "),
            self.docker,
            self.engine,
            self.docker_version,
            self.docker_api,
            self.journal.join(", "),
            self.filevault,
            self.last_error
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::autostart::Autostart;
    use crate::detect::{Engine, Running};
    use crate::docker::Docker;
    use crate::host::{Arch, FakeHost, Os};
    use crate::journal::Step;
    use crate::system::{Check, Level};

    #[test]
    fn report_carries_no_paths_names_or_log_text() {
        let h = FakeHost::mac();
        let sys = SystemReport {
            os: Os::Mac,
            arch: Arch::Arm64,
            os_version: "15.1".into(),
            ram_gb: 16,
            free_gb: 240,
            laptop: false,
            checks: vec![Check { id: "ram", level: Level::Ok, value: "16".into(), need: "4".into() }],
        };
        let f = Finding {
            installed: vec![Engine::DockerDesktop],
            docker: Some(Docker { bin: "/Users/erika/secret/docker".into(), context: "erikas-context".into() }),
            endpoint: Some("unix:///Users/erika/.docker/run/docker.sock".into()),
            running: Some(Running {
                engine: Engine::DockerDesktop,
                version: "27.3.1".into(),
                api: "1.47".into(),
                mem_total_mb: 8000,
                mem_used_mb: 700,
                containers_running: 3,
            }),
            verdict: Verdict::Ready { engine: Engine::DockerDesktop, tested: true, containers_running: 3 },
        };
        let mut j = crate::journal::Journal::default();
        let seq = j
            .begin(
                &h,
                Step::AutostartInstalled { entry: Autostart::MacLaunchAgent { path: "/Users/erika/Library/LaunchAgents/x.plist".into() } },
            )
            .unwrap();
        j.done(&h, seq, None).unwrap();
        let r = build("0.1.0", &sys, Some(&f), &j, FileVault::On, "Start scheiterte: Bind for 127.0.0.1:5880 failed /Users/erika");
        let text = r.to_text();
        for bad in ["/Users", "erika", "127.0.0.1", "secret", "context", "Bind"] {
            assert!(!text.contains(bad), "{bad} im Bericht:\n{text}");
        }
        assert!(text.contains("docker: ready docker-desktop 27.3.1 (API 1.47)"), "{text}");
        assert!(text.contains("journal: autostart-installed:done"), "{text}");
        assert!(text.contains("filevault: on"));
        assert!(text.contains("letzter fehler: other"));
        assert_eq!(build("0.1.0", &sys, None, &j, FileVault::On, "start-failed").last_error, "start-failed");
    }
}
