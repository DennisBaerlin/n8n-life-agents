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
use zeroize::Zeroizing;

/// Fehler-Codes (`report::ERROR_CODES`-Stil): Docker/master antwortet nicht, kein Schlüssel, Datei nicht schreibbar.
pub const KIT_UNAVAILABLE: &str = "kit-unavailable";
pub const KIT_WRITE: &str = "kit-write";

/// Nach so vielen Sekunden leert die App die Zwischenablage wieder, wenn dort noch der Notfallschlüssel steht.
pub const KEY_CLEAR_SECS: u64 = 60;

/// Form des Notfallschlüssels (`common.sh` `backup_key_token`): `labk1_` + 56 Zeichen Crockford-Base32, klein.
pub fn token_ok(s: &str) -> bool {
    s.len() == 62
        && s.starts_with("labk1_")
        && s[6..].bytes().all(|b| b.is_ascii_digit() || (b.is_ascii_lowercase() && !matches!(b, b'i' | b'l' | b'o' | b'u')))
}

// Zwischenablage mit Schutz-Markierung. Der Wert kommt nur über stdin (nie argv, `/proc` bzw. Prozessliste sind lesbar).
// macOS: zusätzlicher Typ org.nspasteboard.ConcealedType (https://nspasteboard.org/), an den sich Verlaufs-Werkzeuge und
// Passwort-Manager halten; eine Absprache unter Programmen, keine Sperre des Systems.
const MAC_SET: &str = "ObjC.import('AppKit');\
var d=$.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;\
var s=$.NSString.alloc.initWithDataEncoding(d,$.NSUTF8StringEncoding).js.trim();\
var p=$.NSPasteboard.generalPasteboard;p.clearContents;\
if(!p.setStringForType($(s),'public.utf8-plain-text')||!p.setStringForType($('1'),'org.nspasteboard.ConcealedType')){throw 'clipboard';}";
const MAC_CLEAR: &str = "ObjC.import('AppKit');\
var d=$.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;\
var s=$.NSString.alloc.initWithDataEncoding(d,$.NSUTF8StringEncoding).js.trim();\
var p=$.NSPasteboard.generalPasteboard;var c=p.stringForType('public.utf8-plain-text');\
if(!c.isNil()&&c.js===s){p.clearContents;}";
// Windows: die drei Formate, die Microsoft für Inhalte ohne Verlauf und ohne Abgleich auf andere Geräte vorsieht
// (https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats, „Cloud Clipboard and Clipboard History
// Formats“); DWORD 0 als vier Null-Bytes. WinForms legt einen Stream als HGLOBAL mit genau diesen Bytes ab. -STA ist
// Pflicht für die OLE-Zwischenablage; 10 Versuche im Abstand von 100 ms, weil ein anderes Programm sie kurz sperren kann.
// Ohne Desktop-Sitzung (Dienst, Fernzugriff ohne Fenster) scheitert jeder Zugriff → KIT_UNAVAILABLE.
const WIN_SET: &str = "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Windows.Forms;\
$s=[Console]::In.ReadToEnd().Trim();$o=New-Object System.Windows.Forms.DataObject;\
$o.SetData([System.Windows.Forms.DataFormats]::UnicodeText,$s);\
foreach($f in 'ExcludeClipboardContentFromMonitorProcessing','CanIncludeInClipboardHistory','CanUploadToCloudClipboard')\
{$o.SetData($f,(New-Object System.IO.MemoryStream(,[byte[]](0,0,0,0))))};\
[System.Windows.Forms.Clipboard]::SetDataObject($o,$true,10,100)";
const WIN_CLEAR: &str = "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Windows.Forms;\
$s=[Console]::In.ReadToEnd().Trim();\
if([System.Windows.Forms.Clipboard]::GetText() -ceq $s){[System.Windows.Forms.Clipboard]::Clear()}";

fn clip_cmd(os: Os, mac: &str, win: &str) -> (&'static str, Vec<String>) {
    match os {
        Os::Mac => ("/usr/bin/osascript", vec!["-l".into(), "JavaScript".into(), "-e".into(), mac.into()]),
        Os::Windows => {
            ("powershell.exe", ["-NoProfile", "-NonInteractive", "-STA", "-Command", win].iter().map(|s| s.to_string()).collect())
        }
    }
}

/// Befehl, der den Notfallschlüssel von stdin in die Zwischenablage legt.
fn clip_set_cmd(os: Os) -> (&'static str, Vec<String>) {
    clip_cmd(os, MAC_SET, WIN_SET)
}

/// Befehl, der die Zwischenablage leert, wenn dort noch genau der Wert von stdin steht (sonst bliebe etwas, das der Nutzer
/// inzwischen kopiert hat, nicht stehen).
fn clip_clear_cmd(os: Os) -> (&'static str, Vec<String>) {
    clip_cmd(os, MAC_CLEAR, WIN_CLEAR)
}

/// Notfallschlüssel aus dem `master` holen und in die Zwischenablage legen. Ergebnis: der Wert, damit der Aufrufer nach
/// `KEY_CLEAR_SECS` `clear_key_if` rufen kann. Ohne gültigen Schlüssel (alter master ohne `--token`) bleibt die
/// Zwischenablage unberührt.
pub fn copy_key(host: &dyn Host, d: &Docker) -> Result<Zeroizing<String>, &'static str> {
    let out = d.call(host, DockerCall::Master(MasterCmd::BackupToken)).map_err(|_| KIT_UNAVAILABLE)?;
    let key = Zeroizing::new(out.stdout.trim().to_string());
    if !out.success() || !token_ok(&key) {
        return Err(KIT_UNAVAILABLE);
    }
    let (program, args) = clip_set_cmd(host.os());
    match host.run_stdin(program, &args, &key) {
        Ok(o) if o.success() => Ok(key),
        _ => Err(KIT_UNAVAILABLE),
    }
}

/// Zwischenablage leeren, wenn dort noch `key` steht.
pub fn clear_key_if(host: &dyn Host, key: &str) {
    let (program, args) = clip_clear_cmd(host.os());
    let _ = host.run_stdin(program, &args, key);
}

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
    // Plausibel nur mit einem Schlüssel: Token-Zeile oder Zeile „1:“ (Blatt mit vier Zeilen); sonst (alter master ohne
    // `backup key`) nichts schreiben.
    if !out.success() || !out.stdout.lines().any(|l| token_ok(l.trim()) || l.trim_start().starts_with("1:")) {
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
/// Nach einer Wiederherstellung mit dem Blatt eines anderen Rechners gilt dessen Schlüssel: das gerade gespeicherte Blatt
/// der Neuinstallation taugt nicht mehr für neue Sicherungen, also den Schritt wieder anbieten.
pub fn reset_kit(host: &dyn Host) -> Result<(), String> {
    let f = kit_flag(host);
    if host.exists(&f) {
        host.remove_file(&f)?;
    }
    Ok(())
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

    // Das Blatt mit dem Notfallschlüssel als Token (erfundene Schlüssel, Ausgabe von `lifeagents backup key --file -`) muss die
    // Prüfung oben bestehen: ein Update tauscht den `master`, nicht die App (Schritte „1:“ auf dem Blatt, common.sh backup_kit_text).
    #[test]
    fn token_sheet_passes_the_check_of_this_app() {
        let sheet = include_str!("../../../../tests/backup/fixtures/notfallblatt-token.txt");
        let h = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupKit)), CmdOut::ok(sheet));
        let p = save_kit(&h, &d(), "Life-Agents-Notfallblatt").unwrap();
        assert_eq!(h.files.borrow().get(&p).map(String::as_str), Some(sheet));
    }

    #[test]
    fn a_sheet_with_only_token_lines_is_saved_too() {
        let sheet = "Life Agents – Notfallblatt\nNotfallschlüssel\n  labk1_04hmasw9nf6yy0938nkrkaydxw0j6hb7h6nwvvr14d2pf2dbsqqz3kfy\n";
        let h = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupKit)), CmdOut::ok(sheet));
        assert!(save_kit(&h, &d(), "x").is_ok());
    }

    // Notfallschlüssel in die Zwischenablage (erfundener Schlüssel). Der Wert geht nur über stdin, nie in eine Befehlszeile.
    const TOKEN: &str = "labk1_04hmasw9nf6yy0938nkrkaydxw0j6hb7h6nwvvr14d2pf2dbsqqz3kfy";
    fn line(p: (&str, Vec<String>)) -> String {
        format!("{} {}", p.0, p.1.join(" "))
    }

    #[test]
    fn token_form() {
        assert!(token_ok(TOKEN));
        assert!(!token_ok(&TOKEN.to_uppercase()));
        assert!(!token_ok(&TOKEN[..61]));
        assert!(!token_ok(&format!("{}u", &TOKEN[..61])));
        assert!(!token_ok("Usage: lifeagents backup …"));
    }

    #[test]
    fn copy_on_the_mac_marks_the_key_as_concealed() {
        let set = line(clip_set_cmd(Os::Mac));
        assert!(set.starts_with("/usr/bin/osascript ") && set.contains("org.nspasteboard.ConcealedType"), "{set}");
        let h = FakeHost::mac()
            .on(&cmd(DockerCall::Master(MasterCmd::BackupToken)), CmdOut::ok(&format!("{TOKEN}\n")))
            .on(&set, CmdOut::ok(""));
        let k = copy_key(&h, &d()).unwrap();
        assert_eq!(k.as_str(), TOKEN);
        assert_eq!(h.stdin_log.borrow().last().cloned(), Some((set, TOKEN.to_string())));
        assert!(h.calls.borrow().iter().all(|c| !c.contains(&TOKEN[6..])), "Schlüssel in einer Befehlszeile");
    }

    #[test]
    fn copy_on_windows_keeps_the_key_out_of_history_and_cloud() {
        let set = line(clip_set_cmd(Os::Windows));
        for f in ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard", "-STA"] {
            assert!(set.contains(f), "{f} fehlt: {set}");
        }
        let h = FakeHost::windows().on(&cmd(DockerCall::Master(MasterCmd::BackupToken)), CmdOut::ok(TOKEN)).on(&set, CmdOut::ok(""));
        assert_eq!(copy_key(&h, &d()).unwrap().as_str(), TOKEN);
        assert_eq!(h.stdin_log.borrow().last().map(|x| x.1.clone()), Some(TOKEN.to_string()));
    }

    #[test]
    fn no_token_from_the_master_touches_no_clipboard() {
        for out in [CmdOut::ok("Usage: lifeagents backup …\n"), CmdOut::fail(1, ""), CmdOut::ok("")] {
            let h = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupToken)), out);
            assert_eq!(copy_key(&h, &d()).err(), Some(KIT_UNAVAILABLE));
            assert!(h.stdin_log.borrow().is_empty());
        }
        let set = line(clip_set_cmd(Os::Mac));
        let h = FakeHost::mac().on(&cmd(DockerCall::Master(MasterCmd::BackupToken)), CmdOut::ok(TOKEN)).on(&set, CmdOut::fail(1, "x"));
        assert_eq!(copy_key(&h, &d()).err(), Some(KIT_UNAVAILABLE), "Zwischenablage nicht beschreibbar");
    }

    #[test]
    fn clearing_compares_first_and_takes_the_key_only_over_stdin() {
        for (h, os) in [(FakeHost::mac(), Os::Mac), (FakeHost::windows(), Os::Windows)] {
            let clear = line(clip_clear_cmd(os));
            let h = h.on(&clear, CmdOut::ok(""));
            clear_key_if(&h, TOKEN);
            assert_eq!(h.stdin_log.borrow().last().cloned(), Some((clear.clone(), TOKEN.to_string())));
            assert!(!clear.contains(&TOKEN[6..]));
        }
        assert_eq!(KEY_CLEAR_SECS, 60);
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
