---
name: privacy-deep-review
description: Geplante Tiefenprüfung des öffentlichen Repos auf persönliche Hinweise – wöchentlich das Neue, monatlich der ganze Stand samt Site, Commit-, Tag- und Release-Texten. Ändert nichts, Bericht nur als privates Artefakt, nie ein Wert. Args woche oder monat; auf Zuruf „Tiefenprüfung“.
---

# Tiefenprüfung des öffentlichen Repos (`/privacy-deep-review`)

Die Prüfung vor jedem Push (`/privacy-review`) sieht nur, was gerade neu ist. Diese Prüfung sieht, was trotzdem draußen liegt: was vor den Sperren hineinkam, was erst jetzt auffällt, weil die Liste gewachsen ist, und was Pushes nicht berührt, etwa Release-Texte. Sie ist nicht deterministisch und übersieht einen Teil.

Grundsatz „Agenten schlagen vor, der Nutzer bestätigt“: Du liest und berichtest, du änderst nichts. Der Owner verbessert diesen Skill, wenn der Bericht nicht passt.

## Harte Grenzen

- **Nur lesend:** kein Commit, kein Push, kein Bereinigen, keine Änderung auf GitHub oder am Live-System. Ein Fix ist ein Vorschlag im Bericht.
- **Geprüft wird das Öffentliche:** Maßstab ist `origin`, nicht dein lokaler Stand. Ein Mitlesen im Haupt-Checkout ist erlaubt, ein Wechsel des Branches dort nicht. `git fetch origin` ist erlaubt.
- **Nie ein Wert im Text:** Bericht, Nachrichten und Dateinamen nennen nur Datei, Zeile und Art wie „Wohnform“ oder „Betrag“. Das gilt auch für die Antworten der Unteragenten.
- **Bericht nur privat:** als privates Artefakt (`Artifact`-Tool, Standard = privat, nicht teilen), nie im Repo. Das Repo ist öffentlich, und eine Fundliste zeigt, wo die echten Stellen liegen.
- **Bei einem Fund nicht reflexhaft bereinigen:** Ein Bereinigungs-Commit zeigt den Wert gebündelt. Der Weg steht in `/privacy-incident`, der Owner entscheidet.
- Ausführung nur über das PowerShell-Tool (Root-`CLAUDE.md` *Scripts*).

## Kosten-Politik

Die Fleißarbeit tragen Sonnet-Unteragenten (`Explore`, immer mit `model: "sonnet"`). Ein Unteragent liest höchstens etwa 300 KB, größere Bereiche teilst du nach Ordnern auf; der ganze Stand passt nicht in einen. Du bewertest nur, gewichtest und schreibst den Bericht. Sie arbeiten nacheinander statt alle auf einmal, und sie lesen keine generierten Dateien doppelt.

## Stand merken

`.local/privacy_deep_review_state.json` im Haupt-Checkout (gitignored) hält nach jedem erfolgreichen Lauf: die Tips aller Branches und Tags von `origin` und den Zeitpunkt. Die Datei enthält keinen Fund. Fehlt sie, läuft der ganze Monats-Umfang. Ein abgebrochener Lauf schreibt sie nicht, die nächste Woche prüft dann mit.

## Ablauf

**Beide Läufe zuerst:** `git fetch origin --tags --prune`, dann `.\scripts\refresh_privacy_denylist.ps1`, dann `.\scripts\privacy_lint.ps1` und `.\scripts\owner_fact_lint.ps1`. Das Auffrischen liest nur lesend auf dem Live-System und schreibt allein nach `.local/`. Scheitert es, etwa weil die Instanz nicht erreichbar ist, läuft die Prüfung mit der alten Liste weiter, und der Bericht sagt das. Lies dann den Steckbrief `.local/privacy_profile.md`. Fehlt er, meldest du das im Bericht und prüfst nach den Arten aus dem Auftrag unten.

### Wöchentlich (`woche`)

Alles Neue seit dem gemerkten Stand:

1. **Commits einzeln:** `git log -p --cc --remotes=origin --not <gemerkte Tips>`, also auch Werte, die ein späterer Commit wieder entfernt hat. Generierte Dateien (`packages/*/workflows/`, `docs/site/public/`, `docs/fn_catalog.md`) lässt du weg, ihre Quellen sind enthalten. Pathspec `:(exclude,glob)packages/*/workflows/**`: ohne `glob` fallen auch die Quellen unter `packages/*/build/workflows/` weg.
2. **Neue Tags und Releases:** Tag-Texte; `gh release list` und `gh release view` für alles seit dem gemerkten Zeitpunkt.
3. **Pull Requests und Issues:** `gh pr list --state all` und `gh issue list --state all`, begrenzt auf den Zeitraum, mit Titel, Text und Kommentaren.

### Monatlich (`monat`)

Der ganze öffentliche Stand, Bereich für Bereich:

1. **Prompts und Texte:** `packages/*/contexts/`, Manifeste, Tool-Beschreibungen, Textkataloge.
2. **Doku:** `*.md` außerhalb der Pakete, `docs/`, Skills, Regeln.
3. **Website:** der gebaute Stand `docs/site/public/`. Das ist, was Besucher sehen, und einzelne Seiten können von der Quelle abweichen.
4. **Testdaten:** `tests/` samt Fällen, Beispielen und Testdokumenten.
5. **Code und SQL:** Kommentare und Beispielwerte in `scripts/`, `provisioning/`, `packages/*/build/`, `packages/*/db/`.
6. **Bilder:** alle getrackten Bilder einzeln ansehen. Das Lint kann sie nicht lesen.
7. **Alle Texte der Historie:** `git log --remotes=origin --format=%B`, alle Tag-Texte, alle Release-Texte, alle Titel und Texte von Pull Requests und Issues.

Die `V__`-Migrationen liest du mit. Ein Fund dort wird gemeldet, ändern lässt er sich nur nach dem Weg in `/privacy-incident`.

### Auftrag an jeden Unteragenten, wörtlich

„Melde jede Stelle, die auf das Leben einer echten Person schließen lässt: Name, Ort, Beruf, Familie, Wohnform, Pläne, Beträge, Konten, Versicherer, Herkunft, auch als Umschreibung, Übersetzung, Beispiel oder als ‚echter Fall‘ markiert. Maßstab ist der Steckbrief. Allgemeine Produkt-Funktionen und offensichtlich erfundene Beispiele sind kein Fund. Der Autorname der Commits ist kein Fund. Antworte je Fund mit Datei oder Commit, Zeile, Art, Sicherheit (hoch/mittel/niedrig) und einem Satz ohne den Wert. Zitiere nichts. Sag am Ende, was du nicht lesen konntest.“

## Bericht

Privates Artefakt, Titel `Tiefenprüfung KW <nn>` oder `Tiefenprüfung <Monat>`, einfache deutsche Sprache (Fachbegriffe in Klammern), Aufbau:

1. **Kurzfazit** (3 Sätze: sauber oder nicht, was ist neu, was ist dringend).
2. **Umfang:** Lauf, verglichener Stand, Anzahl Commits, Dateien, Bilder; ob die Liste frisch war.
3. **Funde** als Tabelle: Art, Datei oder Commit, Zeile, Sicherheit, seit wann öffentlich, Vorschlag. Nie der Wert.
4. **Vorschläge, nummeriert:** bereinigen (Weg aus `/privacy-incident`), Eintrag in die lokale Liste, neue Regel in `scripts/owner_fact_lint.ps1`. Das Artefakt ist eine statische Seite ohne Knopf: Schreibe am Ende den Satz, den der Owner in einer neuen Sitzung im Repo sagt (z. B. „Nimm die Vorschläge 1 und 3 aus dem Bericht Tiefenprüfung KW <nn> auf“).
5. **Nicht geprüft**, ehrlich: Forks, fremde Klone, Caches und CI-Logs erreicht diese Prüfung nicht; dazu alles, was ein Unteragent nicht lesen konnte.

Link zum Artefakt als Ergebnis ausgeben; keine Funde in die Chat-Antwort kopieren, die Kurzfassung genügt. Dann den Stand merken.
