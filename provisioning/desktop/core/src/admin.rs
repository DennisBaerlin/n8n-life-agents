//! Passwort-Abfrage über die System-Mechanik. Die App sieht das Passwort nie.
//!
//! Mac: `osascript … with administrator privileges` zeigt den System-Dialog. Windows: `Start-Process -Verb RunAs`
//! zeigt die Benutzerkontensteuerung. Ein Abbruch durch den Nutzer ist kein Fehler, sondern `Cancelled`.

use crate::host::{CmdOut, Host};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdminError {
    /// Der Nutzer hat den Dialog abgebrochen.
    Cancelled,
    Failed(String),
}

/// Ein Argument für `sh` sicher in einfache Anführungszeichen setzen.
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Text als AppleScript-Zeichenkette (Backslash und Anführungszeichen maskiert).
pub fn applescript_string(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Argumente für `/usr/bin/osascript`, die `shell` als Administrator ausführen.
pub fn mac_admin_args(shell: &str) -> Vec<String> {
    vec!["-e".into(), format!("do shell script {} with administrator privileges", applescript_string(shell))]
}

pub fn run_mac_admin(host: &dyn Host, shell: &str) -> Result<CmdOut, AdminError> {
    let out = host.run("/usr/bin/osascript", &mac_admin_args(shell)).map_err(AdminError::Failed)?;
    if out.success() {
        Ok(out)
    } else if out.stderr.contains("-128") {
        Err(AdminError::Cancelled)
    } else {
        Err(AdminError::Failed(out.stderr.trim().to_string()))
    }
}

/// Ein Argument für PowerShell in einfache Anführungszeichen setzen.
pub fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// Exit-Code, mit dem das Skript einen abgebrochenen UAC-Dialog meldet (ERROR_CANCELLED).
pub const WIN_CANCELLED: u32 = 1223;

/// Programm mit Benutzerkontensteuerung starten und auf das Ende warten; Exit-Code des Programms zurück.
pub fn win_admin_args(program: &str, program_args: &[&str]) -> Vec<String> {
    let list = program_args.iter().map(|a| ps_quote(a)).collect::<Vec<_>>().join(",");
    let script = format!(
        // Abbruch im UAC-Dialog: Win32-Fehler 1223 (ERROR_CANCELLED), unabhängig von der Sprache von Windows.
        "try {{ $p = Start-Process -FilePath {} -ArgumentList {} -Verb RunAs -Wait -PassThru -ErrorAction Stop; exit $p.ExitCode }} \
catch {{ $e = $_.Exception; while ($e) {{ if ($e.NativeErrorCode -eq {WIN_CANCELLED}) {{ exit {WIN_CANCELLED} }}; $e = $e.InnerException }}; throw }}",
        ps_quote(program),
        if list.is_empty() { "@()".to_string() } else { format!("@({list})") }
    );
    vec!["-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), script]
}

pub fn run_win_admin(host: &dyn Host, program: &str, program_args: &[&str]) -> Result<CmdOut, AdminError> {
    let out = host.run("powershell.exe", &win_admin_args(program, program_args)).map_err(AdminError::Failed)?;
    if out.success() {
        Ok(out)
    } else if out.code == WIN_CANCELLED as i32 {
        Err(AdminError::Cancelled)
    } else {
        Err(AdminError::Failed(format!("exit {}", out.code)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::FakeHost;

    #[test]
    fn quoting_survives_hostile_text() {
        assert_eq!(sh_quote("a'b"), "'a'\\''b'");
        assert_eq!(sh_quote("$(rm x)"), "'$(rm x)'");
        assert_eq!(applescript_string("say \"hi\" \\ ok"), "\"say \\\"hi\\\" \\\\ ok\"");
        assert_eq!(ps_quote("it's"), "'it''s'");
        let line = sh_quote("zeile1\nzeile2");
        assert!(line.starts_with('\'') && line.ends_with('\''));
    }

    #[test]
    fn mac_cancel_is_not_an_error() {
        let shell = "/usr/bin/true";
        let h = FakeHost::mac().on(
            &format!("/usr/bin/osascript {}", mac_admin_args(shell).join(" ")),
            CmdOut::fail(1, "0:41: execution error: User canceled. (-128)"),
        );
        assert_eq!(run_mac_admin(&h, shell), Err(AdminError::Cancelled));
    }

    #[test]
    fn windows_cancel_is_detected_by_code_not_language() {
        let exe = "D:\\x.exe";
        let h = FakeHost::windows().on(
            &format!("powershell.exe {}", win_admin_args(exe, &[]).join(" ")),
            CmdOut::fail(1223, "Der Vorgang wurde durch den Benutzer abgebrochen."),
        );
        assert_eq!(run_win_admin(&h, exe, &[]), Err(AdminError::Cancelled));
        let h =
            FakeHost::windows().on(&format!("powershell.exe {}", win_admin_args(exe, &[]).join(" ")), CmdOut::fail(1, "anderer Fehler"));
        assert!(matches!(run_win_admin(&h, exe, &[]), Err(AdminError::Failed(_))));
    }

    #[test]
    fn windows_admin_wraps_runas() {
        let a = win_admin_args("D:\\Downloads\\Docker Desktop Installer.exe", &["install", "--quiet"]);
        assert!(a[3].contains("-Verb RunAs -Wait"));
        assert!(a[3].contains("@('install','--quiet')"));
    }
}
