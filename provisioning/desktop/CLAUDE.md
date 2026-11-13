# Start-App — Konventionen (lädt beim Arbeiten in `provisioning/desktop/`)

Tauri-2-App für Freunde ohne eigenen Server (Plan *Docker-Installer für Freunde*, Pakete 6/7): prüft den Rechner, nutzt vorhandenes Docker oder holt Docker Desktop beim Hersteller, startet nach Zustimmung `anchor` + `master` und zeigt den Fragebogen. Sie enthält keine Installer-Logik; die steckt im `master`. Nicht im Server-Release (`.gitattributes` export-ignore).

## Aufbau

| Ordner | Inhalt |
|---|---|
| `core/` | Prüf- und Änderungs-Logik ohne Tauri, Modul je Prüflisten-Nummer (Kopf von `src/lib.rs`) |
| `app/` | Tauri-Hülle: Befehle (`src/commands.rs`), Symbol in Menüleiste/neben der Uhr, Anmeldestart (`src/main.rs`) |
| `ui/` | Bildschirme (HTML/CSS/JS ohne Build-Schritt); Farben nur `var(--token)`, Texte nur aus dem Katalog (`core.desktop.*` in `packages/core/locales`, de/en/ko); Bilder unter `ui/explain/` (Begrüßung `greeting.<lang>.svg`, erzeugt aus `config/ui.art.greeting.svg`); beide Blöcke aus `scripts/build_ui_tokens.ps1` |
| `preview/` | Attrappe der App-Befehle für die Browser-Vorschau, nie Teil der App |

## Harte Regeln

- **Jeder Systembefehl über `host::Host`**, nie direkt `std::process`/`std::fs`; Tests ersetzen ihn durch `FakeHost`. Programme mit festem Pfad (eine Mac-App sieht den PATH der Kommandozeile nicht).
- **Docker nur über die Positivliste `docker::DockerCall`**, immer mit festem Kontext, ändernde Aufrufe nur mit Projekt `lifeagents`. Test `no_broad_commands` verbietet Aufräumen über alles, Alle-Schalter, ID-Listen für Massen-Löschung und Neustarts.
- **Installieren nur hinter `docker_desktop::guard_install`** (frische Erkennung „fehlt“). Installiert-aber-aus ist nie „fehlt“; Fälle und Tests in `core/src/detect.rs`.
- **Journal vor der Änderung** (`Journal::begin`, danach `done`/`abandon`); jede Änderung hat eine Umkehrung in `journal::undo_of`. Docker Desktop wird nie still entfernt. Ausnahme Wiederherstellen (`restore.rs`): ersetzt Daten im Verbund, nicht am Rechner; die Umkehrung ist die Vorab-Sicherung des `master`, kein Journal-Schritt.
- **Notfallblatt-Text nur in `restore::Sheet`** (zeroize, kein `Debug`/`Serialize`), hinein nur über stdin von `DockerCall::MasterIn`; Datei-Dialog nur aus Rust (`tauri-plugin-dialog`), das Fenster hat kein `dialog:`/`fs:`-Recht (`acl_tests`).
- **Keine Sicherheits-Einstellung:** FileVault nur lesen (`fdesetup status`), keine Gatekeeper-, Quarantäne- oder Anmelde-Schalter; Test `never_touches_security_settings` liest alle Quellen.
- **Passwort nur über die System-Mechanik** (`admin.rs`: `osascript … with administrator privileges`, Windows `-Verb RunAs`); Werte in Admin-Zeilen sind geprüft (nur Ziffern, Kurzname) und gequotet.
- **Fehlerbericht nur aus festen Feldern** (`report.rs`), Fehler als feste Codes (`report::ERROR_CODES`), nie Meldungs- oder Log-Text.
- Neue Quelldatei in `core/src` → in `all_sources()` eintragen (Test `every_source_file_is_watched`).

## Prüfen

- Logik: `.\scripts\dev\test_desktop_core.ps1` (Wegwerf-Container `rust:1-slim`, kein Rust auf dem Rechner nötig), `-Lint` mit fmt + clippy.
- Oberfläche: Vorschau `desktop-app` (`.claude/launch.json`), Fälle per `?state=` (Kopf von `preview/mock.js`), `?theme=dark`, `?os=win`, `?lang=en|ko`.
- App-Bau: nur CI (`.github/workflows/desktop.yml` → `desktop-build.yml`), Artefakte `desktop-dmg`/`desktop-nsis`; danach `--self-test` (alle lesenden Prüfungen gegen das echte macOS bzw. Windows des Runners) und ein kurzer Start der fertigen App; `desktop-vendor-ids.yml` liest Team-ID und Windows-Herausgeber von Docker am Original ab (bei Änderung der Konstanten, wöchentlich, von Hand).

## Schnittstelle zu den anderen Paketen

Alle Namen an einer Stelle: `core/src/contract.rs`. Die App erwartet:

- **Paket 1:** Projekt `lifeagents`, Label `io.lifeagents.install=<projekt>` an allen Objekten. Vor dem ersten Start: `compose config --quiet`, dann die zustandsführenden Volumes (`contract::STATE_VOLUMES`, Quelle `provisioning/lib/runtime.sh`) mit Label anlegen (gleichnamiges ohne Label = Abbruch), dann die Fähigkeits-Prüfung (Plan Nr. 9: Verzeichnis-Unterpfad aus einem Volume, Docker-Zugang im Container, im eigenen Probe-Volume `lifeagents_probe` mit dem busybox-Image des `anchor`), dann `up -d anchor postgres master edge`. Env-Datei der App: `LA_EDGE_PORT` und `LA_WIZARD_PORT` (zwei freie Ports in 5880–5899 auf 127.0.0.1; der Wizard liegt nie auf dem Port, den der Tunnel nach außen bringt), `LA_PG_SUPERPW` (einmal erzeugt, bleibt), `LA_TS_HOSTNAME` (Tailscale-Name aus zwei Wörtern, einmal gezogen aus `provisioning/lib/ts_names.json`, `core/src/ts_name.rs`; gibt es `lifeagents_ts_state` schon oder ist der Wert ungültig, `bot`, nie neu gezogen; nicht geheim, steht in öffentlichen Zertifikats-Protokollen). Sonst nichts: Was dort steht, landet in der Container-Konfiguration und ist in `docker inspect` dauerhaft sichtbar. Der Wizard bildet seine Adresse selbst aus `LA_WIZARD_PORT`. `LA_MASTER_IMAGE` steht nicht in der Env-Datei: das master-Image nennt der Release-Pin in compose.yml (`x-images.master`).
- **Hinweise für den Fragebogen (Paket 4):** flüchtige Datei `/run/lifeagents-wizard/hints.env` im `master` (0600, `KEY=wert`), per `docker exec --interactive` über stdin, neu vor jedem Öffnen des Fragebogens; je Zeile nur, wenn gefunden, alle Werte privat (nie in Log, Fehlerbericht oder Selbsttest-Ausgabe): `LA_HOST_IP` (Heimnetz-Adresse über die Standard-Route, für Paperless), `LA_MYFRITZ_ZONE` (`<kennung>.myfritz.net` aus dem Zertifikat von `https://fritz.box`, ungeprüft gelesen, 2,5 s), `LA_HOST_NAME_FRITZ` (Gerätename, den die FritzBox selbst meldet: PTR der eigenen Adresse beim Standard-Gateway, 2 s, nur Antworten `<name>.fritz.box`, `core/src/dns.rs`), `LA_HOST_NAME_CANDIDATES` (bis zu 4 Gerätenamen, Komma; vorn der geprüfte Name, danach die Ableitungen aus dem Rechnernamen nach FritzBox-Regeln), `LA_USER_FULLNAME`, `LA_USER_LANG`, `LA_BACKUP_CANDIDATES` (Sicherungs-Ordner `<art>|<pfad>;…`) (`core/src/suggest.rs`, `core_start::hints_text`).
- **Paket 4 (im `master`, `node /opt/lifeagents/provisioning/wizard/ctl.js …`, je eine JSON-Zeile):** `url` → `{"url":"http://127.0.0.1:<port>/…"}` (Einmal-Wert; andere Adressen öffnet die App nicht), `status` → `{"phase":"questions|installing|failed|pairing|connected|handoff","lang":"de|en|ko"}` (die App merkt sich `lang` in `core/src/lang.rs` und spricht sie danach auf ihren Seiten und im Menü; davor gilt die Systemsprache), `power-done` nach der Dauerbetrieb-Frage. Nach der Einrichtung: `lifeagents backup key --file -` (Notfallblatt, `MasterCmd::BackupKit`), `node …/server.js --backup-dir` (Änderungs-Modus des Ordners, `status` → `backup_dir|backup_done`, endet nach Fertig oder 15 Min Leerlauf) und `lifeagents backup list|restore|restore-status … --json` (Wiederherstellen, `MasterCmd::BackupList/RestorePlan/Restore/RestoreStatus`, je eine JSON-Zeile mit festen Codes). Der Fragebogen läuft im App-Fenster ohne App-Rechte (Test `acl_tests` in `app/src/main.rs`); bei `handoff` lädt die App ihre Seite mit `#power` neu. Die Schritt-Leiste zeichnet jede Seite selbst aus `config/ui.steps.*` (die App: Vorbereiten, Docker, Dauerbetrieb, Fertig; der Fragebogen: Fragen, Installation, Verbinden).
- **Paket 2:** `lifeagents telegram release-webhook` (Exit 0 = Webhook zurückgesetzt) vor dem Entfernen.
- **Paket 5/Release:** Die App trägt `provisioning/compose/compose.yml` ihres Tags eingebaut (`tauri.conf.json` `bundle.resources`, gelesen über `resource_dir`) und lädt sie nie nach; `desktop-build.yml` prüft Byte-Gleichheit mit der Datei des Commits. Sie nennt den master per Digest. Ein Branch-Bau ohne Release-Pin scheitert an `compose config` (Fehler `invalid_compose`, nichts geändert); für Test-Bauten `LA_MASTER_IMAGE` in der Umgebung der App setzen (Compose erbt sie), nie in `app.env`. Bestehende Installationen aktualisiert der `master` (`lifeagents update`, Image-Wechsel), nie die App: eine ältere App darf darum nie `compose up` auf einen schon laufenden master anwenden, nur beim ersten Start. DMG/EXE stehen in `SHA256SUMS` mit Herkunftsnachweis (`release.yml` desktop-assets, `sign_release.ps1`).

## Handliste für den Test auf echter Hardware (Paket 9)

CI baut, signiert ad hoc, startet die App kurz und prüft lesend gegen das echte System (`--self-test`), startet aber kein Docker und ändert nichts. Auf dem Mac (vorher Paperless-Daten sichern):

1. DMG öffnen, App in Programme ziehen; Start aus der DMG zeigt „Zieh die App zuerst …“.
2. Erster Start: Sperre, *Systemeinstellungen → Datenschutz und Sicherheit → Dennoch öffnen*; erscheint der Knopf, wie lange dauert es, fragt er nach dem Passwort?
3. Docker an, Paperless läuft: „Docker ist schon da“, Programmname stimmt, kein Passwort, keine Installation.
4. Docker Desktop beendet: „Docker ist da, aber gerade aus“; nach Ja startet Docker, nichts wird installiert, Version unverändert (`docker version` vorher/nachher).
4a. Docker Desktop startet, das Lizenzfenster abgelehnt (Docker beendet sich): Meldet die App nach rund 15 s „hat sich wieder geschlossen“ (`docker-closed`, Erkennung `pgrep -x "Docker Desktop"`)? Stimmt der Programmname in `desktop_running`? Journal danach ohne „Docker gestartet“-Rest (unbelegt auf echtem Mac/Windows).
5. Rechner ohne Docker: Download, Prüfung Team-ID, ein Passwort-Dialog, Docker läuft danach; Abbruch des Passwort-Dialogs ändert nichts.
6. Fragebogen lädt im App-Fenster nur `http://127.0.0.1:<port>`; nach „Verbinden“ kommt die App von selbst mit „Dauerbetrieb“ zurück. Nach dem Start aus Programme ist die DMG ausgeworfen; „Download wegräumen“ auf der Fertig-Seite legt die Datei in den Papierkorb (Finder: „Zurücklegen“ geht).
7. Dauerbetrieb Ja: `pmset -g custom` vorher/nachher (nur AC-Bereich geändert), Ergebnis-Seite zeigt nur, was gilt; `fdesetup status` unverändert.
8. Menüleisten-Symbol: Status „Assistent läuft“/„Assistent ist aus: Docker läuft nicht“ nach Docker beenden (bis 60 s), alle Menüpunkte.
9. Abmelden/Anmelden: LaunchAgent `~/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist` startet die App ohne Fenster, Docker und Verbund kommen hoch. Ad-hoc-signierte App als LaunchAgent ist unbelegt.
10. Stecker ziehen: Mac startet (`autorestart`), wartet bei FileVault auf das Passwort, danach kommt alles hoch.
11. Dauerbetrieb zurückstellen und Deinstallieren (je Häkchen einzeln): `pmset -g custom` wie vorher, Plist weg, Paperless laut Vergleich unverändert.
12. Fehlerbericht: keine Namen, Pfade oder Adressen.
12c. Wiederherstellen: Sicherung eines anderen Rechners im Ordner → Karte auf der Fertig-Seite; Notfallblatt als Datei (auch aus iCloud, noch nicht geladen) und getippt mit Tippfehler; „Andere Datei wählen …“ aus Downloads (fragt macOS nach dem Zugriff?) und unter Windows von einem Netzlaufwerk; Fenster zu und Docker beenden während des Laufs (Ergebnis beim nächsten Öffnen); mit eigenen Daten liegt danach eine Vorab-Sicherung im Ordner. Speichert WebView2 die Tipp-Felder trotz `autocomplete="off"` (unbelegt)?
12a. FritzBox: `LA_MYFRITZ_ZONE` stimmt mit der MyFRITZ-Adresse überein; `LA_HOST_NAME_FRITZ` ist der Name des Macs in der FritzBox-Geräteliste. Gerät in der Box umbenennen, App-Fragebogen neu öffnen: Erscheint der neue Name sofort (unbelegt)? Ohne PTR-Antwort ist einer der `LA_HOST_NAME_CANDIDATES` der Name in der Liste (Umlaut-Umwandlung ist unbelegt).
12b. Test-Bau ohne Release-Pin (Branch-Artefakt): App mit dem master-Image aus der Umgebung starten, z. B. `LA_MASTER_IMAGE=<register>/master@sha256:… /Applications/lifeagents.app/Contents/MacOS/lifeagents`; ohne diese Variable meldet sie `invalid_compose` und ändert nichts.
13. Windows (später): UAC-Dialog, eigenes Energieschema in `powercfg /list`, altes bleibt; WSL-Prüfung startet vorhandene Distributionen kurz; `Run`-Eintrag; „Trotzdem ausführen“.
