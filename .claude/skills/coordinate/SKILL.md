---
name: coordinate
description: Koordination paralleler Claude-Sessions im Repo - beim Session-Start pruefen, ob andere Sessions laufen, eine leitende Session mit Merge-Hoheit bestimmen, 15-Minuten-Statusrunde der Leitung, direkte Absprache der Sessions untereinander mit Info an die Leitung, Release-Umfang vom Owner abfragen, Sonderfall von der Leitung per start_session gestartete Unter-Sessions (keine Statusrunde). Nutzen bei JEDEM Session-Start (der SessionStart-Hook erinnert daran) und sobald eine weitere Session dazukommt.
---

# Parallele Sessions koordinieren (`/coordinate`)

Owner-Regel (2026-10-23): Es gibt immer **genau eine leitende Session** mit Merge-Hoheit, die alle anderen zentral koordiniert. Anlass: Beim gemeinsamen Release 2026-10-23 stand die Arbeit zweimal still, weil Sessions untätig aufeinander warteten und sich darauf verließen, dass die Leitung Infos weiterreicht.

## 1. Beim Start: Lage prüfen

- **Nie im Bypass-Modus koordinieren** (Owner-Regel 2026-10-23): Eine Session mit „Bypass permissions“ kann sich mit den übrigen Sessions nicht austauschen. Deren Nachrichten an sie hält die Empfänger-Session zur Freigabe fest, bis sie ablaufen, und sie kommen nie an (der Absender bekommt einen `[Cross-session delivery notice]` „held“/„not approved before expiry“). Den eigenen Modus kann Claude nicht selbst umstellen → **anhalten** und den Owner bitten, auf „Auto“ zu wechseln (Shift+Tab bzw. Modus-Auswahl in VS Code), danach die Anmeldung wiederholen. Der SessionStart-Hook `.claude/hooks/session_coordination.ps1` erinnert daran, der PreToolUse-Hook `.claude/hooks/coordination_mode_guard.ps1` sperrt `ListAgents`/`SendMessage` im Bypass-Modus (der SessionStart-Hook sieht den Modus nicht).
- `ListAgents` (deferred → per `ToolSearch` laden) + `ReadNotifications`.
- **Keine anderen Sessions** → du bist Leitung, sobald eine dazukommt. Weiter mit deiner Aufgabe.
- **Andere Sessions laufen** → per `SendMessage` an alle: „Wer leitet? Woran arbeitest du, welche Dateien/Pakete fasst du an?“ — mit der ausdrücklichen Bitte um Antwort.

## 2. Leitung bestimmen

- Ernennt der Owner eine Session („du bist die Leitung“), gilt das vor allem Folgenden: Sie folgt `/leitung`, eine bisherige Leitung übergibt an sie.
- Gibt es schon eine Leitung, bleibt sie es. Die neue Session meldet sich bei ihr an: Aufgabe, berührte Dateien, Worktree und Branch.
- Gibt es keine, übernimmt die **am längsten laufende** Session (`ListAgents` → „started … ago“) und teilt das allen mit.
- Wird die Leitung beendet, übergibt sie vorher ausdrücklich an eine andere Session, samt Stand: Integrations-Branch, offene Merges, laufende Tests.

## 3. Pflichten der Leitung

- **Merge-Hoheit:** Nur die Leitung merged auf den Integrations-Branch, fährt die Schluss-Gates, pusht `main` und taggt. Niemand sonst pusht oder taggt.
- **`main` und `v*`-Tags sind geschützt** (GitHub-Rulesets): kein Force-Push, kein Löschen, kein Tag-Verschieben, auch nicht für den Owner (diese Sperren haben bewusst keinen Bypass); die Leitung pusht direkt per Admin-Bypass der CI-Pflicht. Ein fehlerhafter Tag wird nie verschoben → neue Patch-Version. Nach jedem Push die CI-Ampel prüfen (`scripts/check_ci_status.ps1`). Ein Leck in einem schon gepushten Text lässt sich nicht still zurückholen → vor dem Push prüft `privacy_lint -Outgoing` Commits und neue Tags; rot ⟹ Text korrigieren, nie `--no-verify`.
- **Fremd-PRs:** Nie auschecken, bevor der Diff gelesen ist (Hooks sehen `.env`). Die Leitung schreibt `gh pr diff <nr>` in eine Datei, fährt darauf `privacy_lint -TextFile <datei>` und die Modell-Prüfung (die Denylist fehlt in der CI, Fork-Läufe sehen sie nie). Erst danach gibt sie den Lauf frei. Merge nur per Squash mit eigenem, geprüftem Text, nach Bestätigung des Owners. Antworten im PR sind öffentlich: keine Live-Werte, auch nicht zur Begründung.
- **Statusrunde alle 15 Minuten** per `CronCreate` (Off-Minuten, z. B. `7,22,37,52 * * * *`, `recurring: true`):
  - zuerst `ListAgents`: Sessions, die noch nicht angemeldet sind, sofort anschreiben — wer leitet, welche Regeln gelten; Aufgabe, Dateien und Worktree erfragen. Sessions können still dazukommen.
  - jede Session mit offener Release-Arbeit anschreiben. Fertige Sessions nur, wenn eine neue Information ihre Arbeit berührt: ein Test-Befund in ihrem Bereich, ein Merge-Konflikt mit ihren Dateien, eine geänderte Entscheidung. Sie sollen dann prüfen, ob sie nacharbeiten müssen, und antworten. Fertige Sessions bleiben bis zum Tag erreichbar.
  - Pflicht-Fragen:
    - Was ist dein Stand?
    - Wartest du auf etwas — ja oder nein? Wenn ja: worauf, von wem?
  - ausdrücklich verlangen, **in jedem Fall** zu antworten, auch mit „unverändert“
  - dem Owner danach kurz den Stand melden
  - nach dem Tag mit `CronDelete` beenden
- **Release-Umfang:** Vor dem Zusammenführen fragt die Leitung den Owner (`AskUserQuestion`), welche fertigen Arbeiten in das gemeinsame Release kommen. Nicht selbst festlegen.
- **Engpässe lösen:** Wartet eine Session auf eine andere, bringt die Leitung beide direkt zusammen. Belegt die Leitung einen Substrat-Platz, den sie gerade nicht braucht (Parallel-Limit in `scripts/dev/bootstrap_test_n8n.ps1`), gibt sie ihn frei.
- Ablauf danach wie gewohnt: Merge-Kette → freie Gates auf dem Gesamtstand (Standard: Integrations-Branch pushen, `gh workflow run free-gates.yml --ref <branch>`; zusätzlich lokal `scripts/dev/run_free_gates.ps1 -Reset -Parallel` mit eigenen Containern nur bei geänderten Test-Skripten, Bot-Anschluss oder Install-Kern (dann `-Cold`) und vor einem Release, vorher per `docker ps` prüfen, ob ein Substrat-Platz frei ist, sonst den Halter direkt um Freigabe bitten; reine Doku-Merges brauchen keinen Lauf) → bezahlte Suiten im Owner-Fenster → annotierter Tag mit englischen Release-Notes (öffentlich: was sich geändert hat, keine Live-Werte; `git tag -a vX.Y.Z --cleanup=whitespace -F <datei>`) → alle Sessions benachrichtigen → Aufräumen.

## 4. Pflichten der übrigen Sessions

- **Direkt untereinander absprechen**, nicht über die Leitung: wer welche Datei bzw. welchen Testfall anfasst, wer auf wessen Commit aufsetzt, wer welchen Substrat-Platz nutzt.
- **Die Leitung immer informieren**, was abgesprochen wurde: kurze Kopie mit Ergebnis, Hashes, wer was macht.
- Jede Statusfrage der Leitung beantworten, auch mit „unverändert“. Commit-Hashes an die Leitung und an betroffene Sessions schicken.
- Fertig heißt: committet, Gates grün, Hash an die Leitung. Danach nichts mehr ohne Absprache committen. Eigene Container abräumen; den eigenen Worktree erst nach dem Tag.

## 5. Von der Leitung gestartete Sessions

Startet die Leitung Unter-Sessions selbst (`start_session`, Desktop-App), kennt die App die Verwandtschaft; die Leitung muss sie nicht über Rundfragen einsammeln:

- **Die 15-Minuten-Statusrunde (§3) entfällt** für diese Sessions, ebenso das `CronCreate`. Die App meldet der Leitung **jedes Zug-Ende** einer Unter-Session als Notiz (Auszug aus deren Abschlussbericht); die Leitung wird damit geweckt und muss nicht nachfragen.
- **Überblick:** `list_sessions {linked:true}` (Tool `mcp__ccd_session_mgmt__list_sessions`) zeigt alle verwandten Sessions mit Status, Titel, Ordner und Branch. Nachrichten gehen per `SendMessage` an die **Session-ID** (`local_…`), nicht an den Namen.
- **IDs merken:** Sessions können sich umbenennen (der Name in `ListAgents` ändert sich dann); die ID bleibt stabil. Die Leitung behält darum die ID jeder gestarteten Session im Gedächtnis (und in der Übergabe-Plandatei) und adressiert nur darüber.
- **Kein Rundruf:** Eine gestartete Unter-Session kennt ihre Leitung aus dem Brief und fragt nicht alle Sessions an (§1 entfällt); mit Sessions, deren Dateien sie berührt, spricht sie sich direkt ab (§4).
- **Remote Control:** Über Remote Control verweigert die App den Start einer Session. Die Leitung sagt das dem Owner sofort; er tippt dann eine Nachricht in der Desktop-App.
- **Owner-Freigaben:** Der Owner bestätigt jedes Paket vor dem Merge. Eine Freigabe, die eine andere Session weiterreicht, fragt die Leitung bei ihm gegen. Unter-Sessions melden Entscheidungen des Owners im Wortlaut an die Leitung; ändert sich ein bestätigter Stand danach, sieht der Owner ihn vor dem Merge erneut.
- **Offene Läufe:** Grüne GitHub-Läufe und fertige Routinen wecken niemanden von selbst. Wer auf einen GitHub-Lauf ohne PR wartet, startet `gh run watch <id> --exit-status` als Hintergrund-Befehl, das weckt die Session beim Ende; fertige Routinen prüft die Leitung bei jedem eigenen Zug und meldet das Ergebnis der wartenden Session. Sonstige Dauerabfragen gibt es nicht.
- **Fragen an den Owner laufen über die Leitung:** Eine Unter-Session schickt ihre Frage per `SendMessage` an die Leitung statt per `AskUserQuestion`; die Leitung fragt den Owner und gibt die Antwort im Wortlaut zurück. Am Zug-Ende fragt sie nie nach Merge, Push oder Release und stellt auch sonst keine Frage an den Owner, sie endet mit dem Bericht an die Leitung. Ausnahme: Was die App nur in der Session selbst annimmt (Plan-Freigabe, Berechtigungs-Karte); die Session meldet das der Leitung, und die Leitung sagt dem Owner, wo er tippen muss. Die Leitung schreibt diese Regel in jeden Brief und trägt die Session ein (`scripts/register_sub_session.ps1`); der Hook `.claude/hooks/enforce_sub_session_questions.ps1` lehnt direkte Fragen dann ab.
- **Sprint-Ende:** Nach dem Merge schlägt die Leitung die fertigen Unter-Sessions gesammelt zum Archivieren vor und archiviert sie auf das Ja des Owners (`archive_session`: stoppt die Session, räumt ihren Worktree ab, wiederherstellbar). Vorher muss alles aus ihnen gemerged sein und ihr Nachlauf erledigt. Löschen (`delete_session`) nur auf ausdrücklichen Wunsch des Owners. Danach räumt die Leitung per `docker ps` die Container fertiger Sessions ab, auch `db_test`-Container (die bleiben nach dem Session-Ende stehen).
- **Weiter gilt für alle Sessions:** Merge-Hoheit (§3) und Release-Umfang beim Owner bleiben bei der Leitung, und nie im Bypass-Modus (§1).
- **Unabhängig vom Owner gestartete Sessions** (eigenes Fenster, nicht von der Leitung per `start_session` erzeugt) folgen unverändert §1–§4: Anmeldung bei der Leitung, Statusrunde alle 15 Minuten, direkte Absprache mit Info an die Leitung. Kommt neben gestarteten Unter-Sessions eine solche Session dazu, läuft die Statusrunde für sie weiter (`ListAgents` zeigt, wer nicht in `list_sessions {linked:true}` steht).
