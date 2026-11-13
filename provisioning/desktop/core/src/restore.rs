//! Wiederherstellen ohne Terminal (Plan „restore-ohne-terminal“): Sicherungen im Sicherungsordner auflisten, eine
//! wählen (oder eine Datei vom Rechner), Notfallblatt als Datei oder getippt, Probelauf, Hintergrund-Lauf und Stand —
//! alles über `lifeagents backup …` im `master` (`provisioning/lib/backup_cli.sh`, Codes dort im Kopf von `_bkp_rdie`).
//!
//! **Geheim:** Das Notfallblatt trägt den Sicherungs-Schlüssel. Es lebt nur in `Sheet` (beim Fallenlassen
//! überschrieben), geht nur über stdin von `docker exec --interactive` in den `master` und nie ins Fenster, ins Journal,
//! in den Fehlerbericht oder in eine Meldung. Antworten des `master` liest die App nur auf feste Felder (`Plan`,
//! `Status`), nie als Text weiter.

use crate::contract::MasterCmd;
use crate::docker::{Docker, DockerCall};
use crate::host::Host;
use zeroize::Zeroizing;

/// Größte Notfallblatt-Datei (das Blatt hat ein paar KB; jede Übernahme eines fremden Schlüssels fügt einen Block an).
pub const SHEET_MAX: u64 = 64 * 1024;
/// Größte Sicherungs-Datei, die die App liest und weiterreicht (Nutzerdaten, verschlüsselt; real wenige MB).
pub const BACKUP_MAX: u64 = 256 * 1024 * 1024;

/// Codes der App-Seite (zusätzlich zu den Codes des `master`).
pub const DOCKER: &str = "docker";
pub const SHEET_INVALID: &str = "sheet_invalid";
pub const SHEET_TOO_BIG: &str = "sheet_too_big";
pub const FILE_TOO_BIG: &str = "file_too_big";
pub const UNREADABLE: &str = "unreadable";
pub const INTERNAL: &str = "internal";

/// Notfallblatt-Text. Kein `Debug`/`Display`/`Clone`/`Serialize`: Er kann nicht versehentlich in ein Log oder eine
/// Antwort ans Fenster gelangen; `Zeroizing` überschreibt den Speicher beim Fallenlassen.
pub struct Sheet(Zeroizing<String>);

impl Sheet {
    /// Vier getippte Zeilen; jede bekommt ihre Nummer vorn (`1: …`), sonst wäre eine Zeile ohne Prüfzeichen nur ein
    /// Form-Fehler statt „Zeile n stimmt nicht“. Alles leer = kein Blatt.
    pub fn typed(lines: &[String]) -> Result<Sheet, &'static str> {
        if lines.len() != 4 || lines.iter().all(|l| l.trim().is_empty()) {
            return Err(SHEET_INVALID);
        }
        let mut s = Zeroizing::new(String::new());
        for (i, l) in lines.iter().enumerate() {
            if l.contains(['\n', '\r']) {
                return Err(SHEET_INVALID);
            }
            // Stückweise in den Zeroizing-Puffer (ein format!-Zwischenwert bliebe unüberschrieben im Speicher).
            s.push(char::from(b'1' + i as u8));
            s.push_str(": ");
            s.push_str(l.trim());
            s.push('\n');
        }
        Ok(Sheet(s))
    }

    /// Inhalt einer Notfallblatt-Datei: UTF-8 (mit oder ohne BOM) oder UTF-16 (Windows-Editor „Unicode“). Ob es wirklich
    /// ein Blatt ist, prüft der `master` (eine Stelle, `backup_key_parse`).
    pub fn from_bytes(bytes: &[u8]) -> Result<Sheet, &'static str> {
        let b = Zeroizing::new(bytes.to_vec());
        // Jeder Zwischenwert gleich in Zeroizing: die Klartext-Kopien werden beim Fallenlassen überschrieben.
        let decoded = Zeroizing::new(if b.starts_with(&[0xFE, 0xFF]) {
            let units = Zeroizing::new(b[2..].chunks(2).filter(|c| c.len() == 2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect::<Vec<u16>>());
            String::from_utf16_lossy(&units)
        } else {
            crate::host::decode(&b)
        });
        let text = Zeroizing::new(decoded.trim_start_matches('\u{feff}').to_string());
        if text.trim().is_empty() {
            return Err(SHEET_INVALID);
        }
        Ok(Sheet(text))
    }

    fn text(&self) -> &str {
        &self.0
    }
}

/// Getippte Zeilen, wie sie aus dem Fenster kamen, nach dem Übernehmen überschreiben (die App-Hülle hat keine eigene
/// zeroize-Abhängigkeit).
pub fn wipe(lines: &mut [String]) {
    use zeroize::Zeroize;
    for l in lines.iter_mut() {
        l.zeroize();
    }
}

/// Woher die Sicherung kommt: Name im Sicherungsordner (der `master` holt sie selbst) oder eine Datei, die die App
/// gelesen hat (Datei-Dialog; geht base64-codiert über stdin, ohne Ordner-Freigabe für Docker).
pub enum Source {
    Folder(String),
    File { name: String, bytes: Vec<u8> },
}

impl Source {
    fn name(&self) -> &str {
        match self {
            Source::Folder(n) => n,
            Source::File { name, .. } => name,
        }
    }
}

/// Name einer Sicherung als Argument für den `master`: nur ein Dateiname (kein Pfad), nicht mit `-` (sonst eine Option),
/// keine Steuerzeichen.
pub fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('-')
        && !name.contains(['/', '\\'])
        && !name.chars().any(|c| c.is_control())
        && name.ends_with(".nla.enc")
}

/// Gewählte Datei lesen (über `Host`, höchstens `BACKUP_MAX`).
pub fn read_backup_file(host: &dyn Host, path: &str) -> Result<Source, &'static str> {
    let name = path.rsplit(['/', '\\']).next().unwrap_or_default().to_string();
    if !name_ok(&name) {
        return Err(UNREADABLE);
    }
    let bytes = host.read_capped(path, BACKUP_MAX).map_err(|e| if e == crate::host::TOO_BIG { FILE_TOO_BIG } else { UNREADABLE })?;
    Ok(Source::File { name, bytes })
}

/// Notfallblatt-Datei lesen (über `Host`, höchstens `SHEET_MAX`).
pub fn read_sheet_file(host: &dyn Host, path: &str) -> Result<Sheet, &'static str> {
    let bytes =
        Zeroizing::new(host.read_capped(path, SHEET_MAX).map_err(|e| if e == crate::host::TOO_BIG { SHEET_TOO_BIG } else { UNREADABLE })?);
    Sheet::from_bytes(&bytes)
}

/// Eine Sicherung im Ordner (`backup list --json`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Entry {
    pub name: String,
    pub date: Option<String>,
    pub release: Option<String>,
    pub key_id: Option<String>,
    pub own: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
pub struct Listing {
    pub ok: bool,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub folder: Option<String>,
    #[serde(default)]
    pub backups: Vec<Entry>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Package {
    pub name: String,
    pub state: String,
}

/// Ergebnis des Probelaufs bzw. des Starts. Bei `ok:false` stehen nur `code` und die Felder, die dazu gehören.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
pub struct Plan {
    pub ok: bool,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub line: Option<u8>,
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub pkg: Option<String>,
    #[serde(default)]
    pub release: Option<String>,
    #[serde(default)]
    pub created: Option<String>,
    #[serde(default)]
    pub packages: Vec<Package>,
    #[serde(default)]
    pub has_data: bool,
    #[serde(default)]
    pub adopt_key_id: Option<String>,
}

/// Stand des Hintergrund-Laufs (`backup restore-status --json`).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
pub struct Status {
    pub state: String,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub created: Option<String>,
    #[serde(default)]
    pub foreign: bool,
    #[serde(default)]
    pub started: u64,
}

/// Letzte JSON-Zeile der Ausgabe auf feste Felder lesen (davor kann Text stehen; der wird nie weitergereicht).
fn last_json<T: serde::de::DeserializeOwned>(stdout: &str) -> Option<T> {
    stdout.lines().rev().find(|l| l.trim_start().starts_with('{')).and_then(|l| serde_json::from_str(l).ok())
}

/// Codes, die die App kennt; alles andere wird `internal` (ein neuer master-Code erscheint so nie als Rohtext).
const KNOWN: [&str; 26] = [
    "key_needed",
    "key_line",
    "key_format",
    "key_foreign",
    "key_no_open",
    "corrupt",
    "corrupt_stored",
    "bundle_incomplete",
    "format",
    "package_unknown",
    "version_older",
    "version_newer",
    "needs_setup",
    "no_tables",
    "unreadable",
    "safety",
    "folder",
    "nofolder",
    "busy",
    "internal",
    DOCKER,
    SHEET_INVALID,
    SHEET_TOO_BIG,
    FILE_TOO_BIG,
    "key_expired",
    "unfinished",
];
fn known(code: Option<String>) -> Option<String> {
    code.map(|c| if KNOWN.contains(&c.as_str()) { c } else { INTERNAL.to_string() })
}
fn fail(code: &str) -> Plan {
    Plan { ok: false, code: Some(code.to_string()), ..Plan::default() }
}

/// Sicherungen im Sicherungsordner.
pub fn list(host: &dyn Host, d: &Docker) -> Listing {
    match d.call(host, DockerCall::Master(MasterCmd::BackupList)) {
        Ok(out) => match last_json::<Listing>(&out.stdout) {
            Some(mut l) => {
                l.code = known(l.code);
                l
            }
            None => Listing { ok: false, code: Some(INTERNAL.into()), ..Listing::default() },
        },
        Err(_) => Listing { ok: false, code: Some(DOCKER.into()), ..Listing::default() },
    }
}

/// stdin für den `master`: Ordner-Sicherung = nur das Blatt (`--key-stdin`); Datei = Zeile `sheet <base64>` + die
/// Sicherung base64-codiert (`--in-stdin`). Gibt `None` für „ohne stdin“ zurück. Der Puffer wird nach dem Aufruf
/// überschrieben.
fn input(src: &Source, sheet: Option<&Sheet>) -> Option<Zeroizing<String>> {
    match src {
        Source::Folder(_) => sheet.map(|s| Zeroizing::new(s.text().to_string())),
        Source::File { bytes, .. } => {
            let mut s = Zeroizing::new(String::with_capacity(bytes.len() * 4 / 3 + 64));
            s.push_str("sheet ");
            if let Some(sh) = sheet {
                base64_into(&mut s, sh.text().as_bytes());
            }
            s.push('\n');
            base64_into(&mut s, bytes);
            s.push('\n');
            Some(s)
        }
    }
}

fn run_master(host: &dyn Host, d: &Docker, cmd: MasterCmd, stdin: Option<Zeroizing<String>>) -> Plan {
    let out = match stdin {
        Some(s) => d.call_stdin(host, DockerCall::MasterIn(cmd), &s),
        None => d.call(host, DockerCall::Master(cmd)),
    };
    match out {
        Ok(o) => match last_json::<Plan>(&o.stdout) {
            Some(mut p) => {
                p.code = known(p.code);
                if !p.ok && p.code.is_none() {
                    p.code = Some(INTERNAL.into());
                }
                p
            }
            None => fail(INTERNAL),
        },
        Err(_) => fail(DOCKER),
    }
}

/// Probelauf: öffnen und prüfen, nichts schreiben.
pub fn plan(host: &dyn Host, d: &Docker, src: &Source, sheet: Option<&Sheet>) -> Plan {
    if !name_ok(src.name()) {
        return fail(UNREADABLE);
    }
    let file = matches!(src, Source::File { .. });
    let cmd = MasterCmd::RestorePlan { name: src.name().to_string(), file, key: sheet.is_some() };
    run_master(host, d, cmd, input(src, sheet))
}

/// Wiederherstellen im Hintergrund starten (nach der Bestätigung). `ok:true` = der `master` hat übernommen; den Stand
/// liefert `status`.
pub fn run(host: &dyn Host, d: &Docker, src: &Source, sheet: Option<&Sheet>) -> Plan {
    if !name_ok(src.name()) {
        return fail(UNREADABLE);
    }
    let file = matches!(src, Source::File { .. });
    let cmd = MasterCmd::Restore { name: src.name().to_string(), file, key: sheet.is_some() };
    run_master(host, d, cmd, input(src, sheet))
}

/// Stand des Hintergrund-Laufs; ohne Antwort `None` (Docker aus).
pub fn status(host: &dyn Host, d: &Docker) -> Option<Status> {
    let out = d.call(host, DockerCall::Master(MasterCmd::RestoreStatus)).ok()?;
    let mut s: Status = last_json(&out.stdout)?;
    s.code = known(s.code);
    Some(s)
}

/// Merker „Ergebnis gesehen“ (neben dem Journal): je Start-Zeitpunkt einmal zeigen.
fn seen_flag(host: &dyn Host) -> String {
    crate::host::join(host.os(), &[&crate::journal::dir(host), "restore_seen"])
}
pub fn seen(host: &dyn Host, started: u64) -> bool {
    host.read_file(&seen_flag(host)).map(|s| s.trim() == started.to_string()).unwrap_or(false)
}
pub fn mark_seen(host: &dyn Host, started: u64) -> Result<(), String> {
    host.write_file(&seen_flag(host), &format!("{started}\n"))
}

/// Merker „Karte weggeklickt“ für genau diese fremden Sicherungen (neue fremde → Karte wieder).
fn dismiss_flag(host: &dyn Host) -> String {
    crate::host::join(host.os(), &[&crate::journal::dir(host), "restore_card_dismissed"])
}
fn foreign_key(l: &Listing) -> String {
    let mut v: Vec<&str> = l.backups.iter().filter(|e| !e.own).map(|e| e.name.as_str()).collect();
    v.sort_unstable();
    v.join("\n")
}
/// Karte zeigen? Nur wenn es fremde Sicherungen gibt und diese Menge nicht weggeklickt ist.
pub fn card_wanted(host: &dyn Host, l: &Listing) -> bool {
    let k = foreign_key(l);
    !k.is_empty() && host.read_file(&dismiss_flag(host)).map(|s| s.trim_end() != k).unwrap_or(true)
}
pub fn dismiss_card(host: &dyn Host, l: &Listing) -> Result<(), String> {
    host.write_file(&dismiss_flag(host), &format!("{}\n", foreign_key(l)))
}

/// base64 (Standard-Alphabet, mit `=`), für den stdin-Rahmen; keine eigene Abhängigkeit für ein paar Zeilen.
pub fn base64(data: &[u8]) -> String {
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    base64_into(&mut out, data);
    out
}

/// Wie `base64`, hängt an einen vorhandenen Puffer an (für das Blatt: kein eigener, unüberschriebener Zwischen-String).
fn base64_into(out: &mut String, data: &[u8]) {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(A[(n >> 18) as usize & 63] as char);
        out.push(A[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { A[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { A[n as usize & 63] as char } else { '=' });
    }
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
    // Erfundenes Blatt (kein echter Wert).
    const PAPER: &str = "Notfallblatt\n  1:  0123-4567-89ab-cdef  73\n";
    const NAME: &str = "lifeagents-backup-20261101033000-k0000000a-v0.44.0.nla.enc";

    #[test]
    fn base64_matches_the_standard() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64("한".as_bytes()), "7ZWc");
    }

    #[test]
    fn typed_lines_get_their_number_and_empty_is_no_sheet() {
        let s = Sheet::typed(&["0123-4567-89ab-cdef 73".into(), "a".into(), "b".into(), " c ".into()]).unwrap();
        assert_eq!(s.text(), "1: 0123-4567-89ab-cdef 73\n2: a\n3: b\n4: c\n");
        assert!(Sheet::typed(&["".into(), " ".into(), "".into(), "".into()]).is_err());
        assert!(Sheet::typed(&["a\nb".into(), "".into(), "".into(), "".into()]).is_err());
        assert!(Sheet::typed(&["a".into()]).is_err());
    }

    #[test]
    fn sheet_file_utf8_bom_and_utf16() {
        let mut bom = vec![0xEF, 0xBB, 0xBF];
        bom.extend_from_slice(PAPER.as_bytes());
        assert_eq!(Sheet::from_bytes(&bom).unwrap().text(), PAPER);
        let le: Vec<u8> = [0xFF, 0xFE].into_iter().chain(PAPER.encode_utf16().flat_map(|u| u.to_le_bytes())).collect();
        assert_eq!(Sheet::from_bytes(&le).unwrap().text(), PAPER);
        let be: Vec<u8> = [0xFE, 0xFF].into_iter().chain(PAPER.encode_utf16().flat_map(|u| u.to_be_bytes())).collect();
        assert_eq!(Sheet::from_bytes(&be).unwrap().text(), PAPER);
        assert_eq!(Sheet::from_bytes(b"  \n").err(), Some(SHEET_INVALID));
    }

    #[test]
    fn names_are_only_backup_file_names() {
        assert!(name_ok(NAME));
        assert!(name_ok("Kopie von lifeagents-backup-20261101033000-k0000000a-v0.44.0 (1).nla.enc"));
        for bad in ["--yes.nla.enc", "../x.nla.enc", "a\\b.nla.enc", "x.txt", "", "a\nb.nla.enc"] {
            assert!(!name_ok(bad), "{bad}");
        }
    }

    #[test]
    fn folder_backup_sends_only_the_sheet_over_stdin_never_as_argument() {
        let call = DockerCall::MasterIn(MasterCmd::RestorePlan { name: NAME.into(), file: false, key: true });
        let h = FakeHost::mac().on(&cmd(call), CmdOut::ok("warn …\n{\"ok\":true,\"has_data\":false,\"packages\":[{\"name\":\"core\",\"version\":\"1\",\"state\":\"ok\"}],\"adopt_key_id\":\"k0000000a\"}\n"));
        let sheet = Sheet::from_bytes(PAPER.as_bytes()).unwrap();
        let p = plan(&h, &d(), &Source::Folder(NAME.into()), Some(&sheet));
        assert!(p.ok && !p.has_data && p.adopt_key_id.as_deref() == Some("k0000000a"));
        let (line, input) = h.stdin_log.borrow()[0].clone();
        assert!(!line.contains("0123-4567"), "Blatt im argv: {line}");
        assert!(line.contains("--key-stdin") && line.contains("--plan") && line.contains("exec --interactive"));
        assert_eq!(input, PAPER);
    }

    #[test]
    fn chosen_file_goes_base64_with_the_sheet_header() {
        let call = DockerCall::MasterIn(MasterCmd::RestorePlan { name: NAME.into(), file: true, key: false });
        let h = FakeHost::mac()
            .on(&cmd(call), CmdOut::fail(1, "x").with_stdout("{\"ok\":false,\"code\":\"key_needed\",\"id\":\"k0000000a\"}\n"));
        let p = plan(&h, &d(), &Source::File { name: NAME.into(), bytes: b"GPG\x01".to_vec() }, None);
        assert_eq!((p.ok, p.code.as_deref(), p.id.as_deref()), (false, Some("key_needed"), Some("k0000000a")));
        let (line, input) = h.stdin_log.borrow()[0].clone();
        assert!(line.contains("--in-stdin") && !line.contains("--key-stdin"));
        assert_eq!(input, format!("sheet \n{}\n", base64(b"GPG\x01")));
    }

    #[test]
    fn unknown_codes_and_garbage_become_internal_docker_off_is_docker() {
        let call = DockerCall::Master(MasterCmd::RestorePlan { name: NAME.into(), file: false, key: false });
        let h = FakeHost::mac().on(&cmd(call), CmdOut::fail(1, "").with_stdout("{\"ok\":false,\"code\":\"neu_und_unbekannt\"}\n"));
        assert_eq!(plan(&h, &d(), &Source::Folder(NAME.into()), None).code.as_deref(), Some(INTERNAL));
        let h2 = FakeHost::mac()
            .on(&cmd(DockerCall::Master(MasterCmd::RestorePlan { name: NAME.into(), file: false, key: false })), CmdOut::ok("kein json"));
        assert_eq!(plan(&h2, &d(), &Source::Folder(NAME.into()), None).code.as_deref(), Some(INTERNAL));
        let h3 = FakeHost::mac();
        assert_eq!(plan(&h3, &d(), &Source::Folder(NAME.into()), None).code.as_deref(), Some(DOCKER));
        let h4 = FakeHost::mac();
        assert_eq!(plan(&h4, &d(), &Source::Folder("--yes.nla.enc".into()), None).code.as_deref(), Some(UNREADABLE));
        assert!(h4.calls.borrow().is_empty(), "ungültiger Name erreicht Docker nie");
    }

    #[test]
    fn listing_status_and_card() {
        let h = FakeHost::mac()
            .on(&cmd(DockerCall::Master(MasterCmd::BackupList)), CmdOut::ok(&format!("{{\"ok\":true,\"folder\":\"/x\",\"backups\":[{{\"name\":\"{NAME}\",\"date\":null,\"release\":\"v0.44.0\",\"key_id\":\"k0000000a\",\"own\":false}}]}}\n")))
            .on(&cmd(DockerCall::Master(MasterCmd::RestoreStatus)), CmdOut::ok("{\"ok\":true,\"state\":\"fail\",\"code\":\"version_older\",\"foreign\":true,\"started\":7}\n"));
        let l = list(&h, &d());
        assert!(l.ok && l.backups.len() == 1 && !l.backups[0].own);
        assert!(card_wanted(&h, &l));
        dismiss_card(&h, &l).unwrap();
        assert!(!card_wanted(&h, &l), "weggeklickt");
        let mut l2 = l.clone();
        l2.backups.push(Entry {
            name: "lifeagents-backup-20261102033000-k0000000b-v0.44.0.nla.enc".into(),
            date: None,
            release: None,
            key_id: None,
            own: false,
        });
        assert!(card_wanted(&h, &l2), "neue fremde Sicherung zeigt die Karte wieder");
        let s = status(&h, &d()).unwrap();
        assert_eq!((s.state.as_str(), s.code.as_deref(), s.started), ("fail", Some("version_older"), 7));
        assert!(!seen(&h, 7));
        mark_seen(&h, 7).unwrap();
        assert!(seen(&h, 7));
    }

    #[test]
    fn files_are_read_with_a_cap() {
        let h = FakeHost::mac();
        h.files.borrow_mut().insert(format!("/Users/erika/Downloads/{NAME}"), "GPG".into());
        h.files.borrow_mut().insert("/Users/erika/Downloads/blatt.txt".into(), PAPER.into());
        h.files.borrow_mut().insert("/Users/erika/Downloads/gross.txt".into(), "x".repeat(SHEET_MAX as usize + 1));
        assert!(matches!(read_backup_file(&h, &format!("/Users/erika/Downloads/{NAME}")), Ok(Source::File { .. })));
        assert_eq!(read_backup_file(&h, "/Users/erika/Downloads/notiz.txt").err(), Some(UNREADABLE));
        assert!(read_sheet_file(&h, "/Users/erika/Downloads/blatt.txt").is_ok());
        assert_eq!(read_sheet_file(&h, "/Users/erika/Downloads/gross.txt").err(), Some(SHEET_TOO_BIG));
        assert_eq!(read_sheet_file(&h, "/Users/erika/Downloads/fehlt.txt").err(), Some(UNREADABLE));
    }
}
