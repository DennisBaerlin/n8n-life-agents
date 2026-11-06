//! Die schmale Schnittstelle zwischen Start-App und dem Rest des Systems, an einer Stelle.
//!
//! **Stand: Attrappe.** Die Namen folgen dem Plan (Projekt `lifeagents`, Label `io.lifeagents.install`,
//! Dienste `anchor` + `master`). Die endgültigen Werte legt Paket 1 (Compose-Betriebsart) fest, den
//! Wizard-Einstieg Paket 4, das Master-Image Paket 5. Ändert sich dort etwas, ändert sich nur diese Datei.
//!
//! Was die App vom `master` erwartet (Paket 4/5 müssen es bedienen), steht bei `MasterCmd`.

/// Compose-Projektname. Jedes Objekt unseres Verbunds trägt ihn (Label `com.docker.compose.project`).
pub const PROJECT: &str = "lifeagents";
/// Eigenes Label an allen Objekten, die der Verbund anlegt. Ein Treffer mit unserem Namen, aber ohne
/// dieses Label, heißt Abbruch (Plan, Einwand 29).
pub const LABEL: &str = "io.lifeagents.install";
/// Dienste, die die App nach der ersten Zustimmung startet. Alles Weitere startet der `master`.
pub const FIRST_SERVICES: [&str; 2] = ["anchor", "master"];
/// Container-Name des `master` (für `docker exec`).
pub const MASTER_CONTAINER: &str = "lifeagents-master";
/// Name der Compose-Datei im Ressourcen-Ordner der App. Fehlt sie, zeigt die App „noch nicht verfügbar“.
pub const COMPOSE_FILE: &str = "compose.yml";
/// Variable für den freien Port auf 127.0.0.1, den die App vorher sucht (Datei `--env-file`).
pub const PORT_VAR: &str = "LIFEAGENTS_HTTP_PORT";
/// Suchbereich für den freien Port (wie im Testpaket).
pub const PORT_RANGE: (u16, u16) = (5880, 5899);

/// Befehle, die die App im `master` ausführt (`docker exec lifeagents-master <cmd>`). Jeder schreibt genau
/// eine Zeile JSON auf stdout. Paket 4 (Wizard) liefert sie; bis dahin zeigt die App eine Platzhalter-Seite.
pub enum MasterCmd {
    /// `{"url":"http://127.0.0.1:<port>/…?t=<einmalwert>"}` – frische Einmal-Adresse des Wizards. Der Wert
    /// liegt nur im Arbeitsspeicher des `master`; ein erneuter Aufruf stellt eine neue Adresse aus.
    WizardUrl,
    /// `{"phase":"running|power|done","bot":"<botname oder leer>"}` – Stand des Wizards. Bei `power` fragt
    /// die App selbst nach dem Dauerbetrieb (braucht das System-Passwort) und meldet die Antwort zurück.
    WizardStatus,
    /// `power-done yes|no` – Antwort auf die Dauerbetrieb-Frage; der Wizard geht danach zu „Fertig“.
    PowerDone(bool),
    /// Vor dem Entfernen (Nr. 17): Telegram-Webhook auf den Stand vor der Einrichtung zurück (alte Adresse aus
    /// dem Journal des `master`) oder löschen. Exit 0 = erledigt. Gehört zu Paket 2 (`uninstall`).
    ReleaseWebhook,
}

impl MasterCmd {
    pub fn args(&self) -> Vec<String> {
        let v: Vec<&str> = match self {
            MasterCmd::WizardUrl => vec!["lifeagents", "wizard", "url"],
            MasterCmd::WizardStatus => vec!["lifeagents", "wizard", "status"],
            MasterCmd::PowerDone(true) => vec!["lifeagents", "wizard", "power-done", "yes"],
            MasterCmd::PowerDone(false) => vec!["lifeagents", "wizard", "power-done", "no"],
            MasterCmd::ReleaseWebhook => vec!["lifeagents", "telegram", "release-webhook"],
        };
        v.into_iter().map(String::from).collect()
    }
}

/// Objekt-Namen unseres Verbunds (Container `lifeagents-*`, Volumes/Netze `lifeagents_*`).
pub fn is_our_name(name: &str) -> bool {
    let n = name.trim_start_matches('/');
    n.starts_with(&format!("{PROJECT}-")) || n.starts_with(&format!("{PROJECT}_"))
}
