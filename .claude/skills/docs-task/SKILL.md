---
name: docs-task
description: Brief für eine Unter-Session, die die Showcase-Site (docs/site, deutsch) oder andere Nutzer-Doku ändert — Hugo-Vorschau, doc_lint, Sprache, keine Live-Werte, build_site.ps1 und den gebauten Output mitcommitten. Args = die Doku-Aufgabe (oder Pfad einer Plan-Datei).
---

# Doku-Aufgabe (`/docs-task`)

Du bist eine von der Leitung gestartete Unter-Session. Dieses Dokument ist dein vollständiger Brief. Die Aufgabe steht in den Args. Root-`CLAUDE.md` gilt. **Das Repo ist öffentlich**: auch Site, Commit-Texte und CI-Logs sind es.

## 1. Zuständigkeit klären

| Text | Ort | Sprache |
|---|---|---|
| Nutzer-/Betreiber-Doku der Showcase-Site | `docs/site/content/docs/<slug>.md`, Startseite `docs/site/content/_index.md` | **Deutsch** |
| Doku für Entwickler und Mitwirkende (`README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`) | Repo-Wurzel | Englisch |
| Entwickler-Doku im Repo (`CLAUDE.md`-Familie, `docs/reference/`, Skills, Stickies, Kommentare) | je Ordner | Deutsch |
| Release-Notes | Tag-Text | Englisch (macht die Leitung) |

- Nutzer-sichtbare Änderung ⟹ Site (deutsch) **und** `README.md` (englisch), wo das Thema dort vorkommt. Sprachpolitik: Root-`CLAUDE.md` *Sprachpolitik*; Steuer-/Rechtsbegriffe bleiben deutsch.
- `CLAUDE.md`-Familie nur **Deltas**. Ein Fakt, eine Adresse: ableitbare Repo-Fakten (Listen, Counts, ID-Ranges, Befehlslisten) nie in Doku spiegeln, sondern verlinken. `doc_lint` erzwingt das.
- Ein Verhalten der **Mini-App** zu beschreiben ist Doku (frei). Das Ändern der App selbst ist `/mini-app-task` und braucht den Owner.
- Ändert sich das **Aussehen** der Site (Layout, Farben, Bausteine), gilt zusätzlich `/ui-task`: Vorschau und Okay des Owners, Farben nur aus `config/ui.tokens.json`.

## 2. Schreiben

- Zielgruppe ist der **Nicht-Programmierer**: einfache, alltagsnahe Sprache, was passiert und warum; Fachbegriff höchstens in Klammern dahinter. Du-Ansprache wie die vorhandenen Seiten; erst einen ähnlichen Abschnitt lesen (Ton, Aufbau, Länge).
- Beschreibe, was der Nutzer **sieht und tut** (Chat, Knöpfe, Karte), nicht die Implementierung. Technik gehört auf `so-funktionierts.md`.
- **Keine Live-Werte.** Namen, Beträge, Bestände, IBANs, Chat-IDs, Heim-IPs, Hostnamen des Owners: nur erfundene Beispiele aus den vorhandenen Personas der Doku (z. B. „Erlenkasse Giro“, Erika). Einen Befund als Beispiel nachbauen = Zahlen neu erfinden, die Eigenschaft behalten; nie aus einem echten Dokument oder Chat abschreiben (`tests/fixtures/README.md`). IP-Beispiele nur aus der Allowlist von `privacy_lint` (Skript-Kopf), Domain-Platzhalter `deine-domain.myfritz.net`.
- Neue Seite: `docs/site/content/docs/<slug>.md` mit Front-Matter **nur** `title: "…"` anlegen **und** in `docs/site/data/docsnav.yaml` eintragen (Gruppe + Reihenfolge; die Datei ist die eine Quelle der Sidebar). Slugs ASCII (`ae`, `ue`).
- Interne Links relativ mit `.html` (`[Chatten & Bestätigen](chatten-bestaetigen.html)`; die Site läuft per Doppelklick und unter dem Pages-Unterpfad: `uglyURLs`, `relativeURLs`). Anker wie `{#unchanged}` an Überschriften sind stabil, wenn Code (z. B. Fehler-Hilfe im Update-Bot) darauf zeigt: **nie umbenennen**, ohne den Verweis im Code mitzuziehen (`docs/reference/provisioning.md` *Fehler-Hilfe*).
- Bilder unter `docs/site/static/img/`; die Mini-App-Beispielbilder nicht von Hand, sondern per `render_app_screenshots.ps1` (siehe `/mini-app-task`). Bildtext nennt „erfundene Werte“.
- Befehls-Tabelle `docs/site/content/docs/befehle.md` spiegelt die Manifest-Befehle; `doc_lint` Check 10 vergleicht beide. Neuer/entfernter Befehl ⟹ Tabelle mitziehen.
- Fertige Entscheidungen des Owners im Chat nicht erneut in Frage stellen; wo die Quelle (Code, Manifest, Skript) etwas anderes sagt als die bestehende Doku, ist das ein **Bug der Doku**: sofort korrigieren und im Bericht nennen.
- Fakten **gegen den Code lesen**, nicht aus dem Gedächtnis beschreiben (Skript, Manifest, Katalog `locales/de.json`).

## 3. Vorschau und Gates

1. **Hugo-Vorschau:** `preview_start` mit `name: "docs-site"` (`.claude/launch.json` → `scripts/build_site.ps1 -Serve`, Port 1313; Seiten unter `http://localhost:1313/docs/<slug>.html`, danach per `navigate` auf die Seite). Die Binary löst das Skript wie der Build auf (`$env:HUGO_EXE`, `.local\bin`, Haupt-Checkout, PATH), die Vorschau läuft deshalb auch im Worktree; sie schreibt nie `public/`. Gepinnt ist Hugo v0.168.0 (`build_site.ps1`, `CONTRIBUTING.md` *Hugo*). Am Ende `preview_stop`.
2. Seite im Pane lesen (`get_page_text`, Screenshot), Navigation, Links und Bilder prüfen; mobile Breite mit `resize_window` (`mobile`), danach zurück auf `desktop`. Konsole auf Fehler prüfen. **Jede Aussage über die App oder den Bot noch einmal gegen die Quelle lesen** (Seite `index.html`, Handler, Katalog): Im Trockenlauf stellte sich der erste Entwurf („Tippe auf Neu laden“) als falsch heraus — der Text existiert nur als Aria-Label des Wiederholen-Knopfs (↻) im Netzfehler-Bildschirm.
3. **`doc_lint`:** `.\scripts\doc_lint.ps1` (Pfade/Datei-Token in Backticks müssen existieren, Sektions-Zeiger (Dateiname in Backticks plus kursiver Abschnittsname) müssen auf eine echte Überschrift zeigen — Beispiel-Zeiger in eigenem Text nur mit existierender Datei und Überschrift schreiben, keine harten Counts, Befehls-Parität). Rot ⟹ fixen. Läuft auch beim Commit.
4. **Privacy:** `.\scripts\privacy_lint.ps1` (getrackter Baum inkl. gebautem `docs/site/public`). Neue echte Werte, die du irgendwo gesehen hast und die nicht ins Repo dürfen, gehören in die lokale `.local/privacy_denylist.txt` (nicht committen) — nie in den Chat oder Commit-Text.
5. **Build:** `.\scripts\build_site.ps1` baut `docs/site/public/` neu (`cleanDestinationDir`). Der Output ist **getrackt** und wird veröffentlicht: **Quelle und gebauten Output in denselben Commit.** Nie in `public/` von Hand ändern. `.\scripts\build_site.ps1 -Verify` ist das Pre-Push-Gate (frischer Build == `public/`, byte-genau).
6. Nur das PowerShell-Tool für `.ps1`, ohne `2>&1`.

## 4. Commit

- Prüfe mit `git status`/`git diff --stat`, dass **nur** Doku-Dateien (Quelle, `docsnav.yaml`, Bilder, `docs/site/public/**`, ggf. `README.md`) im Diff sind. Alles andere, was Skripte nebenbei verändert haben (z. B. neu erzeugte Kataloge), zurücknehmen oder der Leitung melden, nicht still mitcommitten.
- Conventional Commit `docs(site): …` bzw. `docs(<bereich>): …`, deutsch, ohne Live-Werte; mehrzeilig per Datei → `git commit -F`. Commit-Texte sind öffentlich (`privacy_lint -MessageFile` läuft).
- Rot ⟹ fixen, nie `--no-verify`. Kein Push auf `main`, kein Tag — das macht allein die Leitung. Eigene Test-Container sind für reine Doku nicht nötig; was du doch gestartet hast, baust du ab.

**Ergebnis an die Leitung: Branch, Stand, offene Fragen.** Nenne im Bericht: Branch und Commit-Hashes, welche Seiten geändert/neu sind, Ergebnis von `doc_lint`, `privacy_lint` und `build_site.ps1 -Verify`, ob `README.md` mitgezogen wurde, gefundene Falschaussagen in der bestehenden Doku, und was nicht geprüft wurde.
