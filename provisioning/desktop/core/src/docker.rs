//! Positivliste aller Docker-Aufrufe der App. Kein anderes Modul baut Docker-Argumente selbst; jeder Aufruf
//! ist eine Variante von `DockerCall`, läuft mit festem Kontext (`--context`, Prüfliste Nr. 5) und, wenn er
//! etwas ändert, mit festem Projektnamen. Breite Befehle (Aufräumen über alles, „alle“-Schalter beim Löschen,
//! Listen nur aus IDs für Massen-Löschungen) gibt es hier nicht; der Test `no_broad_commands` hält das fest.

use crate::contract::{MasterCmd, FIRST_SERVICES, HINTS_DIR, LABEL, MASTER_CONTAINER, PROBE_VOLUME, PROJECT};
use crate::host::{CmdOut, Host};

/// Gefundenes Docker: Pfad zum Befehl und der festgehaltene Kontext.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Docker {
    pub bin: String,
    pub context: String,
}

pub enum DockerCall<'a> {
    // --- nur lesen ---
    Version,
    Info,
    Stats,
    ContainerIds,
    ContainerInspect(&'a [String]),
    VolumeList,
    NetworkList,
    ImageList,
    /// Ist ein Image schon da? (Vor dem Start: was wir laden, steht danach im Journal.)
    ImageInspect(&'a str),
    /// Objekte mit unserem Namen (Prüfliste Nr. 7): Name und unser Label.
    OurContainers,
    OurVolumes,
    /// Label-Wert eines Volumes (leer = ohne unser Label). Fehlt das Volume, scheitert der Aufruf.
    VolumeLabel(&'a str),
    /// Compose-Datei und Pflicht-Variablen prüfen, ohne etwas auszugeben oder anzulegen.
    ComposeConfig {
        file: &'a str,
        env_file: &'a str,
    },
    // --- ändern, nur unser Projekt ---
    /// Zustandsführendes Volume anlegen (`external` in compose.yml), immer mit unserem Label.
    VolumeCreate(&'a str),
    /// Erste Zustimmung: `anchor`, `postgres`, `master`, `edge` starten (`contract::FIRST_SERVICES`).
    ComposeUpFirst {
        file: &'a str,
        env_file: &'a str,
    },
    /// Nach der Einrichtung bei jeder Anmeldung: vorhandene Container starten, nichts neu anlegen.
    ComposeStart {
        file: &'a str,
        env_file: &'a str,
    },
    /// Entfernen (Nr. 17): Container und Netz des Projekts, nie Volumes (die sind `external`).
    ComposeDown {
        file: &'a str,
        env_file: &'a str,
    },
    /// Fähigkeits-Prüfung (Plan Nr. 9), Wegwerf-Container mit unserem Label im eigenen Probe-Volume:
    /// 1. Verzeichnis mit Datei ins Volume schreiben.
    ProbeWrite {
        image: &'a str,
    },
    /// 2. Dasselbe Verzeichnis als Volume-Unterpfad einhängen und lesen (Engine ab 26; Linux-Engine kann nur
    ///    Verzeichnisse, keine Datei als Unterpfad, darum genau das prüfen).
    ProbeRead {
        image: &'a str,
    },
    /// 3. Docker-Zugang im Container (der `master` braucht den Socket).
    ProbeSocket {
        image: &'a str,
    },
    /// Volume löschen, nur nach Rückfrage und nur mit unserem Label (Aufrufer prüft).
    VolumeRemove(&'a str),
    /// Image löschen, nur wenn das Journal sagt, dass wir es geladen haben.
    ImageRemove(&'a str),
    /// Befehl im `master` (Schnittstelle zu Paket 4).
    Master(MasterCmd),
    /// Hinweise für den Fragebogen als flüchtige Datei im `master` (0600, nur root); Inhalt über stdin (`call_stdin`).
    MasterHints,
    /// Fragebogen im Änderungs-Modus im Hintergrund starten (`contract::WIZARD_SERVER --backup-dir`).
    MasterBackupDir,
}

/// Alle Zustände einzeln als Filter: listet auch gestoppte Container, ohne den „alle“-Schalter, den der
/// Lint gegen breite Befehle verbietet (mehrere `status`-Filter sind ODER-verknüpft).
const ALL_STATES: [&str; 7] = ["created", "restarting", "running", "removing", "paused", "exited", "dead"];

fn push_all_states(a: &mut Vec<String>) {
    for s in ALL_STATES {
        a.push("--filter".into());
        a.push(format!("status={s}"));
    }
}

const FMT_CONTAINER: &str = "{{.Name}}|{{.Id}}|{{.Image}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.State.Status}}|{{index .Config.Labels \"com.docker.compose.project\"}}";

impl Docker {
    pub fn args(&self, call: &DockerCall) -> Vec<String> {
        let mut a: Vec<String> = vec!["--context".into(), self.context.clone()];
        fn p(a: &mut Vec<String>, xs: &[&str]) {
            a.extend(xs.iter().map(|s| s.to_string()));
        }
        match call {
            DockerCall::Version => p(&mut a, &["version", "--format", "{{json .}}"]),
            DockerCall::Info => p(&mut a, &["info", "--format", "{{json .}}"]),
            DockerCall::Stats => p(&mut a, &["stats", "--no-stream", "--format", "{{.Name}}|{{.MemUsage}}"]),
            DockerCall::ContainerIds => {
                p(&mut a, &["container", "ls"]);
                push_all_states(&mut a);
                a.extend(["--no-trunc", "--format", "{{.ID}}"].map(String::from));
            }
            DockerCall::ContainerInspect(ids) => {
                p(&mut a, &["container", "inspect", "--format", FMT_CONTAINER]);
                a.extend(ids.iter().cloned());
            }
            DockerCall::VolumeList => p(&mut a, &["volume", "ls", "--format", "{{.Name}}|{{.Labels}}"]),
            DockerCall::NetworkList => p(&mut a, &["network", "ls", "--no-trunc", "--format", "{{.Name}}|{{.ID}}"]),
            DockerCall::ImageList => p(&mut a, &["image", "ls", "--no-trunc", "--format", "{{.Repository}}:{{.Tag}}|{{.ID}}"]),
            DockerCall::ImageInspect(reference) => {
                p(&mut a, &["image", "inspect", "--format", "{{.Id}}"]);
                a.push(reference.to_string());
            }
            DockerCall::OurContainers => {
                p(&mut a, &["container", "ls"]);
                push_all_states(&mut a);
                a.push("--filter".into());
                a.push(format!("name=^{PROJECT}-"));
                a.extend(["--format", "{{.Names}}|{{.Labels}}"].map(String::from));
            }
            DockerCall::OurVolumes => {
                p(&mut a, &["volume", "ls", "--filter"]);
                a.push(format!("name=^{PROJECT}_"));
                p(&mut a, &["--format", "{{.Name}}|{{.Labels}}"]);
            }
            DockerCall::VolumeLabel(name) => {
                p(&mut a, &["volume", "inspect", "--format"]);
                a.push(format!("{{{{index .Labels \"{LABEL}\"}}}}"));
                a.push(name.to_string());
            }
            DockerCall::ComposeConfig { file, env_file } => {
                compose(&mut a, file, env_file);
                p(&mut a, &["config", "--quiet"]);
            }
            DockerCall::VolumeCreate(name) => {
                p(&mut a, &["volume", "create", "--label"]);
                a.push(format!("{LABEL}={PROJECT}"));
                a.push(name.to_string());
            }
            DockerCall::ComposeUpFirst { file, env_file } => {
                compose(&mut a, file, env_file);
                p(&mut a, &["up", "--detach", "--no-recreate"]);
                p(&mut a, &FIRST_SERVICES);
            }
            DockerCall::ComposeStart { file, env_file } => {
                compose(&mut a, file, env_file);
                p(&mut a, &["start"]);
            }
            DockerCall::ComposeDown { file, env_file } => {
                compose(&mut a, file, env_file);
                p(&mut a, &["down"]);
            }
            DockerCall::ProbeWrite { image } => {
                probe_run(&mut a, &format!("type=volume,src={PROBE_VOLUME},dst=/v"));
                a.extend([image.to_string(), "sh".into(), "-c".into(), "mkdir -p /v/sub && echo ok > /v/sub/f".into()]);
            }
            DockerCall::ProbeRead { image } => {
                probe_run(&mut a, &format!("type=volume,src={PROBE_VOLUME},dst=/m,volume-subpath=sub,readonly"));
                a.extend([image.to_string(), "cat".into(), "/m/f".into()]);
            }
            DockerCall::ProbeSocket { image } => {
                probe_run(&mut a, "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock");
                a.extend([image.to_string(), "test".into(), "-S".into(), "/var/run/docker.sock".into()]);
            }
            DockerCall::VolumeRemove(name) => {
                p(&mut a, &["volume", "rm"]);
                a.push(name.to_string());
            }
            DockerCall::ImageRemove(reference) => {
                p(&mut a, &["image", "rm"]);
                a.push(reference.to_string());
            }
            DockerCall::MasterHints => {
                p(&mut a, &["exec", "--interactive", MASTER_CONTAINER, "sh", "-c"]);
                a.push(format!("umask 077; mkdir -p {HINTS_DIR}; cat > {HINTS_DIR}/hints.env"));
            }
            DockerCall::Master(cmd) => {
                p(&mut a, &["exec", MASTER_CONTAINER]);
                a.extend(cmd.args());
            }
            DockerCall::MasterBackupDir => {
                p(&mut a, &["exec", "--detach", MASTER_CONTAINER, "node", crate::contract::WIZARD_SERVER, "--backup-dir"]);
            }
        }
        a
    }

    pub fn call(&self, host: &dyn Host, call: DockerCall) -> Result<CmdOut, String> {
        host.run(&self.bin, &self.args(&call))
    }

    /// Wie `call`, Eingabe über stdin (private Werte nie im argv).
    pub fn call_stdin(&self, host: &dyn Host, call: DockerCall, input: &str) -> Result<CmdOut, String> {
        host.run_stdin(&self.bin, &self.args(&call), input)
    }
}

/// Vor dem Festhalten des Kontexts (Nr. 5): Name des aktiven Kontexts. Nur lesen.
pub fn context_show(host: &dyn Host, bin: &str) -> Option<String> {
    let out = host.run(bin, &["context".to_string(), "show".to_string()]).ok()?;
    let name = out.stdout.trim().to_string();
    (out.success() && !name.is_empty()).then_some(name)
}

/// Ziel-Adresse eines Kontexts (`unix://…`, `npipe://…`, `ssh://…`). Nur lesen.
pub fn context_endpoint(host: &dyn Host, bin: &str, name: &str) -> Option<String> {
    let a: Vec<String> = ["context", "inspect", name, "--format", "{{.Endpoints.docker.Host}}"].iter().map(|s| s.to_string()).collect();
    let out = host.run(bin, &a).ok()?;
    let ep = out.stdout.trim().to_string();
    (out.success() && !ep.is_empty()).then_some(ep)
}

/// `run --rm` mit unserem Label und genau einem Mount; kein Netz, nichts bleibt zurück.
fn probe_run(a: &mut Vec<String>, mount: &str) {
    for s in ["run", "--rm", "--network", "none", "--label"] {
        a.push(s.to_string());
    }
    a.push(format!("{LABEL}={PROJECT}"));
    a.push("--mount".into());
    a.push(mount.to_string());
}

fn compose(a: &mut Vec<String>, file: &str, env_file: &str) {
    for s in ["compose", "--project-name", PROJECT, "--file", file, "--env-file", env_file] {
        a.push(s.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_calls() -> Vec<DockerCall<'static>> {
        static IDS: [String; 0] = [];
        vec![
            DockerCall::Version,
            DockerCall::Info,
            DockerCall::Stats,
            DockerCall::ContainerIds,
            DockerCall::ContainerInspect(&IDS),
            DockerCall::VolumeList,
            DockerCall::NetworkList,
            DockerCall::ImageList,
            DockerCall::ImageInspect("busybox@sha256:00"),
            DockerCall::OurContainers,
            DockerCall::OurVolumes,
            DockerCall::ComposeUpFirst { file: "c.yml", env_file: "e.env" },
            DockerCall::ComposeStart { file: "c.yml", env_file: "e.env" },
            DockerCall::ComposeDown { file: "c.yml", env_file: "e.env" },
            DockerCall::VolumeRemove("lifeagents_pgdata"),
            DockerCall::ImageRemove("busybox@sha256:00"),
            DockerCall::Master(MasterCmd::WizardUrl),
            DockerCall::Master(MasterCmd::WizardStatus),
            DockerCall::Master(MasterCmd::PowerDone),
            DockerCall::VolumeLabel("lifeagents_pgdata"),
            DockerCall::ComposeConfig { file: "c.yml", env_file: "e.env" },
            DockerCall::VolumeCreate("lifeagents_pgdata"),
            DockerCall::ProbeWrite { image: "busybox:1.37" },
            DockerCall::ProbeRead { image: "busybox:1.37" },
            DockerCall::ProbeSocket { image: "busybox:1.37" },
            DockerCall::Master(MasterCmd::ReleaseWebhook),
            DockerCall::Master(MasterCmd::BackupKit),
            DockerCall::MasterHints,
            DockerCall::MasterBackupDir,
        ]
    }

    #[test]
    fn every_call_pins_the_context() {
        let d = Docker { bin: "docker".into(), context: "desktop-linux".into() };
        for c in all_calls() {
            let a = d.args(&c);
            assert_eq!(&a[..2], &["--context".to_string(), "desktop-linux".to_string()]);
        }
    }

    #[test]
    fn no_broad_commands() {
        // Zusammengesetzt, damit ein Text-Lint über das Repo diese Liste nicht selbst als Fund meldet.
        let banned: Vec<String> = vec![
            ["pr", "une"].concat(),
            ["--", "volumes"].concat(),
            ["-", "v"].concat(),
            ["--", "force"].concat(),
            ["-", "f"].concat(),
            ["-", "q"].concat(),
            ["--", "quiet"].concat(),
            ["-", "a"].concat(),
            ["--", "all"].concat(),
            ["--", "remove-orphans"].concat(),
            ["--", "rmi"].concat(),
            ["kil", "l"].concat(),
            ["restart"].concat(),
        ];
        let d = Docker { bin: "docker".into(), context: "default".into() };
        for c in all_calls() {
            let a = d.args(&c);
            for (i, arg) in a.iter().enumerate() {
                // Einzige Ausnahme: `compose config --quiet` prüft nur und gibt nichts aus (kein ID-Listing).
                if arg == "--quiet" && i > 0 && a[i - 1] == "config" {
                    continue;
                }
                assert!(!banned.contains(arg), "verbotenes Argument {arg} in {a:?}");
            }
        }
    }

    #[test]
    fn created_volumes_carry_our_label() {
        let d = Docker { bin: "docker".into(), context: "default".into() };
        assert_eq!(
            d.args(&DockerCall::VolumeCreate("lifeagents_pgdata")).join(" "),
            "--context default volume create --label io.lifeagents.install=lifeagents lifeagents_pgdata"
        );
    }

    #[test]
    fn writes_always_carry_our_project() {
        let d = Docker { bin: "docker".into(), context: "default".into() };
        for c in all_calls() {
            let a = d.args(&c);
            if a.contains(&"compose".to_string()) {
                let i = a.iter().position(|x| x == "--project-name").expect("Projektname fehlt");
                assert_eq!(a[i + 1], PROJECT);
            }
        }
    }

    #[test]
    fn first_start_only_the_services_of_package_1() {
        let d = Docker { bin: "docker".into(), context: "default".into() };
        let a = d.args(&DockerCall::ComposeUpFirst { file: "c.yml", env_file: "e.env" });
        assert_eq!(a[a.len() - 4..].join(" "), "anchor postgres master edge");
        assert!(a.contains(&"--no-recreate".to_string()));
    }
}
