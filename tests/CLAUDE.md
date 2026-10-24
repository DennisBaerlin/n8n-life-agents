# Tests — Konventionen (lädt beim Arbeiten in `tests/`)

*Wann* getestet wird, steht in der Root-`CLAUDE.md` (*Testing / TDD-Workflow*); hier die Regeln beim Schreiben/Laufen. Dateien-Tabelle mit den exakten Suite-Kommandos, Harness-Mechanik, Judge und E2E-Details → `docs/reference/tests.md` (on-demand).

- **Layout** (`layout_lint` L3): `tests/db/<pkg>/test_*.sql`, `tests/agent/<pkg>/*_cases.json`, `util/`, `fixtures/`, `mock_*/`. `tests/agent/judge_bundle.json` ist transient (gitignored); `tests/fixtures/fixtures.json` ist die eine Namensliste der Routing-Fixtures (`doc_lint` erzwingt Manifest ⊆ Seed).
- **Testdaten nur erfunden** (Repo ist öffentlich): die Personas der bestehenden Tests/Fixtures wiederverwenden, nie Werte aus einem Live-Befund — keine echten Namen, Geburtsdaten, Bestände, Beträge, Kontonummern. Einen Live-Befund als Test nachbauen = Zahlen neu erfinden, Eigenschaft (z. B. Rundungsfall) behalten. `privacy_lint` prüft gegen die lokale `.local/privacy_denylist.txt`.

## LLM-Test-Kosten: OWNER-ONLY

- `n8n_test`, `orch_test`, `e2e_test`, `judge_eval`, `multiturn_test` kosten API-Credits → nur im Owner-Fenster (Hook `.claude/hooks/enforce_owner_window.ps1`; Root-`CLAUDE.md` *Scripts*). Claude **empfiehlt** die Suite und nennt das exakte Kommando (Tabelle in der Referenz), führt sie nicht aus.
- Empfehlung bei: Modellwechsel, Prompt-Refactor, geänderter Tool-Description, neuem Tool (Golden), Orchestrator-Routing. Keine bei DB-Fixes, Stickies, Skript-Refactoring, Doku, Migrationen. `db_test.ps1` und `infra_test.ps1` sind gratis — immer mitlaufen lassen.

## Flakiness + Quarantäne

- Routing-Tests sind ein weiches Gate; ein einzelner Fail beweist keine Regression. `"quarantined": true` am Case: wird ausgeführt und berichtet, aber nicht gewertet und nicht ins Judge-Bundle geschrieben — Pflicht: `notes` mit Grund + Re-Evaluierungs-Trigger.
- Rubrics auf Output-Substanz schreiben, nicht auf die `read_tools`-Liste (der n8n-Action-Log ist unvollständig). Massenhaft `status=error` ⟹ zuerst Modell-Quota prüfen, nicht die Korrelation debuggen.

## DB-Tests: Pattern

- DB-Gesetze und die **Rollen-Perspektiv-Pflicht** (`SET LOCAL ROLE` in `tests/db/cross/test_role_permissions.sql`; `db_test` läuft als Superuser) → `.claude/rules/sql.md` (lädt beim Öffnen einer `.sql`).
- Inner Loop: `db_test.ps1 -Filter '*<subject>*'` (Naming `fn_X → test_fn_X` ist die Change→Test-Map); die Voll-Suite fährt der Pre-Push-Hook; Schema-/Trigger-Querschnitt → einmal voll manuell.
- Jede Datei self-contained (`BEGIN … DO $$ … RAISE EXCEPTION 'FAIL: …' … $$; ROLLBACK;`).

## Agent-/Orchestrator-Tiers (Harness)

- **`enable_mock_telegram.ps1` muss aktiv sein** für jeden Lauf, der ein Write-Tool triggern kann: das HITL-Gate hat keinen Test-Bypass, die Tiers lösen es über das abgefangene Mock-Telegram auf (decline im Routing-Tier, approve im E2E).
- `expected_tool_args`-Feldnamen = die `Build-Trigger`/`$fromAI`-Namen des Tools (aus `packages/<pkg>/build/workflows/tools/<tool>.ps1` übernehmen, nie raten); dynamische Werte (aufgelöste IDs) nicht asserten.
- Langläufer: `"timeout_s"` am Case. Harnesses bei Nichtbenutzung deaktivieren (Webhook-Pfad sonst registriert).

## E2E-Tier

- Voraussetzungen (Konten, Sparziel, Kauf …) per `setup_sql` über die `<pkg>.fn_*` anlegen, der Agent macht nur den **geprüften** Schritt: 4–5 Writes in einer Nachricht sprengen `maxIterations` (bezahlter Lauf 2026-10-23). Jeder Fall muss `status=success` enden (C3/C4), sonst bekäme der Nutzer eine Fehlermeldung.
- Jede E2E-Entität trägt `__E2E__` im Namen; Cleanup **nur** über `agent.fn_clear_e2e_data()` (kein unqualifizierter DELETE). Neue löschbare Entität im E2E ⟹ den Sentinel-Scope des Paket-Hooks `<pkg>.fn_clear_e2e_data` erweitern (sonst Leak).
- Nur sequentielle Läufe (fester Marker); Advisor/Monitor-E2E nutzen den `test_e2e`-chat_id nur für den Sentinel-Domain-Switch.

## Golden-Cases

- Self-contained, reale Entitätsnamen; `create_*` mit **neuen** Namen (Dedup-Treffer → Agent fragt nach → FAIL).
- `set_*`/`close_*`/`delete_*`: Routing-Golden nur mit dauerhafter Prod-Entität, sonst DB-Test + E2E statt eines erzwungenen Goldens (der FAIL wäre ein Fixture-Defekt).
- Onboarding-Vorzustand per `"onboarding": "unknown"` (Haushalt) bzw. `"package_onboarding": {"<pkg>.<section_key>": "unknown"}` (offener Paket-Bereich; vor jedem Case wird alles auf completed zurückgesetzt), Default nach Seed: completed. Mock-Tier: jeder Golden braucht ein Szenario in `tests/mock_llm/scenarios.json` (`mock_lint`).
