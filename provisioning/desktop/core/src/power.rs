//! Dauerbetrieb (Paket 7, Prüfliste Nr. 15): alte Werte sichern, setzen, nachlesen, zurückstellen.
//!
//! Mac: `pmset -c` (nur am Netzteil; ein Mac mini hat nur diesen Bereich, ein Laptop schläft auf Akku weiter).
//! Gesetzt wird nur, was der Rechner kennt. Windows: eigenes Schema per `powercfg /duplicatescheme`, das
//! bisherige bleibt unberührt und wird beim Zurückstellen wieder aktiv.
//!
//! **Keine Sicherheits-Einstellung:** FileVault wird nur gelesen (`fdesetup status`). Der Test
//! `never_touches_security_settings` sucht in allen Quellen nach Befehlen, die das ändern könnten.

use std::collections::BTreeMap;

use crate::admin::{run_mac_admin, AdminError};
use crate::host::{args, Host, Os};

const PMSET: &str = "/usr/bin/pmset";

/// Zielwerte am Netzteil: nie einschlafen, Bildschirm nach 10 Minuten aus, Start nach Stromausfall, Wecken übers Netz.
pub const MAC_TARGET: [(&str, &str); 4] = [("sleep", "0"), ("displaysleep", "10"), ("autorestart", "1"), ("womp", "1")];
/// Windows: Standby nie (0 s), Bildschirm nach 600 s.
pub const WIN_TARGET: [(&str, &str, u32); 2] = [("SUB_SLEEP", "STANDBYIDLE", 0), ("SUB_VIDEO", "VIDEOIDLE", 600)];
pub const WIN_SCHEME_NAME: &str = "lifeagents Dauerbetrieb";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "os", rename_all = "lowercase")]
pub enum PowerBackup {
    /// Alte Werte der Schlüssel, die wir setzen (nur die, die der Rechner kennt).
    Mac { ac: BTreeMap<String, String> },
    /// Vorher aktives Schema und unser neues.
    Windows { previous: String, ours: String },
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct PowerResult {
    pub backup: PowerBackup,
    /// Was nach dem Nachlesen wirklich gilt, je Schlüssel: `true` = Zielwert gilt.
    pub holds: BTreeMap<String, bool>,
    /// Schlüssel, die der Rechner nicht kennt und darum unverändert bleiben (z. B. `womp`).
    pub unsupported: Vec<String>,
}

impl PowerResult {
    pub fn all_hold(&self) -> bool {
        self.holds.values().all(|v| *v)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PowerError {
    Cancelled,
    Unreadable(String),
    Failed(String),
}

impl From<AdminError> for PowerError {
    fn from(e: AdminError) -> Self {
        match e {
            AdminError::Cancelled => PowerError::Cancelled,
            AdminError::Failed(m) => PowerError::Failed(m),
        }
    }
}

// ----------------------------------------------------------------------------------------------------- Mac

/// `pmset -g custom` → Werte des Netzteil-Bereichs. Ein Mac ohne Akku zeigt nur „AC Power:“.
pub fn parse_pmset_custom(text: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut in_ac = false;
    for line in text.lines() {
        if !line.starts_with(' ') && !line.starts_with('\t') {
            in_ac = line.trim_end().trim_end_matches(':') == "AC Power";
            continue;
        }
        if !in_ac {
            continue;
        }
        let t = line.trim();
        if let Some(pos) = t.rfind(char::is_whitespace) {
            let (k, v) = (t[..pos].trim(), t[pos..].trim());
            out.insert(k.to_string(), v.to_string());
        }
    }
    out
}

pub fn read_mac(host: &dyn Host) -> Result<BTreeMap<String, String>, PowerError> {
    let out = host.run(PMSET, &args(&["-g", "custom"])).map_err(PowerError::Unreadable)?;
    let v = parse_pmset_custom(&out.stdout);
    if !out.success() || v.is_empty() {
        return Err(PowerError::Unreadable(out.stderr));
    }
    Ok(v)
}

/// Werte vor dem Einbau in die Admin-Zeile prüfen: nur Ziffern (auch beim Zurückstellen aus dem Journal).
fn pmset_line(values: &[(String, String)]) -> Result<String, PowerError> {
    let mut line = format!("{PMSET} -c");
    for (k, v) in values {
        let key_ok = MAC_TARGET.iter().any(|(t, _)| t == k);
        if !key_ok || v.is_empty() || !v.chars().all(|c| c.is_ascii_digit()) {
            return Err(PowerError::Failed(format!("ungültiger Wert {k}={v}")));
        }
        line.push_str(&format!(" {k} {v}"));
    }
    Ok(line)
}

fn prepare_mac(host: &dyn Host) -> Result<PowerBackup, PowerError> {
    let before = read_mac(host)?;
    let ac = MAC_TARGET.iter().filter_map(|(k, _)| before.get(*k).map(|v| (k.to_string(), v.clone()))).collect();
    Ok(PowerBackup::Mac { ac })
}

fn apply_mac(host: &dyn Host, backup: &BTreeMap<String, String>) -> Result<PowerResult, PowerError> {
    let supported: Vec<(&str, &str)> = MAC_TARGET.iter().copied().filter(|(k, _)| backup.contains_key(*k)).collect();
    let unsupported = MAC_TARGET.iter().filter(|(k, _)| !backup.contains_key(*k)).map(|(k, _)| k.to_string()).collect();
    let set: Vec<(String, String)> = supported.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    run_mac_admin(host, &pmset_line(&set)?)?;
    let after = read_mac(host)?;
    let holds = supported.iter().map(|(k, v)| (k.to_string(), after.get(*k).map(String::as_str) == Some(*v))).collect();
    Ok(PowerResult { backup: PowerBackup::Mac { ac: backup.clone() }, holds, unsupported })
}

fn restore_mac(host: &dyn Host, ac: &BTreeMap<String, String>) -> Result<(), PowerError> {
    if ac.is_empty() {
        return Ok(());
    }
    let set: Vec<(String, String)> = ac.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    run_mac_admin(host, &pmset_line(&set)?)?;
    let now = read_mac(host)?;
    let wrong: Vec<&String> = ac.iter().filter(|(k, v)| now.get(*k) != Some(*v)).map(|(k, _)| k).collect();
    if wrong.is_empty() {
        Ok(())
    } else {
        Err(PowerError::Failed(format!("nicht zurückgestellt: {wrong:?}")))
    }
}

/// FileVault-Zustand, nur gelesen (ohne Passwort).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum FileVault {
    On,
    Off,
    Unknown,
}

pub fn filevault(host: &dyn Host) -> FileVault {
    if host.os() != Os::Mac {
        return FileVault::Unknown;
    }
    match host.run("/usr/bin/fdesetup", &args(&["status"])) {
        Ok(o) if o.stdout.contains("FileVault is On") => FileVault::On,
        Ok(o) if o.stdout.contains("FileVault is Off") => FileVault::Off,
        _ => FileVault::Unknown,
    }
}

// ------------------------------------------------------------------------------------------------- Windows

const POWERCFG: &str = "powercfg.exe";

/// Erste GUID in einer `powercfg`-Ausgabe; sprachunabhängig („Power Scheme GUID“ / „GUID des Energieschemas“).
pub fn parse_guid(text: &str) -> Option<String> {
    let b = text.as_bytes();
    let is_hex = |c: u8| c.is_ascii_hexdigit();
    let groups = [8usize, 4, 4, 4, 12];
    for start in 0..b.len() {
        let mut i = start;
        let mut ok = true;
        for (gi, len) in groups.iter().enumerate() {
            if i + len > b.len() || !b[i..i + len].iter().all(|c| is_hex(*c)) {
                ok = false;
                break;
            }
            i += len;
            if gi < 4 {
                if i >= b.len() || b[i] != b'-' {
                    ok = false;
                    break;
                }
                i += 1;
            }
        }
        if ok && (start == 0 || !is_hex(b[start - 1])) {
            return Some(text[start..i].to_ascii_lowercase());
        }
    }
    None
}

/// `powercfg /query <schema> <sub> <setting>` → Netzteil-Wert. Die letzten beiden Hex-Werte der Ausgabe sind
/// Netzteil und Akku, in jeder Sprache in dieser Reihenfolge.
pub fn parse_ac_index(text: &str) -> Option<u32> {
    let hex: Vec<u32> =
        text.split_whitespace().filter_map(|w| w.strip_prefix("0x")).filter_map(|h| u32::from_str_radix(h, 16).ok()).collect();
    (hex.len() >= 2).then(|| hex[hex.len() - 2])
}

fn pc(host: &dyn Host, a: &[&str]) -> Result<String, PowerError> {
    let out = host.run(POWERCFG, &args(a)).map_err(PowerError::Failed)?;
    if out.success() {
        Ok(out.stdout)
    } else {
        Err(PowerError::Failed(format!("powercfg {} -> {}", a.join(" "), out.code)))
    }
}

fn prepare_windows(host: &dyn Host) -> Result<PowerBackup, PowerError> {
    let previous = parse_guid(&pc(host, &["/getactivescheme"])?).ok_or_else(|| PowerError::Unreadable("aktives Schema".into()))?;
    Ok(PowerBackup::Windows { previous, ours: String::new() })
}

fn apply_windows(host: &dyn Host, previous: &str) -> Result<PowerResult, PowerError> {
    let previous = previous.to_string();
    let ours = parse_guid(&pc(host, &["/duplicatescheme", &previous])?).ok_or_else(|| PowerError::Failed("Kopie ohne GUID".into()))?;
    let backup = PowerBackup::Windows { previous: previous.clone(), ours: ours.clone() };
    // Ab hier gibt es eine Kopie: bei jedem Fehler wieder entfernen, das alte Schema bleibt aktiv.
    let result = (|| {
        pc(host, &["/changename", &ours, WIN_SCHEME_NAME])?;
        for (sub, setting, value) in WIN_TARGET {
            pc(host, &["/setacvalueindex", &ours, sub, setting, &value.to_string()])?;
        }
        pc(host, &["/setactive", &ours])?;
        let active = parse_guid(&pc(host, &["/getactivescheme"])?);
        let mut holds = BTreeMap::new();
        holds.insert("active-scheme".to_string(), active.as_deref() == Some(ours.as_str()));
        for (sub, setting, value) in WIN_TARGET {
            let now = parse_ac_index(&pc(host, &["/query", &ours, sub, setting])?);
            holds.insert(setting.to_ascii_lowercase(), now == Some(value));
        }
        Ok(holds)
    })();
    match result {
        Ok(holds) => Ok(PowerResult { backup, holds, unsupported: vec![] }),
        Err(e) => {
            let _ = pc(host, &["/setactive", &previous]);
            let _ = pc(host, &["/delete", &ours]);
            Err(e)
        }
    }
}

fn restore_windows(host: &dyn Host, previous: &str, ours: &str) -> Result<(), PowerError> {
    let ours_ok = ours.is_empty() || parse_guid(ours).as_deref() == Some(ours);
    if parse_guid(previous).as_deref() != Some(previous) || !ours_ok {
        return Err(PowerError::Failed("ungültige GUID im Journal".into()));
    }
    pc(host, &["/setactive", previous])?;
    // Leer = Abbruch vor der Kopie (Journal stand noch auf „begonnen“): nur das alte Schema aktivieren.
    if !ours.is_empty() {
        pc(host, &["/delete", ours])?;
    }
    Ok(())
}

// --------------------------------------------------------------------------------------------- gemeinsam

/// Liest den aktuellen Stand, ohne etwas zu ändern (Bestandsaufnahme „Energiewerte immer“, Nr. 6).
pub fn snapshot(host: &dyn Host) -> BTreeMap<String, String> {
    match host.os() {
        Os::Mac => read_mac(host).unwrap_or_default(),
        Os::Windows => {
            let mut m = BTreeMap::new();
            if let Some(g) = pc(host, &["/getactivescheme"]).ok().and_then(|t| parse_guid(&t)) {
                m.insert("active-scheme".to_string(), g);
            }
            m
        }
    }
}

/// Schritt 1, nur lesen: die Sicherung, die **vor** der Änderung ins Journal kommt (`Step::PowerChanged`, begonnen).
pub fn prepare(host: &dyn Host) -> Result<PowerBackup, PowerError> {
    match host.os() {
        Os::Mac => prepare_mac(host),
        Os::Windows => prepare_windows(host),
    }
}

/// Schritt 2, erst nach dem Ja: setzen und nachlesen. `result.backup` ersetzt danach den Journal-Eintrag
/// (Windows kennt erst jetzt sein neues Schema).
pub fn apply(host: &dyn Host, prepared: &PowerBackup) -> Result<PowerResult, PowerError> {
    match prepared {
        PowerBackup::Mac { ac } => apply_mac(host, ac),
        PowerBackup::Windows { previous, .. } => apply_windows(host, previous),
    }
}

pub fn restore(host: &dyn Host, backup: &PowerBackup) -> Result<(), PowerError> {
    match backup {
        PowerBackup::Mac { ac } => restore_mac(host, ac),
        PowerBackup::Windows { previous, ours } => restore_windows(host, previous, ours),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::admin::mac_admin_args;
    use crate::host::{CmdOut, FakeHost};

    const MINI_BEFORE: &str = "System-wide power settings:\nCurrently in use:\n standby              0\nAC Power:\n Sleep On Power Button 1\n autorestart          0\n powernap             1\n disksleep            10\n sleep                1\n womp                 1\n displaysleep         10\n";
    const MINI_AFTER: &str = "AC Power:\n Sleep On Power Button 1\n autorestart          1\n powernap             1\n disksleep            10\n sleep                0\n womp                 1\n displaysleep         10\n";
    const BOOK_BEFORE: &str = "Battery Power:\n lidwake              1\n sleep                1\n displaysleep         2\nAC Power:\n lidwake              1\n autorestart          0\n sleep                1\n displaysleep         10\n";

    fn admin(shell: &str) -> String {
        format!("/usr/bin/osascript {}", mac_admin_args(shell).join(" "))
    }

    #[test]
    fn pmset_parsing_takes_only_the_ac_section() {
        let v = parse_pmset_custom(BOOK_BEFORE);
        assert_eq!(v.get("sleep").map(String::as_str), Some("1"));
        assert_eq!(v.get("displaysleep").map(String::as_str), Some("10"));
        assert!(!v.contains_key("womp"));
        assert_eq!(parse_pmset_custom(MINI_BEFORE).get("Sleep On Power Button").map(String::as_str), Some("1"));
    }

    #[test]
    fn mac_mini_backup_set_verify() {
        let h = FakeHost::mac()
            .on_seq("/usr/bin/pmset -g custom", vec![CmdOut::ok(MINI_BEFORE), CmdOut::ok(MINI_AFTER)])
            .on(&admin("/usr/bin/pmset -c sleep 0 displaysleep 10 autorestart 1 womp 1"), CmdOut::ok(""));
        let r = apply(&h, &prepare(&h).unwrap()).expect("gesetzt");
        assert!(r.all_hold(), "{:?}", r.holds);
        assert_eq!(r.backup, PowerBackup::Mac { ac: map(&[("autorestart", "0"), ("displaysleep", "10"), ("sleep", "1"), ("womp", "1")]) });
        assert!(r.unsupported.is_empty());
    }

    fn map(kv: &[(&str, &str)]) -> BTreeMap<String, String> {
        kv.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn mac_laptop_sets_only_ac_and_only_known_keys() {
        let after = BOOK_BEFORE.replace(" autorestart          0", " autorestart          1").replace(
            "AC Power:\n lidwake              1\n autorestart          1\n sleep                1",
            "AC Power:\n lidwake              1\n autorestart          1\n sleep                0",
        );
        let h = FakeHost::mac()
            .on_seq("/usr/bin/pmset -g custom", vec![CmdOut::ok(BOOK_BEFORE), CmdOut::ok(&after)])
            .on(&admin("/usr/bin/pmset -c sleep 0 displaysleep 10 autorestart 1"), CmdOut::ok(""));
        let r = apply(&h, &prepare(&h).unwrap()).expect("gesetzt");
        assert_eq!(r.unsupported, vec!["womp".to_string()]);
        assert!(r.all_hold(), "{:?}", r.holds);
        let calls = h.calls_starting("/usr/bin/osascript");
        assert_eq!(calls.len(), 1);
        assert!(!calls[0].contains("pmset -a") && !calls[0].contains("pmset -b"), "Akku-Bereich bleibt unberührt: {}", calls[0]);
    }

    #[test]
    fn mac_reports_what_really_holds() {
        // pmset meldet Erfolg, der Wert bleibt aber (z. B. Profil-Verwaltung): ehrlich melden.
        let h = FakeHost::mac()
            .on("/usr/bin/pmset -g custom", CmdOut::ok(MINI_BEFORE))
            .on(&admin("/usr/bin/pmset -c sleep 0 displaysleep 10 autorestart 1 womp 1"), CmdOut::ok(""));
        let r = apply(&h, &prepare(&h).unwrap()).expect("Befehl lief");
        assert!(!r.all_hold());
        assert_eq!(r.holds.get("sleep"), Some(&false));
        assert_eq!(r.holds.get("displaysleep"), Some(&true));
    }

    #[test]
    fn mac_cancelled_password_changes_nothing() {
        let h = FakeHost::mac()
            .on("/usr/bin/pmset -g custom", CmdOut::ok(MINI_BEFORE))
            .on(&admin("/usr/bin/pmset -c sleep 0 displaysleep 10 autorestart 1 womp 1"), CmdOut::fail(1, "User canceled. (-128)"));
        assert_eq!(apply(&h, &prepare(&h).unwrap()), Err(PowerError::Cancelled));
    }

    #[test]
    fn mac_restore_puts_old_values_back() {
        let backup = PowerBackup::Mac { ac: map(&[("autorestart", "0"), ("displaysleep", "10"), ("sleep", "1"), ("womp", "1")]) };
        let h = FakeHost::mac()
            .on(&admin("/usr/bin/pmset -c autorestart 0 displaysleep 10 sleep 1 womp 1"), CmdOut::ok(""))
            .on("/usr/bin/pmset -g custom", CmdOut::ok(MINI_BEFORE));
        assert_eq!(restore(&h, &backup), Ok(()));
    }

    #[test]
    fn mac_restore_refuses_tampered_journal_values() {
        let backup = PowerBackup::Mac { ac: map(&[("sleep", "1; rm -rf ~")]) };
        let h = FakeHost::mac();
        assert!(matches!(restore(&h, &backup), Err(PowerError::Failed(_))));
        assert!(h.calls_starting("/usr/bin/osascript").is_empty());
        let backup = PowerBackup::Mac { ac: map(&[("hibernatemode", "0")]) };
        assert!(matches!(restore(&h, &backup), Err(PowerError::Failed(_))), "nur unsere Schlüssel");
    }

    #[test]
    fn filevault_is_only_read() {
        let h = FakeHost::mac().on("/usr/bin/fdesetup status", CmdOut::ok("FileVault is On.\n"));
        assert_eq!(filevault(&h), FileVault::On);
        let h = FakeHost::mac().on("/usr/bin/fdesetup status", CmdOut::ok("FileVault is Off.\n"));
        assert_eq!(filevault(&h), FileVault::Off);
        assert_eq!(filevault(&FakeHost::mac()), FileVault::Unknown);
    }

    #[test]
    fn never_touches_security_settings() {
        // Zusammengesetzt, damit die Liste sich nicht selbst findet.
        let banned = [
            ["fdesetup ", "dis", "able"].concat(),
            ["fdesetup ", "en", "able"].concat(),
            ["spctl ", "--master"].concat(),
            ["spctl ", "--global"].concat(),
            ["csr", "util"].concat(),
            ["com.apple.", "quarantine"].concat(),
            ["autoLogin", "User"].concat(),
            ["Set-Mp", "Preference"].concat(),
            ["bcd", "edit"].concat(),
        ];
        for (name, src) in crate::all_sources() {
            for b in &banned {
                assert!(!src.contains(b.as_str()), "{name} enthält {b}");
            }
            let call = ["\"/usr/bin/fde", "setup\","].concat();
            for line in src.lines().filter(|l| l.contains(&call)) {
                assert!(line.contains("args(&[\"status\"])"), "{name}: fdesetup nur mit status: {line}");
            }
        }
    }

    // ---- Windows ----

    const ACTIVE_DE: &str = "GUID des Energieschemas: 381b4222-f694-41f0-9685-ff5bb260df2e  (Ausbalanciert)\r\n";
    const OURS: &str = "6f1c3b2e-0d4a-4c11-9a2b-5e7f00c0ffee";

    fn query_out(ac: u32, dc: u32) -> String {
        format!("GUID des Energieschemas: {OURS}  (lifeagents Dauerbetrieb)\r\n  Mindestwert: 0x00000000\r\n  Hoechstwert: 0xffffffff\r\nAktueller Wechselstromindex: 0x{ac:08x}\r\nAktueller Gleichstromindex: 0x{dc:08x}\r\n")
    }

    fn win_ok() -> FakeHost {
        FakeHost::windows()
            .on_seq(
                "powercfg.exe /getactivescheme",
                vec![CmdOut::ok(ACTIVE_DE), CmdOut::ok(&format!("GUID des Energieschemas: {OURS}  (lifeagents Dauerbetrieb)\r\n"))],
            )
            .on(
                "powercfg.exe /duplicatescheme 381b4222-f694-41f0-9685-ff5bb260df2e",
                CmdOut::ok(&format!("GUID des Energieschemas: {OURS}  (Ausbalanciert)\r\n")),
            )
            .on(&format!("powercfg.exe /changename {OURS} {WIN_SCHEME_NAME}"), CmdOut::ok(""))
            .on(&format!("powercfg.exe /setacvalueindex {OURS} SUB_SLEEP STANDBYIDLE 0"), CmdOut::ok(""))
            .on(&format!("powercfg.exe /setacvalueindex {OURS} SUB_VIDEO VIDEOIDLE 600"), CmdOut::ok(""))
            .on(&format!("powercfg.exe /setactive {OURS}"), CmdOut::ok(""))
            .on(&format!("powercfg.exe /query {OURS} SUB_SLEEP STANDBYIDLE"), CmdOut::ok(&query_out(0, 900)))
            .on(&format!("powercfg.exe /query {OURS} SUB_VIDEO VIDEOIDLE"), CmdOut::ok(&query_out(600, 300)))
    }

    #[test]
    fn windows_own_scheme_leaves_the_old_one_alone() {
        let h = win_ok();
        let r = apply(&h, &prepare(&h).unwrap()).expect("gesetzt");
        assert!(r.all_hold(), "{:?}", r.holds);
        assert_eq!(r.backup, PowerBackup::Windows { previous: "381b4222-f694-41f0-9685-ff5bb260df2e".into(), ours: OURS.into() });
        for c in h.calls.borrow().iter() {
            assert!(!c.contains("381b4222") || c.contains("/duplicatescheme"), "altes Schema geändert: {c}");
        }
    }

    #[test]
    fn windows_failure_removes_the_copy() {
        let h = win_ok();
        h.set(&format!("powercfg.exe /setactive {OURS}"), CmdOut::fail(1, "Zugriff verweigert"));
        h.set("powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e", CmdOut::ok(""));
        h.set(&format!("powercfg.exe /delete {OURS}"), CmdOut::ok(""));
        assert!(apply(&h, &prepare(&h).unwrap()).is_err());
        assert!(h.called(&format!("powercfg.exe /delete {OURS}")));
    }

    #[test]
    fn windows_restore() {
        let h = FakeHost::windows()
            .on("powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e", CmdOut::ok(""))
            .on(&format!("powercfg.exe /delete {OURS}"), CmdOut::ok(""));
        let b = PowerBackup::Windows { previous: "381b4222-f694-41f0-9685-ff5bb260df2e".into(), ours: OURS.into() };
        assert_eq!(restore(&h, &b), Ok(()));
        let bad = PowerBackup::Windows { previous: "x & del".into(), ours: OURS.into() };
        assert!(restore(&h, &bad).is_err());
    }

    #[test]
    fn windows_restore_after_abort_before_the_copy() {
        let h = FakeHost::windows().on("powercfg.exe /setactive 381b4222-f694-41f0-9685-ff5bb260df2e", CmdOut::ok(""));
        let b = PowerBackup::Windows { previous: "381b4222-f694-41f0-9685-ff5bb260df2e".into(), ours: String::new() };
        assert_eq!(restore(&h, &b), Ok(()));
        assert!(h.calls_starting("powercfg.exe /delete").is_empty());
    }

    #[test]
    fn prepare_only_reads() {
        let h = FakeHost::mac().on("/usr/bin/pmset -g custom", CmdOut::ok(MINI_BEFORE));
        let b = prepare(&h).unwrap();
        assert_eq!(b, PowerBackup::Mac { ac: map(&[("autorestart", "0"), ("displaysleep", "10"), ("sleep", "1"), ("womp", "1")]) });
        assert!(h.calls_starting("/usr/bin/osascript").is_empty());
    }

    #[test]
    fn guid_and_index_parsing() {
        assert_eq!(
            parse_guid("Power Scheme GUID: 381B4222-F694-41F0-9685-FF5BB260DF2E  (Balanced)").as_deref(),
            Some("381b4222-f694-41f0-9685-ff5bb260df2e")
        );
        assert_eq!(parse_guid("kein Schema"), None);
        assert_eq!(parse_ac_index(&query_out(600, 300)), Some(600));
        assert_eq!(parse_ac_index("Current AC Power Setting Index: 0x00000000\nCurrent DC Power Setting Index: 0x00000384"), Some(0));
    }
}
