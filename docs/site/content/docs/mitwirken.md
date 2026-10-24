---
title: "Mitwirken & Entwicklung"
---

Diese Seite richtet sich an neugierige Entwickler, die sich den Code ansehen oder etwas beitragen möchten. Sie ist bewusst kurz — die eigentliche Anleitung steht direkt im Repository, damit es nur eine Stelle gibt, die aktuell gehalten werden muss.

## Der ehrliche technische Kern — drei Entscheidungen

Falls du nur eines mitnimmst, dann diese drei Design-Entscheidungen:

1. **Das Modell schlägt vor — die Datenbank entscheidet.** Kein Agent rechnet Kontostände, Vorzeichen oder Raten. Das Sprachmodell liefert nur, was der Nutzer wörtlich sagt; jede abgeleitete Zahl berechnet eine Datenbank-Funktion, jede Regel erzwingt ein Constraint. Falsch rechnen kann das Modell nicht — es rechnet nicht.
2. **Der Weg jeder Nachricht ist ein Einbahn-DAG.** Telegram → Reverse-Proxy (nur Webhook-Routen) → Orchestrator → Spezialist → Bestätigungs-Gate → PostgreSQL. Agenten rufen keine Agenten; ein Tiefen-Riegel stoppt Schleifen, bevor das teure Modell überhaupt aufgerufen wird — weglaufende Kosten sind strukturell ausgeschlossen.
3. **Jeder Lebensbereich ist ein isoliertes Paket.** Eigenes Datenbank-Schema, eigene Zugriffsrollen, eigenes Manifest. Der Karriere-Coach *kann* nicht in die Finanz-Tabellen schreiben — Pakete verbindet nur ein bewusst veröffentlichtes Lesefenster (Vertrag: `docs/package-contract.md` im Repo).

## Wo die Antworten stehen

Das Projekt trennt seine Doku sauber nach Zielgruppe und Sprache:

- **Einrichtung der Entwicklungsumgebung und Qualitäts-Checks (technisch „Enforcement Gates" genannt):** Datei `CONTRIBUTING.md` im Repo, auf Englisch. Dort steht Schritt für Schritt, welche Werkzeuge installiert werden müssen und welche automatischen Prüfungen beim Speichern eines Standes (technisch „Commit") und beim Hochladen (technisch „Push") laufen.
- **Kurzfassung der wichtigsten Regeln** (Namensgebung, Sprachregeln, wie Änderungen abgesichert werden): Datei `AGENTS.md`, ebenfalls Englisch — gedacht als schneller Einstieg, bevor man tiefer in den Code schaut.
- **Sicherheitslücken melden:** Datei `SECURITY.md`. Es gibt einen privaten Meldeweg über GitHub, keine öffentlichen Issues für Sicherheitsprobleme.
- **Die eigentliche Architektur-Dokumentation** (wie die Agenten, die Datenbank und die Workflows zusammenspielen) liegt in der `CLAUDE.md`-Familie — einer Reihe zusammengehöriger Dateien im Repo, auf Deutsch geschrieben; die ausführliche Mechanik je Bereich steht daneben unter `docs/reference/`. Sie ist in erster Linie als Gedächtnis für die Weiterentwicklung mit einem KI-Coding-Assistenten gedacht, gibt aber auch jedem menschlichen Leser den vollständigen Überblick.

## Wie Änderungen abgesichert werden

Bevor eine Änderung überhaupt eingespielt wird, durchläuft sie mehrere automatische Prüf-Ebenen (technisch „Tests"): von schnellen, kostenlosen Prüfungen direkt an der Datenbank bis hin zu Prüfungen, die eine echte Unterhaltung mit den Agenten simulieren und deren Verhalten bewerten. Welche Ebene greift, hängt davon ab, was verändert wurde — an Datenrichtigkeit gekoppelte Änderungen (z. B. an der Datenbank-Logik) werden immer automatisch geprüft, bevor sie hochgeladen werden dürfen.

## Rechtlicher Hinweis

Das Projekt ist **quelloffen unter der MIT-Lizenz** (Datei `LICENSE` im Repository): Du darfst den Code nutzen, verändern und weitergeben, solange der Lizenzhinweis erhalten bleibt. Es ist ein persönliches Projekt für den eigenen Haushalt, geteilt wie es ist, damit du eine eigene Instanz betreiben kannst — **ohne Support**: Es gibt keine Issues, und Pull Requests werden nicht aktiv geprüft. Der einzige Meldeweg ist der private für Sicherheitslücken (siehe `SECURITY.md`). Eigene Abzweigungen (Forks) sind im Rahmen der Lizenz willkommen.

- **Kein offizielles n8n-Projekt.** n8n ist eine Marke der n8n GmbH; dieses Projekt steht in keiner Verbindung zu ihr.
- **n8n selbst liegt nicht im Repository.** Es steht unter der „Sustainable Use License“ von n8n (keine klassische Open-Source-Lizenz); der Installer installiert n8n aus dem offiziellen Paket auf deinem Rechner und verteilt es nicht selbst.
- **Keine Finanz-, Steuer- oder Rechtsberatung.** Die Agenten liefern Informationen und Vorschläge; Entscheidungen und ihre Folgen bleiben bei dir. Die Software kommt ohne Gewähr.

## Weiterlesen

- [Wie es funktioniert](so-funktionierts.html)
- [Die Pakete](pakete.html)
- [Installation](installation.html)
- [Datenschutz](datenschutz.html)
