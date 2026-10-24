# Scripts — Konventionen (lädt beim Arbeiten in `scripts/`)

Policy (Scripts-Only, PowerShell-Tool, Owner-Fenster, eigene Container) → Root-`CLAUDE.md` *Scripts*; PowerShell-Encoding/`-Verbose`/Dot-Sourcing → `.claude/rules/powershell.md` (lädt beim Öffnen einer `.ps1`). **Pro Skript gilt sein Kopf-Kommentar** (keine Skript-Referenz in Doku); Gate-Matrix → `CONTRIBUTING.md` *The enforcement gates*, Hooks → `.pre-commit-config.yaml`. Substrat-, Mock-LLM-, Deploy- und `.env`-Mechanik → `docs/reference/scripts.md` (on-demand).

## Skripte aus Claude Code ausführen

- Repo-Befehle immer über das PowerShell-Tool, das Skript direkt (`.\scripts\db_apply.ps1 -File '…'`), ohne Output-Redirect; nie über Bash (anderer Tool-Pfad, verliert die stderr-Trennung). Lesen/Suchen/Editieren über Read/Grep/Glob/Edit/Write.
- **Der Owner-Fenster-Hook matcht die Dateinamen der gesperrten Suiten überall im Befehlstext** (auch grep/cat) → Suite-Dateien nur mit Read/Grep öffnen. Claude ruft `grant_owner_window.ps1` nie selbst auf (der Hook verweigert es).
- `db_apply.ps1 -File` mit mehreren Zielen: **unquoted komma-getrennt** (`-File a.sql,b.sql`) oder **ein** gequotetes Glob (`'packages\finance\db\migrations\R__fn_*.sql'`); ein gequoteter `'a.sql,b.sql'`-String wird als ein Glob gelesen und schlägt fehl.
- Mehrzeilige Commit-Messages: Datei via Write + `git commit -F <datei>` — kein Heredoc (bricht am Quoting über den Tool-Layer).
- **CI-Ampel:** `check_ci_status.ps1` zeigt den letzten GitHub-Lauf je Workflow auf `main`; der SessionStart-Hook meldet Rot an jede Session (dann zuerst fixen, dem Owner melden). Lokal laufen die Node-Checks des `workflow_lint` per Docker, nie mehr übersprungen — ein Lint-Unterschied zwischen lokal und CI ist ein Bug.

## Deploy-Modell & Substrat

- **Keine Instanz ist Sync-Ziel:** Workflows, Config/AI-Models und Instruktions-Contexts kommen nur aus dem getrackten Baum (`build.ps1` → `bootstrap_test_n8n.ps1 -Reset` → `provision.sh`; Prod `lifeagents update`). Neue Workflows bekommen eine selbstvergebene id im Dateinamen, kein POST-zum-Minten. PII-Contexts entstehen nur per Onboarding, nie per Seed.
- `N8N_URL`/`N8N_API_KEY` der Tiers kommen ausschließlich aus `.local/n8ntest_state.json` (`Get-TestN8nConnection`), nie aus `.env` → kein versehentlicher Prod-Zugriff. Container-DB nur über `Invoke-TestN8nPsql` (Peer-Auth, `apply_schema.sh`-Pfad), nie `db_apply.ps1` (zielt auf die db_test-DB).
- **Schnellpfad vs. kalt:** `-Reset` startet aus dem lokalen Basis-Image (Software vorinstalliert, Neubau automatisch bei Pin-/Baustein-Änderung; Mechanik im Skript-Kopf). Ändert ein Branch den Install-Kern (der Schnellpfad meldet es, Dateiliste in `Show-InstallCoreHint`) → vor dem Push `-Reset -Cold`; Release-Check `-Version` ist immer kalt. Verworfen: npm-Cache-Volume (`npm cache clean` + Entpacken dominieren), apt-cacher-ng (kein HTTPS-Caching für PGDG/NodeSource), Testcontainers-Reuse (passt nicht zu systemd-Containern mit Provisioning).
- `.env`-Keys des Substrats: Layout = `.env.example` (`doc_lint` 7b erzwingt es); `TEST_HARNESS_SECRET` ist Pflicht, `TEST_TELEGRAM_BOT_TOKEN` ist nie der Prod-Bot.
- **Laufende Executions nie per Roh-SQL zählen:** Läufe mit `saveDataSuccessExecution: none` (z. B. `core.sub_show_thinking`) löscht n8n am Ende nur weich (`deletedAt`, Pruning-Puffer 1 h) und lässt `status = 'running'` stehen, bis der Hard-Delete-Durchlauf sie entfernt; Pausen unter 65 s schlafen im Prozess (kein `waitTill`). Live-Diagnose daher über die API (`executions?status=running`) oder SQL mit `"deletedAt" IS NULL` (Fehlalarm „hängende Schleifen“ 2026-10-24).

## Mock-LLM (gratis Tier, Claude darf ihn fahren)

- `enable_mock_llm.ps1` biegt den Upstream des LLM-Gateways per systemd-Laufzeit-Drop-in auf `tests/mock_llm/server.js`; das Drop-in überlebt keinen Container-Neustart → jede Suite prüft den tatsächlichen Upstream (`Assert-LlmGatewayUpstream -Expect mock|real`). Prod-Workflows bleiben unangetastet.
- Szenarien (`tests/mock_llm/scenarios.json`) müssen **alle Pflicht-`$fromAI`-Felder** als Args tragen (sonst registriert der Call nicht); Tool-Namen per `mock_route_test.ps1 -Discover` ablesen (Orchestrator-Routen sind sanitisiert, `Call_agent_finance_`). `mock_lint.ps1` hält Szenarien ↔ Cases commit-time konsistent.
- Ablauf: `bootstrap_test_n8n.ps1` → `enable_mock_llm.ps1` → `enable_mock_telegram.ps1` → `mock_route_test.ps1` → `-Down`. **Alle freien Gates auf einmal** (Merge-/Release-Stand): `scripts/dev/run_free_gates.ps1` (schaltet alle Mocks selbst ein, Reihenfolge + Zusammenfassung im Skript-Kopf).
