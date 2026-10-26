# Referenz zu `scripts/CLAUDE.md` — Substrat, Mock-LLM, Deploy-Modell, Test-`.env`

On-demand lesen; **keine Regeln** (die stehen in `scripts/CLAUDE.md`). Pro Skript gilt sein Kopf-Kommentar; die Gate-Matrix (Hook × Stage, CI-Parität) steht in `CONTRIBUTING.md` *The enforcement gates*, die Hooks selbst in `.pre-commit-config.yaml`.

## Docker-Test-Substrat (n8n-Integrations-Tiers)

Die n8n-Tiers feuern gegen eine ephemere Docker-Instanz (`scripts/dev/bootstrap_test_n8n.ps1` → byte-identischer Applier `provision.sh` in einem systemd-Container; Detail im Skript-Header + `provisioning/CLAUDE.md` *Verifikation*). Ablauf: `bootstrap_test_n8n.ps1` hochfahren → Tier-Skript → `bootstrap_test_n8n.ps1 -Down`.

- **Basis-Image vs. kalt:** ein neuer Container startet standardmäßig aus `lifeagents-substrate-base` (Dockerfile + `build_base.sh` unter `scripts/dev/substrate-image/`, gebaut aus denselben `provisioning/lib`-Funktionen); `-Cold` und `-Version` nehmen das nackte jrei-Image, `-RebuildBase` baut das Basis-Image frisch. Tag-Logik, Aufräumen und Parallel-Schutz im Skript-Kopf.

- **Verbindung:** `N8N_URL`/`N8N_API_KEY` kommen über `scripts/dev/test_n8n_state.ps1` (`Get-TestN8nConnection`) aus `.local/n8ntest_state.<container>.json` (je Container) — nie aus `.env` (die `.env` wird weiter geladen, u. a. für `TEST_HARNESS_SECRET`) → kein versehentlicher Prod-Zugriff, analog `db_test`.
- **Gewired (alle fünf Tiers):** `infra_test` (Tier 4), `orch_test` (Tier 3), `multiturn_test`, `n8n_test` (Tier 2), `e2e_test` (Tier 5). `TEST_HARNESS_SECRET` = der Wert, mit dem die Harness-Header-Auth-Credential im Container angelegt wird; den Header-Namen `X-Test-Auth` setzt der Treiber via `TEST_HARNESS_HEADER`.
- **Container-DB-Zugriff (Tier 2/5):** die n8n-Instanz hält ihr Postgres container-intern (DB `n8n`, Loopback). `n8n_test` seedet `util_seed_test_fixtures.sql` + verifiziert (`test_fixtures.ps1 -Verify`); `e2e_test` liest/cleant per `verify_sql`/`fn_clear_e2e_data`. Beide über `Invoke-TestN8nPsql`/`Invoke-TestN8nPsqlFile` (`scripts/dev/test_n8n_state.ps1`): `docker exec … runuser -u postgres -- psql -d n8n` — Peer-Auth, kein Passwort/Port, exakt der `apply_schema.sh`-Pfad.
- **psql-`NOTICE` bricht über das PowerShell-Tool nicht ab** (stderr separat). Der Abbruch-Bug betrifft nur die inline-Merge-Form `& script … 2>&1 | Out-String` (PS 5.1 + `$ErrorActionPreference='Stop'` macht aus `NOTICE:` einen terminierenden `NativeCommandError`).

## Mock-LLM (deterministisches, gratis Routing/Tool-Path-Gate)

Der Mock-LLM (`tests/mock_llm/server.js`) macht den Agent-Tool-Pfad (ingress → orchestrator → agent → tool → gate) gratis + deterministisch testbar — anders als die owner-gegateten `n8n_test`/`orch_test` (echtes Modell, prüfen semantisches Routing). Der Mock prüft den deterministischen Tool-Pfad (Bindings, Schemas, `$fromAI`-Wiring, Trigger-Inputs, Gate-Mechanik), nicht die Modell-Intelligenz — ein eigener Tier, vom Owner-Fenster-Hook nicht erfasst → Claude darf ihn selbst fahren.

- **Hebel = der Upstream des LLM-Gateways:** der `lmChatAnthropic`-Node liest `anthropicApiUrl` aus dem `url` der `anthropicApi`-Credential, und die zeigt fest auf den lokalen LLM-Gateway (`provisioning/llm_gateway`). `enable_mock_llm.ps1` biegt dessen Upstream per systemd-Laufzeit-Drop-in (`/run/systemd/system/lifeagents-llm-gateway.service.d/mock.conf`, `LLM_GATEWAY_UPSTREAM`) auf den Stub → alle Claude-Aufrufe (Chat-Agenten und direkte HTTP-Knoten) sprechen mit dem Mock, und der Gratis-Tier testet die Gateway-Haltepunkte mit (der Stub loggt sie als `markers`). Das Drop-in überlebt keinen Container-Neustart → `mock_route_test`/`real_ingress_test`/`infra_test` (`requires: mock_llm`) prüfen den tatsächlichen Upstream (`Assert-LlmGatewayUpstream -Expect mock`), die kostenpflichtigen Suiten `-Expect real`; optional zusätzlich den `host` der `googlePalmApi`-Credential (nur Sprach-Transkription; der Stub spielt Gemini-Upload + `generateContent` nur für markierte Test-Dateien nach (`GEMINI_FILES` in `tests/mock_llm/server.js`), jede andere Datei → 404 → `voice_unavailable`). Kein neuer Node, keine ai_models-/Builder-Änderung, Prod-Workflows unangetastet (Live-Probe: Anthropic-baseUrl zur Laufzeit geehrt, `tool_use` sauber zu `tool_calls` geparst; der Node ruft non-streaming JSON).
- **Stub-Form:** Anthropic `/v1/messages` → `{content:[{type:'tool_use',name,input}],stop_reason:'tool_use'}` bzw. `[{type:'text'}]` (`input` = Objekt); Gemini-Transkription markierter Test-Dateien in echter API-Form (`candidates[].content.parts[].text`); jeder andere Pfad → 404. Zustandsfrei: n8n schickt die volle History → Turn (k) = Anzahl bisheriger `assistant`-`tool_use`-Turns; namespace-aware über die angebotenen Tools → ein Szenario treibt Orchestrator und Sub-Agent.
- **Szenarien:** `tests/mock_llm/scenarios.json` — je `{ match (Task-Substring), calls:[{tool, args}], final }`. Tool-Namen: Orchestrator-Routen sind sanitisiert (`Call 'agent.finance'` → `Call_agent_finance_`), Agent-Tools `tool_*` → mit `mock_route_test.ps1 -Discover` aus dem Mock-Log ablesen. Args müssen alle Pflicht-`$fromAI`-Felder enthalten (sonst weist n8n den Tool-Input ab → der Call registriert nicht); Pflichtfelder = die 3-arg-`$fromAI`-Inputs im jeweiligen `Build-Trigger`/InputSpec.
- **Ablauf:** `bootstrap_test_n8n.ps1` → `enable_mock_llm.ps1` → `enable_mock_telegram.ps1` (fürs Gate) → `mock_route_test.ps1` (→ beide `-Down`). Ingress je Ziel: Orchestrator → echter Telegram-Webhook (numerische chat_id, gepairter Owner); Agent-Ziele über ihren Harness `finance-test`/`advisor-test`/`monitor-test`/`guide-test` (Agent-Node auto-erkannt). Advisor-Lauf: `-TargetWorkflow agent.finance_advisor -WebhookPath advisor-test -CasesFile tests\agent\finance\advisor_cases.json -WriteTools tool_save_plan_section,tool_publish_plan,tool_create_monitor_trigger,tool_search_documents,tool_set_asset_classes` + `TEST_ANTHROPIC_API_KEY` in `.env` + Onboarding aufgelöst.
- **Statisches Drift-Gate (`mock_lint.ps1`, commit-stage):** hält die Szenarien commit-time ehrlich (jeder Nicht-NULL-Case hat ein passendes Szenario; kein Orphan; jeder Call ist ein echter erwarteter Call).

## Deploy-Modell (kein Live-Sync)

- **Workflows** (`packages/<pkg>/workflows/*.json`): `build.ps1` generiert sie (mit eingebackener id + Owner-ID-Redaction). Deploy ins Substrat = `bootstrap_test_n8n.ps1` ohne `-Reset` (fährt `provision.sh` im laufenden Container → `deploy_workflows.sh` spielt nur neue/geänderte Workflows per `import:workflow --separate` ein, id-erhaltend; `-FullDeploy` = alle; `-Reset` = frischer Container). Prod = `provision.sh`/`lifeagents update`.
- **Config + AI-Models** (`.config`-Block je `packages/*/manifest.json` + `packages/core/seed/ai_models.json`, keine PII): Datei = SoT; der Installer seedet sie über `provisioning/lib/seed_data.sh` (`ai_models` zuerst). Eine Änderung erreicht das Substrat über `-Reset`.
- **Instruktions-Contexts** (paket-besessen: `packages/<pkg>/contexts/*.md`, alle no-PII): getrackt = SSOT; `seed_data.sh` seedet sie roh in die typisierten Spalten `managed_by='seed'` + `package=<pkg>`. Löschschutz über `core.protected_contexts`. PII-Contexts (`family`/`finance_profile`/`vehicles`/`financial_planning`/…) entstehen zur Laufzeit per Onboarding (`managed_by='agent'`). Trennlinie + Seed-Mechanik → `provisioning/CLAUDE.md` *Daten-Seed*.
- **Backup vor riskanten lokalen JSON-Edits** (selten — der Baum ist git-versioniert):

```powershell
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$dst = ".local\backups\$ts"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item -Path 'packages\*\workflows\*.json' -Destination $dst
```

## Docker-Test-Substrat-`.env`-Keys (`scripts/dev/bootstrap_test_n8n.ps1`)

Der Substrat-Treiber liest die Test-Identität + optionale Secrets aus `.env` (gitignored) und reicht sie als Install-Env in den Container — gemappt auf die Namen, die der bash-Kern liest. Kanonisches Layout = `.env.example` (`doc_lint.ps1` 7b: jeder `$envMap`-Quell-Key ist dort dokumentiert).

| Schlüssel | Pflicht | Zweck / gemappt auf |
|---|---|---|
| `TEST_HARNESS_SECRET` | ja | Wert der Harness-Header-Auth-Credential; Header-Name `X-Test-Auth` via `TEST_HARNESS_HEADER`. Ohne: infra/n8n-Tier bekommen 403 |
| `TEST_TELEGRAM_BOT_TOKEN` | nein | separater BotFather-Token (nie der Prod-Bot) → `TELEGRAM_BOT_TOKEN`; fehlt → Telegram-Credential + Orchestrator-Trigger-Aktivierung übersprungen |
| `TEST_TELEGRAM_CHAT_ID` | nein | → `OWNER_CHAT_ID` (Owner-Send-Nodes) |
| `TEST_N8N_OWNER_EMAIL` / `TEST_N8N_OWNER_PASSWORD` | nein | n8n-Owner-Login (sonst generiert; PW-Policy 8–64/≥1 Ziffer/≥1 Großbuchstabe) |
| `TEST_N8N_ENCRYPTION_KEY` / `TEST_PG_PASSWORD` | nein | First-Init-Overrides → `N8N_ENCRYPTION_KEY`/`N8N_DB_PASSWORD` (sonst generiert) |
| `TEST_ANTHROPIC_API_KEY` / `TEST_GOOGLE_API_KEY` | Anthropic ja (Agent-Tiers), Google nein | Credential-Secrets (fehlt → Credential übersprungen; ohne Anthropic denkt kein Agent, ohne Google nimmt eine Sprachnachricht den `voice_unavailable`-Weg) |
| `TEST_OWNER_FIRST_NAME` / `_LAST_NAME` / `_BIRTH_DATE` | nein | Owner-Person-Skelett (`bootstrap_owner.sh`); fehlt → Skelett + Pairing-Code übersprungen |
| `N8NTEST_PORT` | nein | Host-Port der socat-Brücke (Default 5680; kein `TEST_*`-Key, nicht im 7b-Check) |

## Entscheidungen (bei uns anders — belegt)

- **Layout-/Doku-Enforcement als PowerShell-local-Hooks** (doc_lint Check 8/8b + `layout_lint` L1–L7) statt OSS-Tools: ls-lint liest keine Datei-Inhalte; pygrep/semgrep können weder zeilen-genaue Ratchet-Suppression noch pfad-abgeleitete Erwartungswerte; lychee/MD051/remark erfassen nur echte `[text](file#anchor)`-Links, nicht die deutsche Prosa-Pointer-Form. Übernommen: die Dead-Gate-Prüfung der `files:`-/`exclude:`-Filter über die prek-nativen `repo: meta`-Hooks `check-hooks-apply` + `check-useless-excludes`. Kipp-Kriterien → `BACKLOG.md`.
