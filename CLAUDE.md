# CLAUDE.md

Leitfaden für Claude Code in diesem Repo: Zweck, Gotchas, Zeiger. Prozeduren liegen in Skills (`.claude/skills/`), harte Verbote in Hooks (`.claude/hooks/`), Bereichs-Konventionen in der Sub-`CLAUDE.md` des Ordners (lädt erst beim Dateizugriff dort), Referenz on-demand in `docs/reference/`, SQL-/PowerShell-Gesetze in `.claude/rules/` (laden beim Öffnen passender Dateien).

## Kommunikation mit dem Owner (jede Antwort)

- Einfache, alltagsnahe Sprache: **was** du tust und **warum**, verständlich ohne Technikwissen; Fachjargon nur in Klammern dahinter.
- Vollständig, ohne Füllstoff: jeder Satz trägt Information. Fehler und Unsicherheiten klar benennen, samt praktischer Folge.
- Code, Commit-Messages und Doku folgen der *Sprachpolitik* unten.

## Projekt

Persönliches Multi-Agent-System auf self-hosted n8n (Debian-LXC im LAN): ein Telegram-Bot → `agent.orchestrator` → Spezialisten-Agenten als Sub-Workflows. Agenten-Instruktionen und Cross-Agent-Memory liegen in PostgreSQL (`agent.core_contexts`); Workflows sind build-generiert unter `packages/<pkg>/workflows/` und werden per `provision.sh` aus dem Baum deployt. Paket-Vertrag `docs/package-contract.md`.

## Arbeitsweise (Gotchas, die der Code nicht zeigt)

- Neue Oberfläche = bestehendes Analog übernehmen (meist `finance`; Katalog `docs/package-contract.md` §8). Abweichung nur mit belegtem Grund (n8n-Quirk, DB-Gesetz, Single-User), nie „YAGNI". Zweiter Konsument eines Sonderwegs → sofort vereinheitlichen; Core-Single-Paket-Naht → jetzt generisch.
- Bugs, stille Falschrechnung, toter Code, Drift: sofort fixen. `BACKLOG.md` nur für bewusst vertagte Features und getriggerte Entscheidungen.
- Recherche vor dem Design bei unklarem Scope, Quellen verlinken. **n8n-Doku vor jedem Node-Bau** (Version 2.44.4): n8n akzeptiert ungültige Parameter beim Publish und failt zur Laufzeit still. Fallen → `packages/CLAUDE.md` *Build-Gotchas*.
- **Daten-Integrität:** DB-Constraint/Trigger ist Gesetz → `fn_*` ist atomare Durchsetzung → Tool/Prompt sind Komfort und driften. Invariante zuerst als Constraint; Multi-Row-Invarianten nie über Gate-Trigger (MVCC). → `.claude/rules/sql.md` *Integritäts-Konventionen*.
- **Das LLM rechnet nicht:** Tool-Inputs sind minimale Roh-Werte (nur Nicht-Ableitbares); jede abgeleitete Größe (Rate, Zins/Tilgung, Vorzeichen, Monats-Normalisierung) berechnet eine `fn_*`/GENERATED-Spalte, kein `$fromAI`-Feld. HITL-Preview-Werte read-only aus derselben `fn` (`packages/CLAUDE.md` *Post-State-Vertrag*).
- Benennung folgt dem etablierten Standard (z. B. Flyway `V__`/`R__`); unklar → recherchieren. Surgical Changes, KISS; YAGNI begrenzt nur den Ausbaugrad, nie Standards oder Bestands-Muster.
- **Sticky-Notes sind Pflicht** (Überblicks-Sticky je Workflow + an nicht-offensichtlichen Stellen, `Build-Sticky`, deutsch), bei jeder Workflow-Änderung gegen den neuen Graphen gegenlesen; `workflow_lint` weist Workflows ohne Sticky ab.
- Ein Fakt, eine Adresse: ableitbare Repo-Fakten (Listen, Counts, ID-Ranges) nie in Doku spiegeln; `doc_lint` erzwingt das.

## Sprachpolitik

| Schicht | Sprache |
|---|---|
| Modell-Instruktion (Contexts, Manifest-Descriptions, Tool-Descriptions) | Englisch |
| Antwort an den Nutzer | Sprache der Nutzer-Nachricht; Steuer-/Rechtsbegriffe bleiben Deutsch |
| Nur-Entwickler-Doku (CLAUDE.md, Stickies, Kommentare, Skills) | Deutsch |
| Code-Identifier (Tabellen, Spalten, ENUMs, Tool-Namen) | Englisch, nie für Sprache umbenennen |
| Gespeicherte Inhalte (Memory, Dokumente) | Originalsprache, nie bulk-übersetzt |
| Release-Notes | Englisch |

Ausgabesprache zentral in `packages/core/contexts/global_instructions.md` *Language*.

## Versionen & Deploy-Modell

n8n **2.44.4** · PostgreSQL **17**. Keine Instanz ist Sync-Ziel, der getrackte Baum ist die Source of Truth. **Dev/Test** = ephemeres Docker-Substrat (`scripts/dev/bootstrap_test_n8n.ps1 -Reset` fährt `provision.sh`); **Dev-Instanz** = realer LXC für den Install-Test des Owners, nur per `/reset-dev`; **Prod** = Deploy-Ziel (`provision.sh`, `lifeagents update`). → `scripts/CLAUDE.md` *Deploy-Modell*.

## Telegram-Architektur

Ein zentraler Bot; der Orchestrator empfängt alles (auch Fotos/Sprachnachrichten). Prod: `Telegram → <fqdn> → Reverse Proxy (bring-your-own, nur /webhook*, /webhook-test*, /webhook-waiting*) → n8n:5678`; **`/webhook-waiting/*` + `/webhook-waiting-telegram` sind Pflicht fürs HITL-Gate**. `WEBHOOK_URL` setzt `provision.sh` aus `--domain`; Proxy-Bind/Firewall → `provisioning/CLAUDE.md` *Install-UX-Phase 5*.

## Credentials & Privacy

Secrets nur im n8n-Credential-Store bzw. in `/etc/lifeagents/<pkg>.env`; nicht-geheime IDs direkt im Node. `.env` (gitignored; Keys → `.env.example`): `OWNER_CHAT_ID` redactet der Build zu `__OWNER_CHAT_ID__`. **Sensible Daten (Finanzdokumente, Lebenslauf, Sprachnachrichten, Lern-Loop, Dokumenten-Assistent) nur über bezahlte, nicht-trainierende Endpunkte**: Anthropic-API; Google nur mit Bezahl-Key für die Transkription. **Repo ist öffentlich**, auch Commit-/Tag-/PR-Texte, Site, CI-Logs → Live-Werte nur erfunden; `privacy_lint` (Modi im Skript-Kopf) prüft gegen `.local/privacy_denylist.txt` (neue echte Werte nachtragen). Fremd-PRs: erst `gh pr diff`, nie ungelesen auschecken (Hooks sehen `.env`).

## Memory & PostgreSQL

Vier Schichten: Static Contexts (immer in der System-Message) · Lazy Contexts (Agent fetcht via `load_context`) · Chat-Historie je Agent `agent.<agent>_chat_memory` · strukturierte Agentendaten (`agent.*`, Paket-Schema wie `finance.*`). Instruktions-Contexts sind getrackt (`packages/<pkg>/contexts/*.md`, geseedet vom Installer); PII-Contexts entstehen nur per Onboarding. **Zentral-Config `core.config`:** SSOT = `.config`-Block im Manifest + `packages/core/seed/ai_models.json`; Modellwechsel = Manifest-Wert oder `lifeagents config set model <key> <wert>` (`packages/core/CLAUDE.md` *Zentral-Config*).

## Repo-Struktur (wo steht was)

| Ordner | Inhalt |
|---|---|
| `packages/<pkg>/` | `db/` (Inits + Flyway-Migrationen), `contexts/`, `seed/`, `build/` (Build-Defs), `workflows/` (**nur via `build.ps1`**), `manifest.json`, `CLAUDE.md` |
| `scripts/` | `<verb>_<noun>.ps1`; `build/` = Bau-Engine, `dev/` = Substrat-Treiber |
| `tests/` | `db/<pkg>/test_*.sql` (Tier 1), `agent/<pkg>/*_cases.json`, Mocks, Fixtures |
| `provisioning/` | bash-Installer, `lifeagents`-CLI, Templates |
| `docs/` | `package-contract.md`, `fn_catalog.md` (generiert), `reference/` (Mechanik je Bereich), `site/` (`public/` nur via `build_site.ps1`) |
| `.claude/` | getrackt: `hooks/`, `rules/`, `skills/`, `agents/Explore.md`, `settings.json`; Gate-Matrix → `CONTRIBUTING.md` |

**Workflow-Naming-Konvention:** `<scope>.<role>_<action>` (scope `core`/`agent`/`agent.<domain>`, role `main`/`cron`/`sub`/`tool`, Datei `<id>-<name>.json`); `tool` = Einzweck-Fähigkeit mit `{ok,…}`-Ausgang, `sub` = breiterer Job mit Seiteneffekten, beide inline und als Agent-Tool aufrufbar. Neues Write-Tool → `packages/<pkg>/build/workflows/tools/`; neue Invariante → `packages/<pkg>/db/*_init.sql` + Test in `tests/db/<pkg>/`.

## Scripts

- **Scripts-Only-Policy:** n8n-API- und DB-Operationen nur über `scripts/`, nie `Invoke-RestMethod`/`psql`/`curl` ad hoc. Routine-Skripte fährt Claude selbst; frisches System → `scripts/setup_dev_env.ps1`. Referenz → `scripts/CLAUDE.md`.
- **Nur das PowerShell-Tool** für `.ps1` (Bash matcht falsche Hook-Namespaces), ohne `2>&1`. Mehrzeilige Commit-Messages: Datei → `git commit -F`.
- **Eigene Test-Container je Session/Worktree:** `$env:N8NTEST_CONTAINER`/`N8NTEST_PORT` und `$env:DBTEST_CONTAINER`/`DBTEST_PG_PORT` in jedem Aufruf setzen (auch `git push`); nie geteilte Defaults oder fremde Container abreißen.
- **Owner-Fenster (Hook `.claude/hooks/enforce_owner_window.ps1`, hart):** LLM-Suiten (`n8n_test`, `orch_test`, `e2e_test`, `judge_eval`, `multiturn_test`) und `reset_dev_instance.ps1` laufen nur im **Owner-Fenster**, das der Owner im Terminal öffnet (`.\scripts\grant_owner_window.ps1`, 30 Min); Claude bittet darum und empfiehlt sonst das exakte Kommando.
- `.claude/settings.local.json`: keine engen allow/ask/deny-Regeln (Resolver-Bug GH#27139). Ein Hook-„ask" wird in der VS-Code-Erweiterung still durchgewinkt; harte Sperren sind `deny`.

## Entwicklungszyklus

Ceremony scales to the task: ein Diff, der in einen Satz passt, braucht keinen Plan-Modus. Blast-Radius-Arbeit (Tabelle unten) läuft über `/feature` (Plan zur Owner-Freigabe → TDD Red → Build + Stickies → Substrat → Doku-Deltas → `/code-review high` → Commit + Push; rot ⟹ fixen, nie `--no-verify`). Neue Architektur/Mechanik → vorher `/arch-challenge`. Parallele Sessions → `/coordinate`.

## Testing / TDD-Workflow

| Berührte Oberfläche | Suite | Gate |
|---|---|---|
| Daten-Korrektheit (`fn_*`, Schema/Trigger/View/CHECK, Migration) | `db_test.ps1` | hart, immer |
| Verhalten/Routing (Modellwechsel, Prompt, Tool-Description, Orchestrator, neuer Agent) | `n8n_test` + `orch_test` + `judge_eval` | weich, Owner-Fenster |
| Schema-Fidelity (neues Write-Tool, geändertes Payload) | `e2e_test` | gezielt, Owner-Fenster |
| Keine (Stickies, Doku, Refactor mit identischem Output) | — | kein Test-Theater |

Neues Tool ⟹ Golden-Case in `tests/agent/<pkg>/*_cases.json` + „Not yet available"-Liste im Prompt kürzen; Mechanik → `tests/CLAUDE.md`.

## Schreibzugriffe: HITL & Atomarität

- **HITL vor jedem persistenten Write** über das geteilte Gate `agent.tool_human_approval` (Maker-Checker: Owner ein Tap, Mitglieder je `approval_matrix` im Manifest). Decline → `{ok:false, cancelled:true}`. **Buttons-only:** Text erreicht den suspendierten Vorgang nicht. Format → `packages/CLAUDE.md` *HITL-Bestätigungs-Format*.
- **Atomarität:** alle Writes eines Tools in einer PL/pgSQL-Function `fn_<tool>(p jsonb)` (RAISE → Rollback), auch bei 1-INSERT-Tools.
- Nutzerkorrigierbare Fehler als Daten `{ok:false, error}` (`Build-ToolError`; DB `{ok:false, reason}` ohne RAISE), `Stop and Error` nur für echte Ausnahmen. `maxIterations` an jedem Agent-Node cappen.

## Anti-Loop-Konvention

Strikter DAG `orchestrator → agent.<x> → tool_* → human_approval`; kein `tool_*` enthält einen Agenten. `call_depth` = Tiefe des Empfängers (Root 0, Sub-Agent `caller_depth + 1`, Tools keines); 1-Node-IF am Agent-Eingang (`call_depth >= 2 → {ok:false, error:"max_call_depth"}`, Muster → `packages/CLAUDE.md` *Workflow-Bau*).

## Fehlerbehandlung

Jeder Produktions-Workflow trägt `settings.errorWorkflow = "Nd3UVmUTzTLOBeba"` (`core.sub_error_notify` → Telegram-Alert); Ausnahmen: Test-Harnesses und der Notify selbst.

## Modell-/Kosten-Politik

Alle Sprachmodelle sind Claude (Register `packages/core/seed/ai_models.json`); Denk-Tiefe (`effort`) je Verbraucher bewusst: Router low, Werkzeug-Agenten medium, Berater/Panel high (Opus). Direkte Aufrufe nur über `New-AnthropicMessagesNode`; keine Sampling-Parameter (die 5.5-Generation lehnt `temperature` ab). Google nur für die Sprach-Transkription.

## Agenten & Prompt-Design

- **Finance = CQRS:** Read via `postgres_select` (`finance_ro`) + `load_context`; Write nur über `agent.finance.tool_*`, kein rohes `postgres_execute`; kein Tool → „kein Tool für X". Katalog → `docs/reference/packages.md` *Write-Tools-Katalog*.
- **Advisor** berät, bucht nie (Ausnahme: Anlageklassen). **Monitor:** Trigger = Daten-Zeilen; schreibt es in Domänen-Tabellen → n8n-Cron, beobachtet es einen Wert → Trigger-Zeile, Vergleich in der DB (`packages/core/CLAUDE.md` *Trigger-Monitoring*).
- **Orchestrator-Routing** kennt kein Paket: WANN welcher Agent steht allein in `provides.agents[].router_description` (`docs/package-contract.md` §2).
- **System-Prompt schlank:** Tool-Spezifisches in die Tool-Description, Übergreifendes in den System-Prompt, nie doppelt; „Not yet available"-Liste pflegen.

## Subagenten

Delegiere nur, was nicht in wenigen eigenen Tool-Aufrufen erledigt ist; keine Subagenten zum Gegenprüfen der eigenen Arbeit; wenn einer reicht, nicht mehrere. Code-Suche → `Explore` (`.claude/agents/Explore.md`, Sonnet); eigene Subagenten immer mit explizitem `model`.
