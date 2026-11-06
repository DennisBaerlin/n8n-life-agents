//! Start bei der Anmeldung. Mac: eigener LaunchAgent mit eindeutigem Namen statt `SMAppService` (Forenberichte
//! über Fehler ohne echte Signatur; Mac-Test prüft). Windows: Wert unter `HKCU\…\Run`. Beides nur für den
//! angemeldeten Nutzer, ohne Passwort.

use crate::host::{args, join, Host, Os};

pub const LABEL: &str = "io.lifeagents.desktop.autostart";
pub const WIN_RUN_KEY: &str = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
pub const WIN_VALUE: &str = "lifeagents";
/// Schalter, mit dem die App beim Anmelden startet: ohne Fenster, nur Symbol, Docker und Verbund hochbringen.
pub const AUTOSTART_ARG: &str = "--autostart";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Autostart {
    MacLaunchAgent { path: String },
    WindowsRun { key: String, value: String },
}

pub fn launch_agent_path(host: &dyn Host) -> String {
    join(Os::Mac, &[&host.home(), "Library/LaunchAgents", &format!("{LABEL}.plist")])
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

pub fn plist(exe: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{}</string>
    <string>{AUTOSTART_ARG}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
"#,
        xml_escape(exe)
    )
}

/// Schreibt den Eintrag. `exe` = Pfad der laufenden App (nur aus dem Programme-Ordner, siehe `system::install_location`).
pub fn install(host: &dyn Host, exe: &str) -> Result<Autostart, String> {
    match host.os() {
        Os::Mac => {
            let path = launch_agent_path(host);
            host.write_file(&path, &plist(exe))?;
            Ok(Autostart::MacLaunchAgent { path })
        }
        Os::Windows => {
            let data = format!("\"{exe}\" {AUTOSTART_ARG}");
            let out = host.run("reg.exe", &args(&["add", WIN_RUN_KEY, "/v", WIN_VALUE, "/t", "REG_SZ", "/d", &data, "/f"]))?;
            if !out.success() {
                return Err(format!("reg add -> {}", out.code));
            }
            Ok(Autostart::WindowsRun { key: WIN_RUN_KEY.into(), value: WIN_VALUE.into() })
        }
    }
}

/// Entfernt nur unseren Eintrag; fehlt er schon, ist das kein Fehler.
pub fn remove(host: &dyn Host, a: &Autostart) -> Result<(), String> {
    match a {
        Autostart::MacLaunchAgent { path } => {
            if !path.ends_with(&format!("/{LABEL}.plist")) {
                return Err(format!("fremder Pfad im Journal: {path}"));
            }
            host.remove_file(path)
        }
        Autostart::WindowsRun { key, value } => {
            if key != WIN_RUN_KEY || value != WIN_VALUE {
                return Err("fremder Registry-Eintrag im Journal".into());
            }
            let out = host.run("reg.exe", &args(&["delete", key, "/v", value, "/f"]))?;
            // 1 = Wert fehlt schon
            if out.success() || out.code == 1 {
                Ok(())
            } else {
                Err(format!("reg delete -> {}", out.code))
            }
        }
    }
}

pub fn is_installed(host: &dyn Host) -> bool {
    match host.os() {
        Os::Mac => host.exists(&launch_agent_path(host)),
        Os::Windows => host.run("reg.exe", &args(&["query", WIN_RUN_KEY, "/v", WIN_VALUE])).map(|o| o.success()).unwrap_or(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};

    #[test]
    fn mac_launch_agent_has_unique_label_and_escaped_path() {
        let h = FakeHost::mac();
        let a = install(&h, "/Applications/lifeagents & co.app/Contents/MacOS/lifeagents").unwrap();
        let path = "/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist";
        assert_eq!(a, Autostart::MacLaunchAgent { path: path.into() });
        let text = h.read_file(path).unwrap();
        assert!(text.contains("<string>io.lifeagents.desktop.autostart</string>"));
        assert!(text.contains("lifeagents &amp; co.app"));
        assert!(text.contains("<string>--autostart</string>"));
        assert!(is_installed(&h));
        remove(&h, &a).unwrap();
        assert!(!is_installed(&h));
    }

    #[test]
    fn remove_refuses_foreign_paths() {
        let h = FakeHost::mac();
        let foreign = Autostart::MacLaunchAgent { path: "/Users/erika/Library/LaunchAgents/com.example.other.plist".into() };
        assert!(remove(&h, &foreign).is_err());
    }

    #[test]
    fn windows_run_value() {
        let exe = "D:\\Programs\\lifeagents\\lifeagents.exe";
        let h = FakeHost::windows()
            .on(&format!("reg.exe add {WIN_RUN_KEY} /v lifeagents /t REG_SZ /d \"{exe}\" --autostart /f"), CmdOut::ok(""))
            .on(&format!("reg.exe delete {WIN_RUN_KEY} /v lifeagents /f"), CmdOut::fail(1, ""));
        let a = install(&h, exe).unwrap();
        assert_eq!(remove(&h, &a), Ok(()), "fehlt schon = in Ordnung");
    }
}
