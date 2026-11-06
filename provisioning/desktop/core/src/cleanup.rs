//! Aufräumen nach dem Reinziehen (Owner-Entscheid 2026-11-06): Die App wirft die eingehängte DMG selbst aus; der
//! Knopf „Download wegräumen“ legt die geladene Datei in den Papierkorb. Nie endgültig löschen, nie ungefragt, und
//! nur, wenn genau eine passende Datei im Download-Ordner liegt (sonst entfällt der Knopf).

use crate::host::{args, join, Host, Os};

/// Eingehängte DMG der App (`/Volumes/lifeagents`, bei Doppelungen `lifeagents 1` usw.).
pub fn mounted_dmgs(host: &dyn Host) -> Vec<String> {
    if host.os() != Os::Mac {
        return vec![];
    }
    host.list_dir("/Volumes")
        .into_iter()
        .filter(|n| n == "lifeagents" || n.starts_with("lifeagents "))
        .map(|n| join(Os::Mac, &["/Volumes", &n]))
        .collect()
}

/// Auswerfen ohne Zwang: Ist die DMG noch in Benutzung, bleibt sie, und die App versucht es beim nächsten Start.
pub fn eject_dmgs(host: &dyn Host) -> Vec<String> {
    let mut ejected = Vec::new();
    for v in mounted_dmgs(host) {
        if host.run("/usr/bin/hdiutil", &args(&["detach", &v])).map(|o| o.success()).unwrap_or(false) {
            ejected.push(v);
        }
    }
    ejected
}

fn downloads(host: &dyn Host) -> String {
    join(host.os(), &[&host.home(), "Downloads"])
}

/// Die geladene Datei, nur wenn genau eine passt (`lifeagents*.dmg` bzw. `lifeagents-setup*.exe`).
pub fn find_download(host: &dyn Host) -> Option<String> {
    let dir = downloads(host);
    let hits: Vec<String> = host
        .list_dir(&dir)
        .into_iter()
        .filter(|n| {
            let l = n.to_ascii_lowercase();
            match host.os() {
                Os::Mac => l.starts_with("lifeagents") && l.ends_with(".dmg"),
                Os::Windows => l.starts_with("lifeagents-setup") && l.ends_with(".exe"),
            }
        })
        .collect();
    (hits.len() == 1).then(|| join(host.os(), &[&dir, &hits[0]]))
}

/// In den Papierkorb legen, aber nur die Datei, die `find_download` gerade eindeutig findet.
pub fn trash_download(host: &dyn Host) -> Result<String, String> {
    let path = find_download(host).ok_or("keine eindeutige Datei")?;
    host.trash(&path)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::{CmdOut, FakeHost};

    #[test]
    fn ejects_only_our_disk_images() {
        let h = FakeHost::mac()
            .with_path("/Volumes/lifeagents")
            .with_path("/Volumes/lifeagents 1")
            .with_path("/Volumes/Paperless Backup")
            .with_path("/Volumes/lifeagents-andere")
            .on("/usr/bin/hdiutil detach /Volumes/lifeagents", CmdOut::ok(""))
            .on("/usr/bin/hdiutil detach /Volumes/lifeagents 1", CmdOut::fail(16, "resource busy"));
        assert_eq!(eject_dmgs(&h), vec!["/Volumes/lifeagents".to_string()]);
        assert_eq!(h.calls_starting("/usr/bin/hdiutil").len(), 2);
        assert!(h.calls.borrow().iter().all(|c| !c.contains("-force")));
    }

    #[test]
    fn download_only_when_exactly_one_matches() {
        let h = FakeHost::mac().with_path("/Users/erika/Downloads/lifeagents.dmg").with_path("/Users/erika/Downloads/Rechnung.pdf");
        assert_eq!(find_download(&h).as_deref(), Some("/Users/erika/Downloads/lifeagents.dmg"));
        let h = h.with_path("/Users/erika/Downloads/lifeagents (1).dmg");
        assert_eq!(find_download(&h), None, "zwei Treffer: Knopf entfällt");
        assert!(trash_download(&h).is_err());
        assert!(h.trashed.borrow().is_empty());
    }

    #[test]
    fn trash_moves_to_bin_never_deletes() {
        let h = FakeHost::mac().with_path("/Users/erika/Downloads/lifeagents.dmg");
        assert_eq!(trash_download(&h).unwrap(), "/Users/erika/Downloads/lifeagents.dmg");
        assert_eq!(h.trashed.borrow().as_slice(), ["/Users/erika/Downloads/lifeagents.dmg"]);
        assert!(find_download(&h).is_none());
    }

    #[test]
    fn windows_setup_file() {
        let h = FakeHost::windows()
            .with_path("D:\\Profiles\\erika\\Downloads\\lifeagents-setup.exe")
            .with_path("D:\\Profiles\\erika\\Downloads\\lifeagents.dmg");
        assert_eq!(find_download(&h).as_deref(), Some("D:\\Profiles\\erika\\Downloads\\lifeagents-setup.exe"));
        assert!(mounted_dmgs(&h).is_empty());
    }
}
