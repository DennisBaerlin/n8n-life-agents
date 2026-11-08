---
name: session-hygiene
description: Wöchentliche Routine (Sonntag) – schlägt vor, welche Sessions, Worktrees, Branches und Docker-Reste aufgeräumt werden können (untätig, gemergt oder leer, alte backup/*). Nur Anzeige; Archivieren und Löschen nur durch den Owner. Nutzen für den Wochenlauf oder auf Zuruf „räum die Sessions auf“.
---

# Session-Hygiene (`/session-hygiene`)

Offene Sessions, Worktrees und Branches sammeln sich an. Diese Routine macht daraus zwei Listen: Archivieren und Löschen, jeweils als Vorschlag. Du änderst nichts: kein `archive_session`, `delete_session`, `git branch -d/-D`, `git worktree remove/unlock`, kein `docker_cleanup.ps1 -Apply`, kein Push, nichts committen. Das tut der Owner oder die Leitung auf sein Wort.

## Harte Grenzen

- Nur lesen und anzeigen. Ungemergte Arbeit (Commits vor `origin/main` oder uncommittete Dateien im Worktree) nie zum Löschen vorschlagen, nur zum Archivieren der Session mit Risiko-Hinweis.
- Nur lokales Löschen vorschlagen; Branches mit Remote-Kopie kennzeichnen. Remote-Löschen nur auf ausdrückliches Owner-Wort (Push-Verbot gilt).
- Bericht privat (Artefakt), keine Gesprächsinhalte wiederholen.

## Kosten-Politik

Ein Sonnet-Unteragent (`Explore`) sammelt die Rohdaten (Schritte 2–6) und liefert nummerierte Tabellen. Bewertung und Listen (Schritt 7) machst du selbst.

## Ablauf

1. **Stand:** `git fetch origin` im Haupt-Checkout (nur Lesen aus dem Netz). Werkzeug laden: `mcp__ccd_session_mgmt__list_sessions` ist deferred, per `ToolSearch` mit `select:mcp__ccd_session_mgmt__list_sessions` laden. Wartezustände liefert das Tool nicht; sie stehen in `.claude/plans/leitung-stand.md` (Sessions, Merge-Reihenfolge).
2. **Archivier-Kandidaten:** `list_sessions` mit `limit` 200 (Standard 20 schneidet ab); Repo-Filter über `cwd` einschließlich `.claude/worktrees/…`. Kandidat = Session, die länger als drei Tage untätig ist ODER deren Branch in `origin/main` enthalten und deren Worktree sauber ist. Sessions ohne Branch (Leitungen, Routine-Läufe) nach Alter und `leitung-stand.md` bewerten. Je Session: Titel, `local_…`-Id, Zustand, Branch. Läuft sie gerade oder wartet auf den Owner, nur nennen.
3. **Branch-Stand je Session:** `git branch --merged origin/main`; bei Rebase-/Squash-Verdacht `git cherry origin/main <branch>` statt `--merged`; sonst `git log origin/main..<branch> --oneline`. Gleich dazu `git status --short` im Worktree der Session: ein Branch mit 0 Commits, aber uncommitteten Dateien ist ungemergte Arbeit.
4. **Worktrees ohne Session:** `git worktree list`; jeder Worktree ohne lebende Session. Detached-HEAD-Worktrees haben keinen Branch, Zuordnung über den Ordnernamen; `locked` Worktrees nennen, nicht entsperren.
5. **Branches ohne Session und ohne Commits vor `origin/main`:** lokale Branches ohne Session und Worktree, bei denen `git log origin/main..<branch>` leer ist. Offene PRs lesen (`gh pr list --state open`, nur lesen): kein Branch mit offenem PR kommt auf die Lösch-Liste.
6. **Alte Sicherungen und Docker:** `git for-each-ref --sort=committerdate --format='%(refname:short) %(committerdate:short)' refs/heads/backup` (ohne Format kein Datum), älter als sieben Tage. Docker: `.\scripts\dev\docker_cleanup.ps1` ohne Schalter (zeigt nur gestoppte eigene Container und dangling Images, löscht nichts; `-Apply` nie). Zusätzlich `docker ps` lesen und gegen `## Container` in `leitung-stand.md` abgleichen; laufende Container ohne Halter als Frage an die Leitung listen, nie als Lösch-Kandidat.
7. **Listen bilden:**
   - **Archivieren** (Session): Begründung (gemergt / Branch leer / untätig seit n Tagen), Risiko falls ungemergt (Anzahl Commits, Thema, gepusht?).
   - **Löschen** (Worktree, Branch, backup/*, Docker-Rest): nur gemergt oder leer und ohne uncommittete Änderungen; Reihenfolge: erst Session archivieren, dann Worktree, dann Branch.

## Bericht

Privates Artefakt `Session-Hygiene <Datum ISO>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Sessions, y Worktrees, z Branches, Docker) · nummerierte Tabelle Archivieren (Session, Begründung, Risiko) · nummerierte Tabelle Löschen (Objekt, Beleg, lokal/Remote-Kopie) · Ungemergte Arbeit einzeln benannt · Fragen an die Leitung (Container ohne Halter) · Nicht geprüft (nicht erreichbar oder nicht zuordenbar). Kein Knopf: Schreibe den Satz mit Nummern, z. B. „Archiviere die Sessions 1–4 und lösche die Zeilen 1–6 laut Bericht Session-Hygiene vom <Datum>“. Link ausgeben.
