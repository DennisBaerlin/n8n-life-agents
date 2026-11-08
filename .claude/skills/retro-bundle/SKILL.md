---
name: retro-bundle
description: Wöchentliche Routine (Freitag) – bündelt Verbesserungs-Zeilen der Stand-Datei und neue Feedback-Memorys nach Ursache, höchstens drei Vorschläge mit Empfehlung und Ziel-Adresse. Ändert nichts, Bericht als privates Artefakt. Nutzen für den Wochenlauf oder auf Zuruf „Retro bündeln“.
---

# Retro-Bündel (`/retro-bundle`)

Verbesserungs-Zeilen bleiben sonst unbearbeitet in den Stand-Dateien liegen. Diese Routine bündelt sie nach Ursache und macht daraus wenige entscheidbare Karten. Du liest und schlägst vor; Dateien änderst du nicht, nichts committen, kein `SendMessage` an andere Sessions außer der Anmeldung bei der Leitung (`/coordinate` §1).

## Harte Grenzen

- Nur lesen: Stand-Dateien, Memory, Git. Kein Anlegen von Regeln, Hooks oder Skills; Umsetzen tut eine Session auf das Wort des Owners.
- Stand-Dateien und Memory sind privat. Der Bericht kommt nie ins Repo, nur als privates Artefakt (`Artifact`, Standard = privat, nicht teilen). Keine privaten Werte, Namen, Lebensumstände oder Session-IDs wiederholen.
- Grep mit Klammer- oder `**`-Glob meldet bei Fehlern still „keine Treffer“: Null-Treffer immer ohne Glob gegenprüfen.

## Kosten-Politik

Ein Sonnet-Unteragent (`Explore`) sammelt alle Verbesserungs-Zeilen und neuen Feedback-Memorys und listet je Zeile Datum, Ursache, Vorschlag und Ziel-Adresse wörtlich auf; den Memory-Ordner-Pfad (System-Prompt, Abschnitt *Memory*) im Prompt mitgeben. Gruppieren, Gegenprüfen, Auswahl und Bericht (Schritte 3–6) machst du selbst.

## Ablauf

1. **Letzter Lauf:** Datum (ISO) im Titel des letzten Artefakts `Retro-Bündel …` (`Artifact`-Liste); fehlt es, 7 Tage nehmen. Karten des letzten Berichts merken (Schritt 5).
2. **Sammeln:**
   - Abschnitt, dessen Überschrift mit `## Verbesserungen` beginnt (Klammerzusatz egal), in `.claude/plans/leitung-stand.md` im Haupt-Checkout; Themen-Dateien `leitung-*-stand.md` laufen aus, solange vorhanden mitlesen. Worktrees haben keine. Fehlender Abschnitt = 0 Zeilen; „Erledigt“-Zeilen zählen als Streichkandidaten.
   - Memory: Einträge vom Typ `feedback` per Grep auf `type: feedback` im Projekt-Memory-Ordner finden (der Index `MEMORY.md` nennt Typ und Datum nicht); Datum = `metadata.modified` ≥ letzter Lauf (ISO, inklusive).
3. **Bündeln:** gleiche Ursache = ein Bündel, auch bei verschiedenem Wortlaut und Quelle. Je Bündel: wie oft, welche Quellen, Ursache in einem Satz.
4. **Schon erledigt?** Jedes Bündel gegen den heutigen Stand prüfen = `main` plus Branches, die in `leitung-stand.md` unter Merge-Reihenfolge stehen (Skill, Hook, Skript, Root-`CLAUDE.md`, per Grep). Steht die Regel schon auf `main`: Streichkandidat. Liegt sie in so einem Branch: Karte „Branch mergen“, nicht „Regel schreiben“.
5. **Auswählen:** höchstens drei Karten (weniger ist erlaubt), Reihenfolge der Wichtigkeit: Daten-/Geldfehler, Wiederholung (≥ 2 Quellen), verlorenes Kontingent, Owner musste es zweimal sagen. Je Karte Empfehlung und genau eine Ziel-Adresse nach „ein Fakt, eine Adresse“ (`/leitung` §3): Alltag der Leitung → `/leitung`; Zusammenspiel der Sessions → `/coordinate`; Ablauf einer Aufgabenart → deren Skill; gilt für jede Session → Root-`CLAUDE.md`; hartes Verbot → Hook (nur mit ausdrücklicher Freigabe); wiederkehrende Handarbeit → Skript; Wrapper-Text einer geplanten Aufgabe (liegt außerhalb des Repos, Tool `mcp__scheduled-tasks__update_scheduled_task`); Zustandsnotiz (keine Regel) → Memory. Die Regel ersetzt Widersprechendes, statt angehängt zu werden. Vorlauf-Abgleich: Karten des letzten Berichts, die noch offen sind, einmal als „offen seit <Datum>“ wiederholen, nicht neu bewerten.
6. **Rest:** alles Übrige als Liste „nicht umsetzen, weil …“ (einmalig, schon abgedeckt, zu selten, Kosten > Nutzen).

## Bericht

Privates Artefakt `Retro-Bündel <Datum ISO>`, einfache deutsche Sprache. Aufbau: Kurzfazit (x Zeilen gelesen, y Bündel, z Karten) · Karten (Problem, Beleg als Datei:Zeile, Branch oder Hash, Empfehlung, Ziel-Adresse, Aufwand klein/mittel/groß) · „offen seit“ · Liste „nicht umsetzen, weil …“ · Streichkandidaten als Datei:Zeile · Nicht geprüft. Kein Knopf: Schreibe den Satz, den der Owner sagt, z. B. „Setze Karte 1 und 3 aus dem Retro-Bündel vom <Datum> um“. Link ausgeben.
