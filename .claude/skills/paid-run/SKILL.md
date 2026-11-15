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

Ein Sonnet-Unteragent (`Explore`) sammelt Fall-IDs und Quellen (Schritte 1–2) als Tabelle. Zuordnung, Bündelung, Schätzung und Bericht (Schritte 3–7) machst du selbst.

## Ablauf

1. **Backlog:** Abschnitt „Offene bezahlte Prüfungen“ in `.local/BACKLOG.md` lesen: je Eintrag Fall-ID, Anlass, feste Daten (Fälle mit Datum zuerst nennen). Das Backlog nennt die Suite oft nicht.
2. **Quarantäne:** Fälle mit `"quarantined": true` in `tests/agent/<pkg>/*_cases.json` (Grep-Tool); je Fall: ID, Datei, Grund, Re-Evaluierungs-Trigger. `pending_*`-Dateien sind kostenlose DB-Tests und gehören nicht in den bezahlten Lauf.
3. **Suite und Agent ableiten:** Fall-ID per Grep unter `tests/agent/<pkg>/*_cases.json` suchen; Datei → Suite: `*_cases.json` (Routing) = n8n_test, `*_e2e_cases.json` = e2e_test, Orchestrator-Fälle = orch_test, `cross/conversation_cases.json` = conversation_test; der Bewerter (judge_eval) läuft direkt nach jeder n8n_test-Gruppe. Zu jedem Fall den Ziel-Agenten notieren (finance, Berater, Guide, Karriere, …; Aufruf-Parameter je Agent in `docs/reference/tests.md`). Nur offene Fälle, nicht ganze Suiten (Memory `paid-tests-targeted`: gezielt, vorher Anzahl nennen). Dritte Gruppe „ohne Fall-ID“ für Einstellungsproben und Prompt-Punkte.
4. **Je Agent bündeln:** Alle Fälle eines Agenten (Routing, e2e, Wiederholungen aus Fall-Notizen wie „≥ 5 isolierte Läufe“) bilden einen Block und laufen direkt hintereinander, Routing als eine gefilterte Fall-Datei (`n8n_test -CasesFile`). So schreibt jeder Agent den Prompt-Cache einmal. Der Cache lebt 1 h (Substrat ohne Keep-alive); ein Substrat-Neustart oder ein anderes `tool_choice` leert ihn für System-Prompt und Werkzeuge nicht, solange der Prompt gleich bleibt.
5. **Kosten schätzen:** nach Abschnitt *Schätzer*. Spanne je Block und Summe; Kaltstart und warme Fälle getrennt ausweisen; ohne Datenbasis ehrlich „nicht schätzbar“. Gilt auch für die Kostenansage vor jedem gezielten Einzellauf.
6. **Abgleich:** Kostenlog-Einträge nach dem Backlog-Stand: betroffene Fälle als „möglicherweise schon gelaufen“ markieren.
7. **Owner-Satz:** Das Owner-Fenster öffnet der Owner im Terminal selbst (Root-`CLAUDE.md` *Scripts*): `.\scripts\grant_owner_window.ps1`. Danach ein Satz für die Session, z. B. „Fahre den bezahlten Sammel-Lauf laut Bericht Bezahlter Lauf vom <Datum>, Blöcke 1–n“. Reihenfolge: fest datierte Fälle zuerst, sonst Block für Block je Agent; eine Einstellungsprobe, die einen Substrat-Neustart braucht, innerhalb der Stunde nach dem Block desselben Agenten.

## Schätzer

Kosten je Block = **Kaltstart des Agenten** (einmal je Agent und Stunde) + **Ausführungen × warmer Preis je Fall**. Summe = Summe der Blöcke + Bewerter. Der Kaltstart steht im Bericht in einer eigenen Spalte, weil er bei kleinen Läufen der Hauptposten ist.

| Agent | Kaltstart | warm je Fall |
|---|---|---|
| agent.finance (Sonnet) | 0,25–0,35 $ | 0,02–0,04 $ |
| agent.finance_advisor (Opus) | 0,20–0,35 $ | 0,04–0,08 $ |
| agent.career_advisor | 0,15–0,25 $ | 0,03–0,07 $ |
| agent.estate_advisor (Opus) | nicht getrennt gemessen | Gesamtlauf 22 Fälle (69 Anfragen): 0,94 $, im Schnitt ≈ 0,043 $ je Fall inkl. Kaltstart |
| agent.guide | 0,03–0,05 $ | 0,01–0,02 $ |
| agent.monitor | 0,04–0,06 $ | 0,005–0,01 $ |
| Orchestrator | 0,02–0,05 $ | 0,005–0,01 $ |
| conversation_test | Kaltstart jedes berührten Agenten | 0,015–0,03 $ je Runde |
| judge_eval (Haiku) | — | ≈ 0,0005 $ |

Ein e2e-Fall direkt nach dem Routing-Block desselben Agenten zählt warm. Ein Agent ohne Zeile: „nicht schätzbar“ oder Werte aus dem Kostenlog ableiten und die Tabelle ergänzen.

**Eichung:** Die Tabelle stammt aus `.local/llm_cost_log.jsonl` (Haupt-Checkout, nur lesen; eine Zeile je Suiten-Aufruf mit `label`, `requests`, `cost_usd`, `hit_pct`). Kalte Läufe erkennt man an niedrigem `hit_pct`, warme an > 95 %. Vor jedem Bericht die neuesten Zeilen gegen die Tabelle halten: liegt ein Lauf außerhalb der Spanne, die Zeile anpassen und den Grund im Bericht nennen. Ziel: Ansage trifft das Ergebnis auf ±30 %. Gegenproben (2026-11-14): neun finance-Fälle real 0,57 $, Modell 0,43–0,71 $; Durchspiel mit zwölf Runden über Orchestrator, finance, Berater und Guide real 0,92 $, Modell 0,68–1,16 $.

## Bericht

Privates Artefakt `Bezahlter Lauf <Datum ISO>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Fälle, y Agenten-Blöcke, Kosten von–bis, davon Kaltstart, Läufe ohne Fallzahl getrennt) · Tabelle {Fall-ID, Agent, Suite, Quelle, Grund, fest datiert?, möglicherweise schon gelaufen?} · Gruppe „ohne Fall-ID“ · Block-Tabelle {Block, Agent, Fälle, Ausführungen, Kaltstart, warm, Summe} mit Eichung gegen das Kostenlog · Satz fürs Owner-Fenster und Auftragssatz · Nicht geprüft. Link ausgeben.
