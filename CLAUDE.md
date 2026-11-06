# CLAUDE.md

Leitfaden für Claude Code in diesem Repo: nur, was der Code nicht zeigt. Prozeduren liegen in Skills (`.claude/skills/`), harte Verbote in Hooks (`.claude/hooks/`), Bereichs-Konventionen in der Sub-`CLAUDE.md` des Ordners, Gesetze je Dateityp in `.claude/rules/`, Mechanik on-demand in `docs/reference/`.

## Kommunikation mit dem Owner (jede Antwort)

- Einfache, alltagsnahe Sprache: was du tust und warum, verständlich ohne Technikwissen; Fachjargon nur in Klammern dahinter.
- Vollständig, ohne Füllstoff: jeder Satz trägt Information. Fehler und Unsicherheiten klar benennen, samt praktischer Folge.

## Projekt

Persönliches Multi-Agent-System auf self-hosted n8n: Telegram-Bot → `agent.orchestrator` → Spezialisten-Agenten als Sub-Workflows, Daten und Agenten-Instruktionen in PostgreSQL. Paket-Vertrag `docs/package-contract.md`. Zielgruppe: Familien (`docs/reference/ui.md`).

## Arbeitsweise (Gotchas, die der Code nicht zeigt)

- Neue Oberfläche = bestehendes Analog übernehmen (meist `finance`; Katalog `docs/package-contract.md` §8). Abweichung nur mit belegtem Grund (n8n-Quirk, DB-Gesetz, Single-User), nicht „YAGNI". Zweiter Konsument eines Sonderwegs → sofort vereinheitlichen; Core-Single-Paket-Naht → jetzt generisch.
- Bugs, stille Falschrechnung, toter Code, Drift: sofort fixen. Privates Backlog `.local/BACKLOG.md` (Haupt-Checkout, nie ins Repo) nur für bewusst vertagte Features und getriggerte Entscheidungen.
- Recherche vor dem Design bei unklarem Scope, Quellen verlinken. n8n-Doku vor jedem Node-Bau: n8n akzeptiert ungültige Parameter beim Publish und failt zur Laufzeit still. Fallen → `packages/CLAUDE.md` *Build-Gotchas*.
- Daten-Integrität: DB-Constraint/Trigger ist Gesetz → `fn_*` ist atomare Durchsetzung → Tool/Prompt sind Komfort und driften. Invariante zuerst als Constraint (`.claude/rules/sql.md` *Integritäts-Konventionen*).
- Das LLM rechnet nicht: Tool-Inputs sind minimale Roh-Werte; jede abgeleitete Größe (Rate, Zins/Tilgung, Vorzeichen, Monats-Normalisierung) berechnet eine `fn_*`/GENERATED-Spalte, kein `$fromAI`-Feld. HITL-Preview-Werte read-only aus derselben `fn` (`packages/CLAUDE.md` *Post-State-Vertrag*).
- Benennung folgt dem etablierten Standard (z. B. Flyway `V__`/`R__`); unklar → recherchieren. Surgical Changes, KISS; YAGNI begrenzt nur den Ausbaugrad, nicht Standards oder Bestands-Muster.
- Generiertes nur über den Generator: `packages/<pkg>/workflows/` via `build.ps1`, `docs/site/public/` via `build_site.ps1`, `docs/fn_catalog.md` via `gen_fn_catalog.ps1`.
- Jeder Workflow erklärt sich über Sticky-Notes (deutsch, `Build-Sticky`: Überblick + nicht offensichtliche Stellen); bei jeder Graph-Änderung gegenlesen (`workflow_lint` prüft das Minimum).
- Kommentare im Code: Leser sind KI-Modelle → `.claude/rules/comments.md` (lädt beim Öffnen von Code).
- Ein Fakt, eine Adresse: ableitbare Repo-Fakten (Listen, Counts, ID-Ranges) nicht in Doku spiegeln (`doc_lint`). Eine neue Regel ersetzt, was ihr widerspricht, statt angehängt zu werden.
- Oberfläche → `/ui-task`. Die Mini-App nur mit Owner-Zustimmung und eigenem Plan, kein Umbau (Hook `.claude/hooks/enforce_app_window.ps1`).

**Workflow-Naming:** `<scope>.<role>_<action>` (scope `core`/`agent`/`agent.<domain>`, role `main`/`cron`/`sub`/`tool`, Datei `<id>-<name>.json`); `tool` = Einzweck-Fähigkeit mit `{ok,…}`-Ausgang, `sub` = breiterer Job mit Seiteneffekten, beide inline und als Agent-Tool aufrufbar.

## Sprachpolitik

| Schicht | Sprache |
|---|---|
| Modell-Instruktion (Contexts, Manifest-Descriptions, Tool-Descriptions) | Englisch |
| Antwort an den Nutzer | Sprache der Nutzer-Nachricht; Steuer-/Rechtsbegriffe bleiben Deutsch |
| Nur-Entwickler-Doku (CLAUDE.md, Stickies, Code-Kommentare, Skills) | Deutsch |
| Code-Identifier (Tabellen, Spalten, ENUMs, Tool-Namen) | Englisch, nie für Sprache umbenennen |
| Gespeicherte Inhalte (Memory, Dokumente) | Originalsprache, nie bulk-übersetzt |
| Commit-Messages, Release-Notes, OSS-Doku (`README.md`, `AGENTS.md`, `CONTRIBUTING.md`) | Englisch |

Ausgabesprache zentral in `packages/core/contexts/global_instructions.md` *Language*.

## Versionen & Deploy-Modell

n8n 2.45.4 · PostgreSQL 17. Der getrackte Baum ist die Source of Truth, keine Instanz ist Sync-Ziel. Dev/Test = ephemeres Docker-Substrat; Dev-Instanz = realer LXC für den Install-Test des Owners, nur per `/reset-dev`; Prod = Deploy-Ziel (`provision.sh`, `lifeagents update`) → `scripts/CLAUDE.md` *Deploy-Modell*. Instruktions-Contexts sind getrackt, PII-Contexts entstehen nur per Onboarding; Modellwechsel = Manifest-Wert oder `lifeagents config set model <key> <wert>` (`packages/core/CLAUDE.md` *Zentral-Config*).

## Credentials & Privacy

- Secrets nur im n8n-Credential-Store bzw. in `/etc/lifeagents/<pkg>.env`; nicht-geheime IDs direkt im Node. `.env` (gitignored; Keys → `.env.example`): `OWNER_CHAT_ID` redactet der Build zu `__OWNER_CHAT_ID__`.
- Sensible Daten (Finanzdokumente, Lebenslauf, Sprachnachrichten, Lern-Loop, Dokumenten-Assistent) nur über bezahlte, nicht-trainierende Endpunkte: Anthropic-API; Google nur mit Bezahl-Key für die Transkription.
- Das Repo ist öffentlich, auch Commit-/Tag-/PR-Texte, Site, CI-Logs: Live-Werte nur erfunden, keine Hinweise auf Lebensumstände des Owners (Wohnform, Pläne, Konten; auch nicht in Kommentaren, Triggern, Beispielen); Prompts kennen keine Fakten über den Owner. `privacy_lint` und `owner_fact_lint` prüfen beim Commit, vor jedem Push `/privacy-review`, Fund → `/privacy-incident`. Fremd-PRs → `/coordinate`.

## Scripts

- Scripts-Only: n8n-API- und DB-Operationen nur über `scripts/`, nicht `Invoke-RestMethod`/`psql`/`curl` ad hoc. Routine-Skripte fährt Claude selbst; frisches System → `scripts/setup_dev_env.ps1`.
- `.ps1` nur über das PowerShell-Tool (Bash matcht falsche Hook-Namespaces), ohne `2>&1`. Mehrzeilige Commit-Messages: Datei → `git commit -F`.
- Eigene Test-Container je Session/Worktree: `$env:N8NTEST_CONTAINER`/`N8NTEST_PORT` und `$env:DBTEST_CONTAINER`/`DBTEST_PG_PORT` in jedem Aufruf setzen (auch `git push`); geteilte Defaults und fremde Container nicht abreißen.
- Bezahlte LLM-Suiten und `reset_dev_instance.ps1` laufen nur im Owner-Fenster, das der Owner im Terminal öffnet (`.\scripts\grant_owner_window.ps1`, Hook `.claude/hooks/enforce_owner_window.ps1`); Claude bittet darum und empfiehlt sonst das exakte Kommando.
- `.claude/settings.local.json`: keine engen allow/ask/deny-Regeln (Resolver-Bug GH#27139). Hook-„ask" winkt VS Code still durch; harte Sperren = `deny`.

## Entwicklungszyklus

Ein Diff, der in einen Satz passt, braucht keinen Plan. Blast-Radius-Arbeit (Tabelle unten) → `/feature`; neue Architektur/Mechanik → vorher `/arch-challenge`; parallele Sessions → `/coordinate`, „du bist die Leitung“ → `/leitung`. Ein rotes Gate wird gefixt, nicht mit `--no-verify` umgangen. Neues, unabhängiges Thema nach abgeschlossener Arbeit → Owner in einem Satz auf `/clear` oder neue Session hinweisen, Offenes vorher in Plan-Datei/Memory; mitten im Sprint nicht.

## Compact Instructions

Zusammenfassungen behalten: eigene Container + Ports, Übergabe-Plandatei, offene Prüfungen, Owner-Entscheidungen aus dem Chat.

## Testing / TDD-Workflow

| Berührte Oberfläche | Suite | Gate |
|---|---|---|
| Daten-Korrektheit (`fn_*`, Schema/Trigger/View/CHECK, Migration) | `db_test.ps1` | hart, immer |
| Verhalten/Routing (Modellwechsel, Prompt, Tool-Description, Orchestrator, neuer Agent) | `n8n_test` + `orch_test` + `judge_eval` | weich, Owner-Fenster |
| Schema-Fidelity (neues Write-Tool, geändertes Payload) | `e2e_test` | gezielt, Owner-Fenster |
| Keine (Stickies, Doku, Refactor mit identischem Output) | — | kein Test-Theater |

Neues Tool ⟹ Golden-Case in `tests/agent/<pkg>/*_cases.json` + „Not yet available"-Liste im Prompt kürzen.

## Schreibzugriffe: HITL & Atomarität

- HITL vor jedem persistenten Write über das geteilte Gate `agent.tool_human_approval` (Maker-Checker: Owner ein Tap, Mitglieder je `approval_matrix` im Manifest). Decline → `{ok:false, cancelled:true}`. Nur Buttons: Text erreicht den suspendierten Vorgang nicht. Format → `packages/CLAUDE.md` *HITL-Bestätigungs-Format*.
- Alle Writes eines Tools in einer PL/pgSQL-Function `fn_<tool>(p jsonb)` (RAISE → Rollback), auch bei 1-INSERT-Tools.
- Nutzerkorrigierbare Fehler als Daten (`{ok:false, reason}` ohne RAISE → `Build-ToolError`), `Stop and Error` nur für echte Ausnahmen (`packages/CLAUDE.md` *Korrigierbare Ablehnung*). `maxIterations` an jedem Agent-Node cappen.

## Anti-Loop-Konvention

Strikter DAG `orchestrator → agent.<x> → tool_* → human_approval`; kein `tool_*` enthält einen Agenten (Depth-Gate → `packages/CLAUDE.md` *Workflow-Bau*).

## Modell-/Kosten-Politik

Alle Sprachmodelle sind Claude (Register `packages/core/seed/ai_models.json`); Denk-Tiefe (`effort`) je Verbraucher bewusst: Router low, Werkzeug-Agenten medium, Berater/Panel high (Opus). Direkte Aufrufe nur über `New-AnthropicMessagesNode`; keine Sampling-Parameter (die 5.5-Generation lehnt `temperature` ab). Claude-Code-Sessions: Stufe laut Plan-Zeile *Denkstufe* (`/feature`).

## Agenten & Prompt-Design

- Write nur über `agent.<pkg>.tool_*`, kein rohes `postgres_execute`; Read über `postgres_select` (`<pkg>_ro`) + `load_context`; kein Tool → „kein Tool für X“ (Katalog `docs/reference/packages.md` *Write-Tools-Katalog*).
- Orchestrator-Routing kennt kein Paket: WANN welcher Agent steht allein in `provides.agents[].router_description` (`docs/package-contract.md` §2).
- System-Prompt schlank: Tool-Spezifisches in die Tool-Description, Übergreifendes in den System-Prompt, nicht doppelt; „Not yet available"-Liste pflegen.

## Subagenten

Delegieren macht keine Antwort besser, es lohnt nur für breites, paralleles Lesen oder lange Rohausgaben. Ein frischer Prüfer hilft, weil er die Herleitung nicht kennt (Plan-Reviewer, `/code-review`, `ui-review`, `/privacy-review`): ihm Artefakt und Maßstab geben, nicht die Begründung. Code-Suche → `Explore` (Sonnet im Frontmatter); Agenten-Typen ohne Modell im Frontmatter bekommen ein explizites `model`.
