//! Docker Desktop holen, prüfen, installieren, starten (Plan, Start-App Schritt 5). Die eine Stelle, die
//! Docker Desktop kennt: Ein späterer Wechsel (Einwand 21, Lima) träfe nur dieses Modul.
//!
//! Reihenfolge, jeder Schritt einzeln testbar: `guard_install` (nur bei „fehlt“) → `download` direkt beim
//! Hersteller → Unterschrift prüfen (Mac: Team-ID + Gatekeeper-Bewertung, Windows: Authenticode-Herausgeber)
//! → `install_*` mit Passwort über die System-Mechanik → Download löschen → `start`.

use crate::admin::{ps_quote, run_mac_admin, run_win_admin, sh_quote, AdminError};
use crate::detect::{Finding, Verdict};
use crate::host::{args, join, Arch, Host, Os};
use crate::journal;

/// Team-ID von Docker Inc. in der Mac-Unterschrift. **Am Original abgelesen** im CI-Job `vendor-ids`
/// (`.github/workflows/desktop-vendor-ids.yml`), der bei Abweichung rot wird.
pub const MAC_TEAM_ID: &str = "9BNSXJN65R";
/// Organisation im Zertifikat des Windows-Installers, ebenfalls im CI-Job `vendor-ids` am Original geprüft.
pub const WIN_PUBLISHER_ORG: &str = "Docker Inc";

pub const URL_MAC_ARM64: &str = "https://desktop.docker.com/mac/main/arm64/Docker.dmg";
pub const URL_MAC_AMD64: &str = "https://desktop.docker.com/mac/main/amd64/Docker.dmg";
pub const URL_WIN_AMD64: &str = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe";
/// Gemessene Größe am 2026-11-04, nur für die Anzeige („rund 600 MB“) und den Fortschritt.
pub const APPROX_MB_MAC: u64 = 573;
pub const APPROX_MB_WIN: u64 = 624;
pub const TERMS_URL: &str = "https://www.docker.com/legal/docker-subscription-service-agreement/";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchError {
    /// Docker ist in irgendeiner Form da: nie darüber oder daneben installieren.
    NotMissing,
    Download(String),
    /// Unterschrift fehlt, ist ungültig oder von jemand anderem.
    Signature(String),
    Cancelled,
    Install(String),
}

impl From<AdminError> for FetchError {
    fn from(e: AdminError) -> Self {
        match e {
            AdminError::Cancelled => FetchError::Cancelled,
            AdminError::Failed(m) => FetchError::Install(m),
        }
    }
}

/// Die einzige Tür zum Installieren: Nur eine frische Erkennung mit „fehlt“ öffnet sie.
pub fn guard_install(f: &Finding) -> Result<(), FetchError> {
    if f.verdict == Verdict::Missing && f.installed.is_empty() && f.docker.is_none() {
        Ok(())
    } else {
        Err(FetchError::NotMissing)
    }
}

pub fn download_url(os: Os, arch: Arch) -> &'static str {
    match (os, arch) {
        (Os::Mac, Arch::Arm64) => URL_MAC_ARM64,
        (Os::Mac, Arch::X64) => URL_MAC_AMD64,
        (Os::Windows, _) => URL_WIN_AMD64,
    }
}

/// Zielpfad des Downloads im App-Datenordner (neben dem Journal, nicht im App-Paket).
pub fn download_path(host: &dyn Host) -> String {
    let name = match host.os() {
        Os::Mac => "Docker.dmg",
        Os::Windows => "Docker Desktop Installer.exe",
    };
    join(host.os(), &[&journal::dir(host), name])
}

fn curl(os: Os) -> &'static str {
    match os {
        Os::Mac => "/usr/bin/curl",
        Os::Windows => "C:\\Windows\\System32\\curl.exe",
    }
}

/// Lädt mit dem System-`curl`, nur über HTTPS, auch bei Weiterleitungen. Blockiert; den Fortschritt liest die
/// App parallel über die Dateigröße.
pub fn download(host: &dyn Host, dest: &str) -> Result<(), FetchError> {
    host.create_parent_dir(dest).map_err(FetchError::Download)?;
    let url = download_url(host.os(), host.arch());
    let a = args(&[
        "--fail",
        "--location",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--retry",
        "3",
        "--silent",
        "--show-error",
        "--output",
        dest,
        url,
    ]);
    let out = host.run(curl(host.os()), &a).map_err(FetchError::Download)?;
    if out.success() {
        Ok(())
    } else {
        let _ = host.remove_file(dest);
        Err(FetchError::Download(out.stderr.trim().to_string()))
    }
}

pub fn mount_point(host: &dyn Host) -> String {
    join(Os::Mac, &[&journal::dir(host), "docker-dmg"])
}

fn ok(host: &dyn Host, prog: &str, a: &[&str]) -> Result<crate::host::CmdOut, String> {
    let out = host.run(prog, &args(a))?;
    if out.success() {
        Ok(out)
    } else {
        Err(format!("{prog} {} -> {}: {}", a.first().unwrap_or(&""), out.code, out.stderr.trim()))
    }
}

/// DMG schreibgeschützt einhängen und die App darin prüfen. Bei jedem Fehler wieder aushängen.
pub fn verify_mac(host: &dyn Host, dmg: &str) -> Result<String, FetchError> {
    let mnt = mount_point(host);
    ok(host, "/usr/bin/hdiutil", &["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", &mnt, dmg])
        .map_err(FetchError::Signature)?;
    let app = join(Os::Mac, &[&mnt, "Docker.app"]);
    let result = (|| {
        ok(host, "/usr/bin/codesign", &["--verify", "--deep", "--strict", &app]).map_err(FetchError::Signature)?;
        // codesign -d schreibt seine Angaben auf stderr.
        let info = ok(host, "/usr/bin/codesign", &["-dv", "--verbose=2", &app]).map_err(FetchError::Signature)?;
        let team =
            info.stderr.lines().chain(info.stdout.lines()).find_map(|l| l.strip_prefix("TeamIdentifier=")).unwrap_or("").trim().to_string();
        if team != MAC_TEAM_ID {
            return Err(FetchError::Signature(format!("Team-ID {team} statt {MAC_TEAM_ID}")));
        }
        // Gatekeeper muss annehmen (sonst scheitert `ok`). spctl nennt dieselbe Datei mal „Notarized Developer ID“, mal nur
        // „Developer ID“; die Herkunft sichern Signatur und Team-ID oben. Darum zählt die Quell-Zeile genau, nicht ein Teilwort.
        let gk = ok(host, "/usr/sbin/spctl", &["--assess", "--type", "execute", "-vv", &app]).map_err(FetchError::Signature)?;
        let text = format!("{}{}", gk.stdout, gk.stderr);
        let source_ok = text.lines().any(|l| matches!(l.trim(), "source=Notarized Developer ID" | "source=Developer ID"));
        if !source_ok || !text.contains(&format!("({MAC_TEAM_ID})")) {
            return Err(FetchError::Signature("Gatekeeper-Bewertung ohne Developer ID von Docker".into()));
        }
        Ok(app.clone())
    })();
    if result.is_err() {
        let _ = host.run("/usr/bin/hdiutil", &args(&["detach", &mnt]));
    }
    result
}

/// Mac-Nutzername für `--user` (Docker richtet die Rechte für genau diesen Nutzer ein).
pub fn mac_user(host: &dyn Host) -> Option<String> {
    let u = host.env("USER").or_else(|| host.run("/usr/bin/id", &args(&["-un"])).ok().map(|o| o.stdout.trim().to_string()))?;
    // Nur, was ein macOS-Kurzname enthalten kann; schützt die Admin-Zeile zusätzlich zum Quoting.
    (!u.is_empty() && u.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))).then_some(u)
}

/// Installiert aus der eingehängten DMG mit den dokumentierten Schaltern (Einwand 9). Ein Passwort-Dialog.
pub fn install_mac(host: &dyn Host, app_in_dmg: &str) -> Result<(), FetchError> {
    let user = mac_user(host).ok_or_else(|| FetchError::Install("Nutzername unklar".into()))?;
    let installer = format!("{app_in_dmg}/Contents/MacOS/install");
    let line = format!("{} --accept-license {}", sh_quote(&installer), sh_quote(&format!("--user={user}")));
    let result = run_mac_admin(host, &line).map(|_| ()).map_err(FetchError::from);
    let _ = host.run("/usr/bin/hdiutil", &args(&["detach", &mount_point(host)]));
    result
}

pub fn verify_windows(host: &dyn Host, exe: &str) -> Result<(), FetchError> {
    let script = format!(
        "$s = Get-AuthenticodeSignature -LiteralPath {}; [pscustomobject]@{{status=$s.Status.ToString(); subject=[string]$s.SignerCertificate.Subject}} | ConvertTo-Json -Compress",
        ps_quote(exe)
    );
    let out = ok(host, "powershell.exe", &["-NoProfile", "-NonInteractive", "-Command", &script]).map_err(FetchError::Signature)?;
    let v: serde_json::Value = serde_json::from_str(out.stdout.trim()).map_err(|e| FetchError::Signature(e.to_string()))?;
    let status = v.get("status").and_then(|s| s.as_str()).unwrap_or("");
    let subject = v.get("subject").and_then(|s| s.as_str()).unwrap_or("");
    if status != "Valid" {
        return Err(FetchError::Signature(format!("Status {status}")));
    }
    if !subject_has_org(subject, WIN_PUBLISHER_ORG) {
        return Err(FetchError::Signature("anderer Herausgeber".into()));
    }
    Ok(())
}

/// `O=Docker Inc` als ganzes Feld im Zertifikats-Namen (nicht „O=Docker Inc Fake“).
pub fn subject_has_org(subject: &str, org: &str) -> bool {
    subject.split(',').map(str::trim).any(|f| f == format!("O={org}") || f == format!("O=\"{org}\""))
}

pub fn install_windows(host: &dyn Host, exe: &str) -> Result<(), FetchError> {
    run_win_admin(host, exe, &["install", "--quiet", "--accept-license"])?;
    Ok(())
}

/// Docker Desktop öffnen (es war aus oder ist frisch installiert). Danach wartet die App mit `detect`.
pub fn start(host: &dyn Host) -> Result<(), String> {
    match host.os() {
        Os::Mac => {
            let user_app = join(Os::Mac, &[&host.home(), "Applications/Docker.app"]);
            let app = if host.exists("/Applications/Docker.app") { "/Applications/Docker.app".to_string() } else { user_app };
            host.spawn("/usr/bin/open", &args(&["-a", &app]))
        }
        Os::Windows => {
            let pf = host.env("ProgramFiles").unwrap_or_else(|| "C:\\Program Files".to_string());
            host.spawn(&join(Os::Windows, &[&pf, "Docker\\Docker\\Docker Desktop.exe"]), &[])
        }
    }
}

/// Entfernen (Nr. 17, nur wenn das Journal sagt, dass die App Docker installiert hat, und nach eigener Frage):
/// Docker-eigener Deinstaller.
pub fn uninstall(host: &dyn Host) -> Result<(), FetchError> {
    match host.os() {
        Os::Mac => {
            let line = format!(
                "{} && /bin/rm -rf {}",
                sh_quote("/Applications/Docker.app/Contents/MacOS/uninstall"),
                sh_quote("/Applications/Docker.app")
            );
            run_mac_admin(host, &line)?;
            Ok(())
        }
        Os::Windows => {
            let pf = host.env("ProgramFiles").unwrap_or_else(|| "C:\\Program Files".to_string());
            run_win_admin(host, &join(Os::Windows, &[&pf, "Docker\\Docker\\Docker Desktop Installer.exe"]), &["uninstall", "--quiet"])?;
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::admin::{mac_admin_args, win_admin_args};
    use crate::detect::{Engine, Finding};
    use crate::docker::Docker;
    use crate::host::{CmdOut, FakeHost};

    fn finding(v: Verdict, installed: Vec<Engine>) -> Finding {
        Finding { installed, docker: None, endpoint: None, running: None, verdict: v }
    }

    #[test]
    fn install_only_when_nothing_was_found() {
        assert_eq!(guard_install(&finding(Verdict::Missing, vec![])), Ok(()));
        for v in [
            Verdict::DesktopStopped,
            Verdict::Ready { engine: Engine::DockerDesktop, tested: true, containers_running: 0 },
            Verdict::TooOld { api: "1.40".into(), need: "1.45".into() },
            Verdict::LowMemory { free_mb: 1, need_mb: 2 },
            Verdict::OtherStopped { engine: Engine::OrbStack },
            Verdict::Unsupported { engine: Engine::Colima },
            Verdict::RemoteContext { endpoint: "ssh://x".into() },
        ] {
            assert_eq!(guard_install(&finding(v.clone(), vec![])), Err(FetchError::NotMissing), "{v:?}");
        }
        // Widersprüchlicher Fund (Bug oder Wettlauf): lieber nicht installieren.
        assert_eq!(guard_install(&finding(Verdict::Missing, vec![Engine::Podman])), Err(FetchError::NotMissing));
        let mut f = finding(Verdict::Missing, vec![]);
        f.docker = Some(Docker { bin: "docker".into(), context: "default".into() });
        assert_eq!(guard_install(&f), Err(FetchError::NotMissing));
    }

    #[test]
    fn download_comes_from_the_vendor_over_https_only() {
        for (os, arch) in [(Os::Mac, Arch::Arm64), (Os::Mac, Arch::X64), (Os::Windows, Arch::X64)] {
            assert!(download_url(os, arch).starts_with("https://desktop.docker.com/"));
        }
        let h = FakeHost::mac();
        let dest = download_path(&h);
        assert_eq!(dest, "/Users/erika/Library/Application Support/io.lifeagents.desktop/Docker.dmg");
        h.set(
            &format!("/usr/bin/curl --fail --location --proto =https --proto-redir =https --retry 3 --silent --show-error --output {dest} {URL_MAC_ARM64}"),
            CmdOut::fail(22, "curl: (22) The requested URL returned error: 404"),
        );
        assert!(matches!(download(&h, &dest), Err(FetchError::Download(_))));
    }

    /// Live-Fund: Beim Erstlauf fehlt der App-Datenordner, und `curl --output` legt ihn nicht an.
    #[test]
    fn download_creates_its_folder_first() {
        let h = FakeHost::mac();
        let dest = download_path(&h);
        h.set(
            &format!("/usr/bin/curl --fail --location --proto =https --proto-redir =https --retry 3 --silent --show-error --output {dest} {URL_MAC_ARM64}"),
            CmdOut::ok(""),
        );
        download(&h, &dest).unwrap();
        assert_eq!(*h.parent_dirs.borrow(), vec![dest]);
    }

    const MNT: &str = "/Users/erika/Library/Application Support/io.lifeagents.desktop/docker-dmg";
    const DMG: &str = "/Users/erika/Library/Application Support/io.lifeagents.desktop/Docker.dmg";

    fn mac_verify(team: &str, gatekeeper: &str) -> FakeHost {
        let app = format!("{MNT}/Docker.app");
        FakeHost::mac()
            .on(&format!("/usr/bin/hdiutil attach -nobrowse -readonly -noautoopen -mountpoint {MNT} {DMG}"), CmdOut::ok("/dev/disk4\t/Users/erika/x\n"))
            .on(&format!("/usr/bin/codesign --verify --deep --strict {app}"), CmdOut::ok(""))
            .on(
                &format!("/usr/bin/codesign -dv --verbose=2 {app}"),
                CmdOut { code: 0, stdout: String::new(), stderr: format!("Executable={app}/Contents/MacOS/Docker Desktop\nAuthority=Developer ID Application: Docker Inc ({team})\nTeamIdentifier={team}\n") },
            )
            .on(&format!("/usr/sbin/spctl --assess --type execute -vv {app}"), CmdOut { code: 0, stdout: String::new(), stderr: gatekeeper.to_string() })
            .on(&format!("/usr/bin/hdiutil detach {MNT}"), CmdOut::ok(""))
    }

    #[test]
    fn mac_signature_from_docker_passes() {
        let gk = format!(
            "{MNT}/Docker.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Docker Inc ({MAC_TEAM_ID})\n"
        );
        let h = mac_verify(MAC_TEAM_ID, &gk);
        assert_eq!(verify_mac(&h, DMG), Ok(format!("{MNT}/Docker.app")));
        assert!(!h.called(&format!("/usr/bin/hdiutil detach {MNT}")), "bleibt für die Installation eingehängt");
    }

    #[test]
    fn mac_signature_from_someone_else_fails_and_unmounts() {
        let gk = "accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example Ltd (ABCDE12345)\n";
        let h = mac_verify("ABCDE12345", gk);
        assert!(matches!(verify_mac(&h, DMG), Err(FetchError::Signature(_))));
        assert!(h.called(&format!("/usr/bin/hdiutil detach {MNT}")));
    }

    /// CI-Fund: spctl nennt dieselbe Docker-Datei von Lauf zu Lauf „Notarized Developer ID“ oder nur „Developer ID“.
    #[test]
    fn mac_developer_id_without_online_answer_passes() {
        let gk = format!("{MNT}/Docker.app: accepted\nsource=Developer ID\norigin=Developer ID Application: Docker Inc ({MAC_TEAM_ID})\n");
        let h = mac_verify(MAC_TEAM_ID, &gk);
        assert_eq!(verify_mac(&h, DMG), Ok(format!("{MNT}/Docker.app")));
    }

    #[test]
    fn mac_origin_line_alone_is_no_source() {
        let gk = format!("{MNT}/Docker.app: accepted\nsource=Apple\norigin=Developer ID Application: Docker Inc ({MAC_TEAM_ID})\n");
        let h = mac_verify(MAC_TEAM_ID, &gk);
        assert!(matches!(verify_mac(&h, DMG), Err(FetchError::Signature(_))));
    }

    #[test]
    fn mac_not_notarized_fails() {
        let h = mac_verify(MAC_TEAM_ID, "rejected\nsource=Unnotarized Developer ID\n");
        assert!(matches!(verify_mac(&h, DMG), Err(FetchError::Signature(_))));
    }

    #[test]
    fn mac_install_uses_documented_switches_and_system_password() {
        let app = format!("{MNT}/Docker.app");
        let line = format!("'{app}/Contents/MacOS/install' --accept-license '--user=erika'");
        let h = FakeHost::mac()
            .with_env("USER", "erika")
            .on(&format!("/usr/bin/osascript {}", mac_admin_args(&line).join(" ")), CmdOut::ok(""))
            .on(&format!("/usr/bin/hdiutil detach {MNT}"), CmdOut::ok(""));
        assert_eq!(install_mac(&h, &app), Ok(()));
        assert!(h.called(&format!("/usr/bin/hdiutil detach {MNT}")));
    }

    #[test]
    fn mac_install_cancelled_password() {
        let app = format!("{MNT}/Docker.app");
        let line = format!("'{app}/Contents/MacOS/install' --accept-license '--user=erika'");
        let h = FakeHost::mac()
            .with_env("USER", "erika")
            .on(&format!("/usr/bin/osascript {}", mac_admin_args(&line).join(" ")), CmdOut::fail(1, "User canceled. (-128)"));
        assert_eq!(install_mac(&h, &app), Err(FetchError::Cancelled));
    }

    #[test]
    fn mac_user_rejects_odd_names() {
        assert_eq!(mac_user(&FakeHost::mac().with_env("USER", "erika")), Some("erika".into()));
        assert_eq!(mac_user(&FakeHost::mac().with_env("USER", "x'; rm")), None);
    }

    fn win_sig(json: &str) -> FakeHost {
        let exe = "D:\\Profiles\\erika\\AppData\\Local\\io.lifeagents.desktop\\Docker Desktop Installer.exe";
        let script = format!(
            "$s = Get-AuthenticodeSignature -LiteralPath {}; [pscustomobject]@{{status=$s.Status.ToString(); subject=[string]$s.SignerCertificate.Subject}} | ConvertTo-Json -Compress",
            ps_quote(exe)
        );
        FakeHost::windows().on(&format!("powershell.exe -NoProfile -NonInteractive -Command {script}"), CmdOut::ok(json))
    }
    const WIN_EXE: &str = "D:\\Profiles\\erika\\AppData\\Local\\io.lifeagents.desktop\\Docker Desktop Installer.exe";

    #[test]
    fn windows_signature_checks_status_and_publisher() {
        assert_eq!(
            verify_windows(
                &win_sig(r#"{"status":"Valid","subject":"CN=Docker Inc, O=Docker Inc, L=San Francisco, S=California, C=US"}"#),
                WIN_EXE
            ),
            Ok(())
        );
        assert!(verify_windows(&win_sig(r#"{"status":"HashMismatch","subject":"CN=Docker Inc, O=Docker Inc"}"#), WIN_EXE).is_err());
        assert!(verify_windows(&win_sig(r#"{"status":"Valid","subject":"CN=Docker Inc, O=Docker Inc Fake, C=US"}"#), WIN_EXE).is_err());
        assert!(verify_windows(&win_sig(r#"{"status":"NotSigned","subject":""}"#), WIN_EXE).is_err());
    }

    #[test]
    fn windows_install_via_uac() {
        let h = FakeHost::windows().on(
            &format!("powershell.exe {}", win_admin_args(WIN_EXE, &["install", "--quiet", "--accept-license"]).join(" ")),
            CmdOut::ok(""),
        );
        assert_eq!(install_windows(&h, WIN_EXE), Ok(()));
    }

    #[test]
    fn start_opens_the_installed_app() {
        let h = FakeHost::mac().with_path("/Applications/Docker.app");
        start(&h).unwrap();
        assert_eq!(h.spawned.borrow().as_slice(), ["/usr/bin/open -a /Applications/Docker.app"]);
    }
}
