//! Kern der Start-App: Prüfungen und kleine, einzeln testbare Änderungs-Schritte. Kennt kein Tauri und
//! kein Fenster; jede Berührung des Systems läuft über `host::Host` (Tests: `host::FakeHost`).
//!
//! Prüfliste des Plans → Modul: Nr. 1/3 `system`, Nr. 2/18 `journal`, Nr. 4/5 `detect`, Nr. 6/7/16
//! `inventory`, Nr. 8 `changes`, Nr. 15 `power`, Nr. 17 `uninstall`. Docker-Aufrufe nur über `docker`.

pub mod contract;
pub mod detect;
pub mod docker;
pub mod host;
