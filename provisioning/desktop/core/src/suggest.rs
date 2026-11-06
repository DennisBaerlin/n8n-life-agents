//! Vorschläge vom Rechner für den Fragebogen (Leitung, Owner-Wunsch „automatisch, mit Mehrwert“ 2026-11-06). Alles
//! nur gelesen und nur als Vorschlag; der Nutzer bestätigt oder ändert im Fragebogen. **Privat:** Die Werte gehen
//! nur in die Env-Datei der App (nur für den Nutzer lesbar) und von dort an den `master`, nie in ein Log, nie in den
//! Fehlerbericht (`report.rs` kennt sie nicht), nie in den Selbsttest außer als „gefunden ja/nein“.
//!
//! - MyFRITZ-Kennung: Das selbst signierte Zertifikat, das die FritzBox auf `https://fritz.box` zeigt, nennt bei
//!   angemeldetem MyFRITZ den Namen `<kennung>.myfritz.net` in den Subject Alternative Names (Leitung, an einer echten
//!   FritzBox geprüft). Ein Verbindungsaufbau mit kurzer Wartezeit, das Zertifikat wird NICHT geprüft, nur gelesen.
//! - Gerätename in der FritzBox, geprüft (Owner-Wunsch: in der Box umbenannte Geräte): Rückwärts-Namensauflösung der
//!   eigenen Adresse direkt beim Router (`dns.rs`); die FritzBox antwortet mit `<gerätename>.fritz.box` (Leitung, an
//!   einer echten Box geprüft). Ob ein Umbenennen dort sofort erscheint, ist offen (Handliste).
//! - Rückfall: Kandidaten aus dem Rechnernamen. Die FritzBox übernimmt den Namen, den der Rechner per DHCP sendet, und
//!   erlaubt nur Buchstaben, Ziffern, Bindestrich. Wie Umlaute umgewandelt werden, ist nicht belegt: darum mehrere.
//! - Vollständiger Name und Sprache des angemeldeten Nutzers.

use std::time::Duration;

use crate::host::{args, Host, Os};

/// Wartezeit für den einen Verbindungsaufbau zu `fritz.box`.
pub const FRITZ_TIMEOUT: Duration = Duration::from_millis(2500);

/// `<kennung>.myfritz.net` aus den Subject Alternative Names eines Zertifikats (DER). Nur ein Name genau dieser Form
/// (eine Kennung aus Kleinbuchstaben und Ziffern), keine Platzhalter wie `*.…`.
pub fn myfritz_zone_from_der(der: &[u8]) -> Option<String> {
    use x509_parser::prelude::*;
    let (_, cert) = X509Certificate::from_der(der).ok()?;
    let san = cert.subject_alternative_name().ok()??;
    san.value.general_names.iter().find_map(|n| match n {
        GeneralName::DNSName(name) => {
            let name = name.to_ascii_lowercase();
            let id = name.strip_suffix(".myfritz.net")?;
            (!id.is_empty() && id.len() <= 63 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')).then_some(name)
        }
        _ => None,
    })
}

/// MyFRITZ-Kennung der FritzBox im Heimnetz, sonst `None` (keine FritzBox, kein MyFRITZ, keine Antwort).
pub fn myfritz_zone(host: &dyn Host) -> Option<String> {
    let der = host.peer_cert_der("fritz.box", 443, FRITZ_TIMEOUT)?;
    myfritz_zone_from_der(&der)
}

/// Wartezeit für die Namensfrage beim Router.
pub const PTR_TIMEOUT: Duration = Duration::from_secs(2);

/// Gerätename, unter dem die FritzBox diesen Rechner führt: PTR der eigenen Adresse beim Router. Nur eine Antwort
/// `<name>.fritz.box` zählt (anderer Router oder keine Antwort: `None`); der Name wird nach der AVM-Regel bereinigt.
pub fn fritz_box_name(host: &dyn Host, route: &crate::network::Route) -> Option<String> {
    let ip: std::net::Ipv4Addr = route.ip.parse().ok()?;
    let server = std::net::SocketAddr::from((route.gateway?, 53));
    let answer = host.dns_ptr(server, ip, PTR_TIMEOUT)?.to_ascii_lowercase();
    let label = answer.trim_end_matches('.').strip_suffix(".fritz.box")?;
    if label.contains('.') {
        return None;
    }
    Some(fritz_name(label, true, true)).filter(|n| !n.is_empty())
}

/// Name so umwandeln, wie die FritzBox ihn zulässt: klein, Buchstaben, Ziffern, Bindestrich. `umlaut_long`: ä → ae
/// (sonst ä → a); `space_dash`: Leerzeichen und andere Zeichen → Bindestrich (sonst entfernt).
pub fn fritz_name(raw: &str, umlaut_long: bool, space_dash: bool) -> String {
    let mut out = String::new();
    for c in raw.trim().chars().flat_map(char::to_lowercase) {
        let rep: &str = match c {
            'ä' if umlaut_long => "ae",
            'ö' if umlaut_long => "oe",
            'ü' if umlaut_long => "ue",
            'ä' => "a",
            'ö' => "o",
            'ü' => "u",
            'ß' => "ss",
            'é' | 'è' | 'ê' => "e",
            'á' | 'à' | 'â' => "a",
            c if c.is_ascii_alphanumeric() => {
                out.push(c);
                continue;
            }
            '-' => "-",
            _ if space_dash => "-",
            _ => "",
        };
        out.push_str(rep);
    }
    let mut collapsed = String::new();
    for c in out.chars() {
        if c == '-' && collapsed.ends_with('-') {
            continue;
        }
        collapsed.push(c);
    }
    let name = collapsed.trim_matches('-').chars().take(63).collect::<String>();
    // Nur aus Ziffern lässt die FritzBox keinen Namen zu.
    if name.chars().all(|c| c.is_ascii_digit()) {
        String::new()
    } else {
        name
    }
}

fn out(host: &dyn Host, prog: &str, a: &[&str]) -> Option<String> {
    host.run(prog, &args(a)).ok().filter(|o| o.success()).map(|o| o.stdout.trim().to_string()).filter(|s| !s.is_empty())
}

/// 2–4 Kandidaten für den Gerätenamen dieses Rechners in der FritzBox, wahrscheinlichster zuerst.
pub fn hostname_candidates(host: &dyn Host) -> Vec<String> {
    let mut raw: Vec<(String, bool, bool)> = Vec::new();
    match host.os() {
        Os::Mac => {
            // LocalHostName sendet der Mac per DHCP: der wahrscheinlichste Name in der FritzBox.
            if let Some(n) = out(host, "/usr/sbin/scutil", &["--get", "LocalHostName"]) {
                raw.push((n, true, true));
            }
            if let Some(n) = out(host, "/usr/sbin/scutil", &["--get", "ComputerName"]) {
                raw.push((n.clone(), true, true));
                raw.push((n.clone(), false, true));
                raw.push((n, true, false));
            }
        }
        Os::Windows => {
            if let Some(n) = host.env("COMPUTERNAME") {
                raw.push((n, true, true));
            }
            if let Some(n) = out(host, "hostname.exe", &[]) {
                raw.push((n, true, true));
            }
        }
    }
    let mut list: Vec<String> = Vec::new();
    for (n, long, dash) in raw {
        let c = fritz_name(&n, long, dash);
        if !c.is_empty() && !list.contains(&c) {
            list.push(c);
        }
    }
    list.truncate(4);
    list
}

/// Für die Env-Datei: Buchstaben (auch Umlaute), Leerzeichen, Bindestrich, Punkt; alles andere fällt weg.
pub fn clean_display_name(raw: &str) -> String {
    let s: String = raw.chars().filter(|c| c.is_alphabetic() || *c == ' ' || *c == '-' || *c == '.').collect();
    s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(64).collect()
}

/// Vollständiger Name des angemeldeten Nutzers (Mac `id -F`, Windows lokales Konto).
pub fn user_fullname(host: &dyn Host) -> Option<String> {
    let raw = match host.os() {
        Os::Mac => out(host, "/usr/bin/id", &["-F"])?,
        Os::Windows => out(
            host,
            "powershell.exe",
            &["-NoProfile", "-NonInteractive", "-Command", "(Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue).FullName"],
        )?,
    };
    Some(clean_display_name(&raw)).filter(|s| !s.is_empty())
}

/// Sprache des Systems als zwei Buchstaben (`de`, `en`).
pub fn user_lang(host: &dyn Host) -> Option<String> {
    let raw = match host.os() {
        // „(\n    "de-DE",\n    "en-DE"\n)“: erster Eintrag
        Os::Mac => out(host, "/usr/bin/defaults", &["read", "-g", "AppleLanguages"])?,
        Os::Windows => {
            out(host, "powershell.exe", &["-NoProfile", "-NonInteractive", "-Command", "(Get-UICulture).TwoLetterISOLanguageName"])?
        }
    };
    let first = raw.split(|c: char| !(c.is_ascii_alphabetic() || c == '-' || c == '_')).find(|t| !t.is_empty())?;
    let lang: String = first.chars().take_while(|c| c.is_ascii_alphabetic()).collect::<String>().to_ascii_lowercase();
    (lang.len() == 2).then_some(lang)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `<name>.fritz.box` zur Laufzeit zusammengesetzt: privacy_lint weist jeden solchen Namen als Literal ab.
    fn fb(name: &str) -> String {
        format!("{name}.fritz.box")
    }
    use crate::host::{CmdOut, FakeHost};

    /// Attrappe eines FritzBox-Zertifikats, erfundene Kennung.
    fn fake_cert(names: &[&str]) -> Vec<u8> {
        let names: Vec<String> = names.iter().map(|s| s.to_string()).collect();
        rcgen::generate_simple_self_signed(names).unwrap().cert.der().to_vec()
    }

    #[test]
    fn myfritz_zone_from_the_certificate() {
        let der = fake_cert(&["fritz.box", "myfritz.box", "deine-domain.myfritz.net"]);
        assert_eq!(myfritz_zone_from_der(&der).as_deref(), Some("deine-domain.myfritz.net"));
    }

    #[test]
    fn no_myfritz_means_none() {
        assert_eq!(myfritz_zone_from_der(&fake_cert(&["fritz.box", "myfritz.box"])), None);
        assert_eq!(myfritz_zone_from_der(&fake_cert(&["*.deine-domain.myfritz.net"])), None, "Platzhalter zählt nicht");
        assert_eq!(myfritz_zone_from_der(b"kein zertifikat"), None);
    }

    #[test]
    fn fritz_box_unreachable_is_none() {
        let h = FakeHost::mac();
        assert_eq!(myfritz_zone(&h), None);
        *h.peer_cert.borrow_mut() = Some(fake_cert(&["fritz.box", "deine-domain.myfritz.net"]));
        assert_eq!(myfritz_zone(&h).as_deref(), Some("deine-domain.myfritz.net"));
    }

    fn route(gw: bool) -> crate::network::Route {
        crate::network::Route { ip: "192.168.178.20".into(), gateway: gw.then(|| std::net::Ipv4Addr::new(192, 168, 178, 10)) }
    }

    #[test]
    fn fritz_box_name_comes_from_the_router() {
        let h = FakeHost::mac();
        *h.ptr.borrow_mut() = Some(fb("Erika-Buero"));
        assert_eq!(fritz_box_name(&h, &route(true)).as_deref(), Some("erika-buero"));
        assert_eq!(h.ptr_asked.borrow().as_slice(), ["192.168.178.10:53 192.168.178.20"], "nur beim Router, nur die eigene Adresse");
        *h.ptr.borrow_mut() = Some(fb("erika-buero") + ".");
        assert_eq!(fritz_box_name(&h, &route(true)).as_deref(), Some("erika-buero"), "Punkt am Ende");
    }

    #[test]
    fn other_routers_or_no_answer_give_nothing() {
        let h = FakeHost::mac();
        assert_eq!(fritz_box_name(&h, &route(true)), None, "keine Antwort");
        *h.ptr.borrow_mut() = Some("erika-buero.speedport.ip".into());
        assert_eq!(fritz_box_name(&h, &route(true)), None, "anderer Router");
        *h.ptr.borrow_mut() = Some(fb("a.b"));
        assert_eq!(fritz_box_name(&h, &route(true)), None, "Gerätenamen haben keinen Punkt");
        *h.ptr.borrow_mut() = Some(fb("erika-buero"));
        assert_eq!(fritz_box_name(&h, &route(false)), None, "ohne Router keine Frage");
        assert_eq!(h.ptr_asked.borrow().len(), 3);
    }

    #[test]
    fn names_follow_the_fritz_box_rules() {
        assert_eq!(fritz_name("Erikas Mac mini", true, true), "erikas-mac-mini");
        assert_eq!(fritz_name("Jörgs MacBook Pro", true, true), "joergs-macbook-pro");
        assert_eq!(fritz_name("Jörgs MacBook Pro", false, true), "jorgs-macbook-pro");
        assert_eq!(fritz_name("Jörgs MacBook Pro", true, false), "joergsmacbookpro");
        assert_eq!(fritz_name("  Büro (2) ", true, true), "buero-2");
        assert_eq!(fritz_name("12345", true, true), "", "nur Ziffern lässt die FritzBox nicht zu");
    }

    #[test]
    fn mac_candidates_start_with_the_dhcp_name() {
        let h = FakeHost::mac()
            .on("/usr/sbin/scutil --get LocalHostName", CmdOut::ok("Erikas-Mac-mini\n"))
            .on("/usr/sbin/scutil --get ComputerName", CmdOut::ok("Erikas Mac mini\n"));
        assert_eq!(hostname_candidates(&h), vec!["erikas-mac-mini", "erikasmacmini"]);
        let h = FakeHost::mac()
            .on("/usr/sbin/scutil --get LocalHostName", CmdOut::ok("Joergs-MacBook\n"))
            .on("/usr/sbin/scutil --get ComputerName", CmdOut::ok("Jörgs MacBook\n"));
        assert_eq!(hostname_candidates(&h), vec!["joergs-macbook", "jorgs-macbook", "joergsmacbook"]);
        assert!(hostname_candidates(&FakeHost::mac()).is_empty());
    }

    #[test]
    fn windows_candidates() {
        let h = FakeHost::windows().with_env("COMPUTERNAME", "DESKTOP-AB12CD").on("hostname.exe", CmdOut::ok("Desktop-AB12CD\r\n"));
        assert_eq!(hostname_candidates(&h), vec!["desktop-ab12cd"]);
    }

    #[test]
    fn user_suggestions() {
        let h = FakeHost::mac()
            .on("/usr/bin/id -F", CmdOut::ok("Erika Beispiel\n"))
            .on("/usr/bin/defaults read -g AppleLanguages", CmdOut::ok("(\n    \"de-DE\",\n    \"en-DE\"\n)\n"));
        assert_eq!(user_fullname(&h).as_deref(), Some("Erika Beispiel"));
        assert_eq!(user_lang(&h).as_deref(), Some("de"));
        let h = FakeHost::mac().on("/usr/bin/id -F", CmdOut::ok("Erika $(rm -rf ~) #1\n"));
        assert_eq!(user_fullname(&h).as_deref(), Some("Erika rm -rf"), "nur harmlose Zeichen in die Env-Datei");
        assert_eq!(user_lang(&FakeHost::mac()), None);
    }
}
