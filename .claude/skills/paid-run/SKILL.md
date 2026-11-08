---
name: paid-run
description: Monatliche Routine – stellt den bezahlten Sammel-Lauf zusammen, ohne ihn zu starten: offene Fälle aus Backlog und Quarantäne, Zuordnung zu Suiten, Kostenschätzung, Satz fürs Owner-Fenster. Bericht als privates Artefakt. Nutzen für den Monatslauf oder auf Zuruf „bezahlte Tests bündeln“.
---

# Bezahlter Sammel-Lauf (`/paid-run`)

Offene bezahlte Testfälle wachsen, weil kein Lauf sie abarbeitet. Diese Routine bereitet den Lauf so vor, dass der Owner ihn mit einem Satz starten kann. Du startest nichts: keine Suite, kein Owner-Fenster, nichts committen, keine Datei ändern. Streichen der grünen Fälle aus dem Backlog ist nicht Teil dieses Skills; das macht die Leitung nach dem Lauf.

## Harte Grenzen

- **Falle:** Ein Hook sperrt jeden Shell-Befehl, in dem der Dateiname einer bezahlten Test-Suite steht (auch beim Suchen, Lesen, Auflisten). Nur Grep, Glob und Read nutzen; Suiten-Dateinamen nie in einen Shell-Befehl schreiben. Auch die Unteragenten bekommen den Hinweis.
- Das Backlog `.local/BACKLOG.md` liegt privat im Haupt-Checkout, nie im Repo. Der Bericht ist ein privates Artefakt; keine Live-Werte.

## Kosten-Politik

Ein Sonnet-Unteragent (`Explore`) sammelt Fall-IDs und Quellen (Schritte 1–2) als Tabelle. Zuordnung, Schätzung und Bericht (Schritte 3–6) machst du selbst.

## Ablauf

1. **Backlog:** Abschnitt „Offene bezahlte Prüfungen“ in `.local/BACKLOG.md` lesen: je Eintrag Fall-ID, Anlass, feste Daten (Fälle mit Datum zuerst nennen). Das Backlog nennt die Suite oft nicht.
2. **Quarantäne:** Fälle mit `"quarantined": true` in `tests/agent/<pkg>/*_cases.json` (Grep-Tool); je Fall: ID, Datei, Grund, Re-Evaluierungs-Trigger. `pending_*`-Dateien sind kostenlose DB-Tests und gehören nicht in den bezahlten Lauf.
3. **Suite ableiten:** Fall-ID per Grep unter `tests/agent/<pkg>/*_cases.json` suchen; Datei → Suite: `*_cases.json` (Routing) = n8n_test, `*_e2e_cases.json` = e2e_test, Orchestrator-Fälle = orch_test; der Bewerter (judge_eval) läuft direkt nach jeder n8n_test-Gruppe. Nur offene Fälle, nicht ganze Suiten (Memory `paid-tests-targeted`: gezielt, vorher Anzahl nennen). Dritte Gruppe „ohne Fall-ID“ für Einstellungsproben und Prompt-Punkte.
4. **Kosten schätzen:** Memory `paid-tests-targeted` (Projekt-Memory, Index `MEMORY.md`) liefert Kosten je Fall und Suite. `.local/llm_cost_log.jsonl` im Haupt-Checkout (nur lesen) zählt Anfragen, nicht Fälle: nur zur Plausibilisierung. Re-Evaluierungs-Läufe aus Fall-Notizen (z. B. „≥ 5 isolierte Läufe“) einrechnen. Spanne je Suite und Summe; ohne Datenbasis ehrlich „nicht schätzbar“. Läufe ohne bekannte Fallzahl (Weiterleitung) getrennt ausweisen.
5. **Abgleich:** Kostenlog-Einträge nach dem Backlog-Stand: betroffene Fälle als „möglicherweise schon gelaufen“ markieren.
6. **Owner-Satz:** Das Owner-Fenster öffnet der Owner im Terminal selbst (Root-`CLAUDE.md` *Scripts*): `.\scripts\grant_owner_window.ps1`. Danach ein Satz für die Session, z. B. „Fahre den bezahlten Sammel-Lauf laut Bericht Bezahlter Lauf vom <Datum> mit den Fällen …“, Reihenfolge: billigste Suite zuerst, fest datierte Fälle haben Vorrang.

## Bericht

Privates Artefakt `Bezahlter Lauf <Datum ISO>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Fälle, y Suiten, Kosten von–bis, Läufe ohne Fallzahl getrennt) · Tabelle {Fall-ID, Suite, Quelle, Grund, fest datiert?, möglicherweise schon gelaufen?} · Gruppe „ohne Fall-ID“ · Kostenschätzung mit Datenbasis · Satz fürs Owner-Fenster und Auftragssatz · Nicht geprüft. Link ausgeben.
