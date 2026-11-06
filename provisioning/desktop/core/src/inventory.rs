//! Bestandsaufnahme fremder Objekte und Vorher-Nachher-Vergleich (Prüfliste Nr. 6, 7, 16). Nur lesen.
//!
//! Vorbild ist das Testpaket (`bestand`/`vergleich`): Container mit Startzeit und Neustart-Zähler, Volumes,
//! Netze, Images mit ID, dazu die Energiewerte. Unsere eigenen Objekte zählen nicht.

use std::collections::{BTreeMap, BTreeSet};

use crate::contract::{is_our_name, LABEL, PORT_RANGE, PROJECT};
use crate::docker::{Docker, DockerCall};
use crate::host::Host;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
pub struct ContainerRow {
    pub name: String,
    pub id: String,
    pub image: String,
    pub started_at: String,
    pub restarts: String,
    pub status: String,
    /// Compose-Projekt des Containers (leer, wenn ohne Compose gestartet).
    pub project: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub struct Snapshot {
    pub containers: Vec<ContainerRow>,
    pub volumes: Vec<String>,
    pub networks: Vec<String>,
    /// `repo:tag|id`
    pub images: Vec<String>,
    pub power: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Deviation {
    ContainerGone {
        name: String,
    },
    /// Neu gestartet, angehalten, anderes Image oder neuer Neustart-Zähler.
    ContainerChanged {
        name: String,
        field: String,
    },
    ContainerNew {
        name: String,
    },
    VolumeGone {
        name: String,
    },
    VolumeNew {
        name: String,
    },
    NetworkGone {
        name: String,
    },
    NetworkNew {
        name: String,
    },
    /// Image fehlt oder sein Tag zeigt jetzt auf ein anderes Image (Einwand 30).
    ImageGoneOrMoved {
        image: String,
    },
    PowerChanged {
        key: String,
    },
}

fn lines(host: &dyn Host, d: &Docker, call: DockerCall) -> Result<Vec<String>, String> {
    let out = d.call(host, call)?;
    if !out.success() {
        return Err(format!("Docker-Abfrage scheiterte ({})", out.code));
    }
    Ok(out.stdout.lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect())
}

fn ours_by_labels(labels: &str) -> bool {
    labels.split(',').any(|kv| kv == format!("com.docker.compose.project={PROJECT}") || kv.starts_with(&format!("{LABEL}=")))
}

pub fn take(host: &dyn Host, d: &Docker) -> Result<Snapshot, String> {
    let ids = lines(host, d, DockerCall::ContainerIds)?;
    let mut containers = Vec::new();
    if !ids.is_empty() {
        for l in lines(host, d, DockerCall::ContainerInspect(&ids))? {
            let f: Vec<&str> = l.split('|').collect();
            if f.len() < 7 {
                continue;
            }
            let row = ContainerRow {
                name: f[0].trim_start_matches('/').to_string(),
                id: f[1].to_string(),
                image: f[2].to_string(),
                started_at: f[3].to_string(),
                restarts: f[4].to_string(),
                status: f[5].to_string(),
                project: if f[6] == "<no value>" { String::new() } else { f[6].to_string() },
            };
            if row.project != PROJECT && !is_our_name(&row.name) {
                containers.push(row);
            }
        }
    }
    containers.sort();
    let mut volumes: Vec<String> = lines(host, d, DockerCall::VolumeList)?
        .into_iter()
        .filter_map(|l| {
            let (name, labels) = l.split_once('|').unwrap_or((l.as_str(), ""));
            (!is_our_name(name) && !ours_by_labels(labels)).then(|| name.to_string())
        })
        .collect();
    volumes.sort();
    let mut networks: Vec<String> =
        lines(host, d, DockerCall::NetworkList)?.into_iter().filter(|l| !is_our_name(l.split('|').next().unwrap_or(""))).collect();
    networks.sort();
    let mut images = lines(host, d, DockerCall::ImageList)?;
    images.sort();
    Ok(Snapshot { containers, volumes, networks, images, power: crate::power::snapshot(host) })
}

/// Vorher-Nachher-Vergleich. `ignore_power` = Schlüssel, die wir laut Journal selbst geändert haben.
pub fn compare(before: &Snapshot, after: &Snapshot, ignore_power: &[String]) -> Vec<Deviation> {
    let mut dev = Vec::new();
    let a_by: BTreeMap<&str, &ContainerRow> = after.containers.iter().map(|c| (c.id.as_str(), c)).collect();
    let b_ids: BTreeSet<&str> = before.containers.iter().map(|c| c.id.as_str()).collect();
    for b in &before.containers {
        match a_by.get(b.id.as_str()) {
            None => dev.push(Deviation::ContainerGone { name: b.name.clone() }),
            Some(a) => {
                for (field, x, y) in [
                    ("started-at", &b.started_at, &a.started_at),
                    ("restarts", &b.restarts, &a.restarts),
                    ("status", &b.status, &a.status),
                    ("image", &b.image, &a.image),
                    ("name", &b.name, &a.name),
                ] {
                    if x != y {
                        dev.push(Deviation::ContainerChanged { name: b.name.clone(), field: field.into() });
                    }
                }
            }
        }
    }
    for a in &after.containers {
        if !b_ids.contains(a.id.as_str()) {
            dev.push(Deviation::ContainerNew { name: a.name.clone() });
        }
    }
    set_diff(&before.volumes, &after.volumes, &mut dev, |n| Deviation::VolumeGone { name: n }, |n| Deviation::VolumeNew { name: n });
    set_diff(&before.networks, &after.networks, &mut dev, |n| Deviation::NetworkGone { name: n }, |n| Deviation::NetworkNew { name: n });
    // Neue Images sind erlaubt (unsere); jedes vorherige muss mit derselben ID noch da sein.
    let a_img: BTreeSet<&String> = after.images.iter().collect();
    for i in &before.images {
        if !a_img.contains(i) {
            dev.push(Deviation::ImageGoneOrMoved { image: i.split('|').next().unwrap_or(i).to_string() });
        }
    }
    let keys: BTreeSet<&String> = before.power.keys().chain(after.power.keys()).collect();
    for k in keys {
        if !ignore_power.contains(k) && before.power.get(k) != after.power.get(k) {
            dev.push(Deviation::PowerChanged { key: k.clone() });
        }
    }
    dev
}

fn set_diff(b: &[String], a: &[String], dev: &mut Vec<Deviation>, gone: impl Fn(String) -> Deviation, new: impl Fn(String) -> Deviation) {
    let bs: BTreeSet<&String> = b.iter().collect();
    let as_: BTreeSet<&String> = a.iter().collect();
    for x in bs.difference(&as_) {
        dev.push(gone((*x).clone()));
    }
    for x in as_.difference(&bs) {
        dev.push(new((*x).clone()));
    }
}

/// Programme, die schon in Docker laufen: je Compose-Projekt eins, sonst je Container (für „Dort laufen schon 3 Programme“).
pub fn running_programs(s: &Snapshot) -> Vec<String> {
    let set: BTreeSet<String> = s
        .containers
        .iter()
        .filter(|c| c.status == "running")
        .map(|c| if c.project.is_empty() { c.name.clone() } else { c.project.clone() })
        .collect();
    set.into_iter().collect()
}

/// Prüfliste Nr. 7: Objekte mit unserem Namen.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum OwnObjects {
    None,
    /// Von einer früheren Einrichtung (tragen unser Label): Journal entscheidet über Fortsetzen oder Rückweg.
    Ours {
        names: Vec<String>,
    },
    /// Tragen unseren Namen, aber nicht unser Label: gehören jemand anderem → Abbruch, nichts überschreiben.
    Foreign {
        names: Vec<String>,
    },
}

pub fn own_objects(host: &dyn Host, d: &Docker) -> Result<OwnObjects, String> {
    let mut ours = Vec::new();
    let mut foreign = Vec::new();
    for l in lines(host, d, DockerCall::OurContainers)?.into_iter().chain(lines(host, d, DockerCall::OurVolumes)?) {
        let (name, labels) = l.split_once('|').unwrap_or((l.as_str(), ""));
        if !is_our_name(name) {
            continue; // Docker-Filter sind Teilstring-Treffer; nur echte Präfix-Treffer zählen
        }
        if ours_by_labels(labels) {
            ours.push(name.to_string());
        } else {
            foreign.push(name.to_string());
        }
    }
    Ok(if !foreign.is_empty() {
        OwnObjects::Foreign { names: foreign }
    } else if !ours.is_empty() {
        OwnObjects::Ours { names: ours }
    } else {
        OwnObjects::None
    })
}

/// Erster freier Port im festen Bereich auf 127.0.0.1.
pub fn free_port(host: &dyn Host) -> Option<u16> {
    (PORT_RANGE.0..=PORT_RANGE.1).find(|p| host.port_free(*p))
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

    const PAPERLESS: &str = "/paperless-webserver-1|c1|sha256:21|2026-11-04T22:29:06Z|0|running|paperless\n/paperless-broker-1|c2|sha256:d7|2026-11-04T22:29:06Z|0|running|paperless\n/lifeagents-master|c9|sha256:99|2026-11-05T10:00:00Z|0|running|lifeagents\n/old-test|c3|sha256:aa|0001-01-01T00:00:00Z|0|exited|<no value>\n";

    fn host_with(inspect: &str, vols: &str, imgs: &str) -> FakeHost {
        let ids = vec!["c1".to_string(), "c2".to_string(), "c9".to_string(), "c3".to_string()];
        FakeHost::mac()
            .on(&cmd(DockerCall::ContainerIds), CmdOut::ok("c1\nc2\nc9\nc3\n"))
            .on(&cmd(DockerCall::ContainerInspect(&ids)), CmdOut::ok(inspect))
            .on(&cmd(DockerCall::VolumeList), CmdOut::ok(vols))
            .on(&cmd(DockerCall::NetworkList), CmdOut::ok("bridge|n1\npaperless_default|n2\nlifeagents_edge|n3\n"))
            .on(&cmd(DockerCall::ImageList), CmdOut::ok(imgs))
            .on("/usr/bin/pmset -g custom", CmdOut::ok("AC Power:\n sleep                1\n"))
    }
    const VOLS: &str = "paperless_data|com.docker.compose.project=paperless\nlifeagents_pgdata|io.lifeagents.install=1\n";
    const IMGS: &str = "ghcr.io/paperless-ngx/paperless-ngx:2.13|sha256:21\nredis:7|sha256:d7\n";

    #[test]
    fn snapshot_excludes_our_objects() {
        let s = take(&host_with(PAPERLESS, VOLS, IMGS), &d()).unwrap();
        assert_eq!(
            s.containers.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(),
            vec!["old-test", "paperless-broker-1", "paperless-webserver-1"]
        );
        assert_eq!(s.volumes, vec!["paperless_data"]);
        assert_eq!(s.networks, vec!["bridge|n1", "paperless_default|n2"]);
        assert_eq!(running_programs(&s), vec!["paperless"]);
        assert_eq!(s.power.get("sleep").map(String::as_str), Some("1"));
    }

    #[test]
    fn unchanged_neighbour_has_no_deviation() {
        let h = host_with(PAPERLESS, VOLS, IMGS);
        let before = take(&h, &d()).unwrap();
        let after = take(&h, &d()).unwrap();
        assert!(compare(&before, &after, &[]).is_empty());
    }

    #[test]
    fn restarted_neighbour_is_reported() {
        let before = take(&host_with(PAPERLESS, VOLS, IMGS), &d()).unwrap();
        let restarted = PAPERLESS.replace("c1|sha256:21|2026-11-04T22:29:06Z|0", "c1|sha256:21|2026-11-06T08:00:00Z|1");
        let after = take(&host_with(&restarted, VOLS, IMGS), &d()).unwrap();
        let dev = compare(&before, &after, &[]);
        assert!(dev.contains(&Deviation::ContainerChanged { name: "paperless-webserver-1".into(), field: "started-at".into() }));
        assert!(dev.contains(&Deviation::ContainerChanged { name: "paperless-webserver-1".into(), field: "restarts".into() }));
    }

    #[test]
    fn missing_volume_and_moved_tag_are_reported() {
        let before = take(&host_with(PAPERLESS, VOLS, IMGS), &d()).unwrap();
        let after = take(
            &host_with(
                PAPERLESS,
                "lifeagents_pgdata|io.lifeagents.install=1\n",
                "ghcr.io/paperless-ngx/paperless-ngx:2.13|sha256:21\nredis:7|sha256:ff\nbusybox:1.37|sha256:bb\n",
            ),
            &d(),
        )
        .unwrap();
        let dev = compare(&before, &after, &[]);
        assert!(dev.contains(&Deviation::VolumeGone { name: "paperless_data".into() }));
        assert!(dev.contains(&Deviation::ImageGoneOrMoved { image: "redis:7".into() }));
        assert!(
            !dev.iter().any(|x| matches!(x, Deviation::ImageGoneOrMoved { image } if image.starts_with("busybox"))),
            "neue Images sind erlaubt"
        );
    }

    #[test]
    fn power_change_ignored_only_when_we_did_it() {
        let mut a = Snapshot::default();
        let mut b = Snapshot::default();
        a.power.insert("sleep".into(), "1".into());
        b.power.insert("sleep".into(), "0".into());
        assert_eq!(compare(&a, &b, &[]), vec![Deviation::PowerChanged { key: "sleep".into() }]);
        assert!(compare(&a, &b, &["sleep".into()]).is_empty());
    }

    #[test]
    fn foreign_object_with_our_name_aborts() {
        let h = FakeHost::mac()
            .on(&cmd(DockerCall::OurContainers), CmdOut::ok("lifeagents-db|com.docker.compose.project=someoneelse\n"))
            .on(&cmd(DockerCall::OurVolumes), CmdOut::ok(""));
        assert_eq!(own_objects(&h, &d()).unwrap(), OwnObjects::Foreign { names: vec!["lifeagents-db".into()] });
        let h = FakeHost::mac()
            .on(
                &cmd(DockerCall::OurContainers),
                CmdOut::ok("lifeagents-master|com.docker.compose.project=lifeagents,io.lifeagents.install=1\n"),
            )
            .on(&cmd(DockerCall::OurVolumes), CmdOut::ok("lifeagents_pgdata|io.lifeagents.install=1\nmy-lifeagents_x|\n"));
        assert_eq!(
            own_objects(&h, &d()).unwrap(),
            OwnObjects::Ours { names: vec!["lifeagents-master".into(), "lifeagents_pgdata".into()] }
        );
    }

    #[test]
    fn failed_query_is_an_error_not_an_empty_inventory() {
        let h = FakeHost::mac().on(&cmd(DockerCall::ContainerIds), CmdOut::fail(1, "daemon gone"));
        assert!(take(&h, &d()).is_err());
    }

    #[test]
    fn free_port_skips_busy_ones() {
        let mut h = FakeHost::mac();
        h.busy_ports = [5880u16, 5881].into_iter().collect();
        assert_eq!(free_port(&h), Some(5882));
        h.busy_ports = (5880u16..=5899).collect();
        assert_eq!(free_port(&h), None);
    }
}
