---
name: coordinate
description: Koordination paralleler Claude-Sessions im Repo - beim Session-Start pruefen, ob andere Sessions laufen, eine leitende Session mit Merge-Hoheit bestimmen, 15-Minuten-Statusrunde der Leitung, direkte Absprache der Sessions untereinander mit Info an die Leitung, Release-Umfang vom Owner abfragen. Nutzen bei JEDEM Session-Start (der SessionStart-Hook erinnert daran) und sobald eine weitere Session dazukommt.
---

# Parallele Sessions koordinieren (`/coordinate`)

Owner-Regel (2026-10-23): Es gibt immer **genau eine leitende Session** mit Merge-Hoheit, die alle anderen zentral koordiniert. Anlass: Beim gemeinsamen Release 2026-10-23 stand die Arbeit zweimal still, weil Sessions untätig aufeinander warteten und sich darauf verließen, dass die Leitung Infos weiterreicht.

## 1. Beim Start: Lage prüfen

- **Nie im Bypass-Modus koordinieren** (Owner-Regel 2026-10-23): Eine Session mit „Bypass permissions“ kann sich mit den übrigen Sessions nicht austauschen. Deren Nachrichten an sie hält die Empfänger-Session zur Freigabe fest, bis sie ablaufen, und sie kommen nie an (der Absender bekommt einen `[Cross-session delivery notice]` „held“/„not approved before expiry“). Den eigenen Modus kann Claude nicht selbst umstellen → **anhalten** und den Owner bitten, auf „Auto“ zu wechseln (Shift+Tab bzw. Modus-Auswahl in VS Code), danach die Anmeldung wiederholen. Der SessionStart-Hook `.claude/hooks/session_coordination.ps1` erinnert daran, der PreToolUse-Hook `.claude/hooks/coordination_mode_guard.ps1` sperrt `ListAgents`/`SendMessage` im Bypass-Modus (der SessionStart-Hook sieht den Modus nicht).
- `ListAgents` (deferred → per `ToolSearch` laden) + `ReadNotifications`.
- **Keine anderen Sessions** → du bist Leitung, sobald eine dazukommt. Weiter mit deiner Aufgabe.
- **Andere Sessions laufen** → per `SendMessage` an alle: „Wer leitet? Woran arbeitest du, welche Dateien/Pakete fasst du an?“ — mit der ausdrücklichen Bitte um Antwort.

## 2. Leitung bestimmen

- Gibt es schon eine Leitung, bleibt sie es. Die neue Session meldet sich bei ihr an: Aufgabe, berührte Dateien, Worktree und Branch.
- Gibt es keine, übernimmt die **am längsten laufende** Session (`ListAgents` → „started … ago“) und teilt das allen mit.
- Wird die Leitung beendet, übergibt sie vorher ausdrücklich an eine andere Session, samt Stand: Integrations-Branch, offene Merges, laufende Tests.

## 3. Pflichten der Leitung

- **Merge-Hoheit:** Nur die Leitung merged auf den Integrations-Branch, fährt die Schluss-Gates, pusht `main` und taggt. Niemand sonst pusht oder taggt.
- **`main` und `v*`-Tags sind geschützt** (GitHub-Rulesets): kein Force-Push, kein Löschen, kein Tag-Verschieben, auch nicht für den Owner (diese Sperren haben bewusst keinen Bypass); die Leitung pusht direkt per Admin-Bypass der CI-Pflicht. Ein fehlerhafter Tag wird nie verschoben → neue Patch-Version. Nach jedem Push die CI-Ampel prüfen (`scripts/check_ci_status.ps1`). Ein Leck in einem schon gepushten Text lässt sich nicht still zurückholen → vor dem Push prüft `privacy_lint -Outgoing` Commits und neue Tags; rot ⟹ Text korrigieren, nie `--no-verify`.
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
- Ablauf danach wie gewohnt: Merge-Kette → freie Gates auf dem Gesamtstand (EIN Befehl: `scripts/dev/run_free_gates.ps1 -Reset -Parallel` mit eigenen Containern, `-Cold` nur bei geändertem Install-Kern; vorher per `docker ps` prüfen, ob ein Substrat-Platz frei ist, sonst den Halter direkt um Freigabe bitten) → bezahlte Suiten im Owner-Fenster → annotierter Tag mit englischen Release-Notes (öffentlich: was sich geändert hat, keine Live-Werte; `git tag -a vX.Y.Z --cleanup=whitespace -F <datei>`) → alle Sessions benachrichtigen → Aufräumen.

## 4. Pflichten der übrigen Sessions

- **Direkt untereinander absprechen**, nicht über die Leitung: wer welche Datei bzw. welchen Testfall anfasst, wer auf wessen Commit aufsetzt, wer welchen Substrat-Platz nutzt.
- **Die Leitung immer informieren**, was abgesprochen wurde: kurze Kopie mit Ergebnis, Hashes, wer was macht.
- Jede Statusfrage der Leitung beantworten, auch mit „unverändert“. Commit-Hashes an die Leitung und an betroffene Sessions schicken.
- Fertig heißt: committet, Gates grün, Hash an die Leitung. Danach nichts mehr ohne Absprache committen. Eigene Container abräumen; den eigenen Worktree erst nach dem Tag.
