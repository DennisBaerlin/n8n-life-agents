---
name: leitung
description: Macht diese Session zur Leit-Session – liest die gemeinsame Stand-Datei, verteilt Arbeit auf Unter-Sessions, bündelt Entscheidungen für den Owner, führt zusammen. Nutzen, sobald der Owner „du bist die Leitung“ oder „du leitest“ sagt oder /leitung aufruft. Nicht für Unter-Sessions.
---

# Leit-Session (`/leitung`)

Der Satz „du bist die Leitung“ reicht; alles Weitere steht hier, der Owner muss keine Datei nennen.

| Was | Wo |
|---|---|
| Arbeitsweise der Leitung (dauerhaft) | dieser Skill |
| Zusammenspiel der Sessions, Merge-Hoheit, Push-Regeln | `/coordinate`, gilt zusätzlich |
| Mechanik, Vorlagen, Fallgeschichten | `docs/reference/sessions.md` |
| Aktueller Stand: Sperren, Freigaben, Merge-Reihenfolge, Sessions, Container | `.claude/plans/leitung-stand.md` (gitignored, nur Haupt-Checkout, Vorlage §5) |

Das Repo ist öffentlich: Stand und private Anlässe gehören nie in diesen Skill.

## 1. Beim Start

1. **Modus:** Läuft die Session im Bypass-Modus, anhalten und den Owner um „Auto“ bitten (`/coordinate` §1).
2. **Eine Leitung zur Zeit:** Sprints von zwei bis drei Tagen laufen nacheinander; ein zweites großes Thema ist der nächste Sprint, keine zweite Leitung. Zeigt `ListAgents` schon eine Session mit der Marke `[Leitung]`, wird diese Session nicht Leitung, auch nicht auf Ernennung: Sie erinnert den Owner an die Regel und legt ihm die Karte mit den zwei Wegen vor, Übergabe an die bestehende Leitung (empfohlen) oder Pause bis zum Sprint-Ende (`/coordinate` §2 *Zweite Ernennung*).
3. **Ort:** Die Leitung arbeitet im Haupt-Checkout. Läuft die Session in einem Worktree, das dem Owner sagen; die Stand-Datei liegt trotzdem im Haupt-Checkout.
4. **Sichtbar machen:** Session anpinnen (`set_pinned`, „self“) und `[Leitung] <Thema>` nennen (`set_session_title`), auch wer erst unterwegs Leitung wird; bei Übergabe die Marke entfernen. Sie ist das Erkennungszeichen (`/coordinate` §2). Eigene Session-ID per `get_session` mit `self` ermitteln (nicht die Transkript-ID) und in die Stand-Datei schreiben.
5. **Stand lesen:** `.claude/plans/leitung-stand.md`, die eine Datei für alle Sessions; Themen-Dateien gibt es nicht. Fehlt sie, aus der Vorlage in §5 anlegen. Schreiben darf nur die Leitung; jede andere Session liest und hält sich an Sperren und Merge-Reihenfolge. Ist `Nachschau fällig:` abgelaufen, jetzt ausführen (§4.1).
6. **Lage prüfen:** `ListAgents`, `ReadNotifications`, `list_sessions {linked:true}`, `git status`, `.\scripts\check_ci_status.ps1`.
7. **Melden:** in wenigen Sätzen an den Owner: was offen ist, was als Nächstes dran ist, was der Owner entscheiden muss. Nichts aus dem Stand ohne Auftrag beginnen.

## 2. Während der Arbeit

- **Hauptüberlegung bei jedem Arbeitspaket**: zuerst die Aufgabe klären, dann ausdrücklich prüfen, wie sie sich auf mehrere Unter-Sessions verteilen lässt. Der Schnitt folgt den Dateigruppen (keine zwei Sessions an denselben Dateien); eine einzige Session braucht eine Begründung.
- **Verteilen:** Was wenige Tool-Aufrufe braucht, macht die Leitung selbst. Eigenständige Aufgaben bekommen je eine Unter-Session (`start_session`, „fresh“, eigener Worktree); Ohne gemeinsame Dateien parallel. Starts nur auf getippte Owner-Nachricht: Zuschnitt + Start-Frage in einen Zug, vor jedem Explore (sessions.md *Start verweigert*). Direkt danach `.\scripts\register_sub_session.ps1 -Id <local_…>` (Wirkung → `docs/reference/sessions.md` *Sessions ansprechen*). **Denkstufe:** `start_session` kürzt `effort` still auf die der Leitung → nach dem Start `set_session_effort`, mit `get_session` prüfen (*Denkstufe setzen*).
- **Brief:** Inhalt nach `docs/reference/sessions.md` *Brief an eine Unter-Session*. Er nennt Ausgangs-Commit, echte Session-ID der Leitung und ihren ListAgents-Titel. Nachrichten gehen an den ListAgents-Titel, nicht an den `name` aus `start_session`; Folge-Aufträge je Session in einer Nachricht, vor unbeaufsichtigten Läufen alle Folgerunden schon im Brief.
- **Entscheidungen gebündelt:** Alles, was der Owner entscheiden muss (Paket-Freigaben, Release-Umfang, Fragen der Unter-Sessions, Verbesserungen), sammelt die Leitung in der Stand-Datei und legt es einmal am Tag als eine Karten-Reihe vor, jede Karte mit Folgen und Empfehlung, dazu derselbe Inhalt als nummerierter Klartext in der Nachricht (die Handy-App zeigt Karten oft nicht). Sofort nur ein Blocker für mehrere Sessions. Meldungen der Unter-Sessions nicht einzeln weitergeben: Jede Nachricht an den Owner endet mit der Liste „Wartet auf dich: …“ (Fragen, wartende Sessions mit Link); ein Punkt bleibt darin, bis er beantwortet ist.
- **Freigaben:** Merge, Push und Release nur auf das eigene Wort des Owners im Chat der Leitung, mit Umfang (`/coordinate` §3 *Push-Regeln*); Wortlaut, Datum und Chat kommen in `## Owner-Freigaben`. Prüfungen werden nicht übersprungen.
- **Stand sofort festhalten:** Session-ID, Branch, Container, Sperren, Zusagen zwischen Sessions und jede Owner-Entscheidung im Wortlaut kommen gleich in die Stand-Datei, nicht erst am Ende (Pflege → `docs/reference/sessions.md` *Stand-Datei*).
- **Modell sparsam:** Mechanische Pakete (Doku, Tests, Werkzeug) laufen als Unter-Session auf Sonnet (`model` im `start_session`), Opus nur für Design und Architektur; wenige parallele Opus-Sessions. Je Sprint Qualität (Nacharbeit, rote Gates) und Tempo der Sonnet-Pakete in der Stand-Datei notieren (Memory `effort-medium-probe`).
- **Schlank bleiben:** Große Dateien und lange Protokolle lesen Unter-Sessions, die Leitung bekommt das Ergebnis.
- **Plan-Freigabe:** Planende Unter-Sessions melden die Plan-Datei aus ihrem Worktree statt einer Plan-Karte (`/feature` §2); die Leitung kopiert sie ins Haupt-Checkout, prüft `Plan-Reviewer:` und `Denkstufe:` und legt den Plan selbst vor (`docs/reference/sessions.md` *Plan-Freigabe*).
- **Warten:** auf GitHub-Läufe per `gh run watch` im Hintergrund, der Owner soll nicht nachfragen müssen (`/coordinate` §5 *Offene Läufe*).
- **Über Remote Control:** keine Seitenfenster, also Bilder und Diffs als Datei in den Chat.
- **Nur Belegtes behaupten:** Eine Regel oder Zusage erst schreiben, wenn sie ausprobiert ist. Was nicht geprüft wurde, steht als ungeprüft im Bericht.

## 3. Arbeitsweise weiterentwickeln

Diese Anleitung soll mit jedem Sprint besser werden. Auslöser: Der Owner korrigiert die Arbeitsweise, dieselbe Reibung tritt zweimal auf oder eine Regel erweist sich als falsch.

1. **Festhalten:** Jede Reibung, jeder eigene Fehler und jede Owner-Korrektur kommt sofort als Zeile in die Stand-Datei unter `## Verbesserungen`: was passiert ist, die Ursache, ein Vorschlag mit Ziel-Adresse (Skill, Hook, Skript). Leitfragen: Wo stand die Arbeit still? Was musste der Owner zweimal sagen oder selbst bemerken? Was hat Kontingent gekostet, ohne zu helfen?
2. **Vorlegen:** gebündelt über `/retro-bundle` bzw. in der Prozess-Session am Sprint-Ende (§4), höchstens drei Vorschläge je Runde, einzeln zur Entscheidung; was sich sonst im selben Sprint wiederholen würde, sofort (§2 *Entscheidungen gebündelt*).
3. **Richtige Adresse wählen (ein Fakt, eine Adresse):** Alltag der Leitung → hier; Zusammenspiel der Sessions → `/coordinate`; Mechanik und Fallgeschichten → `docs/reference/sessions.md`; Ablauf einer Aufgabenart → deren Skill; gilt für jede Session → Root-`CLAUDE.md`; hartes Verbot → Hook, nur nach ausdrücklicher Owner-Freigabe.
4. **Umbauen statt anhängen:** Die Regel ersetzt, was ihr widerspricht. Anlass nur nennen, wenn die Regel sonst unverständlich wäre, und dann ohne Privates.
5. **Sichern:** auf das Ja des Owners committen, unabhängig von laufenden Paketen. Laufende Unter-Sessions bekommen die Regel per `SendMessage`.

## 4. Sprint-Ende und Übergabe

Ein Sprint endet mit dem Tag, der Archivierung aller Unter-Sessions, Worktrees, Branches und Container und der Prozess-Session; erst dann startet die nächste Leitung.

1. **Release-Nachschau:** Nach dem Tag in der Stand-Datei `Nachschau fällig: <Tag + 24 h>` eintragen (keine geplante Aufgabe: Auto-Modus lehnt sie ab). Ist die Zeit um: `/live-findings` lesend, Schritte 1–3, letzte 24 Stunden, privat berichten, Zeile streichen.
2. **Aufräumen:** Fertige Unter-Sessions gesammelt zum Archivieren vorschlagen und auf das Ja des Owners archivieren (`archive_session`); dann Worktrees, Branches, Container (`scripts/dev/docker_cleanup.ps1`) und `.\scripts\register_sub_session.ps1 -Clear`. Reihenfolge und Grenzen → `docs/reference/sessions.md` *Sprint-Ende*.
3. **Prozess-Session:** Nach dem Aufräumen, nicht erst am Freitag: Die Leitung schlägt dem Owner eine eigene Session vor (`start_session`, „fresh“, eigener Worktree), die auf sein getipptes Wort startet; sie wird nicht registriert (`register_sub_session.ps1`), die Session fragt den Owner direkt. Der Brief nennt die Verbesserungs-Zeilen des Sprints, die Feedback-Memorys seit dem letzten Sprint-Ende und die Leitfragen aus §3.1. Die Session bündelt nach Ursache wie `/retro-bundle`, legt höchstens drei Vorschläge mit Empfehlung und Ziel-Adresse (§3.3) als Karten vor und baut die freigegebenen selbst ein; erledigte Zeilen streicht danach die Leitung. Merge und Push nach `/coordinate` §3.
4. **Übergabe:** Stand-Datei und Memory so aktualisieren, dass eine neue Session ohne dieses Gespräch weitermachen kann; auf neue Session oder `/clear` hinweisen (Root-`CLAUDE.md` *Entwicklungszyklus*). Die nächste Leitung startet der Owner mit dem einen Satz.

Routinen daneben: `/retro-bundle` (Freitag, bündelt die Verbesserungs-Zeilen), `/session-hygiene` (Sonntag, idle Sessions, Branches, Worktrees, Docker), `/paid-run` (monatlich, bezahlten Sammel-Lauf vorbereiten).

## 5. Vorlage der Stand-Datei

```markdown
# Stand der Leitung (<Datum>)

## Sperren (Push/Merge/bezahlte Suiten: was, seit wann, Owner-Wortlaut)
## Owner-Freigaben (Wortlaut, Datum, Chat)
## Merge-Reihenfolge (Session, Branch, Hash, gesperrte Dateien, Gates auf GitHub)
## Sessions (ID, Titel, Branch, Container, Stand)
## Container (Name, Port, Halter)
## Verbesserungen (was passiert ist, Ursache, Vorschlag + Ziel-Adresse)
```
