//! Entfernen (Prüfliste Nr. 17): nur Objekte mit unserem Label; Images nur, wenn das Journal sagt, dass wir sie
//! geladen haben; Daten, Energiewerte, Anmeldestart und selbst installiertes Docker getrennt erfragt. Danach
//! Vorher-Nachher-Vergleich der fremden Objekte (Nr. 16).

use crate::autostart::Autostart;
use crate::contract::{is_our_name, LABEL};
use crate::docker::{Docker, DockerCall};
use crate::host::Host;
use crate::inventory::{self, Deviation};
use crate::journal::{self, Journal, State, Step, Undo};
use crate::power::PowerBackup;

/// Was es zu fragen gibt. Leere Felder = keine Frage.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct Plan {
    /// Unsere Datenspeicher (Volumes mit Label): nur nach ausdrücklichem Ja löschen.
    pub data_volumes: Vec<String>,
    pub power: Option<PowerBackup>,
    pub autostart: Option<Autostart>,
    /// Die App hat Docker Desktop installiert (Journal); nur dann die Frage, es zu entfernen.
    pub docker_installed_by_us: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
pub struct Choices {
    pub delete_data: bool,
    pub restore_power: bool,
    pub remove_autostart: bool,
    pub remove_docker: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize)]
pub struct Outcome {
    /// Schritte, die nicht geklappt haben (Codes), z. B. `webhook`, `power`.
    pub failed: Vec<String>,
    /// Vergleich fremder Objekte vor und nach dem Entfernen.
    pub deviations: Vec<Deviation>,
}

fn our_volumes(host: &dyn Host, d: &Docker) -> Vec<String> {
    let Ok(out) = d.call(host, DockerCall::OurVolumes) else { return vec![] };
    out.stdout
        .lines()
        .filter_map(|l| l.split_once('|'))
        .filter(|(name, labels)| is_our_name(name) && labels.split(',').any(|kv| kv.starts_with(&format!("{LABEL}="))))
        .map(|(n, _)| n.to_string())
        .collect()
}

pub fn plan(host: &dyn Host, j: &Journal, d: Option<&Docker>) -> Plan {
    let live = |pred: fn(&Step) -> bool| j.entries.iter().rev().find(|e| e.state != State::Undone && pred(&e.step)).map(|e| e.step.clone());
    Plan {
        data_volumes: d.map(|d| our_volumes(host, d)).unwrap_or_default(),
        power: match live(|s| matches!(s, Step::PowerChanged { .. })) {
            Some(Step::PowerChanged { backup }) => Some(backup),
            _ => None,
        },
        autostart: match live(|s| matches!(s, Step::AutostartInstalled { .. })) {
            Some(Step::AutostartInstalled { entry }) => Some(entry),
            _ => None,
        },
        docker_installed_by_us: j.has_done(|s| *s == Step::DockerInstalled),
    }
}

/// Reihenfolge: Webhook freigeben → Verbund stoppen → unsere Images → (Daten) → (Energie) → (Anmeldestart)
/// → (Docker) → Vergleich. Fehler einzelner Schritte halten nicht an; sie stehen im Ergebnis.
pub fn run(host: &dyn Host, j: &mut Journal, d: Option<&Docker>, p: &Plan, c: Choices) -> Outcome {
    let mut o = Outcome::default();
    let before = d.and_then(|d| inventory::take(host, d).ok());
    if let Some(d) = d {
        let ok = d.call(host, DockerCall::Master(crate::contract::MasterCmd::ReleaseWebhook)).map(|x| x.success()).unwrap_or(false);
        if !ok {
            o.failed.push("webhook".into());
        }
    }
    // Journal-Einträge mit Umkehrung, die ohne Rückfrage gilt: Verbund stoppen, unsere Images.
    for (seq, undo) in j.rollback_plan() {
        let run_it = match &undo {
            Undo::ComposeDown { .. } | Undo::RemoveImages { .. } => true,
            Undo::RestorePower { .. } => c.restore_power,
            Undo::RemoveAutostart { .. } => c.remove_autostart,
            Undo::Nothing => true,
            Undo::AskRemoveDocker => false,
        };
        if !run_it {
            continue;
        }
        let code = match &undo {
            Undo::ComposeDown { .. } => "stop",
            Undo::RemoveImages { .. } => "images",
            Undo::RestorePower { .. } => "power",
            Undo::RemoveAutostart { .. } => "autostart",
            _ => "other",
        };
        match journal::apply_undo(host, d, &undo) {
            Ok(()) => {
                let _ = j.mark_undone(host, seq);
            }
            Err(_) => o.failed.push(code.into()),
        }
    }
    if c.delete_data {
        if let Some(d) = d {
            for v in &p.data_volumes {
                // Label unmittelbar vor dem Löschen noch einmal prüfen.
                if !our_volumes(host, d).contains(v) {
                    o.failed.push(format!("data:{v}"));
                    continue;
                }
                if !d.call(host, DockerCall::VolumeRemove(v)).map(|x| x.success()).unwrap_or(false) {
                    o.failed.push(format!("data:{v}"));
                }
            }
        }
    }
    if let (Some(d), Some(b)) = (d, before) {
        if let Ok(after) = inventory::take(host, d) {
            // Energiewerte haben wir eben selbst zurückgestellt, das ist keine fremde Änderung.
            let ignore: Vec<String> = b.power.keys().cloned().collect();
            o.deviations = inventory::compare(&b, &after, if c.restore_power { &ignore } else { &[] });
        }
    }
    if c.remove_docker && p.docker_installed_by_us {
        match crate::docker_desktop::uninstall(host) {
            Ok(()) => {
                for e in j.entries.clone().iter().filter(|e| e.step == Step::DockerInstalled && e.state == State::Done) {
                    let _ = j.mark_undone(host, e.seq);
                }
            }
            Err(_) => o.failed.push("docker".into()),
        }
    }
    o
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};
    use crate::inventory::Snapshot;
    use std::collections::BTreeMap;

    fn d() -> Docker {
        Docker { bin: "docker".into(), context: "desktop-linux".into() }
    }
    fn cmd(call: DockerCall) -> String {
        format!("docker {}", d().args(&call).join(" "))
    }

    fn setup(h: &FakeHost, docker_by_us: bool) -> Journal {
        let mut j = Journal::default();
        let mut steps = vec![];
        if docker_by_us {
            steps.push(Step::DockerInstalled);
        }
        steps.extend([
            Step::ImagesPulled { refs: vec!["ghcr.io/example/lifeagents-master@sha256:bbbb".into()] },
            Step::CoreStarted { compose_file: "/c/compose.yml".into(), env_file: "/c/app.env".into() },
            Step::PowerChanged { backup: PowerBackup::Mac { ac: BTreeMap::from([("sleep".into(), "1".into())]) } },
            Step::AutostartInstalled {
                entry: Autostart::MacLaunchAgent { path: "/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist".into() },
            },
            Step::SetupComplete,
        ]);
        for s in steps {
            let seq = j.begin(h, s).unwrap();
            j.done(h, seq, None).unwrap();
        }
        j
    }

    fn host() -> FakeHost {
        let h = FakeHost::mac()
            .on(
                &cmd(DockerCall::OurVolumes),
                CmdOut::ok("lifeagents_pgdata|io.lifeagents.install=1\nlifeagents_n8n|io.lifeagents.install=1\n"),
            )
            .on(&cmd(DockerCall::Master(crate::contract::MasterCmd::ReleaseWebhook)), CmdOut::ok(""))
            .on(
                "docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down",
                CmdOut::ok(""),
            )
            .on(&cmd(DockerCall::ImageRemove("ghcr.io/example/lifeagents-master@sha256:bbbb")), CmdOut::ok(""))
            .on(&cmd(DockerCall::VolumeRemove("lifeagents_pgdata")), CmdOut::ok(""))
            .on(&cmd(DockerCall::VolumeRemove("lifeagents_n8n")), CmdOut::ok(""))
            .on("/usr/bin/pmset -g custom", CmdOut::ok("AC Power:\n sleep                1\n"))
            .on("/usr/bin/osascript -e do shell script \"/usr/bin/pmset -c sleep 1\" with administrator privileges", CmdOut::ok(""))
            .with_path("/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist");
        // Bestandsaufnahme: ein Nachbar, vorher wie nachher gleich.
        h.set(&cmd(DockerCall::ContainerIds), CmdOut::ok("c1\n"));
        h.set(
            &cmd(DockerCall::ContainerInspect(&["c1".to_string()])),
            CmdOut::ok("/paperless-webserver-1|c1|sha256:21|2026-11-04T22:29:06Z|0|running|paperless\n"),
        );
        h.set(&cmd(DockerCall::VolumeList), CmdOut::ok("paperless_data|\n"));
        h.set(&cmd(DockerCall::NetworkList), CmdOut::ok("bridge|n1\n"));
        h.set(&cmd(DockerCall::ImageList), CmdOut::ok("redis:7|sha256:d7\n"));
        h
    }

    #[test]
    fn default_choices_keep_data_power_autostart_and_docker() {
        let h = host();
        let mut j = setup(&h, true);
        let p = plan(&h, &j, Some(&d()));
        assert_eq!(p.data_volumes, vec!["lifeagents_pgdata", "lifeagents_n8n"]);
        assert!(p.docker_installed_by_us && p.power.is_some() && p.autostart.is_some());
        let o = run(&h, &mut j, Some(&d()), &p, Choices::default());
        assert!(o.failed.is_empty(), "{:?}", o.failed);
        assert!(o.deviations.is_empty(), "{:?}", o.deviations);
        assert!(
            h.called("docker --context desktop-linux compose --project-name lifeagents --file /c/compose.yml --env-file /c/app.env down")
        );
        assert!(h.called(&cmd(DockerCall::ImageRemove("ghcr.io/example/lifeagents-master@sha256:bbbb"))));
        assert!(h.calls_starting("docker --context desktop-linux volume rm").is_empty(), "Daten nur nach Ja");
        assert!(h.calls_starting("/usr/bin/osascript").is_empty(), "Energie nur nach Ja");
        assert!(h.exists("/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist"));
    }

    #[test]
    fn everything_chosen() {
        let h = host();
        let mut j = setup(&h, false);
        let p = plan(&h, &j, Some(&d()));
        assert!(!p.docker_installed_by_us, "fremdes Docker: keine Frage");
        let c = Choices { delete_data: true, restore_power: true, remove_autostart: true, remove_docker: true };
        let o = run(&h, &mut j, Some(&d()), &p, c);
        assert!(o.failed.is_empty(), "{:?}", o.failed);
        assert_eq!(h.calls_starting("docker --context desktop-linux volume rm").len(), 2);
        assert!(!h.exists("/Users/erika/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist"));
        assert!(h.calls_starting("/usr/bin/osascript").iter().all(|c| !c.contains("Docker.app")), "Docker gehörte uns nicht");
        assert_eq!(j.status(), journal::Status::RolledBack);
    }

    #[test]
    fn volume_losing_our_label_is_not_deleted() {
        let h = host();
        let mut j = setup(&h, false);
        let p = plan(&h, &j, Some(&d()));
        h.set(&cmd(DockerCall::OurVolumes), CmdOut::ok("lifeagents_pgdata|io.lifeagents.install=1\nlifeagents_n8n|\n"));
        let o = run(&h, &mut j, Some(&d()), &p, Choices { delete_data: true, ..Choices::default() });
        assert!(o.failed.contains(&"data:lifeagents_n8n".to_string()));
        assert!(!h.called(&cmd(DockerCall::VolumeRemove("lifeagents_n8n"))));
    }

    #[test]
    fn neighbour_change_is_reported() {
        let h = host();
        let mut j = setup(&h, false);
        let p = plan(&h, &j, Some(&d()));
        // Nachbar startet zwischen Vorher und Nachher neu (simuliert über eine Antwortfolge).
        h.cmds.borrow_mut().insert(
            cmd(DockerCall::ContainerInspect(&["c1".to_string()])),
            vec![
                CmdOut::ok("/paperless-webserver-1|c1|sha256:21|2026-11-04T22:29:06Z|0|running|paperless\n"),
                CmdOut::ok("/paperless-webserver-1|c1|sha256:21|2026-11-06T09:00:00Z|1|running|paperless\n"),
            ],
        );
        let o = run(&h, &mut j, Some(&d()), &p, Choices::default());
        assert!(!o.deviations.is_empty());
        let _ = Snapshot::default();
    }
}
