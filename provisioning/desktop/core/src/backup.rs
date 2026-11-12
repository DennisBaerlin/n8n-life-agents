//! Sicherung aus Sicht der App (Plan „Backup-Notfall“ B-6, Owner-Entscheid F6: Notfallblatt nur in der App, nie im
//! Fragebogen): das Notfallblatt in „Downloads“ speichern und den Fragebogen im Änderungs-Modus öffnen (Menüpunkt
//! „Sicherungsordner ändern …“, Owner 2026-11-12: dieselbe Seite „Wohin sichern?“, kein zweiter Weg).
//!
//! **Geheim:** Der Text des Notfallblatts trägt den Sicherungs-Schlüssel. Er geht nur in die neue Datei, nie ins Fenster,
//! ins Journal, in den Fehlerbericht (`report.rs` kennt ihn nicht) oder in eine Fehlermeldung; Fehler sind feste Codes.
//! Eine neue Datei in Downloads ist keine System-Änderung (nichts zum Zurücknehmen), darum kein Journal-Eintrag.

use crate::contract::MasterCmd;
use crate::docker::{Docker, DockerCall};
use crate::host::{join, Host, Os};

/// Fehler-Codes (`report::ERROR_CODES`-Stil): Docker/master antwortet nicht, kein Schlüssel, Datei nicht schreibbar.
pub const KIT_UNAVAILABLE: &str = "kit-unavailable";
pub const KIT_WRITE: &str = "kit-write";

/// Datum `JJJJ-MM-TT` aus Sekunden seit 1970 (UTC; reicht für den Dateinamen).
pub fn day(epoch: u64) -> String {
    let days = (epoch / 86_400) as i64;
    // Howard Hinnant, „civil_from_days“.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    format!("{:04}-{:02}-{:02}", if m <= 2 { y + 1 } else { y }, m, d)
}

/// Ordner „Downloads“ des Nutzers.
pub fn downloads(host: &dyn Host) -> String {
    join(host.os(), &[&host.home(), "Downloads"])
}

/// Notfallblatt aus dem `master` holen und als neue Datei `<base>-<datum>.txt` in Downloads speichern (gibt es sie,
/// `-2`, `-3` …; nie überschreiben). Ergebnis: voller Pfad der Datei.
pub fn save_kit(host: &dyn Host, d: &Docker, base: &str) -> Result<String, &'static str> {
    let out = d.call(host, DockerCall::Master(MasterCmd::BackupKit)).map_err(|_| KIT_UNAVAILABLE)?;
    // Plausibel nur mit Schlüssel-Zeilen; sonst (alter master ohne `backup key`) nichts schreiben.
    if !out.success() || !out.stdout.lines().any(|l| l.trim_start().starts_with("1:")) {
        return Err(KIT_UNAVAILABLE);
    }
    let dir = downloads(host);
    let stem = format!("{base}-{}", day(host.now()));
    let mut path = join(host.os(), &[&dir, &format!("{stem}.txt")]);
    let mut n = 2;
    while host.exists(&path) {
        if n > 99 {
            return Err(KIT_WRITE);
        }
        path = join(host.os(), &[&dir, &format!("{stem}-{n}.txt")]);
        n += 1;
    }
    // Windows-Editor früherer Fassungen zeigt reine LF-Zeilen als eine Zeile.
    let text = if host.os() == Os::Windows { out.stdout.replace('\n', "\r\n") } else { out.stdout.clone() };
    host.write_file(&path, &text).map_err(|_| KIT_WRITE)?;
    Ok(path)
}

/// Merker „Notfallblatt gespeichert und abgehakt“ (neben dem Journal): bis dahin zeigt die Startseite den Schritt weiter.
fn kit_flag(host: &dyn Host) -> String {
    join(host.os(), &[&crate::journal::dir(host), "kit_saved"])
}
pub fn kit_confirmed(host: &dyn Host) -> bool {
    host.exists(&kit_flag(host))
}
pub fn confirm_kit(host: &dyn Host) -> Result<(), String> {
    host.write_file(&kit_flag(host), "1\n")
}

/// Fragebogen im Änderungs-Modus starten und seine Einmal-Adresse holen: Hinweise (Ordner-Vorschläge) frisch an den
/// `master`, Server im Hintergrund starten, dann bis zu `tries` Mal nach der Adresse fragen (er braucht ein, zwei Sekunden).
pub fn open_backup_dir(host: &dyn Host, d: &Docker, port: u16, tries: u32) -> Result<String, String> {
    crate::core_start::send_hints(host, d)?;
    let out = d.call(host, DockerCall::MasterBackupDir)?;
    if !out.success() {
        return Err(format!("Fragebogen nicht gestartet ({})", out.code));
    }
    let mut last = String::new();
    for i in 0..tries.max(1) {
        match crate::core_start::wizard_url(host, d, port) {
            Ok(u) => return Ok(u),
            Err(e) => last = e,
        }
        if i + 1 < tries {
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    }
    Err(last)
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
    // Erfundenes Notfallblatt (Schlüssel-Zeilen in Papierform, kein echter Wert).
    const KIT: &str = "Life Agents – Notfallblatt\n  1:  0123-4567-89ab-cdef  73\n  2:  0123-4567-89ab-cdef  d3\n";

    #[test]
    fn date_of_the_file_name() {
        assert_eq!(day(0), "1970-01-01");
        assert_eq!(day(1_794_441_600), "2026-11-12");
        assert_eq!(day(951_782_400), "2000-02-29");
    }

    #[test]
    fn kit_goes_to_a_new_file_in_downloads_never_overwritten() {
        let h = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupKit)), CmdOut::ok(KIT));
        let p1 = save_kit(&h, &d(), "Life-Agents-Notfallblatt").unwrap();
        assert!(p1.starts_with("/Users/erika/Downloads/Life-Agents-Notfallblatt-") && p1.ends_with(".txt"));
        h.paths.borrow_mut().insert(p1.clone());
        let p2 = save_kit(&h, &d(), "Life-Agents-Notfallblatt").unwrap();
        assert!(p2.ends_with("-2.txt"), "{p2}");
        assert_eq!(h.files.borrow().get(&p2).map(String::as_str), Some(KIT));
    }

    #[test]
    fn windows_lines_and_folder() {
        let h = FakeHost::windows().on(&cmd(DockerCall::Master(MasterCmd::BackupKit)), CmdOut::ok(KIT));
        let p = save_kit(&h, &d(), "Life-Agents-Emergency-Sheet").unwrap();
        assert!(p.starts_with("D:\\Profiles\\erika\\Downloads\\"), "{p}");
        assert!(h.files.borrow().get(&p).unwrap().contains("\r\n"));
    }

    #[test]
    fn no_key_or_docker_off_writes_nothing_and_never_echoes_the_output() {
        let h = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupKit)), CmdOut::fail(1, KIT));
        assert_eq!(save_kit(&h, &d(), "x"), Err(KIT_UNAVAILABLE));
        let h2 = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupKit)), CmdOut::ok("Usage: lifeagents backup …\n"));
        assert_eq!(save_kit(&h2, &d(), "x"), Err(KIT_UNAVAILABLE), "alter master ohne backup key");
        assert!(h.files.borrow().is_empty() && h2.files.borrow().is_empty());
    }

    #[test]
    fn change_folder_starts_the_wizard_mode_and_returns_only_our_address() {
        let h =
            FakeHost::mac().on(&cmd(DockerCall::MasterHints), CmdOut::ok("")).on(&cmd(DockerCall::MasterBackupDir), CmdOut::ok("")).on_seq(
                &cmd(DockerCall::Master(MasterCmd::WizardUrl)),
                vec![CmdOut::fail(1, "Wizard läuft nicht."), CmdOut::ok("{\"url\":\"http://127.0.0.1:5881/start?t=0123abcd\"}\n")],
            );
        let u = open_backup_dir(&h, &d(), 5881, 3).unwrap();
        assert_eq!(u, "http://127.0.0.1:5881/start?t=0123abcd");
        assert!(h.called(&cmd(DockerCall::MasterBackupDir)));
        assert!(cmd(DockerCall::MasterBackupDir).ends_with("node /opt/lifeagents/provisioning/wizard/server.js --backup-dir"));
    }

    #[test]
    fn kit_flag_lives_next_to_the_journal() {
        let h = FakeHost::mac();
        assert!(!kit_confirmed(&h));
        confirm_kit(&h).unwrap();
        let f = h.files.borrow().keys().next().cloned().unwrap();
        h.paths.borrow_mut().insert(f);
        assert!(kit_confirmed(&h));
    }
}
