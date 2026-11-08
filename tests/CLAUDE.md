# Tests — Konventionen (lädt beim Arbeiten in `tests/`)

*Wann* getestet wird, steht in der Root-`CLAUDE.md` (*Testing / TDD-Workflow*); hier die Regeln beim Schreiben/Laufen. Dateien-Tabelle mit den exakten Suite-Kommandos, Harness-Mechanik, Judge und E2E-Details → `docs/reference/tests.md` (on-demand).

- **Layout** (`layout_lint` L3): `tests/db/<pkg>/test_*.sql`, `tests/agent/<pkg>/*_cases.json`, `util/`, `fixtures/`, `mock_*/`. `tests/agent/judge_bundle.json` ist transient (gitignored); `tests/fixtures/fixtures.json` ist die eine Namensliste der Routing-Fixtures (`doc_lint` erzwingt Manifest ⊆ Seed).
- **Testdaten nur erfunden** (Repo ist öffentlich): Vorrat und Regeln in `tests/fixtures/README.md`, nie Werte aus einem Befund — keine echten Namen, Geburtsdaten, Bestände, Beträge, Kontonummern. Eine Session, die einen Befund nachbaut, bekommt nur die Eigenschaft (z. B. Rundungsfall), nie den Originaltext; Notizen und Kommentare nennen nur sie. `privacy_lint` prüft gegen die lokalen Listen, `owner_fact_lint` typische Formulierungen.

- **Live-Fehler ⟹ zuerst ein roter Test zur Eigenschaft, Fix erst danach; ohne Test nicht fertig.**

## LLM-Test-Kosten: OWNER-ONLY

- `n8n_test`, `orch_test`, `e2e_test`, `judge_eval`, `multiturn_test` kosten API-Credits (Owner-Fenster, Root-`CLAUDE.md` *Scripts*); Claude empfiehlt die Suite mit dem exakten Kommando (Tabelle in der Referenz).
- Empfehlung bei: Modellwechsel, Prompt-Refactor, geänderter Tool-Description, neuem Tool (Golden), Orchestrator-Routing. Keine bei DB-Fixes, Stickies, Skript-Refactoring, Doku, Migrationen. `db_test.ps1` und `infra_test.ps1` sind gratis — immer mitlaufen lassen.
- **Gezielt statt alles:** nur die Fälle, die der Diff berührt (gefilterte Fall-Datei für `n8n_test -CasesFile`, `judge_eval` direkt danach, der nächste Lauf überschreibt das Bundle); eine Suite, deren Oberfläche der Diff nicht ändert, läuft nicht. Vorher dem Owner Anzahl, Grund, grobe Kosten und das Ungeprüfte nennen. Volllauf nur mit begründetem Anlass und nach Rückfrage.

## Flakiness + Quarantäne

- Routing-Tests sind ein weiches Gate; ein einzelner Fail beweist keine Regression. `"quarantined": true` am Case: wird ausgeführt und berichtet, aber nicht gewertet und nicht ins Judge-Bundle geschrieben — Pflicht: `notes` mit Grund + Re-Evaluierungs-Trigger.
- **Treiber mit Fall-Liste** (freie Suiten `real_ingress`, `mock_route`, `infra_test`, `hitl_gate`; `cron_text` hat eine eigene, gleichwertige Absicherung) setzen jeden Fall in `try`/`catch` im selben Bereich wie den Zähler und rufen im `catch` `Write-CaseAbort` (`scripts/dev/test_n8n_state.ps1`, Abschnitt *Fall-Abbruch*): Der Zähler wird nie in einem Scriptblock hochgezählt (eine Kopie ginge verloren, der Lauf bliebe grün), die Fälle laufen mit dem `foreach`-Statement, nie mit `ForEach-Object` (dort beendet `continue` mehr als den Fall). Kein automatisches Wiederholen: Ein roter Fall wird einzeln wiederholt. Eigenbau statt Pester, weil die Fälle linear Substrat-Zustand teilen und `exit $failed` der Vertrag mit `run_free_gates.ps1` ist. Mechanik → `docs/reference/tests.md` *Flakiness-Mechanik*.
- Rubrics auf Output-Substanz schreiben, nicht auf die `read_tools`-Liste (der n8n-Action-Log ist unvollständig). Massenhaft `status=error` ⟹ zuerst Modell-Quota prüfen, nicht die Korrelation debuggen.

## DB-Tests: Pattern

DB-Gesetze und Rollen-Perspektiv-Pflicht → `.claude/rules/sql.md`.

- Inner Loop: `db_test.ps1 -Filter '*<subject>*'` (Naming `fn_X → test_fn_X` ist die Change→Test-Map); die Voll-Suite fährt der Pre-Push-Hook; Schema-/Trigger-Querschnitt → einmal voll manuell.
- Jede Datei self-contained (`BEGIN … DO $$ … RAISE EXCEPTION 'FAIL: …' … $$; ROLLBACK;`).

## Agent-/Orchestrator-Tiers (Harness)

- **`enable_mock_telegram.ps1` muss aktiv sein** für jeden Lauf, der ein Write-Tool triggern kann: das HITL-Gate hat keinen Test-Bypass, die Tiers lösen es über das abgefangene Mock-Telegram auf (decline im Routing-Tier, approve im E2E).
- `expected_tool_args`-Feldnamen = die `Build-Trigger`/`$fromAI`-Namen des Tools (aus `packages/<pkg>/build/workflows/tools/<tool>.ps1` übernehmen, nie raten); dynamische Werte (aufgelöste IDs) nicht asserten.
- Langläufer: `"timeout_s"` am Case. Harnesses bei Nichtbenutzung deaktivieren (Webhook-Pfad sonst registriert).

## E2E-Tier

- Voraussetzungen (Konten, Sparziel, Kauf …) per `setup_sql` über die `<pkg>.fn_*` anlegen, der Agent macht nur den geprüften Schritt: 4–5 Writes in einer Nachricht sprengen `maxIterations`. Jeder Fall muss `status=success` enden (C3/C4), sonst bekäme der Nutzer eine Fehlermeldung.
- Jede E2E-Entität trägt `__E2E__` im Namen; Cleanup nur über `agent.fn_clear_e2e_data()` (kein unqualifizierter DELETE). Neue löschbare Entität im E2E ⟹ den Sentinel-Scope des Paket-Hooks `<pkg>.fn_clear_e2e_data` erweitern (sonst Leak).
- Nur sequentielle Läufe (fester Marker); Advisor/Monitor-E2E nutzen den `test_e2e`-chat_id nur für den Sentinel-Domain-Switch.

## Golden-Cases

- Self-contained, reale Entitätsnamen; `create_*` mit neuen Namen (Dedup-Treffer → Agent fragt nach → FAIL).
- `set_*`/`close_*`/`delete_*`: Routing-Golden nur mit dauerhafter Fixture-Entität, sonst DB-Test + E2E statt eines erzwungenen Goldens (der FAIL wäre ein Fixture-Defekt). Eine neue Fixture-Entität braucht beides: den Payload in `tests/fixtures/util_seed_test_fixtures.sql` und den Namen in `tests/fixtures/fixtures.json`.
- Bewusst ohne Routing-Golden: `tool_update_staging_row` (braucht die `batch_id` eines früheren Turns, ein Ein-Nachricht-Fall kann sie nicht nennen; Korrektur-Logik deckt `test_fn_import_stage`) und `tool_cancel_handoff_task` (läuft erst im Folge-Turn nach der Antwort auf einen Plan-Punkt; Gesetz deckt `test_fn_handoff_tasks` + `test_fn_with_handoff`). Beide gehören in ein Mehrrunden-Szenario (`multiturn_cases.json`), nicht in einen erzwungenen Golden.
- Onboarding-Vorzustand per `"onboarding": "unknown"` (Haushalt) bzw. `"package_onboarding": {"<pkg>.<section_key>": "unknown"}` (offener Paket-Bereich; vor jedem Case wird alles auf completed zurückgesetzt), Default nach Seed: completed. Eine Voraussetzung, die nicht in die Fixtures darf (Einnahme: `real_ingress` braucht den Haushalt ohne), per `setup_sql` wie im E2E-Tier (`__E2E__`-Entitäten, aufgeräumt vor dem nächsten Case). Mock-Tier: jeder Golden braucht ein Szenario in `tests/mock_llm/scenarios.json` (`mock_lint`).
