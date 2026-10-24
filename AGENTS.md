# AGENTS.md

Fast onboarding surface for contributors — human or coding agent. The conventions live in the
`CLAUDE.md` family (root + `packages/`, `packages/<pkg>/`, `scripts/`, `scripts/build/`, `tests/`,
`provisioning/`), path-scoped rules in `.claude/rules/` (SQL, PowerShell) and per-area reference material in `docs/reference/`; when this file and a `CLAUDE.md` disagree, `CLAUDE.md` wins.

## What this project is

A personal multi-agent system on self-hosted **n8n 2.44.4** + **PostgreSQL 17**. One Telegram bot feeds
an orchestrator that routes to specialist agent sub-workflows. Agent instructions and cross-agent memory
live in PostgreSQL (`agent.core_contexts`); workflows are build-generated into
`packages/<pkg>/workflows/*.json` and deployed from the tracked tree (no live sync). Full picture: root
[CLAUDE.md](CLAUDE.md).

## Quick start

The dev tooling is **Windows-only** (PowerShell + Docker Desktop); the deploy target is Debian. From a fresh clone:

1. `scripts/setup_dev_env.ps1` — installs and wires the whole toolchain (details and the two manual steps:
   [CONTRIBUTING.md](CONTRIBUTING.md) *Setup*).
2. `prek run --all-files --hook-stage pre-commit` — the deterministic, free lint gates (CI runs the same,
   minus the local-only hooks listed in [CONTRIBUTING.md](CONTRIBUTING.md) *The enforcement gates*).
3. `scripts/db_test.ps1` — the deterministic DB suite against a throwaway Docker database.

No API credits are needed for any of this. The paid LLM suites need your own `ANTHROPIC_API_KEY` in `.env`.

## Hard rules (the rest is in CLAUDE.md)

- **Data integrity is law:** DB constraints/triggers → `fn_*` enforcement → tool/prompt are convenience.
  **The LLM does not do arithmetic** — derived values are computed in the DB, never by a `$fromAI` field.
- **HITL before every persistent write** via the shared `agent.tool_human_approval` gate; all writes of a
  tool run in one PL/pgSQL function. Finance is CQRS: reads via `postgres_select`, writes only via `tool_*`.
- **Secrets never enter the repo**; no PII in the tracked tree (owner chat id is redacted to `__OWNER_CHAT_ID__`).
- **Workflows are generated** — write `packages/<pkg>/workflows/` only via `scripts/build/build.ps1`;
  every workflow carries sticky notes (German) as its documentation.
- **Run repo scripts through the PowerShell tool**, never ad-hoc `psql`/`curl`/`Invoke-RestMethod`;
  `.ps1` files are UTF-8 with BOM.
- **LLM-cost test suites** (`n8n_test`, `orch_test`, `e2e_test`, `judge_eval`, `multiturn_test`) and the
  dev-instance reset run only inside an owner-opened window (`scripts/grant_owner_window.ps1`, terminal);
  a PreToolUse hook denies them otherwise. The hook only gates Claude Code sessions; the "owner" is
  whoever sits at the terminal of their own clone, and the suites bill that person's Anthropic key.
- **Conventional Commits** (`type(scope): subject`), enforced by the commit-msg hook; multi-line messages
  via `git commit -F <file>`.

## How work gets done

- Ceremony scales to the task: a one-sentence diff needs no plan. Blast-radius work (`fn_*`, schema,
  workflows, build engine, provisioning, auth, new agent/tool) runs through the skill `/feature`:
  plan for owner approval → TDD (`tests/db/<pkg>/test_*.sql` first) → build → `/code-review high` → ship.
  Cycle and test matrix: root [CLAUDE.md](CLAUDE.md) → *Entwicklungszyklus*, *Testing / TDD-Workflow*.
- New architecture or mechanism → `/arch-challenge` (one evidence-backed pass vs. established OSS patterns).
- Gates: deterministic lints + `db_test` run via prek on commit/push and in CI — matrix in
  [CONTRIBUTING.md](CONTRIBUTING.md).

## Language policy

English for model instructions, manifests, code identifiers and OSS-facing docs (`README.md`, this
file, `CONTRIBUTING.md`, `SECURITY.md`); German for the user documentation site (`docs/site/`) and
developer-only docs (the `CLAUDE.md` family, sticky notes,
comments, skills); user-facing replies in the user's language. Full table: root
[CLAUDE.md](CLAUDE.md) → *Sprachpolitik*.

Reporting a vulnerability: [SECURITY.md](SECURITY.md).
