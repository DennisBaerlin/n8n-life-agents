//! Die schmale Schnittstelle zwischen Start-App und dem Rest des Systems, an einer Stelle.
//!
//! Namen von Paket 1 (Compose-Betriebsart, Branch-Stand 2026-11-06; Quelle der Volume-Liste ist
//! `provisioning/lib/runtime.sh` `LA_STATE_VOLUMES`), Befehle von Paket 4 (Wizard, `ctl.js`). Ändert sich dort
//! etwas, ändert sich nur diese Datei. Die Compose-Datei kommt später als signiertes Release-Asset (Paket 5);
//! bis dahin liegt keine im App-Paket, und die App zeigt „fehlt in dieser Test-Fassung“.

/// Compose-Projektname (`LA_PROJECT` von Paket 1, Standard). Jedes Objekt trägt ihn im Namen.
pub const PROJECT: &str = "lifeagents";
/// Label an allen Diensten, Netzen und Volumes; Wert = Projektname. Ein Treffer mit unserem Namen, aber ohne
/// dieses Label, heißt Abbruch (Plan, Einwand 29).
pub const LABEL: &str = "io.lifeagents.install";
/// Dienste des ersten Starts nach der Zustimmung. `master` wartet per `depends_on` auf eine gesunde Datenbank,
/// `edge` ist der einzige Dienst mit veröffentlichtem Port. n8n und gateway startet der `master` selbst.
pub const FIRST_SERVICES: [&str; 4] = ["anchor", "postgres", "master", "edge"];
/// Zustandsführende Volumes (`external` in compose.yml): legt die App vor dem ersten Start mit Label an.
/// Eine Zeile, weil `contract_lint` 33 diese Liste mit `LA_STATE_VOLUMES` in runtime.sh vergleicht.
#[rustfmt::skip]
pub const STATE_VOLUMES: [&str; 9] = ["pgdata", "n8n_home", "etc_n8n", "etc_la", "var_la", "rt_tree", "gw_state", "ts_state", "wizard_state"];
/// Container-Name des `master` (für `docker exec`), Muster `<projekt>-<dienst>`.
pub const MASTER_CONTAINER: &str = "lifeagents-master";
/// Name der Compose-Datei im Ressourcen-Ordner der App (bis Paket 5 eine andere Quelle festlegt).
pub const COMPOSE_FILE: &str = "compose.yml";
/// Pflicht-Variablen jedes Compose-Aufrufs (Datei `--env-file` der App, nie im argv).
pub const PORT_VAR: &str = "LA_EDGE_PORT";
pub const PG_PASSWORD_VAR: &str = "LA_PG_SUPERPW";
/// Zweiter freier Port auf 127.0.0.1, nur für den Wizard (veröffentlicht vom Dienst `edge`).
pub const WIZARD_PORT_VAR: &str = "LA_WIZARD_PORT";
/// Suchbereich für den freien Port (wie im Testpaket).
pub const PORT_RANGE: (u16, u16) = (5880, 5899);
/// Volume der Fähigkeits-Prüfung (Plan Nr. 9): mit unserem Label, nach der Prüfung immer wieder entfernt.
pub const PROBE_VOLUME: &str = "lifeagents_probe";

/// Steuerung des Wizards im `master` (Paket 4): `docker exec lifeagents-master node <CTL> <befehl>`, je eine
/// JSON-Zeile auf stdout. Die `lifeagents`-CLI gibt es im `master` erst nach der Installation.
pub const WIZARD_CTL: &str = "/opt/lifeagents/provisioning/wizard/ctl.js";

pub enum MasterCmd {
    /// `{"url":"http://127.0.0.1:<port>/start?t=<einmalwert>"}`: Einmal-Wert, 10 Minuten gültig, ein neuer Aufruf
    /// macht den alten ungültig. Er liegt nur im Arbeitsspeicher des `master`.
    WizardUrl,
    /// `{"phase":"questions|installing|failed|pairing|connected|handoff","step":"…"}`. Bei `handoff` übernimmt die
    /// App (Dauerbetrieb, Fertig).
    WizardStatus,
    /// Nach der letzten App-Seite: Der Wizard löscht seinen Fortschritt und endet.
    PowerDone,
    /// Vor dem Entfernen (Nr. 17): Telegram-Webhook zurücksetzen. Exit 0 = erledigt. Gehört zu Paket 2.
    ReleaseWebhook,
}

impl MasterCmd {
    pub fn args(&self) -> Vec<String> {
        let v: Vec<&str> = match self {
            MasterCmd::WizardUrl => vec!["node", WIZARD_CTL, "url"],
            MasterCmd::WizardStatus => vec!["node", WIZARD_CTL, "status"],
            MasterCmd::PowerDone => vec!["node", WIZARD_CTL, "power-done"],
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

/// `lifeagents_pgdata` usw.
pub fn state_volume_names() -> Vec<String> {
    STATE_VOLUMES.iter().map(|v| format!("{PROJECT}_{v}")).collect()
}
