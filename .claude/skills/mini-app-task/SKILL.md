---
name: mini-app-task
description: Brief für eine Unter-Session, die die Telegram-Mini-App (Übersicht) ändert — ergänzt den Ablauf /ui-task um das Mini-App-Eigene - App-Fläche, App-Fenster, Vorschau-Server, Datenmodell der Vorschau, danach Doku-Bilder und Site neu bauen. Args = die Aufgabe (oder Pfad einer Plan-Datei).
---

# Mini-App-Aufgabe (`/mini-app-task`)

Du bist eine von der Leitung gestartete Unter-Session. Dieses Dokument ist dein vollständiger Brief. Die Aufgabe steht in den Args. Root-`CLAUDE.md` gilt, Skills und Doku sind deutsch, das Repo ist öffentlich (nur erfundene Werte).

Leitsatz (Owner, 2026-11-01): **Die Mini-App ändert sich nur mit Zustimmung des Owners.** Die Darstellung ist immer ein eigener Plan, nie Nebenwirkung eines Feature-Plans. Der Owner ist mit dem jetzigen Stand sehr zufrieden: so wenig ändern wie möglich, kein Umbau, das Nutzungsgefühl bleibt.

**Der Ablauf ist `/ui-task`** (Freigaben, Vorschau-Seite, Prüf-Agent, Markierungen, Okay vor dem Merge), die Regeln stehen in `docs/reference/ui.md`. Hier steht nur das Mini-App-Eigene.

## 1. Lage klären (nichts ändern)

- Lies die App-Fläche, die du anfassen würdest (nur lesen ist frei):
  - `packages/<pkg>/build/app/**` (die Seite), `core.main_app_serve` (Auslieferung)
  - `migrations/*fn_app_*` (Bildschirm-Handler, Pillen, Banner, Lint)
  - Katalog-Keys `<pkg>.app.*` in `packages/<pkg>/locales/de.json`
  - `manifest.json` `app_screens`
  - Vertrag: `docs/package-contract.md` §3.12; Mechanik: `docs/reference/core.md` (Mini-App-Abschnitt); Owner-Doku: `docs/site/content/docs/uebersicht-app.md`.
- Auch **indirekte** Wirkungen benennen: Eine Änderung an einer Rechen-`fn_*` außerhalb von `fn_app_*` (z. B. `fn_account_low_state`) kann die Anzeige verändern, ohne dass ein Pfad-Muster es erkennt. Das gehört in die Zusammenfassung.
- Frühere Beschlüsse nicht stillschweigend kippen: Konzept `.claude/plans/mini-app-ux-gesamtkonzept-ergebnis.md`.

## 2. Vorher/Nachher an den Owner

Tabelle und Regeln: `/ui-task` Abschnitt 2, **je betroffenem Bildschirm** (Vermögen, Konten, Ziele, Kredite, Depot …), samt indirekter Wirkung aus Abschnitt 1.

Feature-Pläne führen App-Ideen nur als „offen, eigener Plan“. Taucht die App-Änderung als Nebeneffekt eines anderen Pakets auf, gehört sie nicht in dessen Commit.

## 3. App-Fenster (Hook `.claude/hooks/enforce_app_window.ps1`)

- Der Hook sperrt hart (`deny`) jeden Edit/Write auf die App-Fläche, jeden Shell-Befehl mit App-Pfad **und** Schreib-Operator und jeden `git commit`, dessen Stand die App-Fläche berührt — ohne offenes Fenster.
- Das Fenster öffnet **nur der Owner** im Terminal: `.\scripts\grant_app_window.ps1` (Standard 60 Min). Du führst das Skript nie aus und umgehst den Hook nie (auch nicht über Variablen oder ein Skript; schon das Nennen des Fenster-Skripts mit einem Ausführungs-Flag im Befehl wird gesperrt — Notizen dazu mit Read/Edit schreiben).
- Nach der Zustimmung bittest du den Owner (über die Leitung) um das Fenster und nennst das exakte Kommando. Ist es zu, wartest du, statt auszuweichen.
- Das Datenmodell der Vorschau (`scripts/dev/lib/app_preview_data.json`) und die Skripte unter `scripts/dev/` liegen **außerhalb** der App-Fläche; Vorschau und Doku-Bilder sind ohne Fenster möglich.

## 4. Regeln

`docs/reference/ui.md`, dazu `docs/package-contract.md` §3.12 (Bedeutung je Element). Mini-App-eigen: Grün ist allein „Alles in Ordnung“ oben auf der Startseite. Mehr Bildsprache → `docs/site/content/docs/uebersicht-app.md` *Was du siehst*. Beschwerden aus Live-Prüfungen sind **Beispiele** für ein Muster, keine Anforderungsliste.

## 5. Umsetzung (erst nach Ja + offenem Fenster)

- Red/Green nach der Blast-Radius-Tabelle: Änderung an `fn_app_*`/Rechen-`fn_*` ⟹ DB-Test `tests/db/<pkg>/test_fn_*.sql` zuerst; Inner Loop `db_apply` → `db_test.ps1 -Filter '*<subject>*'` (hart, gratis). Nur Seite/Text ⟹ kein Test-Theater.
- Texte nur im Katalog (`<pkg>.app.*`, deutsch; Modell-Instruktionen bleiben englisch), `locale_lint`/`ui_literal_lint` beachten. Neue Key-Namen folgen den vorhandenen.
- Build: `scripts/build/build.ps1`, bei Workflow-Änderung Stickies gegen den neuen Graphen gegenlesen (Pflicht).
- Eigene Test-Container je Session (Namen/Ports aus dem Brief der Leitung setzen, vorher `docker ps`), nie geteilte Defaults.

## 6. Vorschau-Server

Die Vorschau serviert die **echte** Seite `packages/core/build/app/index.html` mit dem echten Renderer und erfundenen Daten — kein Substrat, keine DB. Prüfliste und Vorschau-Seite: `/ui-task` Abschnitte 4 und 6.

- `preview_start` mit `name: "mini-app"` (`.claude/launch.json`, Port 8765; `scripts/dev/serve_app_preview.ps1`). Änderungen an `index.html`, Texten oder am Datenmodell: Seite neu laden. Änderungen an `scripts/dev/lib/app_preview.ps1` oder am Renderer (`build_helpers.ps1`): Server neu starten.
- Dunkel: `?scheme=dark` an der Adresse, unabhängig von der Geräte-Einstellung.
- Zusätzlicher Grenzfall hier: „unvollständig“-Banner.

## 7. Datenmodell der Vorschau bei neuem Zustand erweitern

- `scripts/dev/lib/app_preview_data.json` hat die **Form exakt wie die echten Handler-Antworten** (`core.fn_app_screen` → `finance.fn_app_screen_<screen>`), Werte **frei erfunden**. Er soll **alle** Zustände abdecken, die die Handler erzeugen können.
- Erzeugt deine Änderung einen neuen Zustand (neue Pille, neuer Abschnitt, neuer Hinweis), erweitere das Modell um genau diesen Fall — sonst sieht niemand ihn, auch nicht beim nächsten Umbau. Neue Katalog-Keys müssen im Katalog existieren (die Vorschau bricht bei unbekannten Keys ab; das ist gewollt, es fängt Tippfehler).
- Nie echte Daten, auch nicht „leicht verändert“ (`tests/fixtures/README.md`). Echte Live-Formen nur lesend vom Live-System (Erlaubnis: Memory `live-system-read-permission`), Zahlen und Namen neu erfinden, die Eigenschaft (Zustand, Rundungsfall) behalten. `privacy_lint` prüft gegen die lokale Denylist.

## 8. Danach: Doku-Bilder und Site

- Ändert sich der Bildschirm **Vermögen** sichtbar: `.\scripts\dev\render_app_screenshots.ps1` (Headless-Chrome/Edge, hell + dunkel, Handybreite, Sollzustand `-CalmHome`), danach `.\scripts\build_site.ps1`. Beide Bild-Dateien (`docs/site/static/img/app-uebersicht-{hell,dunkel}.png`) und der Output unter `docs/site/public/` gehören in denselben Commit.
- Beschreibung ändert sich: `docs/site/content/docs/uebersicht-app.md` (deutsch, erfundene Beispielwerte) → Regeln in `/docs-task`. Lies das Ergebnis im Bild gegen den Text gegen (Überschriften, Reihenfolge).
- Andere Bildschirme als Vermögen haben heute keine Doku-Bilder; füge keine ohne Auftrag hinzu.

## 9. Abschluss

- Gates: `db_test` (bei DB-Änderung), `build.ps1`, `locale_lint`, `doc_lint`, `privacy_lint` laufen beim Commit/Push (rot ⟹ fixen, nie `--no-verify`). LLM-Suiten nur im Owner-Fenster: bei geänderter Tool-Description oder Prompt das exakte Kommando empfehlen, nicht selbst starten (Hook sperrt jeden Befehl, der einen Suite-Dateinamen nennt; Suite-Dateien nur mit Read/Grep öffnen).
- Conventional Commit, deutsch ohne Live-Werte; mehrzeilige Messages per Datei → `git commit -F`. Nur `.ps1` über das PowerShell-Tool. Kein Push auf `main`, kein Tag — das macht allein die Leitung.
- Eigene Container abbauen (`scripts/dev/stop_test_containers.ps1` mit deinen Namen); den Rest räumt `/ui-task` Abschnitt 8 auf.
- Fehler, die dir unterwegs auffallen (auch eigene früher), an der Wurzel beheben oder der Leitung melden; Unabhängiges nur als Folgepunkt nennen.

**Ergebnis an die Leitung: Branch, Stand, offene Fragen.** Nenne im Bericht zusätzlich zu `/ui-task` Abschnitt 8: je Bildschirm Vorher/Nachher (Kurzfassung), ob das App-Fenster nötig war, welche Zustände du ins Datenmodell aufgenommen hast.
