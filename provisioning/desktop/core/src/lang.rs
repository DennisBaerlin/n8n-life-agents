//! Sprache der App (Leitung 2026-11-06, Owner-Ziel „top user experience“): Deutsch, Englisch, Koreanisch wie der
//! Fragebogen. Vor dem Fragebogen gilt die Systemsprache des Rechners (Rückfall Deutsch). Stellt der Nutzer im
//! Fragebogen um, meldet `ctl.js status` die Sprache (`lang`); die App merkt sie sich in einer kleinen Datei neben dem
//! Journal und spricht sie danach überall: Dauerbetrieb, Fertig, Menüleiste, auch nach einem Neustart.

use crate::host::{join, Host};

/// Sprachen der App, dieselben wie im Textkatalog (`packages/core/locales/<code>.json`).
pub const SUPPORTED: [&str; 3] = ["de", "en", "ko"];
pub const FALLBACK: &str = "de";

/// Nur bekannte Codes, sonst `None`.
pub fn parse(raw: &str) -> Option<&'static str> {
    let code = raw.trim().to_ascii_lowercase();
    SUPPORTED.iter().copied().find(|c| *c == code)
}

fn file(host: &dyn Host) -> String {
    join(host.os(), &[&crate::journal::dir(host), "lang"])
}

/// Im Fragebogen gewählte Sprache, falls schon gemerkt.
pub fn saved(host: &dyn Host) -> Option<&'static str> {
    host.read_file(&file(host)).as_deref().and_then(parse)
}

/// Systemsprache, sofern die App sie spricht, sonst Deutsch.
pub fn system(host: &dyn Host) -> &'static str {
    crate::suggest::user_lang(host).as_deref().and_then(parse).unwrap_or(FALLBACK)
}

/// Gemerkte Sprache, sonst die des Systems.
pub fn current(host: &dyn Host) -> &'static str {
    saved(host).unwrap_or_else(|| system(host))
}

/// Sprache aus dem Fragebogen merken (nur bekannte Codes; unverändert = nichts schreiben).
pub fn save(host: &dyn Host, raw: &str) -> Result<(), String> {
    let Some(code) = parse(raw) else { return Ok(()) };
    if saved(host) == Some(code) {
        return Ok(());
    }
    host.write_file(&file(host), code)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};

    #[test]
    fn system_language_first_then_the_questionnaire() {
        let h = FakeHost::mac().on("/usr/bin/defaults read -g AppleLanguages", CmdOut::ok("(\n    \"ko-KR\"\n)\n"));
        assert_eq!(current(&h), "ko");
        save(&h, "en").unwrap();
        assert_eq!(current(&h), "en", "Wahl im Fragebogen schlägt die Systemsprache");
        save(&h, "xx").unwrap();
        assert_eq!(current(&h), "en", "unbekannter Code ändert nichts");
    }

    #[test]
    fn unknown_system_language_falls_back_to_german() {
        let h = FakeHost::mac().on("/usr/bin/defaults read -g AppleLanguages", CmdOut::ok("(\n    \"fr-FR\"\n)\n"));
        assert_eq!(current(&h), "de");
        assert_eq!(current(&FakeHost::mac()), "de");
        assert_eq!(parse(" KO "), Some("ko"));
    }
}
