# Status-Panel (Mod für die Desktop-App)

Ein Seitenfenster neben dem Chat, nur lesend:

| Bereich | Quelle | Takt |
|---|---|---|
| Kontingent (Balken, Prozent, Reset) | `$.session.usage().rateLimits`, Fenster `five_hour` und `seven_day` | 30 s und nach jeder Modellantwort |
| Test-Container mit Ports | `docker ps`, Filter `lifeagents-` | 30 s |
| Owner-/App-Fenster (Restzeit) | `.claude/owner_grant.txt`, `.claude/app_grant.txt` im Haupt-Checkout, Zeile 1 | 30 s |
| CI-Ampel | `scripts/check_ci_status.ps1` | 5 Min |

Lässt sich eine Quelle nicht lesen, steht „Nicht lesbar: …“ im Panel; es gibt keine Ersatzquelle und keine Schätzwerte.

**Nur in der Leit-Session:** Das Panel läuft nur in der Session, die `scripts/set_status_panel_home.ps1` eingetragen hat; die Kennung liegt gitignored in `.claude/status_panel_home.txt` im Haupt-Checkout. Jede andere Session lädt den Mod zwar, startet aber keine Abfrage und schließt das Panel.

**Kontingent, aber nur so aktuell wie die letzte Modellantwort:** Die Quelle stellt keine Rückfrage und kostet nichts, fragt aber nichts beim Anbieter ab: Sie gibt nur wieder, was die letzte Modellantwort dieses Prozesses mitbrachte, und andere Sessions verbrauchen dasselbe Kontingent. Deshalb steht bei einem Fenster „unbekannt“ statt einer Zahl, wenn dieser Prozess noch keine Antwort gesehen hat, die letzte 10 Minuten oder älter ist, das Fenster fehlt oder sein Reset vorbei ist. Darunter steht das Alter der letzten Antwort. „Aktualisieren“ holt keine neue Zahl; die bringt erst die nächste Modellantwort der Session.

**Eigen** ist ein Container, den die Session in einem Befehl per `N8NTEST_CONTAINER=`/`DBTEST_CONTAINER=` benannt hat (auch mit Suffix `-b`).

**Fenster:** Das Panel sucht wie die Hooks (`Test-GrantWindow` in `.claude/hooks/lib/grant_window.ps1`): Es zählt nur die Datei im Haupt-Checkout, und sie gilt für alle Worktrees. Eine Kopie im Worktree ist ein Altstand. Ohne Git-Repo gilt das Fenster als zu. Anders als der Hook löscht das Panel keine abgelaufene Datei.

**Laden:** Ordner in `CLAUDE_CODE_PLUGIN_DIRS` eintragen (Prozess-Umgebung oder `env`-Block in `~/.claude/settings.json`, nie Projekt-Settings), neue Session starten; `/status-panel` öffnet das Panel in der Leit-Session wieder.

**Prüfen:** `claude plugin validate <Ordner>` und `claude plugin test <Ordner>`; `claude` ist die CLI aus der Desktop-App, wenn keine im PATH liegt. Die Tests laufen nicht in der CI.
