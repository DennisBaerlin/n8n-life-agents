//! Kern der Start-App: Prüfungen und kleine, einzeln testbare Änderungs-Schritte. Kennt kein Tauri und
//! kein Fenster; jede Berührung des Systems läuft über `host::Host` (Tests: `host::FakeHost`).
//!
//! Prüfliste des Plans → Modul: Nr. 1/3 `system`, Nr. 2/18 `journal`, Nr. 4/5 `detect`, Nr. 6/7/16
//! `inventory`, Nr. 8 `changes`, Nr. 15 `power`, Nr. 17 `uninstall`. Docker-Aufrufe nur über `docker`.

pub mod admin;
pub mod autostart;
pub mod changes;
pub mod cleanup;
pub mod contract;
pub mod core_start;
pub mod detect;
pub mod dns;
pub mod docker;
pub mod docker_desktop;
pub mod host;
pub mod inventory;
pub mod journal;
pub mod network;
pub mod power;
pub mod report;
pub mod suggest;
pub mod system;
pub mod uninstall;

/// Alle Quellen der Bibliothek, für Tests, die über den ganzen Code wachen (z. B. keine Sicherheits-Einstellung).
#[cfg(test)]
pub(crate) fn all_sources() -> Vec<(&'static str, &'static str)> {
    vec![
        ("admin.rs", include_str!("admin.rs")),
        ("autostart.rs", include_str!("autostart.rs")),
        ("changes.rs", include_str!("changes.rs")),
        ("cleanup.rs", include_str!("cleanup.rs")),
        ("contract.rs", include_str!("contract.rs")),
        ("core_start.rs", include_str!("core_start.rs")),
        ("detect.rs", include_str!("detect.rs")),
        ("dns.rs", include_str!("dns.rs")),
        ("docker.rs", include_str!("docker.rs")),
        ("docker_desktop.rs", include_str!("docker_desktop.rs")),
        ("host.rs", include_str!("host.rs")),
        ("inventory.rs", include_str!("inventory.rs")),
        ("journal.rs", include_str!("journal.rs")),
        ("lib.rs", include_str!("lib.rs")),
        ("network.rs", include_str!("network.rs")),
        ("power.rs", include_str!("power.rs")),
        ("report.rs", include_str!("report.rs")),
        ("suggest.rs", include_str!("suggest.rs")),
        ("system.rs", include_str!("system.rs")),
        ("uninstall.rs", include_str!("uninstall.rs")),
    ]
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_source_file_is_watched() {
        let listed: Vec<&str> = super::all_sources().iter().map(|(n, _)| *n).collect();
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
        for e in std::fs::read_dir(dir).unwrap() {
            let name = e.unwrap().file_name().into_string().unwrap();
            if name.ends_with(".rs") {
                assert!(listed.contains(&name.as_str()), "{name} fehlt in all_sources()");
            }
        }
    }
}
