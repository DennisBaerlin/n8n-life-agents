//! Docker-Erkennung (Prüfliste Nr. 4 und 5, Plan *Wenn Docker schon da ist*). Nur lesen.
//!
//! **Die Falle:** Eine Prüfung nur auf „Docker antwortet“ hielte ein ausgeschaltetes Docker für „fehlt“ und
//! installierte darüber. Darum zuerst: Ist irgendetwas installiert (Programm, Befehl, Socket, Kontext,
//! WSL-Engine)? Erst danach: Läuft es? `Verdict::Missing` gibt es nur, wenn keinerlei Hinweis auf Docker
//! gefunden wurde, und nur dann darf die App Docker Desktop holen (`docker_desktop::guard_install`).

use crate::docker::{Docker, DockerCall};
use crate::host::{args, join, Host, Os};

/// Docker-Engine ab 26 (API 1.45) kann Datei-Mounts aus einem Volume-Unterpfad (Plan, Einwand 23).
pub const MIN_API: (u32, u32) = (1, 45);
/// Freier Speicher in Docker, den unser Verbund mindestens braucht (Testpaket-Grenze, Mac-Test prüft nach).
pub const NEED_FREE_MB: u64 = 2500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Engine {
    DockerDesktop,
    OrbStack,
    RancherDesktop,
    Colima,
    Podman,
    /// Docker-Befehl aus Homebrew ohne eine der Apps oben.
    HomebrewDocker,
    /// Eigene Docker-Engine in einer WSL-Distribution (Windows).
    Wsl,
    /// Befehl, Socket oder Named Pipe ohne erkennbares Programm.
    Unknown,
}

impl Engine {
    /// Die App nutzt nur diese mit; getestet wird nur Docker Desktop.
    pub fn usable(self) -> bool {
        matches!(self, Engine::DockerDesktop | Engine::OrbStack | Engine::RancherDesktop)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Verdict {
    /// Nichts installiert: Docker nach Zustimmung holen.
    Missing,
    /// Docker Desktop installiert, aber aus: starten und warten, nichts installieren.
    DesktopStopped,
    /// Läuft und reicht: mitnutzen, keine Zustimmungs-Seite fürs Holen, kein Passwort.
    Ready { engine: Engine, tested: bool, containers_running: u32 },
    /// Zu alt: um ein Update in Docker bitten, nie selbst aktualisieren.
    TooOld { api: String, need: String },
    /// Zu wenig freier Speicher in Docker: sagen, wo man ihn einstellt; selbst nichts ändern.
    LowMemory { free_mb: u64, need_mb: u64 },
    /// OrbStack oder Rancher Desktop installiert, aber aus: nichts dazu installieren, Hilfe zeigen.
    OtherStopped { engine: Engine },
    /// Colima, Podman, Homebrew, WSL-Engine oder Unbekanntes: nichts dazu installieren, Hilfe zeigen.
    Unsupported { engine: Engine },
    /// Der Docker-Kontext zeigt auf einen anderen Rechner: Abbruch.
    RemoteContext { endpoint: String },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Running {
    pub engine: Engine,
    pub version: String,
    pub api: String,
    pub mem_total_mb: u64,
    pub mem_used_mb: u64,
    pub containers_running: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Finding {
    /// Alles, was installiert gefunden wurde, auch was nicht benutzt wird.
    pub installed: Vec<Engine>,
    /// Gefundener Befehl mit festgehaltenem Kontext; alle weiteren Aufrufe laufen darüber.
    pub docker: Option<Docker>,
    pub endpoint: Option<String>,
    pub running: Option<Running>,
    pub verdict: Verdict,
}

pub fn detect(host: &dyn Host) -> Finding {
    // 1. Was ist installiert? Nur Dateien und Registry, noch kein Docker-Aufruf.
    let installed = scan_installed(host);
    let cli = find_cli(host, &installed);
    let mut f = Finding { installed, docker: None, endpoint: None, running: None, verdict: Verdict::Missing };

    // 2. Eine Umgebungsvariable kann jeden Kontext überstimmen: zeigt sie weg, sofort Abbruch.
    if let Some(dh) = host.env("DOCKER_HOST") {
        if !is_local(&dh) {
            f.verdict = Verdict::RemoteContext { endpoint: dh };
            return f;
        }
    }

    // 3. Kontext festhalten (Nr. 5); alle weiteren Aufrufe laufen mit genau diesem Kontext.
    if let Some(bin) = &cli {
        if let Some(ctx) = crate::docker::context_show(host, bin) {
            let ep = crate::docker::context_endpoint(host, bin, &ctx);
            if let Some(ep) = &ep {
                if !is_local(ep) {
                    f.verdict = Verdict::RemoteContext { endpoint: ep.clone() };
                    f.endpoint = Some(ep.clone());
                    return f;
                }
            }
            f.endpoint = ep;
            f.docker = Some(Docker { bin: bin.clone(), context: ctx });
        }
    }

    // 4. Kein einziger Hinweis auf Docker: nur dann „fehlt“.
    let evidence = !f.installed.is_empty() || cli.is_some() || socket_evidence(host);
    if !evidence {
        return f;
    }

    // 5. Läuft es? Wer es ist, sagt die laufende Engine selbst; sonst die Adresse des Kontexts.
    let by_endpoint = f.endpoint.as_deref().map(|ep| engine_from_endpoint(ep, &f.installed));
    if let Some(d) = f.docker.clone() {
        if let Some(r) = read_running(host, &d, by_endpoint) {
            f.verdict = judge_running(&r);
            f.running = Some(r);
            return f;
        }
    }

    // 6. Läuft nicht. Nie installieren: starten (Docker Desktop) oder Hilfe zeigen.
    let engine = match by_endpoint {
        Some(Engine::Unknown) | None => primary(&f.installed, cli.as_deref()),
        Some(e) => e,
    };
    f.verdict = match engine {
        Engine::DockerDesktop => Verdict::DesktopStopped,
        Engine::OrbStack | Engine::RancherDesktop => Verdict::OtherStopped { engine },
        e => Verdict::Unsupported { engine: e },
    };
    f
}

fn judge_running(r: &Running) -> Verdict {
    if !r.engine.usable() {
        return Verdict::Unsupported { engine: r.engine };
    }
    if parse_api(&r.api) < MIN_API {
        return Verdict::TooOld { api: r.api.clone(), need: format!("{}.{}", MIN_API.0, MIN_API.1) };
    }
    let free = r.mem_total_mb.saturating_sub(r.mem_used_mb);
    if free < NEED_FREE_MB {
        return Verdict::LowMemory { free_mb: free, need_mb: NEED_FREE_MB };
    }
    Verdict::Ready { engine: r.engine, tested: r.engine == Engine::DockerDesktop, containers_running: r.containers_running }
}

/// Programme und Befehle, die auf ein Docker hinweisen. Reihenfolge = Vorrang beim Benennen.
fn scan_installed(host: &dyn Host) -> Vec<Engine> {
    let mut out = Vec::new();
    fn add(out: &mut Vec<Engine>, e: Engine, hit: bool) {
        if hit && !out.contains(&e) {
            out.push(e);
        }
    }
    let any = |paths: &[String]| paths.iter().any(|p| host.exists(p));
    let home = host.home();
    match host.os() {
        Os::Mac => {
            add(&mut out, Engine::DockerDesktop, any(&[s("/Applications/Docker.app"), join(Os::Mac, &[&home, "Applications/Docker.app"])]));
            add(&mut out, Engine::OrbStack, any(&[s("/Applications/OrbStack.app"), join(Os::Mac, &[&home, ".orbstack"])]));
            add(&mut out, Engine::RancherDesktop, any(&[s("/Applications/Rancher Desktop.app"), join(Os::Mac, &[&home, ".rd"])]));
            add(
                &mut out,
                Engine::Colima,
                any(&[s("/opt/homebrew/bin/colima"), s("/usr/local/bin/colima"), join(Os::Mac, &[&home, ".colima"])]),
            );
            add(
                &mut out,
                Engine::Podman,
                any(&[
                    s("/opt/podman/bin/podman"),
                    s("/opt/homebrew/bin/podman"),
                    s("/usr/local/bin/podman"),
                    s("/Applications/Podman Desktop.app"),
                ]),
            );
            let app = out.iter().any(|e| matches!(e, Engine::DockerDesktop | Engine::OrbStack | Engine::RancherDesktop));
            add(&mut out, Engine::HomebrewDocker, !app && any(&[s("/opt/homebrew/bin/docker")]));
        }
        Os::Windows => {
            let pf = host.env("ProgramFiles").unwrap_or_else(|| s("C:\\Program Files"));
            let la = host.env("LOCALAPPDATA").unwrap_or_else(|| join(Os::Windows, &[&home, "AppData\\Local"]));
            let reg =
                host.run("reg", &args(&["query", "HKLM\\SOFTWARE\\Docker Inc.\\Docker Desktop"])).map(|o| o.success()).unwrap_or(false);
            add(&mut out, Engine::DockerDesktop, reg || any(&[join(Os::Windows, &[&pf, "Docker\\Docker\\Docker Desktop.exe"])]));
            add(
                &mut out,
                Engine::RancherDesktop,
                any(&[
                    join(Os::Windows, &[&pf, "Rancher Desktop\\Rancher Desktop.exe"]),
                    join(Os::Windows, &[&la, "Programs\\Rancher Desktop\\Rancher Desktop.exe"]),
                ]),
            );
            add(
                &mut out,
                Engine::Podman,
                any(&[
                    join(Os::Windows, &[&pf, "RedHat\\Podman\\podman.exe"]),
                    join(Os::Windows, &[&la, "Programs\\Podman Desktop\\Podman Desktop.exe"]),
                ]),
            );
            // Eigene Engine in WSL nur suchen, wenn sonst nichts da ist: sie wäre der einzige Grund, nicht zu holen.
            if out.is_empty() && wsl_engine(host) {
                add(&mut out, Engine::Wsl, true);
            }
        }
    }
    out
}

/// WSL-Distributionen (ohne die von Docker Desktop, Rancher und Podman) mit eigenem `dockerd`.
/// Startet die Distribution kurz, ändert darin nichts (Handliste: auf echtem Windows prüfen).
fn wsl_engine(host: &dyn Host) -> bool {
    let Ok(out) = host.run("wsl.exe", &args(&["--list", "--quiet"])) else { return false };
    if !out.success() {
        return false;
    }
    let skip = ["docker-desktop", "docker-desktop-data", "rancher-desktop", "rancher-desktop-data", "podman-machine-default"];
    out.stdout.replace('\0', "").lines().map(|l| l.trim()).filter(|d| !d.is_empty() && !skip.contains(d)).any(|d| {
        host.run("wsl.exe", &args(&["--distribution", d, "--exec", "sh", "-c", "command -v dockerd"]))
            .map(|o| o.success() && !o.stdout.trim().is_empty())
            .unwrap_or(false)
    })
}

/// Der Docker-Befehl als fester Pfad: Eine Mac-App sieht den PATH der Kommandozeile nicht.
fn find_cli(host: &dyn Host, installed: &[Engine]) -> Option<String> {
    let home = host.home();
    let candidates: Vec<String> = match host.os() {
        Os::Mac => vec![
            s("/Applications/Docker.app/Contents/Resources/bin/docker"),
            join(Os::Mac, &[&home, "Applications/Docker.app/Contents/Resources/bin/docker"]),
            join(Os::Mac, &[&home, ".orbstack/bin/docker"]),
            s("/Applications/OrbStack.app/Contents/MacOS/xbin/docker"),
            join(Os::Mac, &[&home, ".rd/bin/docker"]),
            s("/opt/homebrew/bin/docker"),
            s("/usr/local/bin/docker"),
        ],
        Os::Windows => {
            let pf = host.env("ProgramFiles").unwrap_or_else(|| s("C:\\Program Files"));
            vec![
                join(Os::Windows, &[&pf, "Docker\\Docker\\resources\\bin\\docker.exe"]),
                join(Os::Windows, &[&pf, "Rancher Desktop\\resources\\resources\\win32\\bin\\docker.exe"]),
            ]
        }
    };
    if let Some(c) = candidates.into_iter().find(|c| host.exists(c)) {
        return Some(c);
    }
    if host.os() == Os::Windows {
        let out = host.run("where.exe", &args(&["docker"])).ok()?;
        let first = out.stdout.lines().map(str::trim).find(|l| !l.is_empty())?.to_string();
        return out.success().then_some(first);
    }
    let _ = installed;
    None
}

fn socket_evidence(host: &dyn Host) -> bool {
    let home = host.home();
    let paths: Vec<String> = match host.os() {
        Os::Mac => vec![s("/var/run/docker.sock"), join(Os::Mac, &[&home, ".docker/run/docker.sock"])],
        Os::Windows => vec![s("\\\\.\\pipe\\docker_engine"), s("\\\\.\\pipe\\dockerDesktopLinuxEngine")],
    };
    paths.iter().any(|p| host.exists(p))
}

fn is_local(endpoint: &str) -> bool {
    endpoint.starts_with("unix://") || endpoint.starts_with("npipe://")
}

fn engine_from_endpoint(ep: &str, installed: &[Engine]) -> Engine {
    let e = ep.to_ascii_lowercase();
    if e.contains(".orbstack") {
        Engine::OrbStack
    } else if e.contains(".colima") {
        Engine::Colima
    } else if e.contains("/.rd/") || e.contains("rancher") {
        Engine::RancherDesktop
    } else if e.contains("podman") {
        Engine::Podman
    } else if e.contains("dockerdesktop") || e.contains("/.docker/run/docker.sock") {
        Engine::DockerDesktop
    } else {
        // Gemeinsame Standard-Adressen (/var/run/docker.sock, docker_engine) nutzen mehrere Programme.
        installed
            .iter()
            .copied()
            .find(|i| matches!(i, Engine::DockerDesktop | Engine::OrbStack | Engine::RancherDesktop))
            .unwrap_or(Engine::Unknown)
    }
}

/// Wofür steht der Fund, wenn die Adresse nichts sagt? Unbenutzbares geht vor: lieber Hilfe als Fehlgriff.
fn primary(installed: &[Engine], cli: Option<&str>) -> Engine {
    for e in [Engine::Colima, Engine::Podman, Engine::Wsl] {
        if installed.contains(&e) {
            return e;
        }
    }
    if let Some(e) = installed.first() {
        return *e;
    }
    match cli {
        Some(c) if c.starts_with("/opt/homebrew/") => Engine::HomebrewDocker,
        _ => Engine::Unknown,
    }
}

fn read_running(host: &dyn Host, d: &Docker, by_endpoint: Option<Engine>) -> Option<Running> {
    let info = d.call(host, DockerCall::Info).ok().filter(|o| o.success())?;
    let info: serde_json::Value = serde_json::from_str(info.stdout.trim()).ok()?;
    let server_version = info.get("ServerVersion").and_then(|v| v.as_str()).unwrap_or("");
    if server_version.is_empty() {
        return None;
    }
    let os_name = info.get("OperatingSystem").and_then(|v| v.as_str()).unwrap_or("");
    let engine = if os_name.contains("Docker Desktop") {
        Engine::DockerDesktop
    } else if os_name.contains("OrbStack") {
        Engine::OrbStack
    } else if os_name.contains("Rancher") {
        Engine::RancherDesktop
    } else {
        by_endpoint.unwrap_or(Engine::Unknown)
    };
    let api = d
        .call(host, DockerCall::Version)
        .ok()
        .filter(|o| o.success())
        .and_then(|o| serde_json::from_str::<serde_json::Value>(o.stdout.trim()).ok())
        .and_then(|v| v.pointer("/Server/ApiVersion").and_then(|a| a.as_str()).map(String::from))
        .unwrap_or_default();
    let mem_total_mb = info.get("MemTotal").and_then(|v| v.as_u64()).unwrap_or(0) / (1024 * 1024);
    let containers_running = info.get("ContainersRunning").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
    let mem_used_mb = if engine.usable() {
        d.call(host, DockerCall::Stats).ok().filter(|o| o.success()).map(|o| sum_mem_usage(&o.stdout)).unwrap_or(0)
    } else {
        0
    };
    Some(Running { engine, version: server_version.to_string(), api, mem_total_mb, mem_used_mb, containers_running })
}

/// „612.5MiB / 7.654GiB“ je Zeile → belegte MB zusammen.
pub fn sum_mem_usage(stats: &str) -> u64 {
    let mut total = 0.0f64;
    for line in stats.lines() {
        let used = line.split('|').nth(1).unwrap_or("").split('/').next().unwrap_or("").trim();
        total += parse_size_mb(used);
    }
    total.round() as u64
}

fn parse_size_mb(s: &str) -> f64 {
    let num: String = s.chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
    let n: f64 = num.parse().unwrap_or(0.0);
    let unit = s[num.len()..].trim();
    match unit {
        "GiB" | "GB" => n * 1024.0,
        "MiB" | "MB" => n,
        "KiB" | "kB" | "KB" => n / 1024.0,
        "B" => n / (1024.0 * 1024.0),
        "TiB" | "TB" => n * 1024.0 * 1024.0,
        _ => 0.0,
    }
}

/// „1.47“ → (1, 47). Unlesbar → (0, 0), gilt damit als zu alt.
pub fn parse_api(api: &str) -> (u32, u32) {
    let mut it = api.trim().split('.');
    let major = it.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    let minor = it.next().and_then(|x| x.parse().ok()).unwrap_or(0);
    (major, minor)
}

fn s(x: &str) -> String {
    x.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};

    const DD_CLI: &str = "/Applications/Docker.app/Contents/Resources/bin/docker";
    const WIN_DD_EXE: &str = "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe";
    const WIN_DD_CLI: &str = "C:\\Program Files\\Docker\\Docker\\resources\\bin\\docker.exe";
    const WIN_DD_REG: &str = "reg query HKLM\\SOFTWARE\\Docker Inc.\\Docker Desktop";

    fn info_json(os_name: &str, mem_gib: u64, running: u32) -> String {
        format!(
            r#"{{"ServerVersion":"27.3.1","OperatingSystem":"{os_name}","MemTotal":{},"ContainersRunning":{running}}}"#,
            mem_gib * 1024 * 1024 * 1024
        )
    }
    fn version_json(api: &str) -> String {
        format!(r#"{{"Client":{{"Version":"27.3.1"}},"Server":{{"Version":"27.3.1","ApiVersion":"{api}"}}}}"#)
    }
    const DAEMON_DOWN: &str =
        "Cannot connect to the Docker daemon at unix:///Users/erika/.docker/run/docker.sock. Is the docker daemon running?";

    /// Befehl + Kontext antworten wie ein echtes Docker; `up` = Daemon läuft.
    fn with_cli(h: FakeHost, bin: &str, ctx: &str, endpoint: &str, up: Option<(&str, &str, u64, u32, &str)>) -> FakeHost {
        let h = h
            .with_path(bin)
            .on(&format!("{bin} context show"), CmdOut::ok(&format!("{ctx}\n")))
            .on(&format!("{bin} context inspect {ctx} --format {{{{.Endpoints.docker.Host}}}}"), CmdOut::ok(&format!("{endpoint}\n")));
        match up {
            None => h
                .on(&format!("{bin} --context {ctx} info --format {{{{json .}}}}"), CmdOut::fail(1, DAEMON_DOWN))
                .on(&format!("{bin} --context {ctx} version --format {{{{json .}}}}"), CmdOut::fail(1, DAEMON_DOWN)),
            Some((os_name, api, mem_gib, running, stats)) => h
                .on(&format!("{bin} --context {ctx} info --format {{{{json .}}}}"), CmdOut::ok(&info_json(os_name, mem_gib, running)))
                .on(&format!("{bin} --context {ctx} version --format {{{{json .}}}}"), CmdOut::ok(&version_json(api)))
                .on(&format!("{bin} --context {ctx} stats --no-stream --format {{{{.Name}}}}|{{{{.MemUsage}}}}"), CmdOut::ok(stats)),
        }
    }

    fn mac_dd_running(api: &str, mem_gib: u64, stats: &str) -> FakeHost {
        let h = FakeHost::mac().with_path("/Applications/Docker.app");
        with_cli(
            h,
            DD_CLI,
            "desktop-linux",
            "unix:///Users/erika/.docker/run/docker.sock",
            Some(("Docker Desktop", api, mem_gib, 3, stats)),
        )
    }

    const STATS_3: &str =
        "paperless-webserver-1|612.5MiB / 7.654GiB\npaperless-broker-1|9.2MiB / 7.654GiB\npaperless-db-1|48MiB / 7.654GiB\n";

    fn assert_never_installs(f: &Finding) {
        assert_ne!(f.verdict, Verdict::Missing, "Fund {:?} darf nie als „fehlt“ gelten", f.installed);
    }

    // ---- Mac: Tabelle Zeile für Zeile -------------------------------------------------------------------

    #[test]
    fn mac_nothing_installed_is_missing() {
        let f = detect(&FakeHost::mac());
        assert_eq!(f.verdict, Verdict::Missing);
        assert!(f.installed.is_empty());
        assert!(f.docker.is_none());
    }

    #[test]
    fn mac_desktop_installed_but_off_is_started_not_installed() {
        let h = FakeHost::mac().with_path("/Applications/Docker.app");
        let h = with_cli(h, DD_CLI, "desktop-linux", "unix:///Users/erika/.docker/run/docker.sock", None);
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::DesktopStopped);
        assert_eq!(f.installed, vec![Engine::DockerDesktop]);
        assert_never_installs(&f);
    }

    #[test]
    fn mac_desktop_off_without_working_cli_is_still_not_missing() {
        // App vorhanden, Befehl fehlt (z. B. nie gestartet, Symlink weg): trotzdem nie „fehlt“.
        let h = FakeHost::mac().with_path("/Applications/Docker.app");
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::DesktopStopped);
    }

    #[test]
    fn mac_desktop_in_user_applications_counts() {
        let h = FakeHost::mac().with_path("/Users/erika/Applications/Docker.app");
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::DesktopStopped);
    }

    #[test]
    fn mac_desktop_running_is_reused_with_pinned_context() {
        let f = detect(&mac_dd_running("1.47", 8, STATS_3));
        assert_eq!(f.verdict, Verdict::Ready { engine: Engine::DockerDesktop, tested: true, containers_running: 3 });
        let d = f.docker.expect("Docker fehlt");
        assert_eq!(d.context, "desktop-linux");
        assert_eq!(d.bin, DD_CLI);
        let r = f.running.expect("läuft");
        assert_eq!(r.api, "1.47");
        assert_eq!(r.mem_used_mb, 670);
    }

    #[test]
    fn mac_desktop_too_old_asks_for_update() {
        let f = detect(&mac_dd_running("1.44", 8, STATS_3));
        assert_eq!(f.verdict, Verdict::TooOld { api: "1.44".into(), need: "1.45".into() });
    }

    #[test]
    fn mac_api_compares_numerically_not_as_text() {
        let f = detect(&mac_dd_running("1.100", 8, STATS_3));
        assert!(matches!(f.verdict, Verdict::Ready { .. }), "{:?}", f.verdict);
    }

    #[test]
    fn mac_desktop_low_memory_names_numbers() {
        // 4 GiB gesamt, 2 GiB belegt -> 2048 MB frei < 2500
        let f = detect(&mac_dd_running("1.47", 4, "paperless-webserver-1|2GiB / 4GiB\n"));
        assert_eq!(f.verdict, Verdict::LowMemory { free_mb: 2048, need_mb: NEED_FREE_MB });
    }

    #[test]
    fn mac_orbstack_running_is_reused_untested() {
        let h = FakeHost::mac().with_path("/Applications/OrbStack.app");
        let h = with_cli(
            h,
            "/Users/erika/.orbstack/bin/docker",
            "orbstack",
            "unix:///Users/erika/.orbstack/run/docker.sock",
            Some(("OrbStack", "1.47", 8, 1, "")),
        );
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Ready { engine: Engine::OrbStack, tested: false, containers_running: 1 });
    }

    #[test]
    fn mac_orbstack_off_gets_help_not_install() {
        let h = FakeHost::mac().with_path("/Applications/OrbStack.app");
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::OtherStopped { engine: Engine::OrbStack });
    }

    #[test]
    fn mac_rancher_running_is_reused() {
        let h = FakeHost::mac().with_path("/Applications/Rancher Desktop.app");
        let h = with_cli(
            h,
            "/Users/erika/.rd/bin/docker",
            "rancher-desktop",
            "unix:///Users/erika/.rd/docker.sock",
            Some(("Rancher Desktop", "1.46", 8, 0, "")),
        );
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Ready { engine: Engine::RancherDesktop, tested: false, containers_running: 0 });
    }

    #[test]
    fn mac_rancher_off_gets_help() {
        let h = FakeHost::mac().with_path("/Applications/Rancher Desktop.app");
        assert_eq!(detect(&h).verdict, Verdict::OtherStopped { engine: Engine::RancherDesktop });
    }

    #[test]
    fn mac_colima_running_is_unsupported() {
        let h = FakeHost::mac().with_path("/opt/homebrew/bin/colima");
        let h = with_cli(
            h,
            "/opt/homebrew/bin/docker",
            "colima",
            "unix:///Users/erika/.colima/default/docker.sock",
            Some(("Ubuntu 24.04 LTS", "1.47", 8, 2, "")),
        );
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Unsupported { engine: Engine::Colima });
    }

    #[test]
    fn mac_colima_off_is_unsupported_never_missing() {
        let h = FakeHost::mac().with_path("/Users/erika/.colima");
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Unsupported { engine: Engine::Colima });
    }

    #[test]
    fn mac_podman_is_unsupported() {
        let h = FakeHost::mac().with_path("/opt/podman/bin/podman");
        assert_eq!(detect(&h).verdict, Verdict::Unsupported { engine: Engine::Podman });
    }

    #[test]
    fn mac_homebrew_cli_without_engine_is_unsupported() {
        let h = with_cli(FakeHost::mac(), "/opt/homebrew/bin/docker", "default", "unix:///var/run/docker.sock", None);
        assert_eq!(detect(&h).verdict, Verdict::Unsupported { engine: Engine::HomebrewDocker });
    }

    #[test]
    fn mac_socket_only_is_unknown_never_missing() {
        let h = FakeHost::mac().with_path("/var/run/docker.sock");
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Unsupported { engine: Engine::Unknown });
    }

    #[test]
    fn mac_remote_context_aborts() {
        let h = FakeHost::mac().with_path("/Applications/Docker.app");
        let h = with_cli(h, DD_CLI, "nas", "ssh://erika@nas.example", None);
        assert_eq!(detect(&h).verdict, Verdict::RemoteContext { endpoint: "ssh://erika@nas.example".into() });
    }

    #[test]
    fn mac_docker_host_env_to_other_machine_aborts() {
        let h = FakeHost::mac().with_path("/Applications/Docker.app").with_env("DOCKER_HOST", "tcp://192.0.2.10:2376");
        assert_eq!(detect(&h).verdict, Verdict::RemoteContext { endpoint: "tcp://192.0.2.10:2376".into() });
    }

    #[test]
    fn mac_desktop_installed_but_active_context_is_colima() {
        // Docker Desktop ist da, benutzt wird aber Colima: nichts umstellen, Hilfe zeigen.
        let h = FakeHost::mac().with_path("/Applications/Docker.app").with_path("/opt/homebrew/bin/colima");
        let h =
            with_cli(h, DD_CLI, "colima", "unix:///Users/erika/.colima/default/docker.sock", Some(("Ubuntu 24.04 LTS", "1.47", 8, 2, "")));
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Unsupported { engine: Engine::Colima });
        assert!(f.installed.contains(&Engine::DockerDesktop) && f.installed.contains(&Engine::Colima));
    }

    #[test]
    fn mac_detection_changes_nothing() {
        let h = mac_dd_running("1.47", 8, STATS_3);
        detect(&h);
        let calls = h.calls.borrow().clone();
        for c in &calls {
            let ok = c.contains(" context show")
                || c.contains(" context inspect ")
                || c.contains(" info ")
                || c.contains(" version ")
                || c.contains(" stats --no-stream");
            assert!(ok, "Erkennung darf nur lesen: {c}");
        }
        assert!(h.spawned.borrow().is_empty());
    }

    // ---- Windows --------------------------------------------------------------------------------------

    fn win() -> FakeHost {
        FakeHost::windows()
            .with_env("ProgramFiles", "C:\\Program Files")
            .with_env("LOCALAPPDATA", "D:\\Profiles\\erika\\AppData\\Local")
            .on(WIN_DD_REG, CmdOut::fail(1, "FEHLER: Der angegebene Registrierungsschluessel wurde nicht gefunden."))
            .on("where.exe docker", CmdOut::fail(1, ""))
            .on("wsl.exe --list --quiet", CmdOut::ok(""))
    }

    #[test]
    fn win_nothing_installed_is_missing() {
        assert_eq!(detect(&win()).verdict, Verdict::Missing);
    }

    #[test]
    fn win_desktop_in_registry_only_is_started() {
        let h = win();
        h.set(WIN_DD_REG, CmdOut::ok("HKEY_LOCAL_MACHINE\\SOFTWARE\\Docker Inc.\\Docker Desktop\n"));
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::DesktopStopped);
    }

    #[test]
    fn win_desktop_off_is_started() {
        let h = win().with_path(WIN_DD_EXE);
        let h = with_cli(h, WIN_DD_CLI, "desktop-linux", "npipe:////./pipe/dockerDesktopLinuxEngine", None);
        assert_eq!(detect(&h).verdict, Verdict::DesktopStopped);
    }

    #[test]
    fn win_desktop_running_is_reused() {
        let h = win().with_path(WIN_DD_EXE);
        let h = with_cli(
            h,
            WIN_DD_CLI,
            "desktop-linux",
            "npipe:////./pipe/dockerDesktopLinuxEngine",
            Some(("Docker Desktop", "1.47", 8, 3, STATS_3)),
        );
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Ready { engine: Engine::DockerDesktop, tested: true, containers_running: 3 });
        assert_eq!(f.docker.unwrap().context, "desktop-linux");
    }

    #[test]
    fn win_wsl_engine_is_unsupported_never_missing() {
        let h = win()
            .on("wsl.exe --list --quiet", CmdOut::ok("Ubuntu\r\ndocker-desktop\r\n"))
            .on("wsl.exe --distribution Ubuntu --exec sh -c command -v dockerd", CmdOut::ok("/usr/bin/dockerd\n"));
        let f = detect(&h);
        assert_eq!(f.verdict, Verdict::Unsupported { engine: Engine::Wsl });
    }

    #[test]
    fn win_wsl_distro_without_docker_is_missing() {
        let h = win()
            .on("wsl.exe --list --quiet", CmdOut::ok("Ubuntu\r\n"))
            .on("wsl.exe --distribution Ubuntu --exec sh -c command -v dockerd", CmdOut::fail(1, ""));
        assert_eq!(detect(&h).verdict, Verdict::Missing);
    }

    #[test]
    fn win_rancher_off_gets_help() {
        let h = win().with_path("C:\\Program Files\\Rancher Desktop\\Rancher Desktop.exe");
        assert_eq!(detect(&h).verdict, Verdict::OtherStopped { engine: Engine::RancherDesktop });
    }

    #[test]
    fn win_podman_is_unsupported() {
        let h = win().with_path("C:\\Program Files\\RedHat\\Podman\\podman.exe");
        assert_eq!(detect(&h).verdict, Verdict::Unsupported { engine: Engine::Podman });
    }

    #[test]
    fn win_named_pipe_only_is_unknown() {
        let h = win().with_path("\\\\.\\pipe\\docker_engine");
        assert_eq!(detect(&h).verdict, Verdict::Unsupported { engine: Engine::Unknown });
    }

    #[test]
    fn win_cli_on_path_only_is_unknown() {
        let h = win();
        h.set("where.exe docker", CmdOut::ok("C:\\tools\\docker.exe\r\n"));
        let h = with_cli(h, "C:\\tools\\docker.exe", "default", "npipe:////./pipe/docker_engine", None);
        assert_eq!(detect(&h).verdict, Verdict::Unsupported { engine: Engine::Unknown });
    }
}
