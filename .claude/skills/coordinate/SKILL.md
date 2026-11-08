---
name: coordinate
description: Koordination paralleler Claude-Sessions – beim Start Stand-Datei und Lage prüfen, die eine Leitung mit Merge-Hoheit kennen, Sperren und Merge-Reihenfolge einhalten, direkte Absprache mit Info an die Leitung. Nutzen bei jedem Session-Start und sobald eine Session dazukommt.
---

# Parallele Sessions koordinieren (`/coordinate`)

Es gibt genau eine leitende Session mit Merge-Hoheit (`/leitung`); alle anderen arbeiten auf eigenen Branches und melden ihr Ergebnis. Sessions warten nicht untätig aufeinander und verlassen sich nicht darauf, dass die Leitung Infos weiterreicht. Mechanik, Vorlagen und Fallgeschichten: `docs/reference/sessions.md`.

## 1. Beim Start: Lage prüfen

- **Bypass-Modus:** Eine Session mit „Bypass permissions“ kann sich mit den übrigen nicht austauschen → anhalten und den Owner bitten, auf „Auto“ zu wechseln, danach die Anmeldung wiederholen (`docs/reference/sessions.md` *Bypass-Modus*).
- **Stand-Datei lesen:** `.claude/plans/leitung-stand.md` im Haupt-Checkout (gitignored) ist die eine Datei für alle Sessions. Jede Session liest sie beim Start und hält sich an `## Sperren` und `## Merge-Reihenfolge`; schreiben darf nur die Leitung. Zusagen zwischen Sessions gelten erst, wenn sie dort stehen. Fehlt die Datei, gibt es keine Leitung (§2).
- `ListAgents` (deferred → per `ToolSearch` laden) + `ReadNotifications`.
- **Keine anderen Sessions** → du bist Leitung, sobald eine dazukommt. Weiter mit deiner Aufgabe.
- **Andere Sessions laufen** → bei der Leitung anmelden: Aufgabe, berührte Dateien, Worktree und Branch (Titel `[Leitung] <Thema>` in `ListAgents`). Ohne Leitung per `SendMessage` an alle: „Wer leitet? Woran arbeitest du, welche Dateien fasst du an?“ (Antwortpflicht §4).

## 2. Leitung bestimmen

- **Eine Leitung zur Zeit:** Sprints von zwei bis drei Tagen laufen nacheinander; ein zweites großes Thema ist der nächste Sprint, keine zweite Leitung. Höchstens ein Integrations-Branch ist offen.
- Ernennt der Owner eine Session („du bist die Leitung“) und läuft keine Leitung, gilt das vor allem Folgenden: Sie folgt `/leitung`, eine bisherige Leitung übergibt an sie, samt Stand-Datei, Integrations-Branch, offenen Merges und laufenden Tests.
- **Leitung erkennen:** Titel mit der Marke `[Leitung] <Thema>` (`/leitung` §1); keine andere Session trägt sie. Die bestehende Leitung ist immer die, die zuerst da war.
- **Zweite Ernennung:** Zeigt `ListAgents` schon eine Session mit der Marke, wird die ernannte Session nicht Leitung. Sie erinnert den Owner an die Regel und legt ihm eine Karte mit zwei Wegen vor: (a) empfohlen: die Aufgabe per `SendMessage` (Aufgabe, Dateien) an die bestehende Leitung übergeben, die entscheidet, ob sie als Paket in den laufenden Sprint passt oder als nächster Sprint in der Stand-Datei vorgemerkt wird; diese Session arbeitet dann höchstens als Unter-Session unter ihr; (b) diese Session pausiert bis zum Sprint-Ende und wird dann die nächste Leitung.
- Gibt es keine und keine Stand-Datei, übernimmt die am längsten laufende Session (`ListAgents` → „started … ago“) und teilt das allen mit.
- Wird die Leitung beendet, übergibt sie vorher ausdrücklich an eine andere Session.

## 3. Pflichten der Leitung

- **Merge-Hoheit:** Nur die Leitung merged auf den Integrations-Branch, fährt die Schluss-Gates, pusht `main` und taggt. Auf lokalem `main` landet nichts außer durch die Leitung, auch kein Doku-Commit; niemand sonst pusht oder taggt.
- **Push-Regeln:** Vor jedem Push auf `main` steht ein grüner `free-gates`-Lauf auf GitHub (Linux) auf dem Integrations-Branch; lokale Windows-Gates sehen Linux-Fehler nicht. Die bezahlten Fall-IDs werden vor dem Push gesammelt und dem Owner als eine Liste genannt. Das Owner-Wort zu Merge oder Push nennt den Umfang (welche Branches, welche Hashes); ein „Ja“ ohne Umfang gilt nur für das, was die Leitung ihm unmittelbar davor als Liste genannt hat. Ablauf und Push-Sperre: `docs/reference/sessions.md` *Release-Ablauf*.
- **Geschützte `main` und `v*`-Tags** (Rulesets → `CONTRIBUTING.md` *Branch protection*): Push per Admin-Bypass der CI-Pflicht, danach die CI-Ampel prüfen (`scripts/check_ci_status.ps1`). Ein fehlerhafter Tag wird nicht verschoben → neue Patch-Version.
- **Fremd-PRs:** nie auschecken, bevor der Diff gelesen und privacy-geprüft ist; Merge nur per Squash nach Bestätigung des Owners (`docs/reference/sessions.md` *Fremd-PRs*).
- **Statusrunde** nur für vom Owner gestartete Sessions, alle 15 Minuten per `CronCreate`, nach dem Tag `CronDelete` (`docs/reference/sessions.md` *Statusrunde*). Für Unter-Sessions der Leitung entfällt sie (§5).
- **Release-Umfang:** Vor dem Zusammenführen fragt die Leitung den Owner, welche fertigen Arbeiten in das Release kommen; gebündelt mit den übrigen Entscheidungen (`/leitung` §2).
- **Engpässe lösen:** Wartet eine Session auf eine andere, bringt die Leitung beide direkt zusammen. Substrat-Plätze verteilt und reserviert die Leitung (`docs/reference/sessions.md` *Substrat-Plätze*).
- **Prüfläufe vor dem Bewegen von `main`:** `free-gates`, `ci` und `genericity` auf dem Integrations-Branch auf GitHub, auf Grün warten (`gh run watch` im Hintergrund).
- Danach: bezahlte Suiten im Owner-Fenster → Master-Image + Pin-Commit → Tag → Release-Nachschau → Sprint-Ende (`/leitung` §4).

## 4. Pflichten der übrigen Sessions

- **Direkt untereinander absprechen**, nicht über die Leitung: wer welche Datei bzw. welchen Testfall anfasst, wer auf wessen Commit aufsetzt, wer welchen Substrat-Platz nutzt.
- **Die Leitung immer informieren**, was abgesprochen wurde: kurze Kopie mit Ergebnis, Hashes, wer was macht. Sie trägt es in die Stand-Datei ein; erst dann gilt es.
- Jede Nachricht einer anderen Session beantworten, auch als Leitung: mindestens „angekommen“ und was daraus folgt, eine Statusfrage auch mit „unverändert“; sonst wartet die andere Seite.
- Fertig heißt: committet, Gates grün, Hash an die Leitung. Danach nichts mehr ohne Absprache committen. Eigene Container abräumen; den eigenen Worktree erst nach dem Tag.

## 5. Von der Leitung gestartete Sessions

Startet die Leitung Unter-Sessions selbst (`start_session`, Desktop-App), kennt die App die Verwandtschaft:

- **Keine Statusrunde:** Die App meldet der Leitung jedes Zug-Ende einer Unter-Session als Notiz; die Leitung wird damit geweckt und muss nicht nachfragen. Überblick per `list_sessions {linked:true}`.
- **Adressieren:** Nachrichten an Unter-Sessions gehen an den Titel aus `ListAgents`, nicht an den `name` aus `start_session`; die Stand-Datei hält ID und Titel jeder Session (`docs/reference/sessions.md` *Sessions ansprechen*).
- **Kein Rundruf:** Eine gestartete Unter-Session kennt ihre Leitung aus dem Brief und fragt nicht alle Sessions an (§1 entfällt bis auf Bypass und Stand-Datei); mit Sessions, deren Dateien sie berührt, spricht sie sich direkt ab (§4).
- **Owner-Freigaben:** Der Owner bestätigt jedes Paket vor dem Merge. Eine Freigabe, die eine andere Session weiterreicht, fragt die Leitung bei ihm gegen. Unter-Sessions melden Entscheidungen des Owners im Wortlaut an die Leitung, die sie in `## Owner-Freigaben` einträgt; ändert sich ein bestätigter Stand danach, sieht der Owner ihn vor dem Merge erneut.
- **Offene Läufe:** Grüne GitHub-Läufe und fertige Routinen wecken niemanden von selbst. Wer auf einen GitHub-Lauf ohne PR wartet, startet `gh run watch <id> --exit-status` als Hintergrund-Befehl; fertige Routinen prüft die Leitung bei jedem eigenen Zug und meldet das Ergebnis der wartenden Session. Sonstige Dauerabfragen gibt es nicht.
- **Fragen an den Owner laufen über die Leitung:** Eine Unter-Session schickt ihre Frage per `SendMessage` an die Leitung statt per `AskUserQuestion`; die Leitung sammelt sie für die gebündelte Vorlage (`/leitung` §2) und gibt die Antwort im Wortlaut zurück. Am Zug-Ende keine Frage an den Owner (auch nicht nach Merge, Push, Release), nur der Bericht an die Leitung. Ausnahme Berechtigungs-Karte: melden, die Leitung sagt dem Owner, wo er tippt. Pläne als Datei im eigenen Worktree (`/feature` §2). Regel in jeden Brief, Session eintragen (`scripts/register_sub_session.ps1`); Hook `.claude/hooks/enforce_sub_session_questions.ps1` lehnt direkte Fragen ab.
- **Sprint-Ende:** Archivieren und Aufräumen der Unter-Sessions → `/leitung` §4.
- **Weiter gilt für alle Sessions:** Merge-Hoheit und Push-Regeln (§3) bleiben bei der Leitung, kein Koordinieren im Bypass-Modus (§1).
- **Vom Owner selbst gestartete Sessions** folgen unverändert §1–§4 (Anmeldung, Statusrunde, Absprache mit Info an die Leitung); `ListAgents` zeigt, wer nicht in `list_sessions {linked:true}` steht.
