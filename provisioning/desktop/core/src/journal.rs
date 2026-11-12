//! Änderungs-Journal (Prüfliste Nr. 2 und 18). Jede Änderung der App wird **vor** dem Ausführen als
//! `Begun` eingetragen und danach als `Done`; ein Abbruch dazwischen lässt `Begun` stehen. So weiß die App beim
//! nächsten Start, ob eine Einrichtung abgebrochen wurde, und kann Schritt für Schritt zurückgehen.
//!
//! Die Datei liegt außerhalb des App-Pakets (Mac `~/Library/Application Support/io.lifeagents.desktop`,
//! Windows `%LOCALAPPDATA%\io.lifeagents.desktop`), damit sie ein Löschen der App übersteht.

use crate::autostart::{self, Autostart};
use crate::docker::{Docker, DockerCall};
use crate::host::{join, Host, Os};
use crate::power::{self, PowerBackup};

pub const APP_ID: &str = "io.lifeagents.desktop";

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "step", rename_all = "kebab-case")]
pub enum Step {
    /// Docker Desktop von der App installiert (nur dann darf das Entfernen danach fragen).
    DockerInstalled,
    /// Docker war aus und wurde von der App gestartet.
    DockerStarted,
    /// Bestandsaufnahme fremder Objekte (Datei neben dem Journal).
    Inventory {
        file: String,
    },
    /// Zustandsführende Volumes, die die App mit Label angelegt hat. Umkehrung: keine, sie tragen Daten;
    /// gelöscht wird nur beim Entfernen nach ausdrücklicher Frage (`uninstall`).
    VolumesCreated {
        names: Vec<String>,
    },
    /// Images, die vor dem Start fehlten und darum von uns geladen werden.
    ImagesPulled {
        refs: Vec<String>,
    },
    /// `anchor` + `master` gestartet.
    CoreStarted {
        compose_file: String,
        env_file: String,
    },
    PowerChanged {
        backup: PowerBackup,
    },
    AutostartInstalled {
        entry: Autostart,
    },
    /// Der Wizard meldet „fertig“; ab hier startet die App nur noch.
    SetupComplete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Begun,
    Done,
    Undone,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Entry {
    pub seq: u32,
    pub at: u64,
    pub state: State,
    #[serde(flatten)]
    pub step: Step,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Status {
    /// Noch nie etwas geändert.
    Fresh,
    /// Ein Schritt begonnen, aber nicht beendet: fortsetzen oder zurück.
    Interrupted {
        step: Step,
    },
    /// Einrichtung läuft noch (Wizard offen), nichts abgebrochen.
    InProgress,
    Complete,
    /// Alles zurückgenommen.
    RolledBack,
}

/// Umkehrung eines Eintrags.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Undo {
    Nothing,
    ComposeDown {
        compose_file: String,
        env_file: String,
    },
    RemoveImages {
        refs: Vec<String>,
    },
    RestorePower {
        backup: PowerBackup,
    },
    RemoveAutostart {
        entry: Autostart,
    },
    /// Docker Desktop selbst wird nie still entfernt: getrennte Frage (Nr. 17).
    AskRemoveDocker,
}

pub fn undo_of(step: &Step) -> Undo {
    match step {
        Step::DockerInstalled => Undo::AskRemoveDocker,
        Step::DockerStarted | Step::Inventory { .. } | Step::VolumesCreated { .. } | Step::SetupComplete => Undo::Nothing,
        Step::ImagesPulled { refs } => Undo::RemoveImages { refs: refs.clone() },
        Step::CoreStarted { compose_file, env_file } => {
            Undo::ComposeDown { compose_file: compose_file.clone(), env_file: env_file.clone() }
        }
        Step::PowerChanged { backup } => Undo::RestorePower { backup: backup.clone() },
        Step::AutostartInstalled { entry } => Undo::RemoveAutostart { entry: entry.clone() },
    }
}

pub fn dir(host: &dyn Host) -> String {
    match host.os() {
        Os::Mac => join(Os::Mac, &[&host.home(), "Library/Application Support", APP_ID]),
        Os::Windows => {
            let base = host.env("LOCALAPPDATA").unwrap_or_else(|| join(Os::Windows, &[&host.home(), "AppData\\Local"]));
            join(Os::Windows, &[&base, APP_ID])
        }
    }
}

pub fn path(host: &dyn Host) -> String {
    join(host.os(), &[&dir(host), "journal.json"])
}

#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct Journal {
    pub entries: Vec<Entry>,
}

impl Journal {
    /// Fehlt die Datei, ist das ein frischer Rechner. Ist sie unlesbar, gilt sie nicht als frisch: Fehler.
    pub fn load(host: &dyn Host) -> Result<Journal, String> {
        match host.read_file(&path(host)) {
            None => Ok(Journal::default()),
            Some(t) => serde_json::from_str(&t).map_err(|e| format!("Journal unlesbar: {e}")),
        }
    }

    fn save(&self, host: &dyn Host) -> Result<(), String> {
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        host.write_file(&path(host), &text)
    }

    /// Vor der Änderung aufrufen. Erst wenn das Journal geschrieben ist, darf die Änderung laufen.
    pub fn begin(&mut self, host: &dyn Host, step: Step) -> Result<u32, String> {
        let seq = self.entries.iter().map(|e| e.seq).max().unwrap_or(0) + 1;
        self.entries.push(Entry { seq, at: host.now(), state: State::Begun, step });
        self.save(host)?;
        Ok(seq)
    }

    /// Nach der Änderung; `step` ersetzt den Eintrag, wenn erst jetzt Daten feststehen (z. B. Sicherung).
    pub fn done(&mut self, host: &dyn Host, seq: u32, step: Option<Step>) -> Result<(), String> {
        let e = self.entries.iter_mut().find(|e| e.seq == seq).ok_or("unbekannter Eintrag")?;
        e.state = State::Done;
        if let Some(s) = step {
            e.step = s;
        }
        e.at = host.now();
        self.save(host)
    }

    /// Ein begonnener Schritt kam nicht zustande (z. B. Passwort abgebrochen): Eintrag verwerfen.
    pub fn abandon(&mut self, host: &dyn Host, seq: u32) -> Result<(), String> {
        self.entries.retain(|e| e.seq != seq);
        self.save(host)
    }

    /// Schließt alle noch begonnenen Einträge dieser Art ab (`done`) oder verwirft sie (sonst). Für Schritte, deren Ergebnis
    /// erst später feststeht (Docker gestartet: erst wenn es antwortet); ohne begonnenen Eintrag geschieht nichts.
    pub fn settle(&mut self, host: &dyn Host, pred: impl Fn(&Step) -> bool, done: bool) -> Result<(), String> {
        let seqs: Vec<u32> = self.entries.iter().filter(|e| e.state == State::Begun && pred(&e.step)).map(|e| e.seq).collect();
        for seq in seqs {
            if done {
                self.done(host, seq, None)?;
            } else {
                self.abandon(host, seq)?;
            }
        }
        Ok(())
    }

    pub fn mark_undone(&mut self, host: &dyn Host, seq: u32) -> Result<(), String> {
        let e = self.entries.iter_mut().find(|e| e.seq == seq).ok_or("unbekannter Eintrag")?;
        e.state = State::Undone;
        e.at = host.now();
        self.save(host)
    }

    pub fn status(&self) -> Status {
        let live: Vec<&Entry> = self.entries.iter().filter(|e| e.state != State::Undone).collect();
        if self.entries.is_empty() {
            return Status::Fresh;
        }
        // Docker Desktop bleibt beim Rückweg absichtlich (eigene Frage beim Entfernen): zählt nicht als Rest.
        if live.iter().all(|e| e.step == Step::DockerInstalled && e.state == State::Done) {
            return Status::RolledBack;
        }
        // Ein begonnener Schritt, den ein späterer Lauf derselben Art abgeschlossen hat (Fortsetzen nach einem
        // Abbruch), ist erledigt; nur ein offener Rest heißt „unterbrochen“.
        let superseded = |b: &Entry| {
            live.iter()
                .any(|e| e.seq > b.seq && e.state == State::Done && std::mem::discriminant(&e.step) == std::mem::discriminant(&b.step))
        };
        if let Some(b) = live.iter().rev().find(|e| e.state == State::Begun && !superseded(e)) {
            return Status::Interrupted { step: b.step.clone() };
        }
        if live.iter().any(|e| e.step == Step::SetupComplete) {
            Status::Complete
        } else {
            Status::InProgress
        }
    }

    pub fn has_done(&self, pred: impl Fn(&Step) -> bool) -> bool {
        self.entries.iter().any(|e| e.state == State::Done && pred(&e.step))
    }

    pub fn last_done(&self, pred: impl Fn(&Step) -> bool) -> Option<&Entry> {
        self.entries.iter().rev().find(|e| e.state == State::Done && pred(&e.step))
    }

    /// Rückweg: alle nicht zurückgenommenen Einträge, jüngster zuerst. Auch `Begun` wird umgekehrt, denn die
    /// Änderung kann halb passiert sein; jede Umkehrung verträgt, dass nichts (mehr) da ist.
    pub fn rollback_plan(&self) -> Vec<(u32, Undo)> {
        self.entries.iter().rev().filter(|e| e.state != State::Undone).map(|e| (e.seq, undo_of(&e.step))).collect()
    }
}

/// Eine Umkehrung ausführen. `AskRemoveDocker` führt hier nie etwas aus (eigene Frage, `uninstall`).
pub fn apply_undo(host: &dyn Host, docker: Option<&Docker>, undo: &Undo) -> Result<(), String> {
    match undo {
        Undo::Nothing | Undo::AskRemoveDocker => Ok(()),
        Undo::ComposeDown { compose_file, env_file } => {
            let d = docker.ok_or("Docker nicht erreichbar")?;
            let out = d.call(host, DockerCall::ComposeDown { file: compose_file, env_file })?;
            if out.success() {
                Ok(())
            } else {
                Err(format!("compose down -> {}", out.code))
            }
        }
        Undo::RemoveImages { refs } => {
            let d = docker.ok_or("Docker nicht erreichbar")?;
            for r in refs {
                // Fehlt das Image schon oder nutzt es inzwischen ein fremder Container, bleibt es: nie erzwingen.
                let _ = d.call(host, DockerCall::ImageRemove(r));
            }
            Ok(())
        }
        Undo::RestorePower { backup } => power::restore(host, backup).map_err(|e| format!("{e:?}")),
        Undo::RemoveAutostart { entry } => autostart::remove(host, entry),
    }
}

/// Rückweg gehen; bricht beim ersten Fehler ab und lässt den Rest im Journal (erneut aufrufbar).
pub fn rollback(host: &dyn Host, journal: &mut Journal, docker: Option<&Docker>) -> Result<(), String> {
    for (seq, undo) in journal.rollback_plan() {
        if undo == Undo::AskRemoveDocker {
            continue;
        }
        apply_undo(host, docker, &undo)?;
        journal.mark_undone(host, seq)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};
    use std::collections::BTreeMap;

    const JPATH: &str = "/Users/erika/Library/Application Support/io.lifeagents.desktop/journal.json";

    fn docker() -> Docker {
        Docker { bin: "docker".into(), context: "desktop-linux".into() }
    }

    fn full_setup() -> Vec<Step> {
        vec![
            Step::DockerInstalled,
            Step::DockerStarted,
            Step::Inventory { file: "inventory-before.json".into() },
            Step::ImagesPulled { refs: vec!["busybox@sha256:aa".into(), "ghcr.io/example/master@sha256:bb".into()] },
            Step::CoreStarted { compose_file: "/c/compose.yml".into(), env_file: "/c/app.env".into() },
            Step::PowerChanged { backup: PowerBackup::Mac { ac: BTreeMap::from([("sleep".to_string(), "1".to_string())]) } },
            Step::AutostartInstalled {
                entry: Autostart::MacLaunchAgent { path: "/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist".into() },
            },
            Step::SetupComplete,
        ]
    }

    #[test]
    fn journal_lives_outside_the_app_bundle() {
        let h = FakeHost::mac();
        assert_eq!(path(&h), JPATH);
        assert!(!path(&h).contains(".app/"));
        let w = FakeHost::windows().with_env("LOCALAPPDATA", "D:\\Profiles\\erika\\AppData\\Local");
        assert_eq!(path(&w), "D:\\Profiles\\erika\\AppData\\Local\\io.lifeagents.desktop\\journal.json");
    }

    #[test]
    fn begin_is_written_before_the_change() {
        let h = FakeHost::mac();
        let mut j = Journal::load(&h).unwrap();
        assert_eq!(j.status(), Status::Fresh);
        let seq = j.begin(&h, Step::DockerStarted).unwrap();
        let on_disk = Journal::load(&h).unwrap();
        assert_eq!(on_disk.entries[0].state, State::Begun);
        assert_eq!(on_disk.status(), Status::Interrupted { step: Step::DockerStarted });
        j.done(&h, seq, None).unwrap();
        assert_eq!(Journal::load(&h).unwrap().status(), Status::InProgress);
    }

    /// Docker gestartet gilt erst, wenn es antwortet: bis dahin begonnen, danach erledigt oder (nicht zustande gekommen) verworfen.
    #[test]
    fn docker_started_settles_once_the_answer_is_known() {
        let h = FakeHost::mac();
        let is_start = |s: &Step| *s == Step::DockerStarted;
        let mut j = Journal::load(&h).unwrap();
        j.begin(&h, Step::DockerStarted).unwrap();
        j.settle(&h, is_start, true).unwrap();
        assert!(j.has_done(is_start));
        assert_eq!(j.status(), Status::InProgress);
        let mut j = Journal::load(&FakeHost::mac()).unwrap();
        j.begin(&h, Step::DockerStarted).unwrap();
        j.settle(&h, is_start, false).unwrap();
        assert!(j.entries.iter().all(|e| e.step != Step::DockerStarted), "nicht zustande gekommen: kein Eintrag bleibt");
        j.settle(&h, is_start, true).unwrap();
    }

    #[test]
    fn resumed_setup_becomes_complete() {
        let h = FakeHost::mac();
        let mut j = Journal::default();
        let core = Step::CoreStarted { compose_file: "/c/compose.yml".into(), env_file: "/c/app.env".into() };
        j.begin(&h, core.clone()).unwrap(); // erster Versuch bricht ab
        assert!(matches!(j.status(), Status::Interrupted { .. }));
        let seq = j.begin(&h, core).unwrap(); // Fortsetzen
        j.done(&h, seq, None).unwrap();
        assert_eq!(j.status(), Status::InProgress);
        let seq = j.begin(&h, Step::SetupComplete).unwrap();
        j.done(&h, seq, None).unwrap();
        assert_eq!(j.status(), Status::Complete);
    }

    #[test]
    fn rollback_with_own_docker_counts_as_rolled_back() {
        let h = FakeHost::mac().on(
            "docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down",
            CmdOut::ok(""),
        );
        let mut j = Journal::default();
        for s in [Step::DockerInstalled, Step::CoreStarted { compose_file: "/c/compose.yml".into(), env_file: "/c/app.env".into() }] {
            let seq = j.begin(&h, s).unwrap();
            j.done(&h, seq, None).unwrap();
        }
        rollback(&h, &mut j, Some(&docker())).unwrap();
        assert_eq!(j.status(), Status::RolledBack);
        assert!(j.has_done(|s| *s == Step::DockerInstalled), "Docker bleibt für die Frage beim Entfernen vermerkt");
    }

    #[test]
    fn every_step_survives_the_round_trip_through_the_file() {
        let h = FakeHost::mac();
        let mut j = Journal::default();
        for s in full_setup() {
            let seq = j.begin(&h, s).unwrap();
            j.done(&h, seq, None).unwrap();
        }
        let seq = j.begin(&h, Step::PowerChanged { backup: PowerBackup::Windows { previous: "a".into(), ours: String::new() } }).unwrap();
        let _ = seq;
        assert_eq!(Journal::load(&h).unwrap(), j);
    }

    #[test]
    fn unreadable_journal_is_not_fresh() {
        let h = FakeHost::mac();
        h.write_file(JPATH, "{kaputt").unwrap();
        assert!(Journal::load(&h).is_err());
    }

    #[test]
    fn complete_after_setup_marker() {
        let h = FakeHost::mac();
        let mut j = Journal::default();
        for s in full_setup() {
            let seq = j.begin(&h, s).unwrap();
            j.done(&h, seq, None).unwrap();
        }
        assert_eq!(j.status(), Status::Complete);
    }

    /// Prüfliste Nr. 18: Abbruch nach jeder Stufe, Rückweg kehrt genau die erreichten Schritte um, jüngster zuerst.
    #[test]
    fn rollback_after_every_stage() {
        let steps = full_setup();
        for stop in 1..=steps.len() {
            for interrupted in [false, true] {
                let h = FakeHost::mac()
                    .on(
                        "docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down",
                        CmdOut::ok(""),
                    )
                    .on("docker --context desktop-linux image rm busybox@sha256:aa", CmdOut::ok(""))
                    .on(
                        "docker --context desktop-linux image rm ghcr.io/example/master@sha256:bb",
                        CmdOut::fail(1, "image is being used by stopped container"),
                    )
                    .on("/usr/bin/osascript -e do shell script \"/usr/bin/pmset -c sleep 1\" with administrator privileges", CmdOut::ok(""))
                    .on("/usr/bin/pmset -g custom", CmdOut::ok("AC Power:\n sleep                1\n"))
                    .with_path("/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist");
                let mut j = Journal::default();
                for (i, s) in steps.iter().take(stop).enumerate() {
                    let seq = j.begin(&h, s.clone()).unwrap();
                    let last = i + 1 == stop;
                    if !(last && interrupted) {
                        j.done(&h, seq, None).unwrap();
                    }
                }
                if interrupted {
                    assert!(matches!(j.status(), Status::Interrupted { .. }));
                }
                rollback(&h, &mut j, Some(&docker())).unwrap_or_else(|e| panic!("Stufe {stop}: {e}"));
                let reached: Vec<&Step> = steps.iter().take(stop).collect();
                let has = |f: fn(&Step) -> bool| reached.iter().any(|s| f(s));
                assert_eq!(
                    h.called(
                        "docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down"
                    ),
                    has(|s| matches!(s, Step::CoreStarted { .. })),
                    "Stufe {stop}"
                );
                assert_eq!(
                    h.calls_starting("docker --context desktop-linux image rm").len(),
                    if has(|s| matches!(s, Step::ImagesPulled { .. })) { 2 } else { 0 }
                );
                assert_eq!(h.calls_starting("/usr/bin/osascript").len(), usize::from(has(|s| matches!(s, Step::PowerChanged { .. }))));
                assert_eq!(
                    h.exists("/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist"),
                    !has(|s| matches!(s, Step::AutostartInstalled { .. }))
                );
                // Docker selbst wird nie still entfernt; der Eintrag bleibt für die eigene Frage stehen.
                let left: Vec<&Entry> = j.entries.iter().filter(|e| e.state != State::Undone).collect();
                assert!(left.iter().all(|e| e.step == Step::DockerInstalled), "Stufe {stop}: {left:?}");
                // Reihenfolge: jüngster zuerst (Verbund stoppen vor Images löschen).
                let calls = h.calls.borrow().clone();
                let down = calls.iter().position(|c| c.ends_with(" down"));
                let rm = calls.iter().position(|c| c.contains("image rm"));
                if let (Some(d), Some(r)) = (down, rm) {
                    assert!(d < r, "erst stoppen, dann Images");
                }
            }
        }
    }

    #[test]
    fn rollback_stops_at_first_failure_and_can_resume() {
        let h = FakeHost::mac().on(
            "docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down",
            CmdOut::fail(1, "Docker antwortet nicht"),
        );
        let mut j = Journal::default();
        for s in [Step::DockerStarted, Step::CoreStarted { compose_file: "/c/compose.yml".into(), env_file: "/c/app.env".into() }] {
            let seq = j.begin(&h, s).unwrap();
            j.done(&h, seq, None).unwrap();
        }
        assert!(rollback(&h, &mut j, Some(&docker())).is_err());
        assert_eq!(j.status(), Status::InProgress, "nichts als zurückgenommen markiert");
        h.set(
            "docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down",
            CmdOut::ok(""),
        );
        rollback(&h, &mut j, Some(&docker())).unwrap();
        assert_eq!(j.status(), Status::RolledBack);
    }
}
