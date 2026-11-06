//! Rechner-Prüfung (Prüfliste Nr. 1) und Zeitpunkt-Prüfung (Nr. 3). Nur lesen, ohne Frage.
//!
//! Ergebnisse sind Codes mit Zahlen, keine Sätze: Die Texte stehen in der Oberfläche (`ui/app.js`).

use crate::host::{args, Arch, Host, Os};

/// Docker verlangt laut Hersteller mindestens 4 GB (Mac) bzw. 8 GB (Windows) Arbeitsspeicher.
pub const MIN_RAM_GB_MAC: u64 = 4;
pub const MIN_RAM_GB_WIN: u64 = 8;
/// Freier Platz: Grenze aus dem Testpaket (Docker-Daten + unsere Images), Mac-Test prüft nach.
pub const MIN_FREE_GB: u64 = 10;
/// Docker Desktop unterstützt die aktuelle und die zwei vorigen macOS-Hauptversionen (Stand macOS 26).
pub const MIN_MACOS_MAJOR: u32 = 14;
/// Windows 10 22H2 (Build 19045) oder Windows 11.
pub const MIN_WIN_BUILD: u32 = 19045;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Ok,
    /// Hinweis, Frage „später weitermachen?“ (Nr. 3)
    Hint,
    /// Abbruch mit Erklärung (Nr. 1)
    Stop,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Check {
    /// Fester Name der Prüfung, z. B. `ram`, `disk`, `os-version`.
    pub id: &'static str,
    pub level: Level,
    /// Gemessener Wert als Text (für die Oberfläche und den Fehlerbericht), z. B. „8“ oder „15.1“.
    pub value: String,
    /// Grenze als Text, z. B. „4“.
    pub need: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct SystemReport {
    pub os: Os,
    pub arch: Arch,
    pub os_version: String,
    pub ram_gb: u64,
    pub free_gb: u64,
    /// Rechner mit Akku (Laptop): Dauerbetrieb gilt dort nur am Netzteil.
    pub laptop: bool,
    pub checks: Vec<Check>,
}

impl SystemReport {
    pub fn blocked(&self) -> bool {
        self.checks.iter().any(|c| c.level == Level::Stop)
    }
}

fn check(id: &'static str, ok: bool, stop: bool, value: impl ToString, need: impl ToString) -> Check {
    let level = if ok {
        Level::Ok
    } else if stop {
        Level::Stop
    } else {
        Level::Hint
    };
    Check { id, level, value: value.to_string(), need: need.to_string() }
}

fn out(host: &dyn Host, prog: &str, a: &[&str]) -> Option<String> {
    host.run(prog, &args(a)).ok().filter(|o| o.success()).map(|o| o.stdout.trim().to_string())
}

pub fn check_system(host: &dyn Host) -> SystemReport {
    match host.os() {
        Os::Mac => check_mac(host),
        Os::Windows => check_windows(host),
    }
}

fn check_mac(host: &dyn Host) -> SystemReport {
    let version = out(host, "/usr/bin/sw_vers", &["-productVersion"]).unwrap_or_default();
    let major: u32 = version.split('.').next().and_then(|m| m.parse().ok()).unwrap_or(0);
    let ram_gb = out(host, "/usr/sbin/sysctl", &["-n", "hw.memsize"]).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0) / (1 << 30);
    let free_gb = out(host, "/bin/df", &["-k", &host.home()]).map(|t| parse_df_free_gb(&t)).unwrap_or(0);
    let hv = out(host, "/usr/sbin/sysctl", &["-n", "kern.hv_support"]).as_deref() == Some("1");
    // Unter Rosetta meldet die App x86_64; die Hardware zählt.
    let arm = out(host, "/usr/sbin/sysctl", &["-n", "hw.optional.arm64"]).as_deref() == Some("1");
    let arch = if arm { Arch::Arm64 } else { host.arch() };
    let batt = out(host, "/usr/bin/pmset", &["-g", "batt"]).unwrap_or_default();
    let laptop = batt.contains("InternalBattery");
    let on_battery = batt.contains("'Battery Power'");
    let backup_running = out(host, "/usr/bin/tmutil", &["status"]).map(|t| t.contains("Running = 1")).unwrap_or(false);
    let checks = vec![
        check("os-version", major >= MIN_MACOS_MAJOR, true, &version, MIN_MACOS_MAJOR),
        check("ram", ram_gb >= MIN_RAM_GB_MAC, true, ram_gb, MIN_RAM_GB_MAC),
        check("disk", free_gb >= MIN_FREE_GB, true, free_gb, MIN_FREE_GB),
        check("virtualization", hv, true, hv, true),
        check("power-source", !on_battery, false, if on_battery { "battery" } else { "ac" }, "ac"),
        check("backup-running", !backup_running, false, backup_running, false),
    ];
    SystemReport { os: Os::Mac, arch, os_version: version, ram_gb, free_gb, laptop, checks }
}

/// `df -k <ordner>`: zweite Zeile, vierte Spalte = verfügbare 1K-Blöcke.
pub fn parse_df_free_gb(df: &str) -> u64 {
    df.lines()
        .nth(1)
        .and_then(|l| l.split_whitespace().nth(3))
        .and_then(|v| v.parse::<u64>().ok())
        .map(|kb| kb / (1024 * 1024))
        .unwrap_or(0)
}

/// Eine PowerShell-Abfrage, Antwort als JSON. Nur lesen.
pub const WIN_QUERY: &str = "$o=Get-CimInstance Win32_OperatingSystem; $c=Get-CimInstance Win32_ComputerSystem; \
$d=Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$env:SystemDrive'\"; $p=Get-CimInstance Win32_Processor | Select-Object -First 1; \
$b=@(Get-CimInstance Win32_Battery); $s=Get-Service LanmanServer -ErrorAction SilentlyContinue; \
[pscustomobject]@{build=[int]$o.BuildNumber; caption=[string]$o.Caption; ram=[int64]$c.TotalPhysicalMemory; free=[int64]$d.FreeSpace; \
virt=[bool]$p.VirtualizationFirmwareEnabled; hypervisor=[bool]$c.HypervisorPresent; battery=($b.Count -gt 0); \
on_battery=(@($b | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0); lanman=[string]$s.Status} | ConvertTo-Json -Compress";

fn check_windows(host: &dyn Host) -> SystemReport {
    let raw = out(host, "powershell.exe", &["-NoProfile", "-NonInteractive", "-Command", WIN_QUERY]).unwrap_or_default();
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);
    let num = |k: &str| v.get(k).and_then(|x| x.as_i64()).unwrap_or(0).max(0) as u64;
    let flag = |k: &str| v.get(k).and_then(|x| x.as_bool()).unwrap_or(false);
    let build = num("build") as u32;
    let ram_gb = (num("ram") + (1 << 29)) / (1 << 30); // gerundet: 7,9 GB Anzeige = 8 GB verbaut
    let free_gb = num("free") / (1 << 30);
    // Läuft Hyper-V schon, meldet die Firmware-Abfrage „aus“; dann ist Virtualisierung trotzdem da.
    let virt = flag("virt") || flag("hypervisor");
    let wsl = host.run("wsl.exe", &args(&["--status"])).map(|o| o.success()).unwrap_or(false);
    let lanman = v.get("lanman").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let checks = vec![
        check("os-version", build >= MIN_WIN_BUILD, true, build, MIN_WIN_BUILD),
        check("ram", ram_gb >= MIN_RAM_GB_WIN, true, ram_gb, MIN_RAM_GB_WIN),
        check("disk", free_gb >= MIN_FREE_GB, true, free_gb, MIN_FREE_GB),
        check("virtualization", virt, true, virt, true),
        // Fehlt WSL, richtet der Docker-Installer es ein; danach braucht Windows einen Neustart.
        check("wsl", wsl, false, wsl, true),
        check("lanman-server", lanman.is_empty() || lanman == "Running", false, &lanman, "Running"),
        check("power-source", !flag("on_battery"), false, if flag("on_battery") { "battery" } else { "ac" }, "ac"),
    ];
    let caption = v.get("caption").and_then(|x| x.as_str()).unwrap_or("").to_string();
    SystemReport {
        os: Os::Windows,
        arch: host.arch(),
        os_version: format!("{caption} ({build})"),
        ram_gb,
        free_gb,
        laptop: flag("battery"),
        checks,
    }
}

/// Wo läuft die App gerade? Mac: Aus der eingehängten DMG oder verschoben (App Translocation) heißt
/// „erst in den Programme-Ordner ziehen“ (Plan, Start-App Schritt 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Location {
    Installed,
    FromDiskImage,
    Translocated,
}

pub fn install_location(os: Os, exe_path: &str) -> Location {
    if os != Os::Mac {
        return Location::Installed;
    }
    if exe_path.starts_with("/Volumes/") {
        Location::FromDiskImage
    } else if exe_path.contains("/AppTranslocation/") {
        Location::Translocated
    } else {
        Location::Installed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};

    const DF: &str = "Filesystem     1024-blocks      Used Available Capacity iused ifree %iused  Mounted on\n/dev/disk3s5    482797652 210000000 251658240    46% 1 2 0%   /System/Volumes/Data\n";

    fn mac(ver: &str, mem_gib: u64, batt: &str) -> FakeHost {
        FakeHost::mac()
            .on("/usr/bin/sw_vers -productVersion", CmdOut::ok(&format!("{ver}\n")))
            .on("/usr/sbin/sysctl -n hw.memsize", CmdOut::ok(&format!("{}\n", mem_gib << 30)))
            .on("/bin/df -k /Users/erika", CmdOut::ok(DF))
            .on("/usr/sbin/sysctl -n kern.hv_support", CmdOut::ok("1\n"))
            .on("/usr/sbin/sysctl -n hw.optional.arm64", CmdOut::ok("1\n"))
            .on("/usr/bin/pmset -g batt", CmdOut::ok(batt))
            .on(
                "/usr/bin/tmutil status",
                CmdOut::ok("Backup session status:\n{\n    ClientID = \"com.apple.backupd\";\n    Running = 0;\n}\n"),
            )
    }
    const MINI: &str = "Now drawing from 'AC Power'\n";
    const BOOK_BATT: &str = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t80%; discharging\n";

    fn level(r: &SystemReport, id: &str) -> Level {
        r.checks.iter().find(|c| c.id == id).unwrap().level
    }

    #[test]
    fn mac_mini_passes() {
        let r = check_system(&mac("15.1", 16, MINI));
        assert!(!r.blocked(), "{:?}", r.checks);
        assert_eq!((r.ram_gb, r.free_gb, r.laptop, r.arch), (16, 240, false, Arch::Arm64));
    }

    #[test]
    fn mac_too_old_stops() {
        let r = check_system(&mac("13.6.1", 16, MINI));
        assert_eq!(level(&r, "os-version"), Level::Stop);
        assert!(r.blocked());
    }

    #[test]
    fn mac_too_little_ram_stops() {
        assert_eq!(level(&check_system(&mac("15.1", 2, MINI)), "ram"), Level::Stop);
    }

    #[test]
    fn mac_laptop_on_battery_is_hint_not_stop() {
        let r = check_system(&mac("15.1", 8, BOOK_BATT));
        assert!(r.laptop);
        assert_eq!(level(&r, "power-source"), Level::Hint);
        assert!(!r.blocked());
    }

    #[test]
    fn mac_running_backup_is_hint() {
        let h = mac("15.1", 8, MINI);
        h.set("/usr/bin/tmutil status", CmdOut::ok("{\n    Running = 1;\n}\n"));
        assert_eq!(level(&check_system(&h), "backup-running"), Level::Hint);
    }

    #[test]
    fn mac_unreadable_values_never_pass_silently() {
        let r = check_system(&FakeHost::mac());
        assert!(r.blocked(), "Ohne Messwerte darf die Prüfung nicht grün sein");
    }

    #[test]
    fn df_parsing() {
        assert_eq!(parse_df_free_gb(DF), 240);
        assert_eq!(parse_df_free_gb(""), 0);
    }

    fn win(json: &str, wsl_ok: bool) -> FakeHost {
        FakeHost::windows()
            .on(&format!("powershell.exe -NoProfile -NonInteractive -Command {WIN_QUERY}"), CmdOut::ok(json))
            .on("wsl.exe --status", if wsl_ok { CmdOut::ok("") } else { CmdOut::fail(1, "") })
    }

    #[test]
    fn windows_home_pc_passes_with_hyperv_running() {
        let j = r#"{"build":26100,"caption":"Microsoft Windows 11 Home","ram":17079074816,"free":107374182400,"virt":false,"hypervisor":true,"battery":false,"on_battery":false,"lanman":"Running"}"#;
        let r = check_system(&win(j, true));
        assert!(!r.blocked(), "{:?}", r.checks);
        assert_eq!(r.ram_gb, 16);
    }

    #[test]
    fn windows_8gb_shown_as_7_9_still_counts_as_8() {
        let j = r#"{"build":19045,"caption":"Microsoft Windows 10 Pro","ram":8480000000,"free":53687091200,"virt":true,"hypervisor":false,"battery":true,"on_battery":false,"lanman":"Running"}"#;
        let r = check_system(&win(j, false));
        assert_eq!(r.ram_gb, 8);
        assert_eq!(level(&r, "ram"), Level::Ok);
        assert_eq!(level(&r, "wsl"), Level::Hint);
        assert!(r.laptop);
    }

    #[test]
    fn windows_old_build_and_no_virtualization_stop() {
        let j = r#"{"build":19044,"caption":"Microsoft Windows 10 Home","ram":17079074816,"free":107374182400,"virt":false,"hypervisor":false,"battery":false,"on_battery":false,"lanman":"Stopped"}"#;
        let r = check_system(&win(j, true));
        assert_eq!(level(&r, "os-version"), Level::Stop);
        assert_eq!(level(&r, "virtualization"), Level::Stop);
        assert_eq!(level(&r, "lanman-server"), Level::Hint);
    }

    #[test]
    fn location_of_the_app() {
        assert_eq!(install_location(Os::Mac, "/Volumes/lifeagents/lifeagents.app/Contents/MacOS/lifeagents"), Location::FromDiskImage);
        assert_eq!(
            install_location(Os::Mac, "/private/var/folders/xy/T/AppTranslocation/1234/d/lifeagents.app/Contents/MacOS/lifeagents"),
            Location::Translocated
        );
        assert_eq!(install_location(Os::Mac, "/Applications/lifeagents.app/Contents/MacOS/lifeagents"), Location::Installed);
        assert_eq!(install_location(Os::Windows, "D:\\Programs\\lifeagents\\lifeagents.exe"), Location::Installed);
    }
}
