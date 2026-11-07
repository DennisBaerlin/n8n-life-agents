//! Tailscale-Rechnername aus zwei Wörtern (`calm-otter`) statt fest `bot`: Er steht in öffentlichen
//! Zertifikats-Protokollen und verrät so weder Person noch Software. Eine Wortliste mit der CLI
//! (`provisioning/lib/ts_names.json`, bash-Seite `ts_name_*` in `provisioning/lib/reach.sh`); beide Seiten ziehen nach
//! derselben Regel und prüfen sie an den `vectors` der Datei. Einmal je Installation ziehen, danach nie neu: Ein neuer
//! Name benennt das Gerät im Tailnet um (neue Internet-Adresse, neuer Webhook).

use crate::host::Host;
use std::sync::OnceLock;

/// Rückfall ohne Namen und für Installationen von vor der Wortliste (`compose.yml`: `${LA_TS_HOSTNAME:-bot}`).
pub const FALLBACK: &str = "bot";

const LIST: &str = include_str!("../../../lib/ts_names.json");

#[derive(serde::Deserialize)]
struct Words {
    adjectives: Vec<String>,
    nouns: Vec<String>,
}

fn words() -> &'static Words {
    static W: OnceLock<Words> = OnceLock::new();
    // Die Datei ist zur Bauzeit eingebettet; Test `the_list_is_usable` prüft sie, ein Fehler hier ist ein Bau-Fehler.
    W.get_or_init(|| serde_json::from_str(LIST).expect("provisioning/lib/ts_names.json"))
}

/// Zieh-Regel: n → `adjectives[n % A]` + `-` + `nouns[(n / A) % N]`.
pub fn from_seed(n: u32) -> String {
    let w = words();
    let a = w.adjectives.len() as u32;
    let o = w.nouns.len() as u32;
    format!("{}-{}", w.adjectives[(n % a) as usize], w.nouns[((n / a) % o) as usize])
}

/// Gültiges Hostname-Label: a–z, 0–9, Bindestrich nicht am Rand, 1 bis 63 Zeichen.
pub fn valid(name: &str) -> bool {
    let ok_chars = name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    (1..=63).contains(&name.len()) && ok_chars && !name.starts_with('-') && !name.ends_with('-')
}

/// Name für die Env-Datei. Ein gültiger gespeicherter Name bleibt (auch `bot`); ein ungültiger wird `bot`, nie still
/// neu gezogen. Ohne gespeicherten Namen: Gibt es das Tailscale-Volume schon (`existing_install`), lief der Rechner
/// schon unter `bot`; sonst einmal ziehen.
pub fn keep_or_draw(host: &dyn Host, saved: Option<&str>, existing_install: bool) -> Result<String, String> {
    match saved {
        Some(v) if valid(v) => Ok(v.to_string()),
        Some(_) => Ok(FALLBACK.to_string()),
        None if existing_install => Ok(FALLBACK.to_string()),
        None => {
            let hex = host.random_hex(4)?;
            let n = u32::from_str_radix(&hex, 16).map_err(|_| "Zufallszahl unlesbar".to_string())?;
            Ok(from_seed(n))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::FakeHost;

    #[test]
    fn the_list_is_usable() {
        let w = words();
        for list in [&w.adjectives, &w.nouns] {
            assert!(!list.is_empty());
            assert!(list.iter().all(|x| !x.is_empty() && x.bytes().all(|b| b.is_ascii_lowercase())), "{list:?}");
            let mut sorted = list.clone();
            sorted.sort();
            sorted.dedup();
            assert_eq!(sorted.len(), list.len(), "doppeltes Wort");
        }
        let longest = w.adjectives.iter().map(String::len).max().unwrap() + 1 + w.nouns.iter().map(String::len).max().unwrap();
        assert!(longest <= 63, "längster Name {longest} Zeichen");
    }

    #[test]
    fn same_names_as_the_cli() {
        let v: serde_json::Value = serde_json::from_str(LIST).unwrap();
        let vectors = v["vectors"].as_array().unwrap();
        assert!(vectors.len() >= 5);
        for t in vectors {
            let seed = u32::try_from(t["seed"].as_u64().unwrap()).unwrap();
            assert_eq!(from_seed(seed), t["name"].as_str().unwrap(), "seed {seed}");
        }
        assert!(vectors.iter().any(|t| t["seed"].as_u64() == Some(u64::from(u32::MAX))), "Prüfwert für die größte Zahl fehlt");
    }

    #[test]
    fn label_rules() {
        let (max, over) = ("a".repeat(63), "a".repeat(64));
        for ok in ["bot", "calm-otter", "a", "x1", max.as_str()] {
            assert!(valid(ok), "{ok}");
        }
        for bad in ["", "-bot", "bot-", "Bot", "calm otter", "calm_otter", "bot\n", over.as_str()] {
            assert!(!valid(bad), "{bad:?}");
        }
    }

    #[test]
    fn drawn_once_kept_afterwards() {
        let h = FakeHost::mac();
        // FakeHost liefert immer abababab.
        assert_eq!(keep_or_draw(&h, None, false).unwrap(), from_seed(0xabab_abab));
        assert_eq!(keep_or_draw(&h, Some("calm-otter"), false).unwrap(), "calm-otter");
        assert_eq!(keep_or_draw(&h, Some("bot"), false).unwrap(), "bot", "Bestand mit bot bleibt bot");
    }

    #[test]
    fn existing_install_or_broken_value_stays_bot() {
        let h = FakeHost::mac();
        assert_eq!(keep_or_draw(&h, None, true).unwrap(), FALLBACK, "Tailscale-Volume da: nie umbenennen");
        assert_eq!(keep_or_draw(&h, Some("Calm Otter"), false).unwrap(), FALLBACK, "ungültig: nie still neu ziehen");
    }
}
