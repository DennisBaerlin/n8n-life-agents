---
name: live-findings
description: Wöchentliche Routine - liest (nur lesend) auf dem Live-LXC Gespräche, Fehler-Alerts und n8n-Ausführungsfehler der letzten 7 Tage, listet Fehlrouten, Abbrüche und Rückfragen und schlägt Backlog-Punkte vor. Bericht als privates Artefakt, nie ins Repo. Nutzen für den geplanten Wochenlauf oder auf Zuruf "was ist live aufgefallen".
---

# Befunde der Woche (`/live-findings`)

Grundsatz „Agenten schlagen vor, der Nutzer bestätigt“: Du **liest und berichtest**, du änderst nichts. Der Owner verbessert diesen Skill, wenn der Bericht nicht passt.

## Harte Grenzen

- **Nur lesend** auf dem Live-System: kein `INSERT/UPDATE/DELETE`, kein n8n-Stop, kein Neustart, kein `lifeagents update`. Jede SQL-Sitzung beginnt mit `SET default_transaction_read_only = on;`, API-Aufrufe sind nur GET. Eine nötige Änderung ist ein **Vorschlag** im Bericht, nie eine Aktion.
- **Der Bericht enthält private Daten** (Gesprächsinhalte, Beträge, Namen) und kommt deshalb **nie ins Repo**: keine Datei im Repo, kein Commit. Ablage nur als **privates Artefakt** (`Artifact`-Tool, Standard = privat, nicht teilen) oder als privates Dokument im Konto des Owners. Das Repo ist öffentlich.
- **Zugang** (Host, Nutzer, Schlüssel) steht in der `.env` des Haupt-Checkouts (`DEV_INSTANCE_HOST`, `DEV_INSTANCE_USER`, `DEV_INSTANCE_SSH_KEY`; Worktrees haben keine `.env`). Nie in den Bericht oder in eine Nachricht schreiben. Das Rezept (Skript in den Scratchpad, LF/ohne BOM, `scp`, `ssh … 'bash /tmp/x.sh; rm -f /tmp/x.sh'`) und die Dauer-Erlaubnis des Owners für lesende Zugriffe stehen in den Memory-Notizen `owner-instance-ssh-access` und `live-system-read-permission` des Projekts (Index `MEMORY.md`). Lies beide zuerst. Blockt der Berechtigungs-Klassifizierer trotzdem, nicht umgehen: den Owner um Freigabe bitten.
- Ausführung nur über das PowerShell-Tool (Root-`CLAUDE.md` *Scripts*), Remote-Skripte ASCII.

## Kosten-Politik

Owner-Entscheid 2026-11-02: Das Hauptmodell einer geplanten Aufgabe ist der App-Standard (Opus), also gehört die Fleißarbeit an **Sonnet-Unteragenten** (`Explore`, immer mit `model: "sonnet"`): Server-Abfragen, Log- und Gesprächs-Lesen, Zählen. Sie liefern dir verdichtete Tabellen und Fundlisten mit Beleg; du bewertest nur, gewichtest und schreibst den Bericht. Ein Unteragent je Themenblock (Schritte 1–3 = Server-Zustand, 4–5 = Gespräche) reicht.

## Ablauf

Zeitraum = letzte 7 Tage bis jetzt. Fakten sammeln, dann auswerten.

1. **Gesundheit:** `lifeagents doctor` (lesend) und `systemctl is-active n8n lifeagents-llm-gateway postgresql@17-main`; Auffälliges in einem Satz.
2. **Ausführungsfehler:** n8n-Tabellen mit Präfix `public.` (`public.execution_entity`, `public.workflow_entity`). **Immer `"deletedAt" IS NULL`** (n8n löscht nicht gespeicherte Läufe weich; sonst falscher Alarm). Je Workflow: Anzahl `status = 'error'` und `crashed`, erster/letzter Zeitpunkt, Fehlermeldung (Ausführungsdaten sind flatted-JSON: parsen mit node + `/usr/lib/node_modules/n8n/node_modules/flatted`). Dazu `status = 'waiting'` älter als 1 Tag (liegengebliebene Bestätigungskarten) — nur zählen, nicht stoppen.
3. **Fehler-Alerts:** Jeder Fehlerlauf löst `core.sub_error_notify` aus (Telegram-Alarm an den Owner); es gibt keine eigene Alarm-Tabelle. Ersatz: die Fehlerläufe aus Schritt 2 gelten als Alarme; zusätzlich `journalctl -u n8n -u lifeagents-llm-gateway --since '7 days ago' -p err` (zusammenfassen, nicht roh einfügen).
4. **Gespräche:** Chat-Gedächtnis-Tabellen entdecken (`information_schema.tables`, Muster `agent.%_chat_memory`; Spalten nicht raten, erst ansehen). Je Agent: Anzahl Gespräche/Nachrichten, Verteilung über die Woche. Die Gesprächsinhalte nur so weit lesen, wie Schritt 5 es braucht.
5. **Auffälligkeiten in den Gesprächen** (Liste je Fund: Agent, Tag, ein Satz, **keine** Beträge/Namen, die der Sache nicht dienen):
   - **Fehlrouten:** der Router (Orchestrator) schickt an den falschen Spezialisten, oder ein Spezialist antwortet „dafür gibt es kein Tool“ / „not yet available“, obwohl ein anderer Agent es kann.
   - **Abbrüche:** Bestätigungskarte nie getippt oder abgelehnt (`cancelled`), Antwort fehlt, `max_call_depth`, Timeout, Wiederholung derselben Frage.
   - **Rückfragen:** der Bot fragt nach etwas, das er selbst hätte nachschlagen oder vorschlagen können (Grundsatz „Agenten denken mit“); der Nutzer korrigiert den Bot.
6. **Kosten-Ausreißer** nur erwähnen, wenn sie zu einem Fund passen (Details macht `/cost-report`).
7. **Privacy-Liste auffrischen:** `.\scripts\refresh_privacy_denylist.ps1` (nur lesend, schreibt nur nach `.local/`, nennt nie Werte). Eine Treffer-Meldung des Skripts gehört als Fund in den Bericht, nur mit Datei und Zeile.

## Bericht

Privates Artefakt, Titel `Befunde KW <nn>`, einfache deutsche Sprache (Fachbegriffe in Klammern), Aufbau:

1. **Kurzfazit** (3 Sätze: läuft es, was ist neu, was ist dringend).
2. **Zahlen:** Gespräche, Fehlerläufe je Workflow, liegengebliebene Karten.
3. **Funde** als Tabelle: Art (Fehlroute/Abbruch/Rückfrage/Fehler), wo, was, Folge für den Nutzer. Ein Fund, der ein neuer Testfall werden sollte, trägt die Markierung **Testfall** und nennt in einem Satz die zu prüfende Eigenschaft. Live-Werte bleiben im privaten Bericht; der Owner gibt markierte Funde für `/test-task` frei, und weiter geht nur dieser eine Satz zur Eigenschaft.
4. **Backlog-Vorschläge:** je Vorschlag Problem, Beleg (Anzahl/Tage, ohne private Werte), grobe Lösungsrichtung, Dringlichkeit. Aufnehmen ins private Backlog tut eine Session auf das Wort des Owners. Das Artefakt ist eine statische Seite ohne Knopf: Schreibe am Ende den Satz, den der Owner in einer neuen Sitzung im Repo sagt (z. B. „Nimm die Vorschläge 1 und 3 aus dem Bericht Befunde KW <nn> ins Backlog auf“), und nummeriere die Vorschläge, damit er einzelne auswählen kann. Nie „mit deinem OK passiert X“ als Knopf-Ersatz schreiben.
5. **Nicht geprüft** (was fehlte oder nicht erreichbar war), ehrlich.

Link zum Artefakt als Ergebnis ausgeben; keine Zahlen oder Gesprächsinhalte in die Chat-Antwort kopieren, die Kurzfassung genügt.
