---
name: session-hygiene
description: Wöchentliche Routine (Sonntag) – schlägt vor, welche Sessions, Worktrees, Branches und Docker-Reste aufgeräumt werden können (untätig, gemergt oder leer, alte backup/*). Nur Anzeige; Archivieren und Löschen nur durch den Owner. Nutzen für den Wochenlauf oder auf Zuruf „räum die Sessions auf“.
---

# Session-Hygiene (`/session-hygiene`)

Offene Sessions, Worktrees und Branches sammeln sich an. Diese Routine macht daraus zwei Listen: Archivieren und Löschen, jeweils als Vorschlag. Du änderst nichts: kein `archive_session`, `delete_session`, `git branch -d/-D`, `git worktree remove`, kein `docker_cleanup.ps1 -Apply`, kein Push, nichts committen. Das tut der Owner oder die Leitung auf sein Wort.

## Harte Grenzen

- Nur lesen und anzeigen. Ein Branch mit Commits vor `origin/main` gilt als ungemergte Arbeit: nie zum Löschen vorschlagen, nur zum Archivieren der Session mit Risiko-Hinweis.
- Bericht privat (Artefakt), Branch- und Session-Namen sind kein Problem, Inhalte von Gesprächen werden nicht wiederholt.

## Kosten-Politik

Ein Sonnet-Unteragent (`Explore`) sammelt die Rohdaten (Schritte 2–6) und liefert Tabellen. Bewertung und Listen (Schritt 7) machst du selbst.

## Ablauf

1. **Stand:** `git fetch origin` im Haupt-Checkout (nur Lesen aus dem Netz). Werkzeug laden: `mcp__ccd_session_mgmt__list_sessions` ist deferred, per `ToolSearch` mit `select:mcp__ccd_session_mgmt__list_sessions` laden.
2. **Untätige Sessions:** `list_sessions` für dieses Repo; Sessions mit letzter Aktivität älter als drei Tage. Je Session: Titel, `local_…`-Id, Zustand, Branch. Läuft sie gerade oder wartet auf den Owner, nur nennen, nicht vorschlagen.
3. **Branch-Stand je Session:** ist der Branch in `origin/main` enthalten (`git branch --merged origin/main`)? Sonst `git log origin/main..<branch> --oneline`: Anzahl und Themen der ungemergten Commits.
4. **Worktrees ohne Session:** `git worktree list`; jeder Worktree, zu dem keine lebende Session gehört (Ordner/Branch in `list_sessions` nicht zu finden). Dazu: `git status --short` im Worktree (uncommittete Änderungen = Risiko).
5. **Branches ohne Session und ohne Commits vor `origin/main`:** lokale Branches, die weder an einer Session noch an einem Worktree hängen und `git log origin/main..<branch>` leer ist.
6. **Alte Sicherungen und Docker:** `backup/*`-Branches mit letztem Commit älter als sieben Tage (`git for-each-ref --sort=committerdate refs/heads/backup refs/remotes/origin/backup`). Docker-Reste nur im Anzeige-Modus: `.\scripts\dev\docker_cleanup.ps1` ohne Schalter (zeigt die Liste, löscht nichts; `-Apply` und `-IncludeOrphanAnonymousVolumes` nie setzen). Eigene Container laufender Sessions (Liste in den Stand-Dateien) sind nicht Teil der Lösch-Liste.
7. **Listen bilden:**
   - **Archivieren** (Session): Begründung (gemergt / Branch leer / untätig seit n Tagen) und Risiko, falls ungemergt (Anzahl Commits, Thema, ob gepusht).
   - **Löschen** (Worktree, Branch, backup/*, Docker-Rest): nur was gemergt oder leer und ohne uncommittete Änderungen ist; Reihenfolge: erst Session archivieren, dann Worktree, dann Branch.

## Bericht

Privates Artefakt `Session-Hygiene <Datum>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Sessions, y Worktrees, z Branches, Docker) · Tabelle Archivieren (Session, Begründung, Risiko) · Tabelle Löschen (Objekt, Beleg) · Ungemergte Arbeit mit Risiko, einzeln benannt · Nicht geprüft. Kein Knopf: Schreibe den Satz für den Owner bzw. die Leitung, z. B. „Archiviere die Sessions 1–4 und lösche die Worktrees und Branches laut Tabelle aus dem Bericht Session-Hygiene vom <Datum>“. Link ausgeben.
