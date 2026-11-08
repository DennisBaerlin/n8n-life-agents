# Referenz zu `/coordinate` und `/leitung` — Stand-Datei, Release-Ablauf, Briefe, Fallgeschichten

On-demand lesen; **keine Regeln** (die stehen in den beiden Skills). Hier liegt die Mechanik hinter den Regeln, die Vorlagen und die Fälle, aus denen die Regeln entstanden sind.

## Stand-Datei

`.claude/plans/leitung-stand.md` im Haupt-Checkout (gitignored) ist die eine Datei für alle Sessions eines Sprints. Es gibt keine Themen-Dateien daneben: Zwei Dateien hießen zwei Wahrheiten über Sperren und Reihenfolge. Nur die Leitung schreibt; jede andere Session liest sie beim Start und vor jedem Merge-Wunsch.

Pflichtabschnitte und was hineingehört:

| Abschnitt | Inhalt je Eintrag |
|---|---|
| `## Sperren` | Was gesperrt ist (Push, Merge, bezahlte Suiten), seit wann, Owner-Wortlaut, wer aufhebt |
| `## Owner-Freigaben` | Wortlaut, Datum, in welchem Chat (Leitung oder Unter-Session); eine Freigabe aus einem anderen Chat fragt die Leitung gegen |
| `## Merge-Reihenfolge` | Session, Branch, Hash, gesperrte Dateien, Stand der Gates auf GitHub (Lauf-ID, grün/rot); Zusagen zwischen Sessions stehen hier, nicht nur in Nachrichten |
| `## Sessions` | Session-ID (`local_…`), ListAgents-Titel, Branch, Container, Stand |
| `## Container` | Name, Port, Halter, Substrat-Platz |
| `## Verbesserungen` | was passiert ist, Ursache, Vorschlag mit Ziel-Adresse (Skill, Hook, Skript) |

Pflege: Session-ID, Branch, Container und jede Owner-Entscheidung im Wortlaut kommen sofort hinein, nicht am Ende. Erledigtes fliegt raus; die Datei beschreibt nur das Jetzt. Geändert wird sie nur mit dem Edit-Werkzeug, nie per Zeilennummer oder `Add-Content` (Encoding-Falle in PowerShell 5.1, `.claude/rules/powershell.md`).

`.claude/plans/` gilt nur im Haupt-Checkout, und eine Unter-Session ändert dort nichts. Planende Unter-Sessions schreiben ihre Plan-Datei deshalb im eigenen Worktree; die Leitung kopiert sie ins Haupt-Checkout, wenn sie den Plan vorlegt.

## Bypass-Modus

Eine Session mit „Bypass permissions“ kann sich mit den übrigen nicht austauschen: Nachrichten an sie bleiben zur Freigabe hängen, bis sie verfallen. Claude kann den Modus nicht selbst umstellen; `.claude/hooks/coordination_mode_guard.ps1` sperrt `ListAgents` und `SendMessage` im Bypass-Modus. Der Owner wechselt auf „Auto“ (Shift+Tab bzw. Modus-Auswahl), danach die Anmeldung wiederholen. Nach einer Plan-Freigabe prüft die Leitung bei der nächsten Notiz der Session den `permissionMode` (schlichtes „Akzeptieren“ hält Auto; andere Knöpfe stellen still auf `acceptEdits`).

## Sessions ansprechen

- **Eigene ID ermitteln:** `mcp__ccd_session_mgmt__get_session` mit `self`. Die Transkript-ID aus der Oberfläche ist eine andere Kennung; ein Brief mit ihr ließ die Unter-Session ins Leere schreiben.
- **Titel statt Name:** Nachrichten an Unter-Sessions gehen per `SendMessage` an den Titel, wie `ListAgents` ihn zeigt, nicht an den `name` aus `start_session` (der ist ein Anzeigewort der App). Sessions können sich umbenennen, die ID bleibt; die Stand-Datei hält beides.
- **Überblick:** `list_sessions {linked:true}` (Tool `mcp__ccd_session_mgmt__list_sessions`) zeigt alle verwandten Sessions mit Status, Titel, Ordner und Branch. Vom Owner selbst gestartete Sessions stehen nur in `ListAgents`.
- **Registrieren:** direkt nach jedem `start_session` `.\scripts\register_sub_session.ps1 -Id <local_…>`; danach lehnt `.claude/hooks/enforce_sub_session_questions.ps1` direkte Owner-Fragen dieser Session ab. Das wirkt nur in Sessions, die den Hook beim Start schon in ihrem Checkout hatten. `-Clear` am Sprint-Ende.
- **Start verweigert:** Nach einer Unteragenten-Meldung oder Session-Notiz verweigert die App `start_session`, auch nach einer Karten-Antwort (die Karte zählt nicht als Owner-Nachricht). Erst auf eine getippte Owner-Nachricht starten.

## Statusrunde (nur Owner-gestartete Sessions)

Für Sessions, die die Leitung selbst gestartet hat, meldet die App jedes Zug-Ende als Notiz; eine Statusrunde entfällt. Nur für vom Owner gestartete Sessions läuft alle 15 Minuten ein `CronCreate` (Off-Minuten, z. B. `7,22,37,52 * * * *`, `recurring: true`):

1. `ListAgents`: noch nicht angemeldete Sessions sofort anschreiben (wer leitet, welche Regeln gelten; Aufgabe, Dateien, Worktree erfragen).
2. Jede Session mit offener Release-Arbeit: „Was ist dein Stand? Wartest du auf etwas, ja oder nein; wenn ja, worauf, von wem?“ Fertige Sessions nur bei neuer Information in ihrem Bereich (Test-Befund, Merge-Konflikt, geänderte Entscheidung).
3. Dem Owner kurz den Stand melden; nach dem Tag `CronDelete`.

## Substrat-Plätze

Das Parallel-Limit steht in `scripts/dev/bootstrap_test_n8n.ps1`. Die Leitung verteilt die Plätze: eine zugesagte, noch nicht gestartete Zuteilung trägt sie mit `scripts/reserve_substrate_slot.ps1` ein, sonst nimmt ihn eine andere Session in der Lücke weg. Einen Platz, den sie selbst nicht braucht, gibt sie frei. Kalte Läufe laufen standardmäßig auf GitHub-Runnern; Compose- und Probe-Container kurz halten. Git je Worktree nur nacheinander: Merge, Checkout und Regenerieren (post-merge-Hook) laufen in einem Worktree nie gleichzeitig.

## Release-Ablauf

1. **Vor jedem Merge `git fetch origin`:** `main` hinter `origin/main` → erst nachziehen; Branch-Inhalt gegen `origin/main` zählen, sonst wirken veröffentlichte Commits fremd.
2. **Merge-Kette** auf den einen Integrations-Branch; `build.ps1` ohne Diff.
3. **Gates auf GitHub:** Integrations-Branch pushen, `gh workflow run free-gates.yml --ref <branch>`, dazu `ci` und `genericity` (laufen sonst nur auf main/PR). Warten per `gh run watch <id> --exit-status` als Hintergrund-Befehl, das weckt die Session; grüne Läufe wecken niemanden von selbst. Lokal zusätzlich `scripts/dev/run_free_gates.ps1 -Reset -Parallel` mit eigenen Containern nur bei geänderten Test-Skripten, Bot-Anschluss oder Install-Kern (dann `-Cold`) und vor einem Release; reine Doku-Merges brauchen keinen Lauf.
4. **Bezahlte Fall-IDs sammeln:** alle Fälle, die der Gesamtstand berührt, als eine Liste (Fall-ID, Fall-Datei, Kostenrahmen) dem Owner nennen, bevor etwas nach `main` geht; der Lauf selbst im Owner-Fenster.
5. **Push:** nur die Leitung, per Admin-Bypass der CI-Pflicht (Rulesets → `CONTRIBUTING.md` *Branch protection*); vorher `/privacy-review`. Danach `scripts/check_ci_status.ps1`. Ein gepushter Text lässt sich nicht still zurückholen; meldet `privacy_lint -Outgoing` rot, wird der Text korrigiert.
6. **Master-Image + Pin-Commit** (`docs/reference/provisioning.md` *Docker-Verbund*).
7. **Tag:** annotiert, englische Release-Notes (was sich geändert hat, keine Live-Werte): `git tag -a vX.Y.Z --cleanup=whitespace -F <datei>`. Ein fehlerhafter Tag wird nicht verschoben → neue Patch-Version.
8. **Release-Nachschau:** direkt nach dem Tag eine einmalige geplante Aufgabe anlegen (`mcp__scheduled-tasks__create_scheduled_task`, `fireAt` = Tag-Zeitpunkt + 24 h). Ihr Prompt: nur lesend wie `/live-findings` Schritte 1–3, Zeitraum die letzten 24 Stunden, Bericht als privates Artefakt; nichts ändern.
9. Alle Sessions benachrichtigen, dann Sprint-Ende (`/leitung` §4).

**Push-Sperre:** Soll nichts nach GitHub, setzt die Leitung `.\scripts\set_no_push.ps1 -On`, noch bevor ein Brief das Pushen erwähnt; aufheben kann nur der Owner im Terminal (`-Off`).

## Fremd-PRs

Nie auschecken, bevor der Diff gelesen ist (Hooks sehen `.env`). `gh pr diff <nr>` in eine Datei, darauf `privacy_lint -TextFile <datei>` und die Modell-Prüfung (Fork-Läufe sehen die Denylist nie), erst dann den Lauf freigeben. Merge nur per Squash mit eigenem, geprüftem Text, nach Bestätigung des Owners. Antworten im PR sind öffentlich: keine Live-Werte, auch nicht zur Begründung.

## Brief an eine Unter-Session

Jeder Brief enthält:

- Aufgabe, betroffene Dateien, woran „fertig“ erkennbar ist; passender Skill als Rahmen (`/feature`, `/test-task`, `/docs-task`, `/mini-app-task`, `/ui-task`)
- echte Session-ID der Leitung (siehe *Sessions ansprechen*) und ihr ListAgents-Titel; die Regel *Fragen an den Owner laufen über die Leitung* (`/coordinate` §5)
- Hinweis auf die Stand-Datei: lesen, Sperren und Merge-Reihenfolge gelten, nicht schreiben
- eigene Container mit Session-Kürzel, freie Ports nach `docker ps`; n8n-Substrat nur nach Reservierung durch die Leitung
- Repo öffentlich: nur erfundene Werte, auch in Commits und Kommentaren
- Testfälle nie ändern, nur damit sie grün werden; Streichen erst nach Owner-Freigabe
- bezahlte Suiten und Mini-App nur im jeweiligen Owner-Fenster
- Bericht am Zug-Ende: Branch, Hash, Gates, offene Punkte; kein Push, kein Merge, keine Frage an den Owner
- Berechtigungs-Karten gebündelt ans Blockende legen und den Befehl melden, statt einzeln zu blockieren
- Notizordner als Rückfall: Sperrt die App Nachrichten nach 10 Sitzungs-Nachrichten ohne Owner-Eingabe, schreibt die Session ihren Bericht als Datei dorthin
- planende Session: Plan-Datei im eigenen Worktree, Pfad melden (siehe *Stand-Datei*)

## Plan-Freigabe

Planende Unter-Sessions melden die Plan-Datei statt einer Plan-Karte (`/feature` §2); die weitergeleitete Karte stellt die Session unzuverlässig von Auto auf manuell und erscheint nicht in der Handy-App. Die Leitung prüft die Zeilen `Plan-Reviewer:` und `Denkstufe:` (sonst Aufgabe des ExitPlanMode-Hooks `.claude/hooks/dev_cycle_plan_gate.ps1`), kopiert die Datei ins Haupt-Checkout und legt den Plan selbst vor: „Kurz gesagt“, Datei per `SendUserFile`, Karte. Auf das Ja trägt sie die Antworten in die Plan-Datei ein und startet die Bauer frisch (`permission_mode` „auto“, `effort` laut Plan-Zeile; liegt sie über der eigenen, fragt die App den Owner, in derselben Nachricht ankündigen).

## Sprint-Ende

Reihenfolge nach dem Tag, erst danach startet die nächste Leitung:

1. `archive_session` je Unter-Session (stoppt sie, räumt ihren Worktree ab, wiederherstellbar); vorher muss alles aus ihr gemerged und ihr Nachlauf erledigt sein. `delete_session` nur auf ausdrücklichen Wunsch des Owners.
2. Worktrees (`git worktree prune`) und gemergte Branches lokal und auf GitHub entfernen; Branches auf GitHub nur auf Owner-Wort.
3. Container: `.\scripts\dev\docker_cleanup.ps1` (Liste), dann `-Apply`; `db_test`-Container bleiben nach dem Session-Ende stehen und sind mit dabei.
4. `.\scripts\register_sub_session.ps1 -Clear`.
5. Stand-Datei auf das Jetzt kürzen, Memory aktualisieren, Verbesserungs-Zeilen für `/retro-bundle` stehen lassen.

Weitere Routinen übernehmen den Rest: `/retro-bundle` (Freitag) bündelt die Verbesserungs-Zeilen, `/session-hygiene` (Sonntag) räumt idle Sessions, Branches, Worktrees und Docker, `/paid-run` (monatlich) bereitet den bezahlten Sammel-Lauf vor.

## Fallgeschichten

- **Vier Leitungen gleichzeitig:** Wartezeiten aufeinander, dieselbe Owner-Frage in zwei Chats verschieden beantwortet, Merge-Ketten über vier Integrations-Branches, zweimal die Nutzungsgrenze. Daraus: eine Leitung, Sprints nacheinander, eine Stand-Datei, Entscheidungen gebündelt; eine zweite Ernennung wird zur Übergabe oder Pause.
- **Windows-Gates grün, Linux rot:** Ein Backslash-Pfad zur `.env` lief lokal, brach aber im `free-gates`-Lauf auf GitHub (Linux). Daraus: vor jedem Push auf `main` ein grüner Linux-Lauf auf dem Integrations-Branch.
- **Doku-Commit auf lokalem `main`:** Eine Nicht-Leitung committete eine Skill-Zeile direkt auf `main`; die Leitung musste die Reihenfolge der Merges neu sortieren. Daraus: auf `main` landet nichts außer durch die Leitung.
- **Transkript-ID im Brief:** Die Unter-Session schrieb ihre Berichte an eine Kennung, die keine Session war. Daraus: eigene ID per `get_session self`, Titel für Nachrichten.
- **Acht Retro-Punkte an eine Session:** Unabhängige Punkte liefen nacheinander statt in drei Sessions parallel. Daraus: Schnitt nach Dateigruppen als Hauptüberlegung bei jedem Paket.
- **Fünf Session-Starts verweigert:** Die Karte nach einer Prüfer-Meldung zählte nicht als Owner-Nachricht. Daraus: Starts erst auf eine getippte Nachricht.
