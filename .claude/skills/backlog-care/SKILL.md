---
name: backlog-care
description: Zweiwöchentliche Routine - pflegt das private Backlog (.local/BACKLOG.md) als Vorschlagsliste - erkennt erledigte Punkte (git log, Code), Doppelungen und veraltete Trigger und schlägt eine Prioritätsreihenfolge vor. Ändert nichts, Bericht als privates Artefakt. Nutzen für den geplanten Lauf oder auf Zuruf "räum das Backlog auf".
---

# Backlog-Pflege (`/backlog-care`)

Das Backlog liegt privat in .local/BACKLOG.md im Haupt-Checkout, nie im Repo. Es hat eine Regel: erledigte Punkte werden **gelöscht**, nicht durchgestrichen; nur bewusst Vertagtes und getriggerte Entscheidungen stehen dort. Diese Routine prüft, ob die Datei noch stimmt. Sie **schlägt vor**, der Owner entscheidet; die Datei änderst du nicht, nichts committen.

## Kosten-Politik

Owner-Entscheid 2026-11-02: Das Hauptmodell einer geplanten Aufgabe ist der App-Standard (Opus), also gehört die Fleißarbeit an **Sonnet-Unteragenten** (`Explore`, immer mit `model: "sonnet"`): die „Erledigt?“-Suche (Schritt 2) je Abschnitt der Liste, getrennt nach PRIO, Owner-Proben und DEFER. Sie liefern je Punkt Status und Beleg; Trigger, Doppelungen, Priorität und Bericht (Schritte 3–6) bewertest du selbst.

## Ablauf

1. **Stand:** im Haupt-Checkout `git fetch origin` (nur Lesen aus dem Netz), dann das Backlog aus der privaten Datei lesen und alles gegen `origin/main` prüfen (`git log origin/main`). Letzten Lauf finden: Das Datum steht im Titel des letzten Berichts-Artefakts `Backlog-Pflege …` (`Artifact`-Liste); fehlt es, 14 Tage nehmen.
2. **Erledigt?** Für jeden offenen Punkt Stichworte (Funktions-, Tabellen-, Workflow-Namen, Trigger-Text) nehmen und prüfen:
   - `git log origin/main --since=<letzter Lauf> --oneline` sowie `git log origin/main -S<Stichwort> --oneline` bzw. `--grep`;
   - im Code/Test nachsehen, ob die beschriebene Lücke noch besteht (Grep in `packages/`, `tests/`, `docs/`). Ein Commit mit passendem Wort allein reicht nicht: der Beleg ist der Code-Stand.
   - Ergebnis je Punkt: **erledigt** (Beleg: Commit + Datei), **teilweise** (was fehlt), **offen**, **unklar** (Grund).
3. **Getriggert?** Bei DEFER-Punkten den Trigger lesen und prüfen, ob er eingetreten ist (ein Datum, eine Version, ein Bedarf, der in Commits oder in der PRIO-Liste auftaucht). Eingetretene Trigger nach oben melden.
4. **Doppelungen und Widersprüche:** gleiche oder überlappende Punkte (auch zwischen PRIO, Owner-Proben und DEFER), Punkte, die einem Owner-Grundsatz in der Root-`CLAUDE.md` widersprechen, Punkte, die ein anderer Punkt schon enthält.
5. **Priorität:** Vorschlag für die Reihenfolge der PRIO-Liste. Kriterien in dieser Reihenfolge: Daten-Korrektheit/Sicherheit/Privatsphäre · von echten Nutzern gemeldeter Schmerz · schon vorbereitete Pläne · Aufwand (klein zuerst bei gleichem Nutzen) · Abhängigkeiten (was blockiert was). Je Punkt ein Satz Begründung. Bezahlte Suiten (Owner-Fenster) als Bündel nennen, weil sie Kontingent kosten.
6. **Formfehler:** Einträge ohne Trigger (DEFER braucht einen), durchgestrichene oder als „erledigt“ markierte Reste; echte Werte aus der privaten Datei im Bericht nie wiederholen.

**Falle:** Ein Hook sperrt jeden Shell-Befehl, in dem der Dateiname einer bezahlten Test-Suite steht (auch beim bloßen Suchen). Backlog-Punkte zu diesen Suiten deshalb mit dem Grep-Tool oder mit Stichworten ohne den Skript-Namen prüfen, nie eine Suite starten.

## Bericht

Privates Artefakt `Backlog-Pflege <Datum>` (Datum im Titel, siehe Schritt 1), einfache deutsche Sprache. Aufbau: Kurzfazit (x erledigt, y getriggert, z Doppelungen) · Tabelle **Löschvorschläge** (Punkt, Beleg) · **Trigger eingetreten** · **Doppelungen/Widersprüche** · **Prioritätsvorschlag** (neue Reihenfolge, Begründung) · **Formfehler**. Am Ende steht kein Knopf und keine Freigabe-Zeile (das Artefakt ist eine statische Seite, der Owner kann dort nichts anklicken). Schreibe stattdessen den Satz, den der Owner in einer neuen Sitzung im Repo sagt, z. B. „Setze den Bericht Backlog-Pflege vom <Datum> im privaten Backlog um: Löschungen laut Tabelle und neue Reihenfolge“, und nenne, welche Punkte er vorher streichen oder ändern soll. Selbst nichts ändern. Link ausgeben.
