//! Texte der App aus dem Textkatalog (`packages/core/locales/<code>.json`, Schlüssel `core.desktop.*`), eine Quelle
//! mit Bot und Fragebogen. Rust braucht sie für das Menü am Symbol; die Fenster-Seiten bekommen dieselben Schlüssel
//! als Block in `ui/app.js` (`scripts/build_ui_tokens.ps1`). Beim Bau eingelesen: Die App lädt nichts nach.

use std::collections::HashMap;
use std::sync::OnceLock;

static DE: &str = include_str!("../../../../packages/core/locales/de.json");
static EN: &str = include_str!("../../../../packages/core/locales/en.json");
static KO: &str = include_str!("../../../../packages/core/locales/ko.json");

fn catalog() -> &'static HashMap<&'static str, HashMap<String, String>> {
    static CAT: OnceLock<HashMap<&'static str, HashMap<String, String>>> = OnceLock::new();
    CAT.get_or_init(|| {
        [("de", DE), ("en", EN), ("ko", KO)]
            .into_iter()
            .map(|(code, raw)| (code, serde_json::from_str::<HashMap<String, serde_json::Value>>(raw).unwrap_or_default()))
            .map(|(code, map)| (code, map.into_iter().filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string()))).collect()))
            .collect()
    })
}

/// Text zu `key` in `lang`; fehlt er, der deutsche, sonst der Schlüssel selbst (fällt im Test auf).
pub fn text(lang: &str, key: &str) -> String {
    let cat = catalog();
    cat.get(lang).and_then(|m| m.get(key)).or_else(|| cat.get("de").and_then(|m| m.get(key))).cloned().unwrap_or_else(|| key.to_string())
}

/// Schlüssel der Texte im Menü am Symbol (`app/src/main.rs`).
pub const TRAY_KEYS: [&str; 11] = [
    "core.desktop.tray.checking",
    "core.desktop.tray.running",
    "core.desktop.tray.stopped",
    "core.desktop.tray.open",
    "core.desktop.tray.telegram",
    "core.desktop.tray.power_restore",
    "core.desktop.tray.report",
    "core.desktop.tray.backup_kit",
    "core.desktop.tray.backup_dir",
    "core.desktop.tray.uninstall",
    "core.desktop.tray.quit",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tray_text_exists_in_every_language() {
        for lang in crate::lang::SUPPORTED {
            for key in TRAY_KEYS {
                let t = catalog().get(lang).and_then(|m| m.get(key));
                assert!(t.is_some_and(|t| !t.trim().is_empty()), "{key} fehlt in {lang}.json");
            }
        }
    }

    #[test]
    fn falls_back_to_german_then_to_the_key() {
        assert_eq!(text("xx", "core.desktop.tray.quit"), text("de", "core.desktop.tray.quit"));
        assert_eq!(text("de", "core.desktop.gibt_es_nicht"), "core.desktop.gibt_es_nicht");
        assert_ne!(text("ko", "core.desktop.tray.quit"), text("de", "core.desktop.tray.quit"));
    }
}
