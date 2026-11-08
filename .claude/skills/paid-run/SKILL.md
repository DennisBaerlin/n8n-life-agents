---
name: paid-run
description: Monatliche Routine – stellt den bezahlten Sammel-Lauf zusammen, ohne ihn zu starten: offene Fälle aus Backlog und Quarantäne, Zuordnung zu Suiten, Kostenschätzung, Satz fürs Owner-Fenster. Bericht als privates Artefakt. Nutzen für den Monatslauf oder auf Zuruf „bezahlte Tests bündeln“.
---

# Bezahlter Sammel-Lauf (`/paid-run`)

Offene bezahlte Testfälle wachsen, weil kein Lauf sie abarbeitet. Diese Routine bereitet den Lauf so vor, dass der Owner ihn mit einem Satz starten kann. Du startest nichts: keine Suite, kein Owner-Fenster, nichts committen, keine Datei ändern. Streichen der grünen Fälle aus dem Backlog ist nicht Teil dieses Skills; das macht die Leitung nach dem Lauf.

## Harte Grenzen

- **Falle:** Ein Hook sperrt jeden Shell-Befehl, in dem der Dateiname einer bezahlten Test-Suite steht (auch beim Suchen, Lesen, Auflisten). Nur das Grep-Tool, Glob und Read nutzen; Suiten-Dateinamen nie in einen Shell-Befehl schreiben. Auch die Unteragenten bekommen diesen Hinweis.
- Das Backlog `.local/BACKLOG.md` liegt privat im Haupt-Checkout, nie im Repo. Der Bericht ist ein privates Artefakt; keine Live-Werte.

## Kosten-Politik

Ein Sonnet-Unteragent (`Explore`) sammelt Fall-IDs und Quellen (Schritt 1–2) als Tabelle. Zuordnung, Schätzung und Bericht (Schritte 3–5) machst du selbst.

## Ablauf

1. **Backlog:** Abschnitt „Offene bezahlte Prüfungen“ in `.local/BACKLOG.md` lesen: je Eintrag Fall-ID, Anlass, Suite, feste Daten (Fälle mit Datum zuerst nennen).
2. **Quarantäne:** mit dem Grep-Tool unter `tests/` nach `pending_*`-Dateien und Quarantäne-Markierungen suchen (Muster nachlesen in `tests/CLAUDE.md`); je Fall: ID, Datei, Grund, Re-Evaluierungs-Trigger. Fälle, deren Trigger nicht eingetreten ist, getrennt als „noch nicht fällig“ führen.
3. **Zuordnen:** Fall-IDs den Suiten zuordnen (Verhalten/Routing, Prompt-Qualität/Judge, Schema-Fidelity; Tabelle in Root-`CLAUDE.md` *Testing*, Details in `tests/CLAUDE.md`). Nur die Fälle, die offen sind, nicht ganze Suiten (Memory `paid-tests-targeted`: gezielt, vorher Anzahl nennen).
4. **Kosten schätzen:** aus den letzten Läufen: Memory `paid-tests-targeted` und `llm-cost-report-command` (Projekt-Memory, Index `MEMORY.md`), dazu `.local/llm_cost_log.jsonl` im Haupt-Checkout, falls vorhanden (nur lesen). Spanne je Suite (Anzahl Fälle × Durchschnitt je Fall der letzten Läufe) und Summe; ohne Datenbasis ehrlich „nicht schätzbar“ schreiben.
5. **Owner-Satz:** Das Owner-Fenster öffnet der Owner im Terminal selbst (Root-`CLAUDE.md` *Scripts*): `.\scripts\grant_owner_window.ps1`. Danach ein Satz, den er in der Session sagt, z. B. „Fahre den bezahlten Sammel-Lauf laut Bericht Bezahlter Lauf vom <Datum> mit den Fällen …“, mit Reihenfolge (billigste Suite zuerst, festen Daten Vorrang).

## Bericht

Privates Artefakt `Bezahlter Lauf <Datum>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Fälle, y Suiten, Kosten von–bis) · Tabelle {Fall-ID, Suite, Quelle, Grund, fest datiert?} · „noch nicht fällig“ · Kostenschätzung mit Datenbasis · Der Satz fürs Owner-Fenster und der Auftragssatz · Nicht geprüft. Link ausgeben.
