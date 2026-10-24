# Contributing

Thanks for looking at this repo. It is a personal, self-hosted multi-agent system (n8n + PostgreSQL).
There is no live prod to build against — the author loop and every test tier run against throwaway
Docker containers (the DB and n8n substrates), and prod is a deploy-only target. This guide covers the
toolchain and the enforcement gates; conventions live in [AGENTS.md](AGENTS.md) and the deep
architecture in the [CLAUDE.md](CLAUDE.md) family.

**Before you start:**

- The dev tooling is **Windows-only** (PowerShell 5.1 + Docker Desktop); the deploy target is Debian 12.
- This is a personal project shared as-is: there is **no support**, the issue tracker is switched off, and
  pull requests are not actively reviewed. Security problems go privately via [SECURITY.md](SECURITY.md).
  The rest of this guide is for working on your own fork or clone.
- You need **no API credits** for the free gates (lints, `db_test`, the mock-based substrate suites). The
  paid LLM suites run against your own `ANTHROPIC_API_KEY`; you do not have to run them for a PR.
- The PR template's **Real behavior proof** comes from your own throwaway Docker substrate
  (`scripts/dev/bootstrap_test_n8n.ps1 -Reset`), not from a production instance.
- By contributing you agree that your contribution is licensed under the repository's
  [MIT License](LICENSE).

## Setup

**Fresh Windows machine? One command detects and installs the whole dev toolchain:**

```powershell
scripts/setup_dev_env.ps1          # detect + install everything missing (idempotent)
scripts/setup_dev_env.ps1 -Verify  # only check, change nothing (exit code = number missing)
```

It installs the winget packages (PostgreSQL 17, `prek`), `PSScriptAnalyzer`, and the three pinned
binaries (`gitleaks`, `squawk`, `dotenv-linter`) into `$HOME\.local\bin` — **and adds that directory
to your user PATH** — wires the git hooks, and creates `.env` from `.env.example` with an
`OWNER_CHAT_ID=0` placeholder (enough for lint/build; replace it with your numeric Telegram chat_id
for a real run). Add `-Site` to also fetch the pinned Hugo, `-Full` for a closing `prek run` smoke.

**Two things it deliberately does NOT do** — each needs a reboot or a personal choice, so install them
yourself: **Docker Desktop** (the DB / n8n test substrate; see below) and the **Windows developer
mode** (Settings → System → For developers → "Developer Mode", then sign out/in). Both are reported by
`-Verify`; a missing Docker keeps the "dev env incomplete" reminder up until you install it and re-run.
When the script finishes, **restart every open terminal *and* VS Code** (a new tab is not enough) so
the PATH/env changes take effect.

The rest of this section is the **manual per-tool reference** — what the one command automates, for
when you install a piece by hand or need to know why a pin exists — plus the **Windows quirks** it
works around (bottom).

### The hook runner: `prek`

`prek` is the only thing you strictly need for the standard linters — **no Python or Node** on your
machine (the `shellcheck`, `markdownlint` and `sqlfluff` hooks each fetch their own toolchain in
isolation). The exceptions are the PowerShell linter (a module) and the three prebuilt binaries below.

```powershell
winget install --id j178.Prek        # the hook runner (a single Rust binary)
prek install                         # wire up the git hooks (or: scripts/install_git_hooks.ps1)
```

### Required for editing `*.ps1`: `PSScriptAnalyzer`

The `ps-lint` commit-stage hook runs [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer)
over `scripts/**/*.ps1` and `packages/*/build/**/*.ps1` (rules curated in [config/PSScriptAnalyzerSettings.psd1](config/PSScriptAnalyzerSettings.psd1)).
It is a PowerShell **module**, not a binary `prek` can fetch, so it runs as a `language: system` hook —
which means it runs in **both** points (local *and* CI, where it is preinstalled on `windows-latest`).
Install it once locally:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

If your `Documents` folder is redirected by OneDrive (Known-Folder-Move), `Install-Module` may fail
with a "part of the path … could not be found" error. In that case save the module to the fallback
location that [scripts/ps_lint.ps1](scripts/ps_lint.ps1) also checks:

```powershell
New-Item -ItemType Directory -Force "$HOME\.local\psmodules" | Out-Null
Save-Module PSScriptAnalyzer -Path "$HOME\.local\psmodules"
```

### Required: `gitleaks` (secret scan, runs on every commit)

The `gitleaks` commit-stage hook scans your **staged diff** for secrets on *every* commit (a second
net beside `detect-private-key`), so every contributor needs the binary. `prek` can't fetch it — the
upstream hook is `language: golang`, which prek would build from source (needs a Go toolchain), the
same class of gap as the Rust `dotenv-linter` below. So it runs as a `language: system` hook on a
prebuilt binary on your `PATH`. Install the pinned release once:

```powershell
scoop install gitleaks   # if you use scoop
# otherwise: download gitleaks_8.30.1_windows_x64.zip from the GitHub releases and put gitleaks.exe
# on PATH (e.g. "$HOME\.local\bin" — setup_dev_env.ps1 creates that dir and puts it on your user PATH)
```

CI does **not** use your binary — the dedicated `gitleaks` CI job downloads its own pinned copy and
scans the full git **history** (not just the tree). Allowlist for verified non-secrets:
[config/.gitleaks.toml](config/.gitleaks.toml).

`prek` reads [.pre-commit-config.yaml](.pre-commit-config.yaml) — the **single source of
enforcement**. To run the whole suite by hand:

```powershell
prek run --all-files                 # all stages
prek run --all-files --hook-stage pre-commit --show-diff-on-failure   # the fast, deterministic gates (exactly what CI runs)
```

For database / n8n work you also need `.env` filled in (there is no live prod anymore, so **no**
`N8N_*`/`PG_*` keys — just `OWNER_CHAT_ID`, `ANTHROPIC_API_KEY` (judge_eval) and the `TEST_*` substrate keys; gitignored)
and the PostgreSQL client `psql` on PATH. Layout: [.env.example](.env.example). See
[scripts/CLAUDE.md](scripts/CLAUDE.md).

### Optional: `dotenv-linter` (only if you edit `.env.example`)

A `local` commit-stage hook style-checks [.env.example](.env.example) with
[dotenv-linter](https://github.com/dotenv-linter/dotenv-linter). It fires **only when that file is
staged**, so you need the tool only if you touch it. `prek` can't fetch it — its Rust `cli:`
dependencies compile from source (`cargo install`), which needs the MSVC linker on Windows, and prek
has no prebuilt/binstall path ([j178/prek#681](https://github.com/j178/prek/issues/681)). So install
the small prebuilt binary once and put it on your `PATH`:

```powershell
scoop install dotenv-linter   # if you use scoop
# otherwise: download dotenv-linter-win-x64.zip from the GitHub releases and put dotenv-linter.exe on PATH
```

This hook is **local-only** — CI skips it (`SKIP=dotenv-linter`). The substantive `.env` invariants
(single template, `TEST_` key naming, all Docker-test-substrate keys present) are enforced by `doc_lint`, which
*does* run in CI.

### Required for migrations: `squawk` (only if you add a versioned migration)

Unlike `dotenv-linter` above, this is a **hard gate that also runs in CI** — "only if" refers to *when
the install is needed*, not to the gate being skippable. A `local` commit-stage hook lints
`packages/*/db/migrations/V*.sql` (Flyway versioned migrations) with
[squawk](https://squawkhq.com), catching unsafe migration patterns that *apply* cleanly but would
block or fail on a real DB — an unsafe `NOT NULL` add, `CREATE INDEX CONCURRENTLY` inside our
transaction-wrapped migrations, a stray `BEGIN/COMMIT`. It fires **only when a `V*.sql` is staged**, so
you need the tool only if you add one. `prek` can't fetch it (the Rust binary builds from source —
[j178/prek#681](https://github.com/j178/prek/issues/681)), so install the small prebuilt binary once:

```powershell
# Download squawk-windows-x64.exe from the v2.70.0 release and put it on PATH as squawk.exe
# (e.g. "$HOME\.local\bin" — the dir setup_dev_env.ps1 adds to your user PATH)
Invoke-WebRequest https://github.com/sbdchd/squawk/releases/download/v2.70.0/squawk-windows-x64.exe -OutFile "$HOME\.local\bin\squawk.exe"
```

CI installs the same pinned binary ([ci.yml](.github/workflows/ci.yml)), so it gates there too. Rules +
rationale (every excluded rule carries a reason; `assume_in_transaction` because our driver
wraps each migration in one transaction) live in [config/.squawk.toml](config/.squawk.toml).

**Hugo (showcase site, only if you edit `docs/site/`):** the site under `docs/site/` is built by
`scripts/build_site.ps1` around a pinned **Hugo v0.168.0** single binary (no Node/npm). Viewers never
need it — the generated `docs/site/public/` is tracked, opens via double-click (`file://`) and is
published unchanged to GitHub Pages by [pages.yml](.github/workflows/pages.yml) on every push to `main`
that touches it. Content editors install the pinned binary once:

```powershell
# Download hugo_0.168.0_windows-amd64.zip from github.com/gohugoio/hugo/releases/tag/v0.168.0,
# put hugo.exe into <repo>\.local\bin\ (gitignored) — or anywhere on PATH / point $env:HUGO_EXE at it.
# build_site.ps1 hard-asserts the version (a different Hugo changes the output byte-wise).
```

### Required for the DB / n8n tiers: Docker Desktop

Every test substrate (`bootstrap_test_db.ps1` for the DB tier, `bootstrap_test_n8n.ps1` for the n8n
tiers) runs as a throwaway Docker container — there is no live prod to test against. So `db_test`,
`n8n_test`, `e2e_test` and friends all need a running **Docker Desktop**. `setup_dev_env.ps1` only
*detects* it (a missing Docker blocks the success marker and keeps the session reminder up); it never
installs it, because Docker Desktop needs a reboot. Install it from
<https://www.docker.com/products/docker-desktop/>, restart Windows, then re-run `setup_dev_env.ps1`.

### Windows quirks (what `setup_dev_env.ps1` works around)

- **AppData junction-traversal block → `prek`/`uv`-managed Python fails.** On some Windows setups
  traversing a freshly-created directory under `%LOCALAPPDATA%` throws `ERROR_PATH_NOT_FOUND`
  (`0x80070003`) *even though the target exists by direct path* — which breaks how `prek` provisions
  its `uv`-managed Python. The fix is to move those trees out of AppData: `setup_dev_env.ps1` probes for
  the block and, only if it reproduces, sets the user env vars `PREK_HOME=$HOME\.prek` and
  `UV_PYTHON_INSTALL_DIR=$HOME\.uv\python`. `%LOCALAPPDATA%\Temp` is exempt from the block, so the probe
  deliberately does not run there. **Do not** work around this with a system Python — prek-managed
  Python is the supported path.
- **PEP-514 registry leftovers.** If a previous system/`uv` Python left stale entries under
  `HKCU\Software\Python` (e.g. `HKCU\Software\Python\Astral`), delete them so prek's Python discovery
  starts clean.
- **OneDrive-redirected `Documents` → `Install-Module` fails.** Known-Folder-Move breaks the default
  module path; `setup_dev_env.ps1` (and [scripts/ps_lint.ps1](scripts/ps_lint.ps1)) fall back to
  `Save-Module … -Path "$HOME\.local\psmodules"`.
- **winget PATH refresh.** A fresh `winget install` (PostgreSQL, prek) updates the *persisted* PATH but
  not your current shell. `setup_dev_env.ps1` mirrors every PATH/env change into the running process so
  its own later steps see it — but **you** still need to restart terminals *and* VS Code afterwards.
- **Success-marker limitation.** The marker `.local/devenv_state.json` fingerprints the *requirement
  list* (tool names + pins), not the live install state (no TTL — KISS). So a pin bump or an added tool
  correctly re-triggers the reminder, but a tool you *manually uninstall* later is not re-detected;
  re-run `setup_dev_env.ps1 -Verify` if in doubt.

## The enforcement gates

There are two enforcement points: **local (`prek`)** and **CI** ([.github/workflows/ci.yml](.github/workflows/ci.yml)).
CI runs the *same* commit-stage hooks via the same runner OS (Windows), so there is no local↔CI drift
(the exceptions are `dotenv-linter` and `gitleaks`, skipped in CI via `SKIP` — see Setup above).

| Stage | When | Examples | Hardness |
|---|---|---|---|
| **commit-stage** | every commit + CI | hygiene (trailing-ws, eof, private-key), actionlint/zizmor on our CI, the per-language linters (`shellcheck` on `provisioning/**/*.sh`, `ps-lint`/PSScriptAnalyzer on `scripts/**/*.ps1` + `packages/*/build/**`, `markdownlint` on hand-authored `*.md`, `sqlfluff-lint` on all tracked SQL (`packages/*/db/**` + `tests/**`; 7 per-file excludes with reasons in [.pre-commit-config.yaml](.pre-commit-config.yaml)), `gitleaks` secret scan on the staged diff), and the project gates: `doc_lint`, `config_test`, `mock_lint`, `workflow_lint`, `locale_lint` (text catalog per language complete, real umlauts), `contract_lint`, `cron_toggle_lint` (cron-toggle UX parity), `core_literal_lint` (no new core package-literal), `ui_literal_lint` (no new fixed German user text in workflows/R__ fns; ratchet allowlist), `role_test_lint` (every published DEFINER read-bridge fn with a `_ro` EXECUTE grant needs a SET-LOCAL-ROLE role-perspective test, fail-closed), `privacy_lint` (no real owner data: private IPs outside the example allowlist, home-network hostnames, Windows user paths; on the owner's machine also the gitignored denylist `.local/privacy_denylist.txt`), `layout_lint` (repo layout/structure invariants L1–L7 + retired-roots ratchet), the `repo: meta` hooks (`check-hooks-apply`/`check-useless-excludes` — every hook filter/exclude matches ≥1 file), capabilities catalog, fn catalog | **Hard** — deterministic, free, blocks the commit. |
| **commit-stage (migrations)** | adding/editing `packages/*/db/migrations/V*.sql` | `squawk` (Postgres migration safety: unsafe `NOT NULL` add, `CONCURRENTLY` inside a transaction, stray `BEGIN/COMMIT`) | **Hard** — runs locally **and** in CI (pinned binary; see Setup). |
| **commit-stage (local-only)** | editing `.env.example` | `dotenv-linter` (.env style) | **Hard locally, skipped in CI** (needs the prebuilt binary; see Setup). |
| **commit-msg** | every commit | Conventional Commits regex (`type(scope): subject`; optional `!` before the colon marks a breaking change) + `privacy-msg` (`scripts/privacy_lint.ps1 -MessageFile`: the message and the author/committer identity against the same privacy rules as the tree) | **Hard.** |
| **pre-push** | every push | `privacy-outgoing` (`privacy_lint -Outgoing`: messages + identities of every outgoing commit and every new annotated tag, i.e. the release notes) + `db_test` (Tier 1, deterministic DB/`fn_*` suite against an ephemeral Docker test DB) | **Hard.** |
| **pre-push (site)** | pushes touching `docs/site/` | `site-verify` (`build_site.ps1 -Verify`: fresh Hugo build byte-compared against the tracked `docs/site/public/`; needs the pinned Hugo binary — see Setup) | **Hard** (fires only for site-touching pushes). |
| **pre-push (soft)** | every push | `infra_softcheck` + `llm_suite_advice` (warns on touched behaviour surfaces; flags a new package surface for the parity checklist + owed README/site when the diff adds a new package-surface) — warnings only, never block | **Soft** (exit 0). |

The Docker-substrate and slow hooks are pre-push only and are **excluded from CI** (no test substrate
there). The **LLM-cost test suites** (`n8n_test`, `orch_test`, `e2e_test`, `judge_eval`,
`multiturn_test`) are **not** wired into the gates — they cost real credits and are owner-triggered;
`llm_suite_advice` only *recommends* them based on what you touched. For Claude Code sessions the
PreToolUse hook `.claude/hooks/enforce_owner_window.ps1` denies them (and the dev-instance reset) unless the
owner opened a window in the terminal with `scripts/grant_owner_window.ps1`.

The **free substrate suites** (`scripts/dev/hitl_gate_test.ps1`, `real_ingress_test.ps1`, `mock_route_test.ps1`,
`bot_menu_test.ps1`, `cron_text_test.ps1` — the last one triggers every cron and checks its Telegram texts in the
recipient's language, ~2 min per case) run against the mock Telegram/LLM in your own Docker substrate;
`release_fetch_test.ps1` tests the anonymous release download against a mock GitHub in a container (no n8n
needed). They are not
gates either (they need the substrate); run the one matching the surface you touched, or all of them at once with `scripts/dev/run_free_gates.ps1` (merge/release state).

### `--no-verify`

`git push --no-verify` (or `git commit --no-verify`) bypasses the hooks. **Emergency only.** A red
gate means fix the underlying issue — never bypass to ship. If a soft check is flaky (e.g. the substrate is
not running), it already exits 0 and will not block you, so the bypass should almost never be
needed.

## Branch protection

`main` and the `v*` release tags are protected by repository rulesets: no force-push, no deletion, no
moving a tag. Pull requests need the CI checks from [ci.yml](.github/workflows/ci.yml) to pass; the
maintainer pushes directly (admin bypass). Workflow runs from outside contributors wait for maintainer
approval and, as fork `pull_request` runs, get no secrets and a read-only token.
[.github/CODEOWNERS](.github/CODEOWNERS) documents who owns the sensitive paths (secrets / auth / build /
db functions).

## Workflow

1. Read [AGENTS.md](AGENTS.md) for the conventions, then the relevant `CLAUDE.md` for the area you
   touch (`packages/` + `packages/<pkg>/`, `scripts/`, `tests/`, …); mechanics and case histories live in `docs/reference/<area>.md`, SQL/PowerShell rules in `.claude/rules/` (loaded when matching files are opened).
2. **Plan first** for feature / blast-radius work (skill `/feature`): branch off `main`, then plan
   before any code — Scope → Plan (assumptions, touched surfaces, blast-radius gates, sources, the
   reference analog named; for `fn_*`/schema/trigger/new agent/tool/auth one Opus plan-reviewer, recorded
   as a `Plan-Reviewer:` line) → **Established-Pattern Check** (skill `/arch-challenge`: one evidence-backed
   research pass vs. established OSS patterns) for any new architecture/mechanism. A continuation session
   that only runs a plan phase: launch with `claude --permission-mode plan` (alias `claude-plan`) and read
   the handoff plan file first.
3. Make surgical changes against the approved plan.
4. TDD for any `fn_*` / schema change: write `tests/db/<pkg>/test_*.sql` first; iterate with
   `db_test.ps1 -Filter '*<subject>*'`.
5. Build workflows via `build.ps1`; deploy to the ephemeral Docker substrate via
   `scripts/dev/bootstrap_test_n8n.ps1 -Reset` (no live prod sync — prod is a deploy-only target via
   `provisioning/provision.sh`); verify against the substrate's real n8n run.
6. Before pushing a phase or a blast-radius change, run the built-in `/code-review high` on the diff
   (step 8 in the dev cycle) and fold in the findings; a new package surface additionally gets the
   parity checklist from `docs/package-contract.md` §8 against its reference analog.
7. Commit (Conventional Commits) and open a PR using the template — the **Real behavior proof**
   section is required, and all chat ids must be redacted to `__OWNER_CHAT_ID__`.
