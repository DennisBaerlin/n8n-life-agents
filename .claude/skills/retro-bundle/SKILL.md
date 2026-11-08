---
name: retro-bundle
description: Wöchentliche Routine (Freitag) – bündelt Verbesserungs-Zeilen der Stand-Dateien und neue Feedback-Memorys nach Ursache, höchstens drei Vorschläge mit Empfehlung und Ziel-Adresse. Ändert nichts, Bericht als privates Artefakt. Nutzen für den Wochenlauf oder auf Zuruf „Retro bündeln“.
---

# Retro-Bündel (`/retro-bundle`)

Verbesserungs-Zeilen bleiben sonst unbearbeitet in den Stand-Dateien liegen. Diese Routine bündelt sie nach Ursache und macht daraus wenige entscheidbare Karten. Du liest und schlägst vor; Dateien änderst du nicht, nichts committen, kein `SendMessage` an andere Sessions außer der Anmeldung bei der Leitung (`/coordinate` §1).

## Harte Grenzen

- Nur lesen: Stand-Dateien, Memory, Git. Kein Anlegen von Regeln, Hooks oder Skills; Umsetzen tut eine Session auf das Wort des Owners.
- Stand-Dateien und Memory sind privat. Der Bericht kommt nie ins Repo, nur als privates Artefakt (`Artifact`, Standard = privat, nicht teilen). Keine echten Werte, Namen oder Lebensumstände wiederholen.

## Kosten-Politik

Die Fleißarbeit macht ein Sonnet-Unteragent (`Explore`): alle Verbesserungs-Zeilen und neuen Feedback-Memorys einsammeln, je Zeile Datum, Ursache, Vorschlag und Ziel-Adresse wörtlich auflisten. Gruppieren, Gegenprüfen, Auswahl und Bericht (Schritte 3–5) machst du selbst.

## Ablauf

1. **Letzter Lauf:** Datum im Titel des letzten Artefakts `Retro-Bündel …` (`Artifact`-Liste); fehlt es, 7 Tage nehmen.
2. **Sammeln:**
   - Abschnitt `## Verbesserungen` in `.claude/plans/leitung-stand.md` und in jeder noch vorhandenen `.claude/plans/leitung-*-stand.md` (Haupt-Checkout und Worktrees, per Glob/Grep-Tool).
   - Memory-Einträge vom Typ `feedback` mit Änderungsdatum nach dem letzten Lauf: Index `MEMORY.md` im Projekt-Memory-Ordner dieser Session (Pfad steht im System-Prompt unter „Memory“), dann die Dateien öffnen (Frontmatter `metadata.type: feedback`).
3. **Bündeln:** gleiche Ursache = ein Bündel, auch wenn Wortlaut und Quelle verschieden sind. Je Bündel: wie oft, in welchen Quellen, Ursache in einem Satz.
4. **Schon erledigt?** Jedes Bündel gegen den heutigen Stand prüfen (Skill, Hook, Skript, Root-`CLAUDE.md`, per Grep): steht die Regel längst dort, ist es kein Vorschlag, sondern Streichkandidat der Stand-Zeile.
5. **Auswählen:** höchstens drei Vorschläge, in dieser Reihenfolge der Wichtigkeit: Daten-/Geldfehler, Wiederholung (≥ 2 Quellen), verlorenes Kontingent, Owner musste es zweimal sagen. Je Vorschlag eine Karte mit Empfehlung und genau einer Ziel-Adresse nach „ein Fakt, eine Adresse“ (`/leitung` §3): Alltag der Leitung → `/leitung`; Zusammenspiel der Sessions → `/coordinate`; Ablauf einer Aufgabenart → deren Skill; gilt für jede Session → Root-`CLAUDE.md`; hartes Verbot → Hook (nur mit ausdrücklicher Freigabe); wiederkehrende Handarbeit → Skript. Die Regel ersetzt Widersprechendes, statt angehängt zu werden.
6. **Rest:** alles Übrige als Liste „nicht umsetzen, weil …“ (einmalig, schon abgedeckt, zu selten, Kosten > Nutzen).

## Bericht

Privates Artefakt `Retro-Bündel <Datum>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Zeilen gelesen, y Bündel, z Vorschläge) · bis zu drei Karten (Problem, Beleg ohne private Werte, Empfehlung, Ziel-Adresse, Aufwand) · Liste „nicht umsetzen, weil …“ · Streichkandidaten in den Stand-Dateien · Nicht geprüft. Kein Knopf: Schreibe den Satz, den der Owner sagt, z. B. „Setze Karte 1 und 3 aus dem Retro-Bündel vom <Datum> um“. Link ausgeben.
