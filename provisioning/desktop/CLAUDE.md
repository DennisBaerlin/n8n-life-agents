# Start-App — Konventionen (lädt beim Arbeiten in `provisioning/desktop/`)

Tauri-2-App für Freunde ohne eigenen Server (Plan *Docker-Installer für Freunde*, Pakete 6/7): prüft den Rechner, nutzt vorhandenes Docker oder holt Docker Desktop beim Hersteller, startet nach Zustimmung `anchor` + `master` und zeigt den Fragebogen. Sie enthält keine Installer-Logik; die steckt im `master`. Nicht im Server-Release (`.gitattributes` export-ignore).

## Aufbau

| Ordner | Inhalt |
|---|---|
| `core/` | Prüf- und Änderungs-Logik ohne Tauri, Modul je Prüflisten-Nummer (Kopf von `src/lib.rs`) |
| `app/` | Tauri-Hülle: Befehle (`src/commands.rs`), Symbol in Menüleiste/neben der Uhr, Anmeldestart (`src/main.rs`) |
| `ui/` | Bildschirme (HTML/CSS/JS ohne Build-Schritt); Farben nur `var(--token)`, Block aus `scripts/build_ui_tokens.ps1` |
| `preview/` | Attrappe der App-Befehle für die Browser-Vorschau, nie Teil der App |

## Harte Regeln

- **Jeder Systembefehl über `host::Host`**, nie direkt `std::process`/`std::fs`; Tests ersetzen ihn durch `FakeHost`. Programme mit festem Pfad (eine Mac-App sieht den PATH der Kommandozeile nicht).
- **Docker nur über die Positivliste `docker::DockerCall`**, immer mit festem Kontext, ändernde Aufrufe nur mit Projekt `lifeagents`. Test `no_broad_commands` verbietet Aufräumen über alles, Alle-Schalter, ID-Listen für Massen-Löschung und Neustarts.
- **Installieren nur hinter `docker_desktop::guard_install`** (frische Erkennung „fehlt“). Installiert-aber-aus ist nie „fehlt“; Fälle und Tests in `core/src/detect.rs`.
- **Journal vor der Änderung** (`Journal::begin`, danach `done`/`abandon`); jede Änderung hat eine Umkehrung in `journal::undo_of`. Docker Desktop wird nie still entfernt.
- **Keine Sicherheits-Einstellung:** FileVault nur lesen (`fdesetup status`), keine Gatekeeper-, Quarantäne- oder Anmelde-Schalter; Test `never_touches_security_settings` liest alle Quellen.
- **Passwort nur über die System-Mechanik** (`admin.rs`: `osascript … with administrator privileges`, Windows `-Verb RunAs`); Werte in Admin-Zeilen sind geprüft (nur Ziffern, Kurzname) und gequotet.
- **Fehlerbericht nur aus festen Feldern** (`report.rs`), Fehler als feste Codes (`report::ERROR_CODES`), nie Meldungs- oder Log-Text.
- Neue Quelldatei in `core/src` → in `all_sources()` eintragen (Test `every_source_file_is_watched`).

## Prüfen

- Logik: `.\scripts\dev\test_desktop_core.ps1` (Wegwerf-Container `rust:1-slim`, kein Rust auf dem Rechner nötig), `-Lint` mit fmt + clippy.
- Oberfläche: Vorschau `desktop-app` (`.claude/launch.json`), Fälle per `?state=` (Kopf von `preview/mock.js`), `?theme=dark`, `?os=win`.
- App-Bau: nur CI (`.github/workflows/desktop.yml` → `desktop-build.yml`), Artefakte `desktop-dmg`/`desktop-nsis`; Job `vendor-ids` liest Team-ID und Windows-Herausgeber von Docker am Original ab.

## Schnittstelle zu den anderen Paketen

Alle Namen an einer Stelle: `core/src/contract.rs` (Stand: Attrappe nach Plan, bis Paket 1 die Compose-Namen festlegt). Die App erwartet:

- **Paket 1:** Compose-Datei als Ressource `compose.yml` im App-Paket (fehlt sie, zeigt die App „fehlt in dieser Test-Fassung“), Projekt `lifeagents`, Dienste `anchor` + `master`, Label `io.lifeagents.install` an allen Objekten, Port per `--env-file` als `LIFEAGENTS_HTTP_PORT` (App sucht 5880–5899 auf 127.0.0.1), `image:`-Zeilen mit Digest.
- **Paket 4 (im `master`, je eine JSON-Zeile auf stdout):** `lifeagents wizard url` → `{"url":"http://127.0.0.1:<port>/…"}` (frische Einmal-Adresse; andere Adressen öffnet die App nicht), `lifeagents wizard status` → `{"phase":"running|power|done","bot":"<name>"}`, `lifeagents wizard power-done yes|no`. Bei `power` fragt die App selbst nach dem Dauerbetrieb.
- **Paket 2:** `lifeagents telegram release-webhook` (Exit 0 = Webhook zurückgesetzt) vor dem Entfernen.
- **Paket 5/Release:** DMG/EXE hängen mit `.sha256` am Release-Entwurf, stehen aber nicht in `SHA256SUMS`; eigene Prüfkette offen.

## Handliste für den Test auf echter Hardware (Paket 9)

CI baut und signiert ad hoc, startet aber weder Docker noch die App. Auf dem Mac (vorher Paperless-Daten sichern):

1. DMG öffnen, App in Programme ziehen; Start aus der DMG zeigt „Zieh die App zuerst …“.
2. Erster Start: Sperre, *Systemeinstellungen → Datenschutz und Sicherheit → Dennoch öffnen*; erscheint der Knopf, wie lange dauert es, fragt er nach dem Passwort?
3. Docker an, Paperless läuft: „Docker ist schon da“, Programmname stimmt, kein Passwort, keine Installation.
4. Docker Desktop beendet: „Docker ist da, aber gerade aus“; nach Ja startet Docker, nichts wird installiert, Version unverändert (`docker version` vorher/nachher).
5. Rechner ohne Docker: Download, Prüfung Team-ID, ein Passwort-Dialog, Docker läuft danach; Abbruch des Passwort-Dialogs ändert nichts.
6. Fragebogen-Fenster öffnet nur `http://127.0.0.1:<port>` (sobald Paket 4 da ist); bis dahin Platzhalter.
7. Dauerbetrieb Ja: `pmset -g custom` vorher/nachher (nur AC-Bereich geändert), Ergebnis-Seite zeigt nur, was gilt; `fdesetup status` unverändert.
8. Menüleisten-Symbol: Status „Läuft“/„Docker ist aus“ nach Docker beenden (bis 60 s), alle Menüpunkte.
9. Abmelden/Anmelden: LaunchAgent `~/Library/LaunchAgents/io.lifeagents.desktop.autostart.plist` startet die App ohne Fenster, Docker und Verbund kommen hoch. Ad-hoc-signierte App als LaunchAgent ist unbelegt.
10. Stecker ziehen: Mac startet (`autorestart`), wartet bei FileVault auf das Passwort, danach kommt alles hoch.
11. Dauerbetrieb zurückstellen und Deinstallieren (je Häkchen einzeln): `pmset -g custom` wie vorher, Plist weg, Paperless laut Vergleich unverändert.
12. Fehlerbericht: keine Namen, Pfade oder Adressen.
13. Windows (später): UAC-Dialog, eigenes Energieschema in `powercfg /list`, altes bleibt; WSL-Prüfung startet vorhandene Distributionen kurz; `Run`-Eintrag; „Trotzdem ausführen“.
