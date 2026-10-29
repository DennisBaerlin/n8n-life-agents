# Core ↔ Package Contract

**Status:** Phases 1–5 of the Core/Package architecture (plan `tender-stargazing-shannon`) are **built**:
the DB framework + role model, the package tree (`packages/core`, `packages/finance`), the package-aware
toolchain, the finance extraction, and the **full lifecycle** — install/uninstall/activate/deactivate +
`backup` restore-before-install + bare-core-from-tarball (`provision.sh` = core bare + per-package loop). This
document is the **authoritative specification** of the contract surface — manifest, standardized package
files, DB isolation, and the CLI lifecycle. The implementing tooling (build/apply/deploy/seed,
`pkg_lifecycle.sh`) is built against this spec; the per-package install state-flow is in §6.

The contract is intentionally **0.x** (pre-1.0 SemVer: a minor bump may break) until the second
package confirms it (D8, §7). `CORE_API_VERSION` lives in `core.config (category='api',
key='core_version')`, seeded from the `.config` block of `packages/core/manifest.json` (§3.6).

---

## 1. CORE_API_VERSION & compatibility

- A package manifest declares the **minimum** `core_api` it needs (e.g. `"0.1.0"`).
- `core.fn_pkg_check_deps(p jsonb)` gates install/update with **SemVer-caret** semantics:
  compatible ⟺ *same major* **AND** *current ≥ required* (element-wise int compare). In 0.x the
  major is `0`, so any `0.y.z` package is checked against the current `0.Y.Z` core.
- Package roles never read `core.config` directly (§4). They obtain the value through the
  published `SECURITY DEFINER` read-fn `core.fn_core_api_version()`.
- **Breaking the contract** (removing/renaming a published read-fn or service alias, changing a
  `fn_*` return shape, an incompatible manifest-field change) ⟹ bump the **major** once ≥ 1.0;
  in 0.x ⟹ bump the **minor** and re-check every installed package on `update` (R9).
- **History:** `0.2.0` (paperless Phase 2) — additive: cross-package tool services (§5.1: object-form
  `provides.services`, qualified `core.services` rows + `permission`, `agent.sub_dispatch_tool`,
  `core.fn_resolve_service`); packages consuming `<pkg>:<alias>` services declare `core_api` `0.2.0`.
  `0.3.0` (Textkatalog Phase B) — packages read `core.fn_ui_text` for DB toasts, manifest text fields retired into
  the catalog (§3.11). `0.4.0` (Textkatalog Phase C) — additive: the recipient-text window `core.fn_ui_texts_for`
  (granted to every package role), `fn_advisor_review` alerts/digest as typed `tpl` structure, `validate_fn.display`
  may be a typed value (§3.9), `core.fn_staleness_alert` key overload.

---

## 2. `manifest.json` (one per package, fail-fast on a missing required field)

| Field | Req | Meaning |
|---|---|---|
| `name` | ✓ | Package id = schema name = role prefix. Must match `^[a-z][a-z0-9_]*$` (validated by `core.fn_provision_package_roles`). |
| `version` | ✓ | SemVer of the package. |
| `description` | ✓ | Long English technical description (developer/model layer; non-empty). Not shown to the owner. The owner-facing name + one-liner (AppStream `name`/`summary`/`description` triad) live in the text catalog as `<pkg>.package.name` / `<pkg>.package.summary` (§3.11; the former manifest fields `display_name`/`summary` are retired, `contract_lint` 15). |
| `core_api` | ✓ | Minimum `CORE_API_VERSION` required (SemVer). |
| `requires` | – | `[]` of package names that must be installed **and** `active` first (dep graph, checked **before** any mutation). |
| `schema` | ✓ | The package's primary Postgres schema name (= `name`; **Core exception** — multi-schema `core`+`agent`, see the privileged fields below). |
| `provides` | ✓ | `{ agents[], tools[], crons[], routes[], config[], models[], services{}, reads[]? }` — what the package adds (drives catalog/onboarding/routing materialization in later phases). `services` is the host's public service surface (§5): a `{ alias → workflow-name }` map (bare alias keys); consumers reference it as `core:<alias>`. A non-core package declares cross-package **tool services** in object form `{ alias → {workflow, description, permission, inputs} }` (§5.1), referenced as `<pkg>:<alias>`. `reads[]` = provider-owned read-fns this package publishes for OTHER packages to consume cross-package (mirror of `consumes.reads`, §4.2; e.g. `["finance.fn_liquidity_snapshot()"]`). `agents[]` = objects `{name, router_description, order, fallback_for?}`: `router_description` (EN, layer 1, **required** for every agent except `orchestrator`) is the agent's **whole routing knowledge** — what it handles, its boundaries (`NOT for … -> agent.<x>`, every `agent.<x>` must be a declared agent — a reference to an agent of a package ABSENT from the repo is only a warning, Phase D; a near-miss of a declared/present name stays an error), which attachment document kinds it accepts; the build bakes it into the router's call-tool description, the core router prompt names no package (Phase C). `fallback_for` (optional list, allowed kinds: `attachment`) = this agent receives an attachment whose kind stays unclear; each kind is claimed by at most one agent across all packages (the build throws otherwise). Enforced by `scripts/build/lib/agent_routing.ps1` (build + `contract_lint` Check 19). |
| `consumes` | – | `{ services[], reads[] }` — namespaced core service aliases `core:<name>` (§5) + opt-in tool services of other packages `<pkg>:<alias>` (§5.1, never the own package) and published read-fns the package may call: `core.fn_*(…)` (host read windows) **and** cross-package `<pkg>.fn_*(…)` declared in that provider's `provides.reads` (§4.2, optional dependency). **The lint source** for D9/D10: a package may only reference what it declares here; `contract_lint` reconciles non-`core.*` entries against the provider's `provides.reads` (fail-closed). |
| `context_validators` | – | `{ "<context_name>": "<schema>.<fn>" }` — declares a structural validator for a package-owned `core_contexts` facts-sidecar (§3.3). The host seeds it into `core.context_validators`; the core trigger dispatches generically. `<schema>` **must** equal `name` (own-schema-scoped). |
| `context_renderers` | – | `{ "<context_name>": "<schema>.<fn>" }` — declares the header renderer (`fn(text)→text`) for a facts-carrying `core_contexts` row (§3.3). Host seeds it into `core.context_renderers`; `core.fn_fetch_context` (SECURITY DEFINER) dispatches + wraps banner/stamp/prose generically. Own-schema-scoped; **core** may bind `agent.*` (only the host `family` renderer; package contexts register their own renderer, e.g. `finance.fn_render_finance_profile`). |
| `advisors` | – | **Nested** `{ "<domain>": { "plan_context": "<context>", "review_fn": "<schema>.<fn>", "advisor_agent", "learn_notes"? } }` — declares an advisor domain (Soll-Ist drift/staleness/digest, §3.3). Host (`_seed_advisors`) seeds it into `core.advisors`; the generic wrapper `core.fn_advisor_review_evaluate` dispatches + latches. `review_fn` (`fn(text,text,jsonb)→jsonb` = domain, person_id, observations — P2a uniform person-fanning) own-schema-scoped. Tuning lives in `core.config`. Optional `learn_notes` (bool, default false, Phase A) = the plan document may carry owner-confirmed learned notes (`## Gelernt`, `core.fn_note_context_allowed`); household plan contexts only (`contract_lint` 16c). Optional `own_review_cron` (bool, default false, Roter Faden) = the domain brings its own review cron, so the shared advisor crons (`drift_check`/`plan_review`) skip it (estate). Optional `plan_step` (bool, default false, 2026-10-28) = the domain offers the recommended onboarding plan step (button `plan:<domain>` → `advisor_agent`; §3.2); with it, optional `gaps_fn` (`fn(text,text)→int`, open points of the active plan) and `readiness_fn` (`fn(text,text)→jsonb {ready, missing:[{key, section}]}`, hard minimum data for a meaningful plan; missing-item texts `<pkg>.plan_ready.<key>`), both own-schema-scoped and read only by `core.fn_advisor_plan_status` (`contract_lint` 16c). |
| `context_scopes` | – | **Nested** `{ "<context_name>": { "scope", "write_permission" } }` — declares the scope (`household`/`per_user`) + write_permission (`owner_only`/`adults_only`/`own_user_only`) of a facts-context (§3.3, P0a). Host (`_seed_context_scopes`) seeds it into `core.context_scopes`; `agent.fn_check_write_permission` enforces it (identity from `fn_resolve_sender`). Data enums, **no** own-schema check. Every `context_validators` key needs a row (`contract_lint` Check 10). |
| `context_skeletons` | – | **Nested** `{ "<context_name>": { agent_name, description, content, facts } }` — package-owned facts-contexts whose EMPTY skeleton the package itself creates (Install-UX-Phase 6; Debian-postinst pattern). Host (`seed_data.sh _seed_context_skeletons`) inserts the row **insert-only** (`ON CONFLICT DO NOTHING`, lazy, `managed_by='agent'`, `package=<pkg>`) on every install/update, also with `--no-seed` — existing (PII) facts are never touched; `fn_pkg_purge_data` removes it with the package. Every key must be a `context_validators` key and must not be `per_user`; conversely every household-scoped `context_validators` key needs a skeleton (`contract_lint` 15b/16a; details §3.3). |
| `monitor_acquisition_methods` | – | **Nested** `{ "<method>": { acquire_fn, validate_fn, params_description } }` — package value-acquisition methods of the core trigger monitoring (§3.9, Phase B). Host (`_seed_monitor_acquisition_methods`) upserts them into `core.monitor_acquisition_methods` (fns own-schema-scoped, `(jsonb)` arity); `params_description` (EN) is build-time data baked into the monitor tools; the owner-visible name lives in the text catalog (`<pkg>.monitor_method.<method>`, §3.11). **Core** declares none (its builtins are init rows). `contract_lint` Check 18. |
| `languages` | – | **Core only.** `{ "_comment", "list": [ { code, name, locale, date_pattern, ord, aliases[] } ] }` — THE list of supported languages for fixed user texts (§3.11). Host (`_seed_ui_languages`) upserts it into `core.ui_languages` (never deletes a code in use); `locale_lint` keeps every `locales/` complete against it. |
| `personas` | – | **Core only.** `{ "_comment", "list": [ { code, ord } ] }` — THE list of bot personas per person (`family.persons[].persona`; `neutral` = key omitted). Host (`_seed_ui_personas`) upserts it into `core.ui_personas` (never deletes); every code needs `core.persona.name.<code>` (`locale_lint`) and, except `neutral`, a `### <code>` section in `packages/core/contexts/persona_styles.md` (`contract_lint`). |
| `retired_workflows` | – | `{ "_comment", "list": [ { "id", "name", "since" } ] }` — explicit tombstones of workflows this package once shipped (Phase A; dpkg `rm_conffile` analogue). `deploy_workflows.sh retire_workflows` deletes them on existing instances after the import (GET name check, 404 = already gone, an active trigger ⟹ one n8n restart). A retired id must not be in the tree nor referenced (`contract_lint` 16e). **Bei uns anders:** no set-based prune (ApplySet/Flux) — n8n workflows carry no ownership label, a name-prefix prune would be heuristic. |
| `retired_credentials` | – | `{ "_comment", "list": [ { "name", "type", "env_keys": [], "since" } ] }` — explicit tombstones of n8n credentials this package once created (paperless v0.3.0; sibling of `retired_workflows`, dpkg `rm_conffile` analogue). `deploy_workflows.sh retire_credentials` runs right AFTER `retire_workflows` (the retired workflows referenced them): deletes only on matching name AND type (mismatch = warn), 404/absent = already gone, never fatal; then strips exactly the listed `env_keys` from `/etc/lifeagents/<pkg>.env` (no secret left behind). `contract_lint` 16f: a retired name/env key belongs to no current `credentials` entry. **Bei uns anders:** tombstones, not a reconcile — same reason as `retired_workflows` (external credential names do not even carry a package prefix). |
| `catalog` | – | Capabilities-catalog **block** owning the STRUCTURE of this package's `/help` categories + tail sections (§3.5): `{ ord, categories[{id,ord}], tail[{id,ord}] }`; the texts are catalog keys `<pkg>.help.<id>.*` (§3.11). `build.ps1` renders one fragment per catalog language from it + the co-located tool `_manifest`s; the host composes all fragments by package `ord`. |
| `commands` | – | Slash-command registry **block** (WS-5): `{ list:[{cmd, visibility:owner\|member\|all, dispatch?:{agent,task}}] }` — the single SoT for the package's deterministic Telegram commands; the menu text is the catalog key `<pkg>.cmd.<name>` (§3.11, ≤ 48 chars per language). Feeds `scripts/command_lint.ps1` (coverage vs the orchestrator `Command router` + the `/help` tail in every language, fail-closed) and `setMyCommands` (owner menu = visibility IN (owner,all); default menu = visibility IN (member,all); one menu per catalog language + a fallback in the owner's language, §3.11). Hidden deterministic commands (`/start`, `/hilfe`, `/sprache`) are allowlisted in the lint, not registered. **`dispatch:{agent,task}` (optional, WS-5 estate `/notfall`) = a CODE-PATH command:** `build.ps1 $CommandDispatchList` (mirror of `$OnboardingDispatchList`) generates a `/xxx` switch case in the orchestrator `Command router` + a Run/Relay dispatch arm → `agent.<agent>` INLINE (message.text path, synthetic `task`, `call_depth=1`; fallback stays LAST). Core commands (`/help`/`/onboarding`/`/start`) have NO `dispatch` = host-bespoke handlers. **Discriminant (§8):** a code-path command → the build-time `Command router` switch; a pure text-/button-callback prefix → the runtime `core.callback_handlers` registry. |
| `backup` | – | Declarative backup surface (§3.7) — which of the package's user-data tables the CLI (`lifeagents backup`) dumps/restores: `{ schema_dump?, exclude_tables[]?, full_tables[]?, filtered_tables{qual→WHERE}? }`. Read by `backup_cli.sh` (jq), not by SQL. |
| `credentials` | – | Declarative package secrets (§3.8) — the n8n credentials a package needs from external API keys: `{ "<name>": { placeholder, name, type, required?, env{ KEY: {field, validator?, secret?, prompt} } } }`. Read by `inject_credentials.sh` + the stage-4 wizard (jq), never by SQL. |
| `approval_matrix` | – | Maker-checker tier per HITL-gate caller of this package (§3.10): `{ "<workflow-name>": { tier, reason[, break_glass] } }`. Build data only (`build.ps1` injects the tier, `approval_lint` verifies) — never read by the installer or SQL. |
| `app_screens` | – | Screens this package contributes to the read-only Telegram Mini App (§3.12): `{ "<screen>": { handler_fn, ord, icon } }`. Host (`_seed_app_screens`) seeds them into `core.app_screens`; `core.fn_app_screen` dispatches generically. Own-schema-scoped, `(jsonb)` arity. |
| `migrations` | ✓ | Path to the package's `db/` migration set (own schema only; **no core/agent DDL** — DB4/R11). |

The **core is itself a package** (`name: "core"`, always `active`) for homogeneous handling (D1/PM4) — but
as the **privileged host** it is the one documented exception to the single-schema / isolated-role model:

- **`privileged: true`** — the core package is **exempt from the per-package role isolation** of §4. It is
  **not** provisioned `core_rw`/`core_ro` (`core.fn_provision_package_roles` is **not** called for it); the
  core workflows use the host n8n credentials (`n8n write` + the RO leases). A normal domain package never
  sets `privileged`.
- **`schemas` (array)** — the core owns **two** Postgres schemas (`core` + `agent`, the shared framework,
  both *never dropped*). `schema` (singular, = `name`) stays for homogeneity; `schemas` lists the full set
  it owns. A normal package owns exactly one schema (`schemas` = `[name]`, may be omitted).

These two fields are **only** valid on the core package; the registry/catalog/lifecycle treat core like any
other package (it has a manifest with `description`, a registry row, a catalog fragment).

---

## 3. Standardized package declaration files

### 3.1 `contexts/*.md` (D4)

Each file becomes one row in `agent.core_contexts` on install, stamped with the **typed columns**
`package='<name>'` (ownership / uninstall-purge key) and `managed_by='seed'` (sync provenance — both
are real columns since D14/WS-B2, not `metadata` keys; `--purge` drops `WHERE package='<name>'`),
removed on uninstall/purge. YAML frontmatter, then the body — the three-field seed-context schema:

| Frontmatter | Meaning |
|---|---|
| `description` | Required, non-empty (manifest index for lazy contexts). |
| `agent_name` | Empty ⟹ `NULL` (visible to all); else the owning agent. |
| `load_strategy` | `static` \| `lazy`. |

Filename (sans `.md`) = the DB `name`, must match `^[a-z0-9_]+$`. **Deletion protection is NOT a
frontmatter field** — it is declared per package in the manifest `protected_contexts` list (§3.4), which
also covers runtime-created contexts that have no `.md` (e.g. `family`, `finance_profile`).

### 3.2 `onboarding/sections.json` (WS-B3, O3 — DRY onboarding, replaces the D3/K5 delegation model)

`[ { "key", "ord", "gates_advisor"? } ]` — the package's own onboarding sections (no `handler`/`content_ref`:
there is **no cross-agent delegation**). The label of each section is the catalog key `<pkg>.onboarding.<key>`
(§3.11; the `/onboarding` menu shows it in the viewer's language, the state-table column `label` is the German
model-facing projection seeded from `locales/de.json`; a `label` in `sections.json` is retired, `contract_lint` 15).
The host seeds them into the package's own state table via `seed_data.sh` (`_seed_onboarding_sections`). Model
(owner decision O3):

- **Core owns the generic onboarding *feature*, not per-package copies.** The tri-state machine lives once
  in two **package-keyed** core functions — `core.fn_onboarding_status(p_package)` (SECURITY DEFINER, the
  published read window — combined: it returns the core leg **and** the named package's leg in one call) and
  `core.fn_set_onboarding_section(p jsonb {package,section_key,status})` (SECURITY INVOKER — the write stays
  bounded by the caller's own grants). Both are EXECUTE-granted to the package roles in
  `core.fn_provision_package_roles`. Status is `text + CHECK ('unknown'|'completed'|'skipped')` — **not** a
  shared cross-schema ENUM (avoids the restricted-role type-USAGE trap; Crunchy "Enums vs CHECK").
- **Each package owns only data:** a state table of the **homogeneous shape** `<schema>.onboarding_state`
  (`section_key`/`ord`/`label`/`status`/`updated_at`/`status_changed_at`) in its own schema, seeded from its
  `sections.json`. The host maps the package key → `<pkg>.onboarding_state` by **convention** (derivable →
  no registry, "one fact one address"); the package key is a build-time constant, never `$fromAI`. Core's
  own onboarding table is the host-exception `agent.guide_onboarding_state` (key `'core'`, holds `household`).
- **Agent-driven on first invocation:** the owning agent requests its onboarding itself — the finance agent
  reads `core.fn_onboarding_status('finance')` at its entry (under its read role) and, when incomplete,
  proactively guides capture with its own tools + marks sections via its `set_onboarding_section` tool. There
  is **no** guide→package delegation: the guide onboards only `household`; each package onboards its own
  sections. The mandatory-onboarding gate (finance advisor pre-req, finance-owned key `feature.onboarding_gate`) reads the same combined
  fn (`core.complete AND package.complete`), except that open sections marked `"gates_advisor": false` in `sections.json` do not block it (finance: the monthly statement check). The flag only matters for a package whose advisor has such a hard entry gate and is not itself the onboarding agent (finance); career's advisor onboards its own sections, estate has no package gate.
- **Next-step card + follow-up (Roter Faden 2026-10-23):** every `set_onboarding_section` tool ends with
  `New-OnboardingProgressCallNode` (core service `core:onboarding_progress` → `core.sub_onboarding_progress`, fire-and-
  forget). `core.fn_set_onboarding_section` returns `area_completed_now` (this call closed the area — advisory-locked per
  (package, person), exactly once per transition) and `area_all_skipped`; the sub then sends the `/onboarding` overview
  with a header ("<area> set up") and its "Weiter" button, once the learn-loop offer (owner, after the LAST area) and once
  "you can start" to the paired members (household done) — latched in `core.fn_onboarding_progress_event`. The agent
  therefore never points to the next area itself (`packages/core/contexts/global_instructions.md` *Onboarding hand-off*). Stalled onboarding is
  followed up by `agent.guide.cron_onboarding_nudge` (`core.fn_onboarding_nudges_due`: 3 / 10 idle days on
  `status_changed_at`, then silence until new open sections appear) — so `status_changed_at` is part of the convention
  and is stamped only by `fn_set_onboarding_section` / `fn_reset_onboarding_state` (status changes, not label resyncs).
- **Plan step (2026-10-28):** an advisor domain with `advisors.<domain>.plan_step` (§1 table) gets a *recommended* step
  behind its package's sections — never a section: it counts neither in the progress nor in the "all set up" latch
  (`fn_onboarding_progress_event` and the nudges read only `sections`), it never blocks the path to other areas, it
  sends no reminders. The menu reads it from `core.fn_advisor_plan_status` (own DEFINER window for `core_ro`;
  `fn_onboarding_overview` stays sections-only, its card/cron callers never pay for or fail on package fns; a failing
  package fn degrades to neutral) — the one address for state `none|draft|gaps|complete`, `open` = `gaps_fn`, `ready`/`missing` = `readiness_fn`, `can_write`
  = owner, as the plan tools are `owner_only`. Available once no *gating* section of the package is open (same
  `gates_advisor` rule as the advisor gate). "Next" points to it on that package's done card, or when no section is
  open anywhere; missing minimum data turn the button into "First: <section>" (`onboarding:<pkg>:<section>`).
  The button `plan:<domain>` is a `callback_handlers` prefix (`core.fn_handle_plan_cb`, member_permeable) → the
  orchestrator's build-time arm per domain starts the `advisor_agent` with a fixed English task + the tapper's reply
  language.
- **Plan sharing (2026-10-28):** after publishing a **household** plan, `tool_publish_plan` offers the owner
  "Inform adults" (`core.fn_plan_share_preview`; button `plan:share:<domain>:<version>`). `core.sub_share_plan` sends each
  adult member (role `partner`, connected, person reminder `plan_news` on; one rule `core.fn_plan_adult_recipients`)
  one message per plan version (latch `plan_news` `<pid>:<domain>:p<plan_id>`, set only after a delivered send by
  `core.fn_plan_share_mark`; the owner gets the result as a message),
  in the member's language; the stored `change_summary` shows only for the language it was written in
  (`change_summary_lang`), never translated. Buttons `plan:explain:<domain>` / `plan:wish:<domain>` (partner only) start
  the advisor in explain mode (read-only) or wish mode (`tool_record_plan_wish`, `owner_info`: the owner gets the wish
  verbatim; `agent.advisor_plan_wishes`), `rem:off:plan_news` unsubscribes.
- **Button follow-up (2026-10-28):** every button arm that starts an agent records it after the relay
  (`agent.fn_set_dispatch_followup`); the next routed message reads it once (`agent.fn_take_dispatch_followup`, 30 min) →
  router flag `followup_agent` (router rule 2a). One row per chat, last write wins; commands do not consume it.
- **Registry upgrade trigger:** switch the convention to a `core.onboarding_packages` registry only once a
  package's state table stops matching `<pkg>.onboarding_state` (first non-conforming package).
- **Generic discovery (WS-3, no registry):** `core.fn_onboarding_pending_packages()` (SECURITY DEFINER) walks
  `core.package_registry` (active, non-`core`) + `to_regclass('<pkg>.onboarding_state')` and returns the packages
  with still-open sections — the guide offers them generically after household onboarding (no `finance` hardcode).
  Same convention-over-registry stance as above (derivable → no table until it breaks).
- **Generic `/onboarding` menu + routing (P1):** a package that wants its own onboarding declares **one** manifest
  block `"provides": { "onboarding": { "agent": "<agent>" } }` — the agent that *captures* its sections (not derivable:
  finance has two agents, the bookkeeper captures; career has `career_advisor`). That is the ONLY new declarative fact;
  the sections still come from the convention `packages/<pkg>/onboarding/sections.json` (no `sections_file` field —
  arch-challenge D3, "one fact one address"). The menu reads the no-arg window `core.fn_onboarding_overview()` →
  `{ok, sections:[{package,key,label,status,ord}]}` (core household first, then active packages); buttons encode
  `onboarding:<package>:<key>` and the orchestrator's onboarding-callback arm is **build-time generated** per package
  (parity with `$AgentRoutingList` — a new onboarding package docks without an orchestrator edit; convention over a
  runtime registry, arch-challenge D1). `contract_lint` check 11 enforces `provides.onboarding.agent` ⟺ a non-empty
  `sections.json` (bidirectional, fail-closed) + that the agent is one of the package's `provides.agents`. Core stays
  the hardcoded special case (household → `agent.guide`, no `provides.onboarding`). The hard per-package onboarding
  gate (advisor pre-req) for a per-person package (career) is **implemented in P2b-1**: career-local
  `feature.career_onboarding_gate` (default ON) at the career_advisor entry (after Load Config) reads
  `core.fn_onboarding_status('career', chat_id)` person-scoped; if the asking person's own career onboarding is
  incomplete, a `## Career onboarding required` section is appended to the system prompt and the advisor captures the
  profile first instead of advising (no redirect: an advisor that is its package's own `provides.onboarding.agent`
  must not redirect, or it locks out its own onboarding task); `career.onboarding_state` is per-person (`career:V004`). Details in §8.
- **Core-first invariant (WS-3):** no package may be used before **core** onboarding (household) is complete. The
  authoritative gate is a deterministic, always-on stage at **each package agent's entry** (after the package-active
  gate, before Load Config) reading `core.fn_onboarding_status('core')` — not the router (LLM-routed, package-neutral).
  It is generic (core leg, no package literal); a package-local flag-gated advisor gate (finance `feature.onboarding_gate`
  = core+finance, declared in the finance manifest since Phase C; career `feature.career_onboarding_gate`) remains the
  stricter stage on top.

### 3.3 `context_validators` manifest block (WS-B1 / D12)

A package-owned `core_contexts` facts-sidecar (e.g. `finance_profile`) gets its structural rules
enforced by a **package** function; the core must **not** name the package. The manifest declares the
binding (`{ "<context_name>": "<schema>.<fn>" }`); the host (`seed_data.sh`, jq) **upserts** it into the
host table **`core.context_validators(context_name PK, validate_fn)`** — the package never writes that
table itself (declaration vs. execution; package roles are D10-isolated from schema `core` anyway). The
core trigger `agent.trg_core_contexts_validate_facts_fn` then dispatches **generically**: `NEW.name →
registry lookup → dynamic EXECUTE` of `validate_fn(jsonb)` (a per_user row `<base>__<pid>` resolves via its
longest per_user base name in `core.context_scopes`; its error message carries no values), with `search_path` pinned to `pg_catalog`
(CVE-2018-1058) and a `to_regprocedure` guard (missing row ⟹ silent skip = graceful degradation when the
package is absent). Constraints: `validate_fn` must be schema-qualified lowercase (CHECK) and point into the
**own** schema (`<name>.*`, host-enforced at seed); the PRIMARY KEY means **one validator per context**
(first package wins, a second binding collides visibly at seed). This is the established **plugin/hook
registry** shape (DIP/OCP) for pure-SQL packages, replacing the earlier hardcoded `to_regprocedure('finance…')`
dispatch (owner override, arch-challenge ADOPT).

**`context_renderers` manifest block (WS1b — render registry).** The sibling registry for the *rendering*
half: a package binds a facts-carrying `core_contexts` name to the function that builds its **authoritative
facts header** (`{ "<context_name>": "<schema>.<fn>" }` → host upserts into **`core.context_renderers(context_name
PK, render_fn, package)`**). The generic engine `core.fn_fetch_context` dispatches over it (`p_name → render_fn`,
dynamic EXECUTE, `search_path=pg_catalog`, `to_regprocedure(…(text))` guard) and **wraps** the result uniformly:
`Banner + Header + _meta stamp + '---' + prose content`. The renderer returns **only the header** (derivations —
calendar years, ages, nominal projections — computed at render time, never stored), or NULL ⟹ the engine returns
the raw prose. Key differences from `context_validators`: the signature is **`fn(text)→text`** (context name as
arg, not `fn(jsonb)`); and the **core** package may bind `agent.*` (not just `core.*`) because the shared
household renderers (`family`, `finance_profile`) live in the host `agent` schema (`finance_profile_context`
joins `family` cross-context — a host concern). This replaces the earlier WS1a name-bound whitelist branch in
`fn_fetch_context` **and** the mutable `metadata.render_fn` flag (an attacker with context-write could set it;
the registry is installer-only) — one render path for every context, financial_planning incl. (arch-challenge ADOPT).

**`advisors` manifest block (WS2 — Core-Advisor-Engine).** A third sibling registry: a package declares an
**advisor domain** — a binding of a domain to its Soll-plan context + the package function that computes
Soll-Ist drift / staleness / the periodic digest. **Nested** shape (two values per domain, unlike the flat-map
siblings): `{ "<domain>": { "plan_context": "<context>", "review_fn": "<schema>.<fn>" } }` → host
(`seed_data.sh _seed_advisors`, jq) upserts into **`core.advisors(domain PK, plan_context, review_fn, package)`**,
own-schema-scoped (`review_fn` must be `<pkg>.*`; core may bind `core.*`/`agent.*`). The generic wrapper
`core.fn_advisor_review_evaluate(domain[, person_id])` dispatches over the registry (`domain → review_fn`, dynamic EXECUTE,
`search_path=pg_catalog`, `to_regprocedure` guard) and applies the generic latch (the shared
`core.notification_state` via `core.fn_should_notify`, `source='advisor:'||domain||COALESCE(':'||person_id,'')` — P2a person-suffix, NULL=household byte-equal) plus reconcile-GC; the two core crons (`agent.advisor.cron_drift_check`/`cron_review`) iterate the registry. The
`review_fn` signature is **`fn(text,text,jsonb)→jsonb`** (domain, person_id, observations; P2a uniform 3-arg — finance ignores person_id=household, career uses it) returning `{alerts, digest}` where each alert and the digest
carry a package-rendered `text` field (the generic crons know no package fields — they only join `text`).
`package` scopes the uninstall purge (`fn_pkg_purge_data` removes the advisor row, else an orphan `review_fn`
dangles after the package's `DROP SCHEMA`). Optional per-domain flags/fns beyond the two required values: `learn_notes`,
`own_review_cron`, `plan_step` + `gaps_fn`/`readiness_fn` (onboarding plan step, read only by
`core.fn_advisor_plan_status`; §1 table, §3.2). Tuning scalars (cadence, model, thresholds) live in `core.config`
(`schedule.*`/`model.advisor_review`/`cron_enable.*`/`advisor.*`), **not** in the registry (owner directive: no
model coupling). Established **plugin/hook registry** shape, like its two siblings (arch-challenge via precedent).

**`context_scopes` manifest block (P0a — declarative scope/permission registry).** A further sibling: a package
declares per facts-context **two orthogonal axes** — `scope` (`household` = one shared row | `per_user` = one row
per person) and `write_permission` (`owner_only` | `adults_only` = role ∈ {owner,partner} | `own_user_only` =
resolved person == target person_id). **Nested** shape `{ "<context>": { "scope", "write_permission" } }` → host
(`seed_data.sh _seed_context_scopes`, jq) upserts into **`core.context_scopes(context_name PK, scope,
write_permission, package)`**. **No own-schema boundary check** (unlike validators/renderers/advisors — like
`cron_labels`): the values are data enums, **not** fn identifiers; the enforcement is the table CHECKs (`scope`,
`write_permission`, and the cross-CHECK `own_user_only ⟹ per_user`). The permission is enforced by the generic
predicate `agent.fn_check_write_permission(write_permission, chat_id, target_person_id)` (NULL=ok / reason-token,
identity always from `agent.fn_resolve_sender` — never LLM); the `owner_only` branch **delegates to**
`agent.fn_sender_is_member` (no duplicated logic). Orthogonal to the `approval_matrix` (two axes: HOW it's
confirmed = HITL flow per gate-caller; WHO may write = identity per context). `contract_lint` Check 10 enforces
**validator ⟺ scope** parity bidirectionally (every `context_validators` key has a `context_scopes` row and vice
versa, fail-closed). P0a is behavior-neutral (all contexts `household`/`owner_only` = byte-identical to the prior
hardcode); **P0b wires `per_user`/`own_user_only` live for `career_profile` + `career_preferences`**; **P0c adds
`career_planning`** (its writer is the shared `advisor_plans` machinery — now `(domain, person_id)`-keyed; see the `advisors` registry above + `packages/core/CLAUDE.md`).
All three career contexts are now `per_user`/`own_user_only`; `financial_planning` stays `household` (registry-driven).
**Per-user storage = name suffix** `<base>__<person_id>` in `agent.core_contexts` (arbiter decision: `name` stays
UNIQUE, no schema migration, no FK). `core.fn_fetch_context(p_name, p_chat_id)` (read) + `agent.fn_set_context_facts` (write) resolve the
`person_id` from the chat_id via `fn_resolve_sender` (never `$fromAI`), suffix for content I/O, and **strip back to the
base name for every registry lookup** (registries stay exact-match). Unresolved sender ⟹ fail-closed (read = empty base
row, write = `{ok:false}`). `trg_core_contexts_protect` is suffix-aware (a living member's per_user PII stays
delete-protected); `fn_remove_household_person` purges the removed person's per_user rows generically over
`context_scopes WHERE scope='per_user'`. Migration `career:V001` renames existing base rows to the owner suffix
(idempotent). **"Bei uns anders" (name suffix vs. discriminator column):** these contexts are fn-lifecycle-managed
(`managed_by='agent'`, never seeded, purged explicitly), person deletion is project-wide RESTRICT+explicit purge (FK
benefit moot), and the column variant would force a `DROP UNIQUE(name)` breaking ~3 prod + ~50 test paths on
**uninvolved** household contexts (Surgical Changes).

**Facts write path (Phase A — ONE write path for every facts-sidecar).** A package-owned PII facts-sidecar must be
written at runtime, yet D10 forbids any package role from writing the shared host table `agent.core_contexts`. The
single core service `agent.fn_set_context_facts(p jsonb)` (HITL tool `agent.tool_set_context_facts`, approval tier
`owner_only`; one workflow, several bindings — the guide binds it as `tool_set_household_facts` with `scope='household'`
fixed, career as `tool_set_profile_facts`/`tool_set_career_preferences` with `scope='per_user'` fixed, never `$fromAI`)
mediates it — gated **not** by a hardcoded context allowlist but by the registries: a package opts in by declaring a
`context_validators` entry (+ `context_scopes`). It replaced `fn_set_household_facts` + `fn_set_profile_facts`.
- **household branch** (`family` = host context, hard `owner_only` checked first; plus registered household contexts of
  ACTIVE packages, gate `core.fn_facts_context_allowed`): the row **must already exist** (installer skeleton, see
  `context_skeletons` below) — a missing row is `{ok:false}`, never an insert, because the visibility (`agent_name`) is
  package-declared and an insert-on-first-write would make it silently global.
- **per_user branch**: person from `fn_resolve_sender(chat_id)` (fail-closed), storage `<base>__<person_id>`,
  **INSERT on first write** (`managed_by='agent'`, `load_strategy='lazy'`, `agent_name=NULL`, `package` from the
  registry row), package must be active.
- **Reserved core shape keys** (every sidecar; validated by the core trigger): `persons` = array of objects keyed by a
  regex-valid unique `person_id` (household contexts only; every `person_id` of a non-family context must exist in
  `family`), `household` = object. Merge = strategic-merge-patch analogue: `persons` merged per `person_id` (as_of
  stamp), `household` shallow, other top-level keys replaced; `null` deletes exactly that patch key; `persons:null`,
  `household:null`, `person_id:null` and any `_meta` input are `{ok:false}` (removing a person is
  `fn_remove_household_person`, which also cascades the person's entries out of every `persons[]` context).
- Registry-driven write-permission DB backstop (`agent.fn_check_write_permission` over `context_scopes`; missing row ⟹
  `owner_only`), friendly pre-validation (core validator + registered package validator ⟹ `{ok:false}` without write),
  the derived-value denylist trigger is the structural backstop.

**`context_skeletons` (Install-UX-Phase 6) — pre-seeded empty skeleton of a HOUSEHOLD facts-context.** Every
household-scoped facts-context of a package declares `{ "<context>": { agent_name, description, content, facts } }`
(`contract_lint` 16a enforces it — the write path never creates household rows); the host
(`seed_data.sh _seed_context_skeletons`) inserts it **insert-only** (`ON CONFLICT DO NOTHING`, only if the package
is registered, also with `--no-seed`; incomplete entries are warned + skipped) — the Debian-postinst pattern that
replaced the core owner-bootstrap creating a package row. `fn_pkg_purge_data` removes it with the package
(`core_contexts WHERE package`). Writable only while the package is active (`core.fn_facts_context_allowed`).
`contract_lint`: every key must be a `context_validators` key and must **not** be `per_user` (per_user contexts are
created on first write as `<base>__<person_id>` by `fn_set_context_facts`; an unsuffixed base skeleton would never be
written).

**HITL labels of a facts-context** live in the package's text catalog (§3.11), not in the manifest: the title
`<pkg>.facts.<context>.title` (required per `context_validators` key, `locale_lint`) and one key per field
`<pkg>.facts.<context>.<field>` (one flat namespace for top-level, `persons[]` and `household` keys; an open field
without a key shows its readable field name). `build.ps1` derives `{context: package}` from the `context_validators`
blocks and bakes it into `agent.tool_set_context_facts`; the gate renders the labels in the recipient's language. The
former `facts_display` block is retired (`contract_lint` 16b rejects it).

### 3.4 `protected_contexts` manifest block (WS-B2b — deletion protection)

A package declares which `core_contexts` rows must not be deleted by listing their names in the manifest
(`"protected_contexts": ["<name>", …]`). The host (`seed_data.sh`, jq) **upserts** them into the host table
**`core.protected_contexts(context_name PK, package)`** — the package never writes that table (declaration vs.
execution; package roles are D10-isolated from schema `core`). The core trigger `agent.trg_core_contexts_protect`
(BEFORE DELETE, `search_path` pinned, **no** SECURITY DEFINER) raises if `OLD.name` is registered. This is the
**Kubernetes finalizer / ownerReference** pattern: a registered row is undeletable until its registry entry is
removed — which only the host does, at **uninstall** (§6). Core is never uninstalled ⟹ core's protected contexts
are permanent. The list covers **runtime-created** contexts too (`family`, `finance_profile`, `financial_planning`),
which have no `.md` to carry frontmatter — the decisive reason this is a manifest list, not a per-file flag.
Replaces the retired name-hardcode + mutable `metadata.protected` flag + name-pattern auto-protect trigger
(owner directive 2026-06-18, arch-challenge ADOPT). PK = one declaration per context; `package` scopes the
uninstall purge.

### 3.5 `catalog` manifest block (WS-B7 — per-fragment capabilities catalog)

Each package **owns** its `/help` capability surface in its manifest `catalog` block — the STRUCTURE only:
`categories[{id,ord}]` (the `id` must equal the `Category` of the package's co-located tool `_manifest`s — a tool
whose `Category` is undeclared here is a hard `build.ps1 -VerifyCatalog` FAIL, the cross-package leak guard; the
**reverse** is allowed — a category declared with **no** matching tool `_manifest` is silently **skipped** at
render time, the forward-declaration pattern for planned tools) + package-owned `tail[{id,ord}]` (capabilities
without a tool: advice, commands). The TEXTS live in the package's text catalog (§3.11, Textkatalog Phase B):
`<pkg>.help.<id>.title|description` + up to three examples `<pkg>.help.<id>.ex1..ex3` per category,
`<pkg>.help.<id>.title|body` per tail section, the header `core.help.*`. Examples are curated in the catalog (no
longer pulled from the tools); the **German** value of every example must be a verbatim routing-case utterance
(`Find-CatalogExamplesWithoutCase`, the golden cases are German) — the translations carry the same statement.
`build.ps1` **renders** one GENERATED fragment per package AND catalog language
(`packages/<pkg>/seed/capabilities_catalog/<lang>.fragment.md`, path by convention) from this block + the tool
`_manifest`s + the catalog, then **composes** the fragments of each language by package `ord` (low first;
core/host chrome uses a high `ord` so it trails) + the header into `packages/core/seed/capabilities_catalog/<lang>.md`.
All are **tracked** GENERATED artifacts — `-VerifyCatalog` compares each against a fresh render (per fragment and
language) + compose-integrity, and fails on a missing catalog text. The host engine (`scripts/build/lib/catalog.ps1`)
holds **only** the generic renderer + compose — **no** package-specific categories. This is the **Helm umbrella**
layering: structured SSOT (manifest + catalog) → build-time renderer (`build.ps1`) → pre-rendered artifact
(fragment) → dumb host concat.

**Installed-set composition (Install-UX-Phase 4) per language.** `seed_data.sh::_capabilities_catalog_md <lang>`
composes at install time from the header of the composed file (up to the first `##` heading) + the fragments of
core + every **active** registry package (same rule as the command menu and onboarding menu; + the package being seeded),
ordered by `catalog.ord`, + the section „more functions" (`core.help.more_*`, `<pkg>.package.*`) — one row per
catalog language in **`core.help_catalog(lang, content)`**, which the orchestrator reads for `/help` in the sender's
language (missing → en). The lazy context `capabilities_catalog` (guide agent, model knowledge) is the German
rendering of the same composition (one source, no prompt change). `pkg_lifecycle.sh::_pkg_refresh_surfaces`
re-composes it (and the Telegram command menu, §6) after every install/activate/deactivate/uninstall.

**/help-Chunking (WS-5):** the seeded catalog body is split at `##` category boundaries into multiple Telegram messages at runtime (the `Split help` Code node in the orchestrator, with an index card first + `(n/N)` prefixes); `Build-ComposedCatalog` asserts each category block **and** the projected index message ≤ `PACK_BUDGET` (4000) — so every runtime chunk stays < 4096 by construction without duplicating the packer. The per-block cap replaced the old whole-body 3900 throw.

### 3.6 `config` manifest block (WS4a — per-package central config)

Every package — **including the privileged core host** — declares its configuration in its manifest
`config` block; the retired flat `config.json` is gone (core is just an extended privileged package,
homogeneous). Shape: `config.<category>.<key> = { value, description, summary, type?, minimum?, maximum?,
managed_by? }`, grouped by category (`model`,
`schedule`, `feature`, `cron_enable`, package-specific tuning, `api`, …). The `description` preserves the
per-row documentation of the `core.config.description` column (e.g. "vision_extract = paid-tier mandatory").
`summary` is **required**: a German one-liner (≤ 100 chars, no control characters) saying what the entry does
for the owner — shown by `lifeagents config list` and in the `config set` explanation box, copied into
`core.config.summary` (CHECK `config_summary_single_line`; `contract_lint` check 12f). `summary` is German owner
display text, `description` English developer/model text — the split follows the language policy (layer 2 vs. 1),
not the same-language summary/description pair of AppStream/GSettings. `help` (askable entries, below) is the
installer wizard's explanation; `summary` is the one-liner for `config list`/`config set` — different jobs, no
duplication. **Rule: every row `config list` shows takes effect** — a value is read at runtime, or (schedules) filled
in at deploy time and re-deployed by `config set`. No config value is baked in at build time (`config_test` (4)
proves every `model.*` row is read by a workflow).

**Value types (JSON Schema `type`/`minimum`/`maximum`, stored like `pg_settings.vartype`/`min_val`/`max_val`).**
`type` ∈ `string` (default) | `integer` | `number` | `boolean` (exactly `true`/`false`) | `cron` (5 fields, or 6 with
a fixed second; no names) — `minimum`/`maximum` (JSON numbers) only for `integer`/`number`. Required by category:
`schedule` → `cron`, `cron_enable` → `boolean`. The DB checks every **new** value (`trg_config_check_value_type`,
German error text naming what is expected — `lifeagents config set` shows it); `scripts/config_test.ps1` checks the
shipped defaults with the same rules (shared cron case list `tests/util/util_cron_cases.sql`). Seed rule: an
existing value that does not fit the (new) type falls back to the default (NOTICE) — the trigger itself skips
unchanged values, so an old owner value never aborts an update.

**`managed_by`** ∈ `owner` (default) | `system`: a `system` row (e.g. `api.core_version`) is overwritten by every
seed and hidden from `config list`/`set`/`reset` (not an owner setting).

**Schedules.** A workflow's `scheduleTrigger` carries the placeholder `__CFG_SCHEDULE_<KEY>__`
(`Build-ScheduleTrigger -ScheduleKey`); `deploy_workflows.sh` fills it from `core.config` at deploy time (exact
string match via `jq`, a leftover placeholder aborts the deploy) and **deactivates every live workflow with its own
trigger before the import** — `n8n import:workflow` runs in a separate process and would leave the old in-memory
schedule running next to the new one. `lifeagents config set|reset schedule <key>` re-deploys the owning package's
workflows, so the new schedule applies at once, no n8n restart. The `schedule.<key>` row lives in the manifest of the
package that owns the workflow (`config_test` (3), both directions).

**Seeding (host-mediated, package-scoped).** The installer seeder `seed_data.sh _seed_package_config` loops
**all** manifests and upserts each entry into `core.config(package, category, key, value, description, summary,
value_type, minimum, maximum, managed_by)` with
`package = manifest.name`, via **`core.fn_config_seed(p jsonb)`** with **dpkg-conffile semantics**
(Install-UX-Phase 4): `core.config.default_value` remembers the shipped default; an update overwrites `value`
only while it still equals the old default (the owner never changed it) — a value set with `lifeagents config
set` survives every update. `managed_by='system'` is always overwritten; a value that no longer fits its type falls
back to the default; `category='cron_enable'` keeps the existing row (runtime toggles survive); a `model` value whose
model kind (`agent.ai_models.mode` chat|embedding) no longer matches the new default falls back to it (`core.fn_model_value_eligible`;
a vanished `model_key` is impossible since core:V024 — `value` and `default_value` carry a foreign key to `agent.ai_models`). `lifeagents config list` marks owner-changed values with `*`, `lifeagents config reset <cat>
<key>` (`core.fn_config_reset`) restores the default. Seeded **after** `ai_models` (the `category='model'` enum
trigger references `agent.ai_models`).

**Askable entries (Install-UX-Phase 4).** An entry may carry `prompt` (+ optional `help`, `validator`,
`choices[{value,label}]`) — then `lifeagents package install` asks it in its question phase (debconf-template
pattern, same vocabulary as §3.8 `credentials.env`; `choices` = a pick list instead of free text, debconf
`Choices`). Only interactive; Enter/„Später festlegen" keeps the default; an already non-empty value is never
re-asked, and a skipped question leaves a seen line `CONFIG_<CAT>_<KEY>=` in `<pkg>.env` (same debconf seen model
as §3.8) so updates never re-ask it. Answers are buffered and written **after** stage 5 (the row exists only after the seed) as a plain
`UPDATE` (= owner-set, survives updates). `contract_lint` check 12e types the fields (prompt/help non-empty
text, validator ∈ the closed enum, `choices` entries with non-empty value+label, not both `choices` and `validator`,
no `choices` value `__later__` — reserved for the wizard's own „Später festlegen" option).
Like §3.8 the `prompt`/`help`/`label` texts are German (owner-facing terminal UX).

**Reads — runtime only.** Agents pivot `core.config` via `core.sub_load_config` (Owner-cred, package-agnostic) for
`model.*`; every other model consumer (crons, tools, direct Claude calls) reads its key each run through the
build helper `New-ModelConfigNode` (Pg node `Load model config` → `core.fn_config_get`); the published read-window
`core.fn_config_get(package, category, key)` (SECURITY DEFINER, **read-all**, NULL when absent) lets a package
role read **any** package's value (the finance crons read their `cron_enable` flags this way under
`finance_ro`/`finance_rw`).

**Window access model (Owner directive, applies to every window-mediated table).** **Read = all** (any role
may read any package's config via the window). **Write = own only**, host-mediated and package-scoped:
package DB-roles never write `core.config` directly (D10 schema isolation blocks it); the only writers are the
host seeder (`WHERE package`, per manifest) and the CLI `lifeagents config set` (UPDATE-only on an existing
`(category,key)` row — no INSERT, and the `package` ownership column is **never** changed by the CLI). A new
key is therefore always a manifest declaration + seed, never CLI drift. Same model already established by
`fn_core_api_version` / `fn_advisor_read_plan` / `fn_onboarding_status` / `fn_package_active` (read-published,
host-mediated writes).

**Cron gating (F9).** A package cron's entry gate is `core.fn_package_active('<pkg>') AND
COALESCE(core.fn_config_get('<pkg>','cron_enable','<cron>')='true', false)` — **fail-closed** (inactive
package OR missing row OR `'false'` → off; the DB decides the comparison). The `cron_enable` default row
guarantees the flag exists (always-on crons `'true'`, opt-in `'false'`); `contract_lint` check (7) enforces
that every gated cron's `cron_enable` literal is declared (and flags an orphan flag). Core crons stay ungated
(core = always-on host). `lifeagents config set cron_enable <cron> false` toggles a cron at runtime, no rebuild.

### 3.7 `backup` manifest block (Phase 4b — declarative backup surface)

A package declares **which of its user-data tables** the CLI (`lifeagents backup export|restore`) saves —
purely declarative data, no code. Read by `backup_cli.sh` (jq), **never by SQL** (the CLI has filesystem
access and assembles the `pg_dump`/`pg_restore`/`\copy` invocations; that's why no host registry is needed —
unlike `core.services`/`core.context_validators`, which exist for runtime SQL with no filesystem access):

```jsonc
// domain package (owns its own schema fully → no row filter needed)
"backup": { "schema_dump": true, "exclude_tables": ["import_staging"] }
// core (host; user data lives mixed with code in the shared `agent` schema)
"backup": {
  "full_tables":     ["agent.advisor_plans", "agent.advisor_plan_wishes", "agent.guide_onboarding_state", "agent.reminder_prefs"],   // wipe+restore whole
  "filtered_tables": { "agent.core_contexts": "managed_by = 'agent'",           // \copy (SELECT … WHERE …) + fn
                       "agent.monitor_triggers": "origin = 'user'" }
}
```

- **`schema_dump:true`** (+ `exclude_tables[]`) → the whole package schema via `pg_dump -a --disable-triggers
  -Fc` (materialized tables 1:1, no trigger recompute). Domain packages use this — they own their schema fully.
- **`full_tables[]`** (qualified) → wiped + restored whole. **`filtered_tables{qual→WHERE}`** → row-filtered:
  `pg_dump` cannot filter rows, so the CLI exports them as jsonb and `core.fn_backup_restore_filtered` replays
  them rule-aware (protected contexts UPDATE-only, `family` before `finance_profile`, monitor de-dup). This is
  **structurally core-only** — the shared `agent` schema is host space; domain packages never need it.
- **Restore is atomic** (`psql -1`): `pg_restore -f -` emits SQL text (no own DB connect) → TRUNCATE + restore
  SQL + the filtered fn + a count-verify (vs. `manifest.verify_counts`) run in one transaction. `--disable-
  triggers` (superuser) also disables the RI/FK triggers → no topo-sort needed. Mechanik → `provisioning/CLAUDE.md`.
- **Not backed up** (code/ephemeral): `*_instructions`/`capabilities_catalog` (`managed_by≠'agent'` = repo code),
  `ai_models`/`config`, chat memory, `pairing_state`, `notification_state` (shared notify-dedup, ephemeral), `dispatch_followup` (button follow-up, 30 min), `monitor_observations`. The installer
  rebuilds code/workflows/secrets; n8n credentials are **never** in a backup (tied to `N8N_ENCRYPTION_KEY`).
- **Schema `core` is NEVER in a backup block (arch-challenge round-3 Obj 3 — two mandatory notes).** The
  backup encryption key lives in `core.backup_key`; a bundle must not contain the very key that decrypts it.
  Structurally it already cannot — `_bkp_bulk_tables` only dumps `schema_dump` schemas + `full_tables`, and no
  package lists a `core.*` table (core's block is `agent.*` only). **Enforced** by `contract_lint.ps1` check (8):
  no `core.<table>` in `full_tables`/`filtered_tables`, and no `schema_dump:true` on a package that owns schema
  `core` (M4 also bans code-seed tables `agent.ai_models`/`core.config` from a dump). **(Note a)** the DB copy
  of the key is only the *operative* one — an **offline copy of `core.backup_key` is a DR requirement** (a wiped
  host loses the key; the bundle is then undecryptable). **(Note b)** restore is data-only into a **living** DB
  that already holds the key (it is never restored from the bundle).

### 3.8 `credentials` manifest block (Install-UX — declarative package secrets)

A package declares the **n8n credentials it needs from external API keys** (e.g. career's Adzuna/JSearch
job sources) — purely declarative data, no code. Like the `backup` block (§3.7) it is read by **bash tools
via jq, never by SQL** (secrets go into n8n credentials, never into the DB — root `CLAUDE.md`
*Credentials-Policy*): the **stage-4 wizard** in `pkg_install_one`/`pkg_cmd_reconfigure` (asked up front by `collect_package_inputs`) prompts the
declared env keys (env-override-first → seen-line in `/etc/lifeagents/<pkg>.env` → interactive TTY only,
never on `--unattended`), and `inject_credentials.sh::_inject_manifest_credentials` assembles + upserts
the credential id-stably. `deploy_workflows`/`pkg_teardown` resolve/delete the declared names generically
via `_cred_pkg_placeholder_names`. **Host code carries no package secret literals** (the pre-phase
Adzuna/JSearch hardcode in `inject_credentials` stages 8/9 + `_INSTALL_ENV_KEYS` was exactly the
core-single-package seam this block removes; `contract_lint` seam-guard fails any recurrence at commit).

```jsonc
"credentials": {
  "adzuna": {                                    // block key = logical name (like provides.services)
    "placeholder": "__CRED_ADZUNA__",            // __CRED_*__ token in the built workflow JSONs (lint anchor)
    "name": "Adzuna Jobs API",                   // n8n credential NAME (deploy resolves by name+type)
    "type": "httpCustomAuth",                    // n8n credential TYPE (keys the bash data assembler)
    "required": false,                           // credential-level (all-or-fail); default false
    "env": {                                     // one entry per env key (prompt granularity = debconf)
      "ADZUNA_APP_ID":  { "field": "app_id",  "validator": "none", "secret": false, "prompt": "…" },
      "ADZUNA_APP_KEY": { "field": "app_key", "validator": "none", "secret": true,  "prompt": "…" }
    }
  }
}
```

- **No data template in the manifest** (arch-challenge E3: a stringify marker or raw jq string would be
  embedded code — the manifest declares, the host executes, exactly like `context_validators` binding fn
  *names*). The per-TYPE data assembly (n8n API quirks like the mandatory `allowedDomains:""`, the
  `httpCustomAuth` single stringified `json` field) lives ONCE in
  `inject_credentials.sh::_cred_assemble_data <type>`: `httpCustomAuth` → `{json: ({qs:{<field>:<val>,…}}
  | tojson), allowedDomains:""}` (qs form — the only real one; headers/body forms are BACKLOG via a future
  `custom_auth_in` field); `httpHeaderAuth` → `{name:<field>, value:<val>, allowedDomains:""}` (exactly one
  env key; `field` = header name); unknown type → `die` (and `contract_lint` fails it at commit already).
- **`field`** is the type-dependent binding slot: `httpCustomAuth` = query-string parameter name,
  `httpHeaderAuth` = header name. (The former `googleApi` service-account type and the `generate:true` env field
  — installer-minted secrets — left with the retired paperless pipeline, v0.3.0: no other consumer.)
- **`value_prefix`** (optional per env entry, arch-challenge D4 REJECT-mit-Notiz): a
  FLAT literal the host prepends to the entered value at assembly time (consumer from paperless phase 2:
  `Authorization: Token <raw>` — the owner enters the raw token). Deliberately NOT a template string (`"Token {token}"`
  was rejected: parsing a marker is the embedded-code side of the E3 line); a second consumer needing
  suffix/concatenation graduates this to a second flat field (rule of three), never to a template engine.
- **`validator`** is a CLOSED enum, name-bound like `context_validators` — never executable code:
  `none | url | email | live_check:<name>` (`live_check` names an existing bash validator:
  `telegram|google|anthropic`). Unknown value → wizard warns + accepts unvalidated (the `_cred_test`
  after import is the second barrier).
- **`secret: true`** masks the prompt input (`read -rs` / `gum input --password`).
- **`help`** (optional, Install-UX-Phase 4): German explanation shown as a box **only when the question is
  actually asked** (what it is for, where to get it, what skipping means). Three invalid entries are never
  accepted silently: optional → skipped (visible), required → abort; a live check that cannot reach the
  service (no network) accepts with a note (`_cred_test` re-checks at inject).
- **`required`** sits on the CREDENTIAL level: the coupling "both-or-neither" (Adzuna needs BOTH keys) is
  credential **atomicity** — ALL env keys non-empty → staged; any missing → optional = graceful skip with
  a `lifeagents package reconfigure <pkg>` hint, required = `die` (fail-fast, debconf-critical/Helm
  precedent; today every real credential is optional, the die branch is dormant). The **question phase**
  applies the same rule to an optional credential with several keys: if its FIRST key (manifest
  order) stays empty, the remaining keys are not asked (seen lines, one hint); if it ends half-filled after a
  question in this run, the wizard offers „Nochmal eingeben / Zugang auslassen" (re-ask: „Nichts ändern") so a
  partial credential is never stored silently. Order the env keys so the first one is the natural "do you have
  this?" question.
- **Seen model (debconf):** a `KEY=` line in `<pkg>.env` (even empty) marks the question as asked — a
  re-run never re-nags; `lifeagents reconfigure <pkg>` (= `lifeagents package reconfigure <pkg>`) re-asks
  deliberately (Enter = keep; a `secret: true` value is never shown, a `secret: false` value is shown as
  the default — debconf convention, Install-UX-Phase 7). The answers are written only after the last one,
  so a multi-key credential changes as a whole (Ctrl-C = nothing changed). A `required` credential cannot
  be re-asked to empty. Legacy keys that predate this block are migrated once from `core.env` to
  `<pkg>.env` at install (generic over the declared keys, `_pkg_migrate_legacy_env`).
- **Review before installing (Install-UX-Phase 7):** after the questions of `lifeagents package install`
  (and of the first install) a summary box lists every credential (`gesetzt` / `übersprungen` /
  `unvollständig`, never the value) and every `prompt` setting; one item can be re-asked, Esc/abort installs
  nothing. No manifest change is needed — the summary reads this block and §3.6.
- **Uninstall symmetry (§6):** the package teardown deletes the declared credentials along with the two
  role credentials (`_pkgt_pkg_cred_names` reads this block).
- **"Bei uns anders" (two deliberate deltas):** (a) the `prompt` texts are **German** — owner-facing
  terminal UX is user-language (layer 2/5, precedent `cron_labels`), deviating from the English manifest
  description rule (layer 1); (b) the n8n-facing `name`/`type` stay verbatim n8n domain language
  (`credentials`, not "secrets" — the target object is an n8n credential).

### 3.9 `monitor_acquisition_methods` manifest block (Phase B — package value sources for the trigger monitor)

A package can offer its own **value acquisition method** to the core trigger monitor (e.g. finance `fx_rate` =
its daily FX table). The core keeps only its builtins `web_search | sql | none`; every other method is a row in
the host registry **`core.monitor_acquisition_methods(method, acquire_fn, validate_fn, package)`** (pattern
`core.callback_handlers`: builtins hard-wired, package entries via a generic dispatch fallback).

```jsonc
"monitor_acquisition_methods": {
  "fx_rate": {
    "acquire_fn":  "finance.fn_monitor_acquire_fx_rate",   // fn(p jsonb {spec, as_of}) -> {ok, value, unit?, as_of?, source_url?} | {ok:false, reason}
    "validate_fn": "finance.fn_monitor_validate_fx_rate",  // fn(p jsonb {params})      -> {ok:true, spec, display} | {ok:false, reason}
    "params_description": "…"                             // English, LLM-facing (monitor tool description)
  }
}
```

- **Seeding** `seed_data.sh _seed_monitor_acquisition_methods`: own-schema boundary (both fns in `<pkg>.*`), arity
  warning `(jsonb)`, fills a V020 placeholder, never steals another package's method. `params_description` is
  **build data** (`build.ps1 $MonitorAcquisitionMethodList` → monitor tool descriptions), not DB; the owner-visible
  method name is the catalog key `<pkg>.monitor_method.<method>` (§3.11, required by `locale_lint`).
- **DB law.** `agent.monitor_triggers.acquisition_method` → FK on the registry (NO ACTION, core:V020); the spec of a
  package method is checked by its `validate_fn` in a `BEFORE INSERT OR UPDATE OF acquisition_method,
  acquisition_spec` trigger (pattern `context_validators`; heartbeat updates never fire it). `validate_fn` returns
  jsonb (not the validators' text) because it also **normalises** the spec and supplies the confirmation line.
  `display` is a typed text reference `{kind:'tpl', value:'<pkg>.monitor_display.<name>', params}` (`core.fn_ui_tpl`,
  §3.11) — the HITL gate renders it in the confirmer's language; a plain string `display` (older packages) still works.
  **Idempotence contract:** `validate_fn` must accept its own normalised `spec` as `params` and return it unchanged
  (the trigger re-validates the stored spec; `fn_set_monitor_trigger` validates `stored spec || new params`) —
  params and spec therefore share one shape.
- **Availability** (`agent.fn_monitor_method_status`): unknown / placeholder / fn missing / package not active →
  not available. The heartbeat **parks** such triggers (no fail streak, no alert, resumes when the package is
  active again); probe/create return `{ok:false}`; disabling a trigger always works.
- **Tool input:** the monitor tools take package-method parameters as ONE field `acquisition_params` (JSON string,
  parsed via the shared `Get-GuardedJsonExpr`). Config a method needs is package-owned (finance `monitor.fx_stale_days`;
  the former core row needs no V-migration — `core.fn_config_seed` re-owns an existing `(category,key)` to the
  declaring package on conflict and keeps an owner-changed `value`).
- **Uninstall:** `fn_pkg_purge_data` step 3c (§6). **Restore:** a bundle trigger whose method is not registered on
  the target aborts the restore with a readable message (install the providing package first).
- Lint: `contract_lint` Check 18 (name form/uniqueness, fns in own schema and defined, label/description hygiene).

### 3.10 `approval_matrix` manifest block (WS-5b maker-checker; Phase D — owned per package)

Every workflow that calls the shared gate `agent.tool_human_approval` needs a deliberate **tier** — declared by the
package that owns the workflow (the build engine knows no package; before Phase D this was one central file):

```jsonc
"approval_matrix": {
  "_comment": "…",
  "agent.<pkg>.tool_<verb>_<noun>": { "tier": "owner_approval", "reason": "one sentence why" }
}
```

- **Tiers** (strictest last): `owner_info` (member confirms + owner is informed) < `owner_approval` (member confirms,
  THEN the owner releases — four eyes) < `owner_only` (a non-owner is hard-blocked; plus a DB backstop in the fn).
- **`self`** (outside the scale and the verb floor): the asking person confirms their OWN data; the owner is neither
  asked nor informed (an info message would carry private per_user data to the owner). Allowed only for a workflow whose
  sole write is `agent.fn_set_own_context_facts` (scope fixed to `per_user` inside the fn) and that has no `scope`
  input — enforced by `approval_lint` (e) on the built JSON. First consumer: `agent.tool_set_own_context_facts`.
- **Verb floor** (the tier must be at least as strict as the verb implies; stricter is allowed, weaker = build error):
  `save`/`publish`/`invite` → `owner_only`; `set`/`close`/`delete`/`void`/`settle`/`sell`/`reconcile`/`commit` →
  `owner_approval`; `create`/`book`/`record`/`cancel`/`export` → `owner_info`. `record_` = idempotent tracking entry
  (UPSERT, deliberately not `create_`). A new verb must be classified on purpose in the ONE verb→rank map
  (`scripts/build/lib/approval_matrix.ps1`). **Break-glass:** an entry with `"break_glass": true` may carry
  `owner_info` below its verb floor — only for a write a survivor must be able to do without the owner
  (`owner_approval` would deadlock when the owner is the affected person); the `reason` states why. First consumer:
  `agent.estate.tool_set_case_task`.
- **Ownership:** the declaring package must be the package of the workflow name (`Get-WorkflowPackage`) AND of the
  build def that produces it (build), resp. of the `workflows/` directory the built file lives in (lint).
- **Fail-closed:** a gate caller without an entry = build error (deny by default); an entry without a built gate caller
  = lint error (orphan). Harnesses (`*.test_harness`) pass `approval_tier` via their webhook and are exempt.
- Consumers: `build.ps1` `Set-ApprovalTier` (injects the tier into every gate-call node) + `scripts/approval_lint.ps1`
  (verifies the built JSONs) — both through the shared `scripts/build/lib/approval_matrix.ps1`.

### 3.11 `locales/<lang>.json` — text catalog of fixed user texts

Fixed (non-LLM) user-facing texts — HITL confirmation cards and buttons, the language picker, welcome, pairing and
invitation texts, button toasts, `/help`, the onboarding menu, cron switches, the command menu (Phase B); every
reminder, dialog and report the bot sends on its own (crons), offer cards, agent entry-gate redirects, the error alert
and the emergency binder (Phase C) — come from a per-language catalog, so every person gets them in their own
language (de/en/ko today). Owner-only messages (most crons, the error alert) use the owner's language; the binder
uses the language of the person who requests it. Pattern Rails `config/locales` / gettext: the tracked files are the truth, one file per
language. Conversation replies stay LLM-written in the language of the message; the person's language only steers
fixed texts.

- **Files:** `packages/<pkg>/locales/<code>.json`, a flat object `"<pkg>.<area>.<name>": "text"` (`_comment` allowed),
  exactly one file per code in the core manifest `languages.list`. One key = one whole sentence; named `{placeholders}`.
  Areas in use: `hitl` (card titles), `label`, `enum.<type>.<value>`, `note`, `tpl`, `facts.<context>`,
  `monitor_method`, `package.name|summary` (owner-facing name + one-liner, every package), `help.<id>.*` (§3.5),
  `cmd.<name>` (command menu, ≤ 48 chars), `cron.<key>.on_toast|off_toast|on_message|off_message` (per `cron_labels`
  key), `onboarding.<section>` (§3.2), `toast.*` (button toasts of the package's callback handlers), `dialog.*`
  (cron reminders/dialogs incl. action buttons and result lines), `advisor.*` (alert/digest texts of
  `fn_advisor_review`), `offer.*` (offer cards with a `cron_on` button), `gate.*` (agent entry-gate redirects),
  `monitor_display.*` (validate_fn confirmation lines, §3.9), estate `register`/`binder`/`gap`, career `jobcard`,
  core-only `fmt`/`lang`/`welcome`/`orch`/`dispatch`/`onboarding.menu`/`learn`/`monitor`/`error`. German with real
  umlauts; Korean puts names as `{name} 님` (fixed particle); German legal/tax terms stay German in every language
  (with a short explanation in brackets).
- **Seed:** `seed_data.sh _seed_ui_texts` replaces the package's rows in `core.ui_texts` on every install/update (code
  seed, also `--no-seed`; build-managed, no owner edit). The core run seeds **every bundled** package, installed or
  not (the onboarding menu and the dispatcher name absent packages too), and drops packages that left the release;
  `fn_pkg_purge_data` leaves the texts alone.
- **Runtime — one lookup path:** `core.fn_ui_text` / `core.fn_ui_texts` (fallback language → `en` → key) and, for the
  gate, `core.fn_hitl_texts`; the recipient's language comes from `agent.fn_person_lang` (person → owner → `en`).
  - **Workflows** load the keys they need ONCE per recipient as a `t`-map (`core.fn_ui_texts`; build helpers
    `Get-UiKeysSql` + `Get-UiTextJs`/`Get-UiTextExpr` check every key at build time). The orchestrator's sender
    resolution returns `lang` + `t` (sender/tapper) + `t_owner`; pairing nodes add `t_person` (the invited person).
  - **DB callback handlers** return their toast via `core.fn_ui_text(key, agent.fn_person_lang(<tapper>)->>'lang')`
    (unresolved tapper → owner language), pattern `agent.fn_set_person_language`.
  - **Package roles** (crons/gates under `<pkg>_rw/_ro`, D10) use the published window `core.fn_ui_texts_for({chat_id?,
    keys[], doc?})` → `{lang, locale, language, language_label, t}` (recipient = the person behind `chat_id`, else the owner; keys =
    `keys` + every key-shaped string in `doc`; never raises, never returns a person). INVOKER core is
    `agent.fn_ui_texts_for`, which `core.fn_hitl_texts` also uses (one lookup path). A cron that latches (advisor,
    monitor, case tasks) loads its texts **in the same statement** as the latch — a failed text read must never mark
    an alert as sent.
  - **Structure instead of text from SQL:** a fn that reports to a user returns typed text references in the HITL form
    `{kind:'tpl', value:<key>, params}` with raw values (`core.fn_ui_tpl` + `fn_ui_money`/`fn_ui_num`/`fn_ui_date`; keys
    only as complete literals, `locale_lint` checks them). `fn_advisor_review` alerts carry `msg` (sentences), the digest
    `lines` (null = blank line). The workflow renders them with the ONE renderer `Get-UiRenderLibJs` (also inside the
    HITL gate): amounts/dates/numbers via Intl in the recipient's locale (`Fmt-MoneyJs`/`Fmt-DateJs` require a locale);
    an LLM only rephrases in the recipient's language and keeps every number. Messages to the LLM (tool results such as
    "cancelled", finance fold hints) are model layer → English.
  - **SQL-rendered documents** (emergency binder, register body) call `core.fn_ui_text(s)` directly; the one date uses
    `core.fn_fmt_date(date, lang)` with the language's `date_pattern` (core manifest `languages.list`, same output as
    Intl). **Bei uns anders:** PostgreSQL has no Intl.
  - **Welcome:** `core.fn_render_welcome(p_lang text DEFAULT NULL)` (NULL → owner language) — orchestrator `/start`
    and the installer (`owner_connect._oc_send_welcome`) share it, incl. the button texts.
  - **`/help`:** one composed text per language in `core.help_catalog` (§3.5).
- **Own language:** `/language` (hidden alias `/sprache`) sends `core.sub_send_language_picker` in mode `self` (the
  question in all catalog languages, nothing stored until the tap; the `lang:` callback lets a member set only
  themselves). At pairing, Telegram's `from.language_code` is normalised (`agent.fn_normalize_language`) and kept only
  as `agent.pairing_state.language_hint`; after the owner's confirm a member without an own language gets the picker
  with that language marked 👉 — never set silently.
- **Command menu:** `deploy_workflows.sh _set_bot_command_menus` sets per catalog language `Default+language_code`
  and `Chat(owner)+language_code`, plus both without `language_code` in the owner's language (texts read from the
  tracked `locales/*.json`). **Bei uns anders:** the menu follows the language of the person's Telegram app, not the
  person's language — n8n has no `setMyCommands` operation and its Telegram credential cannot be used by the HTTP
  node (no `authenticate`), so a per-person chat menu would need the bot token inside a workflow
  ([Bot API order](https://core.telegram.org/bots/api#determining-list-of-commands): Chat+lc beats Chat, no shadowing).
- **Lint:** `locale_lint` — languages = manifest list, key and placeholder parity, no empty values, no umlaut
  substitutes in German, required keys (`facts.<context>.title`, `monitor_method.<method>`), every catalog key literal in
  an `R__` fn exists; `contract_lint` 15 (`package.*`, `onboarding.*`, retired manifest text fields), `command_lint`
  (`cmd.*` per language), `cron_toggle_lint` (`cron.<key>.*`), `build.ps1 -VerifyCatalog` (`help.*`). **Ratchet**
  `ui_literal_lint`: no fixed German text in a Telegram/Code/Set node or an `R__` fn; the remaining spots are only
  model/admin/data texts (no user text: model input, console RAISE, stored content), listed with a reason in
  `scripts/build/ui_literal_allowlist.json`, which may only shrink. Behaviour test `scripts/dev/cron_text_test.ps1`
  (every cron send in the recipient's language, against the mock Telegram/LLM).
- **Bei uns anders:** plain `{name}` placeholders, no ICU MessageFormat/Fluent (no plural/gender cases in the
  catalog; CLDR: ko has only `other`).

### 3.12 `app_screens` manifest block — screens of the read-only Telegram Mini App

The Mini App (menu button „📊 Übersicht“, workflow `core.main_app_serve`) is a generic shell: it knows no
package. Each screen is a package read-fn that returns a **view model** (structure + typed values, never text);
the page renders it with the ONE renderer `Get-UiRenderLibJs` (§3.11), in the viewer's language and locale. The
page computes nothing — states, progress and sums come from the DB.

```jsonc
"app_screens": {
  "_comment": "…",
  "overview": { "handler_fn": "finance.fn_app_screen_overview", "ord": 10, "icon": "💶" }
}
```

- **Registry** (host-seeded like `callback_handlers`, §3.3 — not a §4.2 cross-package read): `seed_data.sh
  _seed_app_screens` replaces the package's rows in `core.app_screens(screen, package, handler_fn, ord, icon)` (DELETE + INSERT, so a removed screen disappears); own-schema boundary,
  `(jsonb)` arity warning; screen keys are unique across packages (`contract_lint`); `fn_pkg_purge_data` deletes
  the package's rows. The tab title is the catalog key `<pkg>.app.screen.<screen>`.
- **Dispatcher** `core.fn_app_screen(p text)` (INVOKER under the host credential, pattern
  `core.fn_dispatch_callback`; never RAISEs): verifies Telegram `initData` (`core.fn_app_verify_init_data`,
  HMAC with `core.app_secret`, `auth_date` ≤ `app.init_data_max_age_s`), checks `app.enabled`/`app.audience`,
  re-resolves the person (`agent.fn_resolve_sender`), then calls `handler_fn(jsonb)` of an active package.
- **Handler contract** `<pkg>.fn_app_screen_<screen>(p jsonb {person_id, params}) RETURNS jsonb`:
  - SECURITY DEFINER read window (pattern `career.fn_read_job_matches`): pinned `search_path … pg_temp`,
    `REVOKE ALL FROM PUBLIC`, first statement `core.fn_is_free_sql_session()` → `{ok:false, code:'forbidden'}`.
  - **Zero-trust visibility:** the handler asks the ONE role helper `core.fn_app_sees_household(person_id)` (allow-list —
    only `owner`/`partner` see the household, every other or unknown role sees only own rows); what "own" means per
    object stays in the handler. A row the viewer may not see never appears, not even as a name inside a banner or as
    a counter-account (use a neutral key).
  - `params.probe = true` → `{ok:true, empty:<bool>, banners?:[…]}` only (navigation shows non-empty screens).
    **Banners exist only here:** `alert|warn` built from the same filtered set as the screen, `target.screen` = the
    handler's own screen. The dispatcher (`core.fn_app_nav`) collects them from every non-empty screen (`empty:true`
    drops them), checks each element on its own (bad element → dropped, never the screen), sorts alert before warn,
    then `ord`, and puts them on the home screen (first in navigation, also when it is reloaded on its own); every other
    screen gets `banners: []` — banners in a full handler view are ignored.
  - Every text is a typed reference (`core.fn_ui_tpl`, keys `<pkg>.app.*` as complete literals); amounts
    `core.fn_ui_money`, dates `core.fn_ui_date`, numbers `core.fn_ui_num`; raw names from data are plain strings.
- **View model v1** (handler output; fixture `tests/fixtures/app_view_model_v1.json`):

```jsonc
{ "ok": true,
  "title": <tpl>,
  "hero": { "label": <tpl>, "value": <money>, "gap": false, "note": <tpl>|null } | null,
  "banners": [ { "state": "alert|warn|ok", "icon": "alert|calendar|clock|check|pause|info", "text": <tpl>,
                 "target": { "screen": "<screen>", "params": {} } | null } ],
  "sections": [ { "title": <tpl>, "value"?: <money>|<tpl>|null, "empty": <tpl>, "items": [ {
      "label": "<raw name>" | <tpl>, "sub": <tpl>|null, "value": <money>|<number>|null, "gap": false,
      "pill": { "state": "ok|warn|alert|neutral", "icon": "…", "text": <tpl> } | null,
      "progress": { "pct": 0-100, "state": "ok|warn|alert|neutral" } | null,
      "target": { "screen": "<screen>", "params": {} } | null,
      "details"?: [ { "label": "<raw>" | <typed>, "value": "<raw>" | <typed> | null } ] | null } ] } ] }
```

  `state` always comes with an `icon` (`check|alert|calendar|clock|pause|info|up|down`; colour is never the only
  signal). `gap: true` = an FX rate or price is missing in that sum (`has_fx_gap`), the page marks the value as
  incomplete. Optional fields (additive, still v1; a handler without them stays valid): `section.value` = the sum
  shown next to the section title; `item.details` = key/value lines the row expands to on tap (progressive
  disclosure, no navigation, so no IDs leave the DB; a `target` wins over `details`). Money may carry `sign: true`
  (`core.fn_ui_money(v, cur, true)`): the renderer puts `+` before a positive amount (gain since purchase).
- **Page responses** of `core.fn_app_screen` (POST body `{init_data, screen?, params?}`):
  navigation `{ok:true, ui, screens:[{screen, title:<tpl>, icon}], first?:{screen, view}}` (the first screen rides along,
  one request on open), screen `{ok:true, ui, view}`, refusal
  `{ok:false, code, ui, text:<tpl>}` — `ui` = `agent.fn_ui_texts_for` (`{lang, locale, t}`) for the viewer, with
  every key of the response plus the shell keys (`core.app.*`, `core.fmt.*`).

---

## 4. DB isolation — structural, not lint (D10)

**Exception — the privileged core package** (§2, `privileged: true`) is **not** isolated: it gets **no**
`core_rw`/`core_ro`, `core.fn_provision_package_roles` is **not** called for it, and it owns both the `core`
and `agent` schemas via the host n8n credentials. Everything below applies to **domain** packages only.

Per **domain** package, **two login roles** provisioned by `core.fn_provision_package_roles(p jsonb)` after
the schema/table migration, dropped by `core.fn_drop_package_roles(p jsonb)` on `--purge`:

- **`<pkg>_rw`** — `SELECT/INSERT/UPDATE/DELETE` + sequences + `EXECUTE` **only** in schema
  `<pkg>`. **No `CREATE`/DDL** (R11: a package may not run schema/core DDL; tables are created by
  the installer as superuser).
- **`<pkg>_ro`** — **only `SELECT`** in schema `<pkg>` + `default_transaction_read_only`.
- **Both** — `USAGE` on schema `core` *solely* to call the published `SECURITY DEFINER` read-fns,
  plus `EXECUTE` on exactly those fns. **No** `SELECT`/`USAGE` on `core` tables, `agent.*`, or any
  neighbour package schema.

The boundary is **physical**: `JOIN <pkg>.x agent.y` → `permission denied for schema agent`;
`SELECT core.config` → `permission denied for table config`. Core data is reachable **only**
through the published read-fns. Each package gets its own n8n credentials (`<pkg> write` /
`<pkg> read-only`, injected by the installer). Verified by `tests/db/core/test_fn_pkg_roles.sql` (VF3).

**Published SECURITY DEFINER read-fn pattern** (the one Core↔Package read window): search_path
hardened (`SET search_path = pg_catalog`, all objects schema-qualified), `REVOKE ALL FROM PUBLIC`,
`EXECUTE` granted only to the package roles. Phase 1 reference fn: `core.fn_core_api_version()`.
Phase 3a adds `core.fn_advisor_read_plan(text)` (O1 — the engine finance_ro reads `agent.advisor_plans`
only through it). Later phases copy it 1:1 for further sensitive reads.

### 4.1 Package read-contract — the Core-host read window (Owner-lock 2026-06-18)

The privileged Core host runs **core-owned agents** (`agent.monitor`, `agent.guide`) whose free-SQL read
path (`postgres_select`) needs to browse **both** their own `agent`/`core` tables **and** a package's data
(e.g. the guide dedups against finance overviews during onboarding; the monitor dry-runs a finance SELECT
before saving it as a trigger). The narrow package role `<pkg>_ro` cannot serve this (it is scoped to
`<pkg>` only). Therefore:

- **`core_ro`** — a Core-host read-only login role (read-only on `agent` + `core`; **not** a package
  isolation role, distinct from the "Core gets no core_rw/_ro" rule in §2 which is about isolation roles).
  `packages/core/db/util/util_create_core_ro.sql`; `core.backup_key` is REVOKEd from it (backup key). The core-agent n8n
  read credentials (`__CRED_POSTGRES_CORE_RO__`) connect as `core_ro`. Write-safety for LLM-authored SQL is
  preserved (read-only role) — the reason a read role exists at all.
- **Package opens a read window (declaration vs. execution):** when a domain package is provisioned,
  `core.fn_provision_package_roles('<pkg>')` **unconditionally** grants `core_ro` `SELECT` on schema `<pkg>`
  (tables + views; own-schema-scoped via the validated package name → a package can never grant a foreign
  target). **Unconditional = system invariant:** the privileged Core host may read every package read-only;
  a package must not be able to hide from host oversight (no opt-in flag). The window falls away with the
  schema on uninstall. Views remain the **recommended first stop** (tool-description steering); raw tables
  are readable as fallback (max host context — Owner decision).
- **Person privacy beats host oversight (Owner decision 2026-10-24, "strictly private"):** the free-SQL roles
  (`core_ro`, `<pkg>_ro`) never see another person's private data. The **host derives** it — still no package
  flag: in a package with `per_user` scopes (`core.fn_package_is_per_user`) every table with `person_id NOT NULL`
  plus every view depending on it loses `SELECT` for `<pkg>_ro` and `core_ro` (`core.fn_provision_package_roles`;
  the install passes `per_user` read from the manifest, because the registry is only seeded afterwards). Row-level: RLS hides per_user context rows (`<base>__<person_id>`) and person plans
  (`agent.advisor_plans.person_id NOT NULL`) from `core_ro`; `util_create_core_ro.sql` denies chat memories,
  pairing codes, raw ingress and open card texts. A person reads their own data only through a **bound DEFINER
  window** called with the build-fixed `chat_id` under a non-free-SQL credential; such a window returns nothing
  for per_user data when `core.fn_is_free_sql_session()` (login role `*_ro` — the `chat_id` would be LLM-chosen).
  **Accepted residual (status metadata, no content):** the menu windows `core.fn_onboarding_status`/
  `fn_onboarding_overview` and `core.fn_reminders_overview` take a `chat_id` and stay executable by `core_ro`/
  `<pkg>_ro`, because deterministic menu/gate nodes share those login roles; they reveal only which onboarding
  sections a person finished and which reminders are on.
- **The package only DECLARES, the host EXECUTES.** Package SQL contains **no** `GRANT`/`CREATE|ALTER ROLE`
  and references no foreign schema (only `EXECUTE` on published core read-fns). The sole privilege authority
  is `core.fn_provision_package_roles` (always own-schema-scoped). The manifest `read_surface` field declares
  the package's read window (host role + preferred views) as **data**. Enforcement: structural (the host fn
  cannot target a foreign schema) + a boundary lint (package SQL has no role-DDL / foreign grant) as
  defense-in-depth.
- **Read-surface descriptions are package-contributed (built, Phase B):** the SELECT-node descriptions of the
  core agents are **assembled build-time** from a core base + every package's `read_surface.preferred_views`
  (`build.ps1 $ReadSurfaceList`; `agent.monitor` lists the views per package, `agent.guide` names "the schema of
  every ACTIVE package"). Build set = repo tree, not the installed set: a view of an uninstalled package simply
  fails the dry-run (graceful) — no per-install rebuild.

Verified: `tests/db/finance/test_finance_isolation.sql` (finance_ro VF3 + `core_ro` reads finance read-only +
`core.backup_key` denied + `finance_rw` write-roundtrip).

### 4.2 Cross-package reads (optional-provider convention, WS-5 — LOCKED)

A package's agent may read **another** package's data only through this convention. The cross-package
dependency is **optional** — never a hard `requires` entry (the consumer must work whether the provider is
installed or not). Adjudicated by two arch-challenges (window placement + the general mechanism, Red/Blue +
Opus arbiter) — do not re-open without new evidence.

- **Provider side.** The provider publishes exactly one named, provider-owned read function per capability and
  declares it in its manifest under **`provides.reads`** (e.g. finance → `finance.fn_liquidity_snapshot()`).
  The physical entry point depends on the consuming **surface**:
  - **Surface A — render-at-fetch (a standing line in a plan header):** the read fn is **PLAIN STABLE, no
    grant**. It is invoked by the consumer's `*.fn_render_*` inside `core.fn_fetch_context`, which already runs
    `SECURITY DEFINER` (owner = superuser) and therefore reads the provider schema **with no new grant**.
  - **Surface C — interactive tool (runs under the consumer's `<pkg>_ro` role):** the read fn is
    `SECURITY DEFINER`, `EXECUTE` granted to the consumer role in the **provider's** `fn_provision_package_roles`.
  `provides.reads` is declared in **both** cases; the grant model is the only per-surface difference.
- **Consumer side.** The consumer declares the dependency under **`consumes.reads`** (the first non-`core.*`
  entry allowed) and **always double-guards** before reading: `core.fn_package_active('<provider>')` (lifecycle
  presence) **and** `to_regprocedure('<provider>.fn_x()')` (object presence — covers build skew). On either miss
  it **degrades gracefully** (NULL / line omitted), never raises. The double-guard is non-negotiable.
- **Enforcement.** `contract_lint` reconciles every non-`core.*` `consumes.reads` entry against a matching
  `provides.reads` in the named provider's manifest (fail-closed); a `db_test` proves graceful degradation when
  the provider is absent/inactive (`test_fn_runway`, `test_fn_render_career_planning`).
- **No generic dispatcher yet (for READS).** With a single consumer the call is a direct call behind the existence guard;
  core knows nothing about the specific read (avoids the god-module anti-pattern). **Graduation trigger:** at
  **2+ provider packages × 2+ consumer packages** fan-out, promote to a host-seeded `core.cross_package_reads`
  registry with generic core dispatch (the §3.3 host-seeded-registry + `to_regprocedure`-skip pattern), seeded
  from the existing `provides.reads` declarations. Until then, do not build it. **Rejected: a `core.fn_*` that
  hardcodes a domain package's tables** (violates §3.3 "Core kennt kein Paket", no OSS precedent, larger
  attack surface). **WS-5 instantiation:** finance `fn_liquidity_snapshot()` (surface A, plain, no grant);
  the runway line renders in `career.fn_render_career_planning` under the double-guard. (Cross-package **tools**
  — workflows, not DB reads — do have a generic dispatcher: §5.1.)

---

## 5. Service alias (D9, build-time)

The host declares its public service surface in `core/manifest.json` → `provides.services`: a
`{ alias → workflow-name }` map (bare keys, e.g. `human_approval → agent.tool_human_approval`,
`load_config → core.sub_load_config`). Packages reference a service as **`core:<name>`** (the provider
namespace lives in the value, not the field name). At build time `build.ps1`'s `Resolve-CoreServiceAlias`
dereferences `core:<name>` → the physical workflow **name** (from `provides.services`), and the existing
`Get-WorkflowIdByName` resolves the name → id from the **tracked file state** — `build.ps1` has **no DB
access**, so resolution is manifest + filename, never the DB. Deploy stays id-preserving.

The DB table **`core.services`** (formerly `core.core_services`) holds the same alias→id map as **declared
state** plus the owning `package` column: `seed_data` materializes it generically from `provides.services`
across **all** package manifests (`_seed_services`, WS-B6), resolving the workflow id from the tracked
workflow JSONs (artifact-declared, no REST read-back); the actual deployed existence is confirmed by the
post-deploy verification (workflow_entity join). Per-package reconcile (ownership-scoped) prunes only a
package's own removed aliases. It is **not** a build input. (Runtime route materialization on top of this
map is WS-B8, not the seeding here.)

The lint (SC1, `contract_lint.ps1`) allows only the aliases a package declares in `consumes.services`
(entries are `core:<name>`, identical to the build-def reference token → direct set check), checks every
`provides.services` value resolves to **exactly one** real core workflow (ambiguous `.name` → `_seed_services`
id-collision), and that every `consumes.services` entry names a real provided service.

### 5.1 Cross-package tool services (paperless Phase 2, `CORE_API_VERSION` 0.2.0)

A **non-core** package may offer read tools to **other** packages' agents (first provider: `paperless` →
`search_documents` / `get_document` / `ask_documents` for finance, finance_advisor, career_advisor, estate_advisor).

- **Provider (object form).** `provides.services.<alias> = { workflow, description, permission, inputs }` —
  `workflow` = an own `agent.<pkg>.*` tool whose start trigger declares exactly `args` + `chat_id`; `description` (EN)
  becomes the tool description in every consuming agent verbatim; `permission` ∈ `all_members | adults_only |
  owner_only`; `inputs.<name> = { type: string|number, required, default?, description }` is the ONE source for the
  model-facing schema (`$fromAI`) and the tool's own argument check. Core keeps the string form.
- **Consumer (opt-in).** `consumes.services: ["<pkg>:<alias>", …]`; the provider never names a consumer. Each agent
  def binds them with the build helper **`Add-ServiceTools`** (`-Own` for the provider's own agent).
- **Runtime.** `_seed_services` stores non-core rows **qualified** as `name = '<pkg>:<alias>'` (+ `permission`,
  `description`); a CHECK ties the prefix to `package` and the permission to the three levels. Every call goes
  through the core sub-workflow **`agent.sub_dispatch_tool`**: it asks **`core.fn_resolve_service`** (service known?
  package active — `fn_package_status`? sender allowed — identity re-resolved from `chat_id`, unresolved = denied?)
  and runs the tool by **expression id** from `core.services`, or returns `{ok:false, error, hint}` as data
  (`unknown_service` / `package_unavailable` / `not_permitted`). A consumer therefore activates and runs without the
  provider package.
- **Bei uns anders** (vs. the agent dispatcher `agent.sub_dispatch_agent`): a **sibling, not a merge** — tools never
  carry `call_depth` (anti-loop) and return `{ok}` data instead of `.output` text; **runtime lookup** of the target
  id instead of a build-time id — no foreign package id ever sits in a consumer workflow (seam lint stays strict, no
  cross-package build order) — and **fail-closed** on a check error (a tool does not re-check itself). Decision point
  in the DB = the PEP/PDP pattern of `core.fn_dispatch_callback`.
- **Enforcement.** `contract_lint`: provider object form (own workflow, permission enum, `$fromAI`-safe inputs, `*_id`
  never number, no identity inputs), consumer entries against the provider manifest, no self-consumption, every
  `$fromAI` key inside the `args` stringify ∈ provider `inputs`, the dispatcher edge (target trigger = `args`+`chat_id`)
  and **no bypass** (a service workflow is bound literally only by test harnesses). `workflow_lint`: no workflow
  references a workflow of a **foreign** package literally. Tier 1: `test_fn_resolve_service`, `test_core_services`.

---

## 6. Registry & lifecycle

`core.package_registry` is the install/status truth; `core.fn_pkg_register / _set_status /
_check_deps / _remove` are the DB steps. Status lifecycle is **two-stage** `installing → active ⇄ inactive`
(`active` is always set **last** = atomic convergence deploy, R7; the `installed` value stays in the CHECK
but is unused — KISS, the pre-router only reads `active`, M1). The CLI verbs (`pkg_lifecycle.sh`):
`catalog · list · install [<pkg>…] [--no-seed] · reconfigure · activate · deactivate · uninstall [--keep-data|--purge] · doctor`.

**Installed set (Install-UX-Phase 4, apt/dnf model).** A fresh install brings **core only**; packages are added
one by one with `lifeagents package install` (or `provision.sh --packages all|a,b`; `--core-only` = alias for
`--packages none`). Every later `provision.sh` run / `lifeagents update` processes core + the **installed** set
(every registry row): an uninstalled package stays gone, a deactivated one is updated but **stays** `inactive`
(`pkg_install_one` keeps a prior `inactive` status), a newly bundled package is only offered in the recap.

**Install front door (`pkg_cmd_install`).** Interactive: pick list (multi-select) → **all questions first**
(declared credentials §3.8 + askable config §3.6, for every selected package) → quiet run with one ✓/✗ line per
package (log `/var/log/lifeagents/package-*.log`) → summary box. Non-interactive, `--no-seed` (restore) or
already inside a quiet `provision.sh` run → straight to `pkg_install_one`, no question phase.

**Install (per-package state-flow, dpkg-analog — `pkg_install_one`).** **`install core` is rejected** (the
privileged host is installed with the system, not via CLI). This is the **one code path** that `provision.sh`
calls per package (bundle = metapackage: core bare, then a per-package loop — `register_packages` is gone),
that the CLI front door calls, **and** that restore-before-install uses (§3.7 backup). Stages (each idempotent → a partial failure leaves `status='installing'`; a re-run converges,
no auto-rollback): **(0) gate** (`_pkg_gate_install`: core `active` + dep/`core_api`) **(0b) n8n-resolve**
(`N8N_API_KEY`/`N8N_URL` from `/etc/lifeagents/core.env` + `n8n.env`; absent → `die`) **(1) register**
(`status='installing'`) **(2) migrate** (`apply_schema <pkg>`: inits→V→R in one psql-TX + owner-grant on the
`<pkg>` schema) **(3) roles** (`core.fn_provision_package_roles`: `<pkg>_rw/_ro` LOGIN, no password) **(4)
credentials** (generic `provision_role_password` from `/etc/lifeagents/<pkg>.env`, override-first, **always**
`ALTER ROLE … PASSWORD` so role ↔ credential stay in sync after a `--purge`/re-install; then the **secrets
wizard** over the declared `credentials` block (§3.8, interactive-gated, seen-persisted) and the n8n creds —
the 2 role creds + the declared external-API creds — id-stably upserted). A later
**`lifeagents package reconfigure <pkg>`** re-asks the declared secrets (Enter = keep) + re-injects (§3.8)
**(5) seed** (`SEED_PKG=<pkg>`: config/contexts/validators/protected/onboarding/services for `<pkg>` only;
`--no-seed` skips **only** `<pkg>.onboarding_state` — restore brings it — code-seeds always run; **(5b)** the
buffered answers to askable config entries, §3.6) **(6) deploy**
(only the package's workflows by `provides.agents` name-prefix; credential remap by **name resolution** against
live n8n, no remap-file) **(7) active** (`fn_pkg_set_status active`, last → pre-router routes immediately).
`deactivate`/`activate` are **pure runtime** (status flip, no redeploy) — enforced by the **routing
status gate (R4, WS-B8)**: each package agent (every workflow in the package's `provides.agents`) reads
`core.fn_package_active('<pkg>')` at its entry, **before the LLM**, via a structural IF (mirroring the
depth gate) and declines with `{ok:false,error:'package_inactive'}` when the package is not `active`. The
read uses the published SECURITY-DEFINER window under `<pkg>_ro` (no direct `SELECT core.package_registry`,
D10); a DB-read error fails **open** (lifecycle gate, not a security quarantine), an explicit non-`active`
status fails **closed**. Package **crons** are gated too (F9, WS-1/Phase-4a): each cron's entry runs
`core.fn_package_active('<pkg>') AND core.fn_config_get('<pkg>','cron_enable','<cron>')='true'` (fail-closed).

**Reaching package agents from core — the dispatcher (Install-UX-Phase 4).** n8n (checked 2.21.7 + 2.44.4) refuses to
**activate** a workflow whose *literal* `executeWorkflow` target does not exist (`workflow-validation.service.ts`;
expression ids `=…` are skipped). A core workflow with a literal reference to a package workflow therefore makes
core unusable without that package (a deaf bot after a core-only install or an uninstall). Rule: **no core
workflow references a package workflow literally** (`workflow_lint` seam check). The orchestrator's router tools,
onboarding arms and command arms call **`agent.sub_dispatch_agent`** with build-time fixed inputs
(`workflow_id`, `package` + `task`/`chat_id`/`call_depth`; the package's display name + the hints come from the
text catalog in the sender's language at runtime, §3.11); the dispatcher asks
`core.fn_package_status` (`{ok, status, reason: not_installed|incomplete|inactive, is_owner}`) and only then calls
the agent by **expression id** (`waitForSubWorkflow`, HITL waits propagate). Not usable → a friendly
`{ok:false, output}` (the owner gets the CLI hint `lifeagents package install|activate <pkg>`). `call_depth` is
passed through unchanged (the dispatcher is a `sub`, not an agent hop). `contract_lint` re-checks the lost static
edge (each dispatcher target's trigger declares `task`/`chat_id`/`call_depth`). The onboarding menu labels
sections of non-active packages „nicht installiert" (`fn_onboarding_overview.active_packages`) and then adds a footer with
the server command (Install-UX-Phase 6; hiding them is impossible — n8n keyboards are build-time, n8n#19955); the Telegram
command menu (`setMyCommands`) is built from core + **active** packages and re-set on every status change.

**Uninstall (per-package, WS-2/Phase-4a — built consumer).** `lifeagents package uninstall <pkg>
[--keep-data|--purge] [--yes]` (`pkg_cmd_uninstall` + the REST teardown in `pkg_teardown.sh`). Order:
**(1) core-reject** (the privileged host is never uninstallable — also a backstop in `fn_pkg_purge_data`);
**(2) reverse-dependency guard** `core.fn_pkg_reverse_deps('<pkg>')` — refuses if any **active** package lists
`<pkg>` in `requires` (apt/dpkg rdepends); **(3) confirm** (TTY `ja` / `--yes`); **(4) n8n teardown** — delete
the package's workflows (live `GET /workflows`, word-boundary name-prefix from `provides.agents`: name `agent.<a>`
or `agent.<a>.*`) **and** the package credentials — the two role creds from the convention `Postgres <pkg>_rw
(read-write)` / `Postgres <pkg>_ro (read-only)` **plus** the names declared in the `credentials` block
(§3.8, uninstall symmetry; shared host creds match neither),
with a gated n8n restart if a package workflow was active (#21770 — teardown DELETEs workflows → real
in-memory orphan; distinct from the removed deploy-side restart, which id-stable credential injection retired); **(5) DB teardown**.
- **`--keep-data` (= `apt remove`):** only steps 1–4 + registry de-reg (`fn_pkg_remove`). Schema/roles/data/
  contexts/config stay → `fn_package_active` returns false (agents + crons dark) → re-install/re-provision
  restores operation.
- **`--purge` (= `apt purge`):** additionally, in **one psql transaction** (PG DDL is transactional →
  all-or-nothing; single-app-DB assumption makes the cluster-global `DROP ROLE` check safe):
  `core.fn_pkg_purge_data('<pkg>')` → `DROP SCHEMA <pkg> CASCADE` → `core.fn_drop_package_roles('<pkg>')` →
  `fn_pkg_remove`.

**`core.fn_pkg_purge_data(p jsonb)`** (SECURITY INVOKER, atomic) deletes the package-owned rows that live
**outside** the package schema (so `DROP SCHEMA … CASCADE` would not reach them), in **finalizer order**
(WS-B2b, Kubernetes-ownerReference): **(1)** `core.protected_contexts WHERE package` — lifts the finalizer so
**(2)** `agent.core_contexts WHERE package` deletes (the BEFORE-DELETE trigger blocks it otherwise; the
uncommitted DELETE is visible to its own transaction); **(3)** `core.context_validators` + `core.context_scopes` + `core.context_renderers` + `core.advisors WHERE package` (before
`DROP SCHEMA`, else `validate_fn`/`render_fn`/`review_fn` orphan; renderers + advisors joined the order in
WS1/WS2, `context_scopes` in P0a — a finance uninstall otherwise leaked an orphan `render_fn`/`review_fn`/scope row); **(3b)** `agent.monitor_triggers WHERE package AND origin='user'`
(advisor-created plan triggers in the host table, unreached by `DROP SCHEMA <pkg>`; the `origin='user'` guard is
mandatory — an `origin='core'` row would trip the protect trigger and abort the whole purge); **(3c)** (Phase B)
user triggers that use one of the package's **monitor acquisition methods** (also the ones the core monitor agent
created with `package='core'`, which 3b misses), then the package's `core.monitor_acquisition_methods` rows (the FK
is NO ACTION → order matters; both counted in the result); **(4)** `core.services` +
`core.config WHERE package` (+ `core.schema_version WHERE package`, Flyway-clean). Returns the per-table counts;
`package='core'` → `{ok:false}`. The package's own tables (e.g. `finance.onboarding_state`)
fall with `DROP SCHEMA <pkg> CASCADE`.

**Factory reset + test cleanup (Phase B — core knows no package).** Package set for both = `core.package_registry` ∪
`core.schema_version` (so a `--keep-data`-uninstalled package is covered), schema must exist.

- **`core.fn_reset_user_data('RESET')`** (owner ops, destructive, wrapper `util_reset_user_data.sql`; owner decision
  2026-10-19 "Werkszustand"): back to the post-install state — **deny-by-default** over the package schemas (PG
  `pg_extension_config_dump` precedent): every base table is emptied except tables marked `COMMENT ON TABLE … IS
  'lifecycle:reference - <reason>'` (seed catalogs/caches), extension-owned tables and `<pkg>.onboarding_state`; a
  schema marked `COMMENT ON SCHEMA … IS 'lifecycle:reset-skip - <reason>'` is left alone entirely (for a package whose
  schema only caches an external system; no package uses it since paperless v0.3.0 — the mechanism stays contract,
  proven by a test-local schema in `test_fn_reset_user_data`). ONE multi-table `TRUNCATE … CONTINUE IDENTITY`, never `CASCADE`. Then the host part:
  per-person onboarding rows of non-owners, advisor plans, user monitor triggers, learn state, the latches of the
  reset packages, chat memory, non-owner persons (via `fn_remove_household_person`), all agent-managed contexts
  except `family` + the household fact skeletons (the deletion protection is lifted and restored in the same
  transaction), stubs, family → owner skeleton, `core.fn_reset_onboarding_state()`. **A package adds a new
  reference/cache table ⟹ mark it** — `test_fn_reset_user_data` fails on an unmarked table that has rows after a
  fresh init.
- **`core.fn_reset_onboarding_state()`**: generic loop over the `<pkg>.onboarding_state` convention + core.
- **E2E cleanup = convention hook `<pkg>.fn_clear_e2e_data(p_runid text) RETURNS jsonb`** (1:1 package-keyed like
  `onboarding_state`, no registry): the package deletes its own `__E2E__` sentinel rows incl. its own guards and
  returns flat counts; `agent.fn_clear_e2e_data(text)` (core) cleans the host rows, calls every hook and merges the
  counts (counter keys must be unique across packages — a collision RAISEs). A package with a schema but no hook →
  RAISE (contract_lint Check 17 catches it at commit). A package without E2E tier ships an explicit no-op
  (paperless: no tables at all). **Bei uns anders:** hooks stay `SECURITY INVOKER` without `REVOKE … FROM public` (package-fn
  convention) — `<pkg>_rw` already holds DELETE on its own tables, so the hook grants nothing new; a hook that ever
  becomes `SECURITY DEFINER` must revoke.

---

## 7. Second-consumer paper validation (D8 — finance-leakage check)

The finance extraction is the *build method*; to prove the contract is **generic** (not finance
shaped), it is validated on paper against a hypothetical second package **before** 1.0. Two
candidates: **`monitor`** (already core-resident as the shared heartbeat per D11 — so the relevant
second domain consumer is a *new* vertical) and **`jobscout`** (a job/career-watch agent:
read-only research + watch triggers, structurally an advisor-like package).

| Contract element | Generic? | Finding |
|---|---|---|
| `manifest.json` fields | ✓ | `jobscout` populates `provides.agents=[jobscout]`, `provides.tools=[…]`, `consumes.services=[core:web_search, core:human_approval, core:monitor]`. No finance field. The `provides`/`consumes` shape is domain-neutral. |
| Own schema `<pkg>` + `<pkg>_rw/_ro` | ✓ | `jobscout` schema holds its own tables; roles isolate it from `finance.*` and `agent.*` exactly as for finance. The role model has **no finance assumption**. |
| `contexts/*.md` + `protected_contexts` | ✓ | a hypothetical `jobscout` would ship `jobscout_agent_instructions` (declared protected via its manifest `protected_contexts`, §3.4) + lazy `career_planning`; same three frontmatter fields. (Illustrative — no such file exists in core.) |
| `onboarding/sections.json` | ✓ | `jobscout` may add a `career_goals` section with its own `handler`; the core driver iterates it without knowing its semantics. The section schema is generic. |
| Published core read-fns | ⚠ | `jobscout` needs household facts too — confirms such a read-fn belongs in **core**, not finance. `core.fn_core_api_version()` is already neutral. A dedicated `core.fn_household_member()` is **deferred** (P9): no Phase-3 consumer exists — household reads run in the core trigger or via `load_context` (owner cred), never under a package read role; build it only when a package-role-scoped family read actually appears. **Action:** keep household reads in `core`, never in `finance` (already the D12 split). |
| Service alias `core:*` | ✓ | `jobscout` consumes `core:web_search`/`core:human_approval`/`core:monitor` — the same host services finance uses. No finance-specific alias exists. |
| `consumes.services` lint (SC1) | ✓ | Generic allow-list mechanism; nothing finance-specific baked in. |

**Verdict:** the contract surface is domain-neutral. The single coupling risk is **household
facts** — they must live in `core` (read-fn), not in the finance package, so a second household-
aware package can read them without depending on finance. That is already the plan's D12/R1 split
(`fn_validate_household_facts` → core family part + registrable package validators; a
`core.fn_household_member()` `SECURITY DEFINER` read window is **deferred until a package-role-scoped
family read actually exists**, P9). No contract change needed; `core_api` stays 0.x until a real second
package exercises this in code.

**Update (2026-06-28 — WS-0 `career`, the real second consumer):** the career-coach advisor domain now exists
as a **scaffold**. WS-0 confirms the **structural** half of this validation **in code** — own schema `career` +
isolated roles `career_rw`/`career_ro` + a near-empty manifest + the install/uninstall lifecycle all generalize
unchanged (`tests/db/career/test_career_isolation.sql`). Building it surfaced two finance-shaped tooling assumptions the
paper exercise could not: `deploy_workflows.sh` raised `die` for a package with empty `provides.agents` (now a
graceful no-op), and the db-test substrate `bootstrap_test_db.ps1` hard-coded finance schema/role provisioning
(now package-generic). The published-read-fn half (`consumes.reads`) stays paper-only until the career advisor
binds it in WS-1+; `core_api` remains 0.x accordingly.

## 8. Pattern-Parität — der Finance-Bauplan als Referenz-Analog (Phase 0, M5)

**Zweck:** die *eine* Adresse für Root-CLAUDE.md *Arbeitsweise* („Neue Oberfläche = bestehendes Analog übernehmen“). Beim Bau des N-ten
Exemplars eines bestehenden Bauteils ist der **Default die exakte Übernahme** des hier genannten Referenz-Analogs;
eine Abweichung braucht einen belegten Grund (n8n-Quirk / DB-Gesetz / Single-User / genuin 1-Instanz-mit-Trigger) und
wird unten als „bei uns anders"-Notiz festgehalten (damit sie nicht je Paket re-litigiert wird).

| Artefakt-Typ | Kanonisches Muster (Kurz) | Referenz-Analog | Wächter (Lint/Test) |
|---|---|---|---|
| **Paket** | homogenes `manifest.json` (provides/consumes/config/validators/renderers/advisors/protected_contexts/read_surface/catalog/backup/credentials) + eigenes Schema + `<pkg>_rw/_ro` + Lifecycle | `packages/finance/manifest.json` + `finance.tables_init.sql` | `contract_lint`, `test_<pkg>_isolation` |
| **Paket-Secret / Fremd-API-Credential** | manifest-`credentials`-Block (§3.8: placeholder/name/type/required + env{field,validator,secret,prompt}) → Stage-4-Wizard (seen-persistiert `<pkg>.env`) + `_inject_manifest_credentials` (data-Assembly per Typ ZENTRAL in bash) + Teardown-Symmetrie; NIE Host-Code-Literale | `packages/career/manifest.json` `credentials` (Adzuna/JSearch) | `contract_lint` (Parität/Naht-Guard/type-Enum), doctor |
| **Fakten-Kontext** (deterministisch) | `metadata.facts` jsonb in `agent.core_contexts` (`managed_by='agent'`), validate-on-write + render-at-fetch, registriert in `core.context_validators`+`core.context_renderers`+`core.context_scopes` (scope/write_permission, P0a); geschrieben ueber den EINEN Schreibweg `agent.fn_set_context_facts` (Phase A); ein household-Kontext deklariert sein leeres Skelett per Manifest-`context_skeletons` + seine HITL-Labels im Textkatalog (`<pkg>.facts.<context>.*`, §3.3) | `finance_profile` / `career_profile` (`fn_validate_*`/`fn_render_*`) | `db_test` je fn; `contract_lint` |
| **Plan-/Prosa-Kontext** | `agent.advisor_plans` (`(domain, person_id)`-keyed seit P0c, draft/active, versioniert) + `core_contexts`-Prosa; Sektionen via `tool_save_plan_section`/`tool_publish_plan`; Fakten-Header via Renderer. scope/Person aus der `core.context_scopes`-Registry (household → `person_id` NULL; per_user → Sender via `fn_resolve_sender`, Prosa-Doc suffigiert). Domain→Context-Map aus `core.advisors.plan_context`. | `financial_planning` (household) / `career_planning` (per_user) | `db_test fn_advisor_save_section`/`_publish_plan`/`advisor_plans_person_keying` |
| **Instruktions-Kontext** | seedbare `.md` (Frontmatter `description`/`agent_name`/`load_strategy`), `managed_by='seed'`, in `protected_contexts` | `finance_advisor_instructions` (`packages/<pkg>/contexts/*.md`) | `doc_lint`, Seed |
| **Write-fn** | `fn_<tool>(p jsonb)` atomar → `{ok:true, …post_state}` \| `{ok:false, reason}` (korrigierbar, kein RAISE) \| RAISE (unrecoverable → errorWorkflow); abgeleitete Werte **DB-seitig** | `finance.fn_book_transaction` | `db_test test_fn_<name>` (Happy + {ok:false}) |
| **Write-Tool** | Sub-Workflow Trigger→Resolve→Check→HITL-Gate (`agent.tool_human_approval`, Tier aus dem `approval_matrix`-Block des Paket-Manifests, §3.10)→Write-fn→Return; `Build-Trigger`+`$fromAI` an ZWEI Stellen; `_manifest` (Category/Examples) ODER `@{ Internal = $true }` (genau eins); genau EINE Top-Level-`Build-*` je `tools/`-Def (Builder-Discovery `scripts/build/lib/builder_discovery.ps1`, keine Registry) | `packages/finance/build/workflows/tools/book_transaction.ps1` | `approval_lint`, `mock_route`, `-VerifyCatalog` |
| **Read-Pfad** | `postgres_select` (`<pkg>_ro`, `onError continue`) · `load_context` · publizierte Views; Manifest `read_surface` | finance `account_overview` + `read_surface`-Block | `contract_lint` |
| **Cross-Paket-Read** (optional-provider, §4.2) | Provider veröffentlicht provider-eigene Lese-fn + `provides.reads`; Consumer `consumes.reads` + **Doppel-Guard** (`fn_package_active`+`to_regprocedure`)+graceful NULL; Oberfläche A=plain fn render-at-fetch (kein Grant), C=DEFINER+Grant unter `<pkg>_ro`; KEIN generischer Core-Dispatcher (1 Konsument) | finance `fn_liquidity_snapshot()`→career `fn_runway`/Runway-Zeile (WS-5) | `contract_lint` (consumes.reads↔provides.reads), `role_test_lint` (Oberfläche-C DEFINER+`_ro`-Grant ⟹ `SET LOCAL ROLE`-Perspektiv-Test-Pflicht), `db_test test_fn_runway`/`_render_career_planning` |
| **Paket-Tool-Service** (Cross-Paket-Werkzeug, §5.1) | Provider: Objekt-Form in `provides.services` ({workflow, description, permission, inputs}) + Werkzeug `agent.<pkg>.tool_*` mit Trigger `args`+`chat_id` (Parse args aus den Manifest-inputs); Konsument: `consumes.services` `<pkg>:<alias>` + `Add-ServiceTools` in der Agent-Def (eigener Agent `-Own`); Laufzeit IMMER `agent.sub_dispatch_tool` → `core.fn_resolve_service` (Service/Paket/Absender, fail-closed) → Ausdrucks-ID aus `core.services` | paperless `search_documents`/`get_document`/`ask_documents` → finance/finance_advisor/career_advisor/estate_advisor + `agent.paperless_assistant` | `contract_lint` (SC1 Objekt-Form, args-`$fromAI`, Vermittler-Kante, Bypass), `workflow_lint` (Fremd-Paket-Naht), `db_test test_fn_resolve_service`, `infra_test` (Mock) |
| **Cron** | dedizierter `cron.*.ps1`; Schedule aus `config.schedule.<job>` als Deploy-Platzhalter (`Build-ScheduleTrigger -ScheduleKey`, nie eingebacken); Schwellen zur Laufzeit via `fn_config_get` mit COALESCE-Default; F9-Gate `fn_package_active AND fn_config_get(cron_enable)`; **zwei Toggle-Muster nach `cron_enable`-Default** (Opt-in `value=false`: `cron_on:<key>` Setup + `cron_off:<key>` Laufzeit, Re-Aktivieren per `/reminders`; always-on `value=true`: Plumbing nur Konsole, registrierte Erinnerungen an der Karte + `/reminders`) — s. Cron-Toggle-Modell unten; errorWorkflow auto | `cron.advisor_common.ps1` (opt-in `cron_off`-Nudge) / `tools/publish_plan.ps1` (opt-in `cron_on`-Emitter, **kein** Cron) / `cron.reconcile_accounts.ps1` (always-on) | `config_test`, `cron_toggle_lint`, `db_test` |
| **Config-Eintrag** (§3.6) | Manifest `config.<cat>.<key> = {value, description, summary, type?, minimum?, maximum?, managed_by?}` → `_seed_package_config` → `core.fn_config_seed` (conffile); Wert-Typ = DB-Gesetz (`trg_config_check_value_type`, nur bei Wertänderung; Seed setzt typ-ungültige Altwerte zurück); `managed_by system` = ausgeblendet; Verbraucher lesen zur Laufzeit (`core.fn_config_get`/`core.sub_load_config`). **Bei uns anders:** die Form-/Typ-Prüfung der Manifest-Felder lebt in `config_test` (nicht in `contract_lint` 12e/12f), weil sie denselben Wert-Prüfer braucht, der `core.fn_config_value_valid` spiegelt (Standardwerte + gemeinsame Cron-Fallliste) — ein Split doppelte ihn | `finance.reconcile_overdue_days` (integer ≥ 1), `core` `schedule.*` (cron), `api.core_version` (system) | `config_test` (2–4), `test_config_value_checks.sql`, `contract_lint` 12f (`summary`) |
| **Agent** | `New-AdvisorGateChain` (Depth+Package-Active+Core-first) → Load-Config → `New-ModelSelectorBundle` → Tool-Bindings (`New-AdvisorToolNode`) → LM-Chat → Memory `agent.<agent>_chat_memory`; `maxIterations` cap | `agent.finance_advisor.ps1` (+ `New-AdvisorGateChain`) | `infra_test` (Depth/Package-Gate), `orch_test` |
| **Registry** | im Manifest deklarieren → `seed_data.sh _seed_*` upsertet generisch (`package=$pkg`, **kein** Core-Paket-Literal) → Core-Dispatcher via dynamic `EXECUTE format(...)` (`to_regprocedure`-Guard, INVOKER, pinned `search_path`) | `core.context_validators`/`advisors` + `core.fn_advisor_review_evaluate`; **Callback:** `core.callback_handlers`+`core.fn_dispatch_callback` | `db_test`, `contract_lint`, `core_literal_lint` |
| **Callback-Handler** | NEUER Paket-Prefix = **nested Daten-Zeile** in `core.callback_handlers` (`prefix→{handler_fn, member_permeable}`), dispatch via die generische `extra`-Fallback-Verzweigung; die 9 Core-Prefixes bleiben direkt-verdrahtet (Multi-Node-Ketten). **`member_permeable`** (bool, **fail-closed** DEFAULT false) = darf ein aufgelöstes Nicht-Owner-Mitglied den Prefix auslösen? Der Dispatcher `core.fn_dispatch_callback` enforced es (re-resolvt den Sender selbst: owner/member/unresolved), die FEINE Auth (adults_only/Per-Item-Eigentum) macht der Handler; Owner-Admin-Prefixes (nicht in der Registry) sind für Mitglieder strukturell unerreichbar (`unknown_callback_prefix`) | `learn:` (direkt) · `job:`/`est:`/`lang:`/`rem:`/`plan:` (Registry, `member_permeable=true`; `lang:` = Sprach-Picker, Owner jede Person, Mitglied nur sich; `plan:` = Plan-Schritt, Mitglied bekommt den Handler-Toast) | `real_ingress` (ri19–21, ri23–24), `contract_lint` (9), `db_test test_fn_set_person_language` |
| **Fester Nutzertext** (Textkatalog, §3.11) | Text nie als Literal im Build-Def/SQL, sondern Key in `packages/<pkg>/locales/<code>.json` (alle Sprachen der Core-Liste, ganze Sätze, `{platzhalter}`); Laufzeit-Lookup über `core.fn_ui_text(s)` in der Sprache des Empfängers (`agent.fn_person_lang`); HITL-Karte = `New-HitlSummary` (Keys + typisierte Rohwerte, das Gate rendert je Empfänger); Workflow-Text = `t`-Map + `Get-UiTextExpr`; DB-Toast = `core.fn_ui_text` mit der Sprache des Tippenden | `agent.tool_human_approval` + `finance/tools/book_transaction.ps1`; Orchestrator-Toasts (`Resolve callback sender` → `t`); `estate.fn_handle_case_task_callback` | `locale_lint`, `ui_literal_lint` (Ratchet), `workflow_lint` (HITL-Summary strukturiert, echte Umlaute), `hitl_gate_test` (hitl08), `real_ingress_test` (ri30–ri37) |
| **App-Bildschirm** (Mini-App, §3.12) | Manifest-Block `app_screens` → `_seed_app_screens` **ersetzt** die Zeilen des Pakets (DELETE+INSERT; bei uns anders als upsert-only: ein entfernter Bildschirm bleibt nicht als tote Navigation stehen) → `core.app_screens` → Dispatcher `core.fn_app_screen` (initData, Person, Schalter, `fn_package_active`+`to_regprocedure`) → `<pkg>.fn_app_screen_<screen>(jsonb)` = DEFINER-Fenster, löst die Rolle selbst auf (nur owner/partner = Haushalt), liefert das View-Modell mit typisierten Text-Verweisen | `finance.fn_app_screen_overview` | `contract_lint` (29/29b), `db_test test_fn_app_screen`/`test_fn_app_screen_overview`/`test_fn_pkg_purge_data`/`test_role_permissions`, `app_endpoint_test` |
| **Monitor-Beschaffungs-Methode** (Phase B, §3.9) | Manifest-Block `monitor_acquisition_methods` → `core.monitor_acquisition_methods` (Core-Builtins web_search/sql/none fest, Paket-Methoden per Registry-Dispatch, `to_regprocedure`-Guard) + FK von `monitor_triggers.acquisition_method` + `validate_fn` im BEFORE-Trigger; nicht verfuegbar → Trigger geparkt | finance `fx_rate` | `contract_lint` (18), `db_test test_monitor_acquisition_methods`/`test_core_only` |
| **Daten-Lebenszyklus** (Phase B, §6) | Werkszustand-Reset deny-by-default ueber Tabellen-Marker `lifecycle:reference` / Schema-Marker `lifecycle:reset-skip` (kein Paket-Code); E2E-Cleanup = Konventions-Hook `<pkg>.fn_clear_e2e_data(text)` (Muster `<pkg>.onboarding_state`) | finance/career/estate (paperless No-op, leeres Schema) | `contract_lint` (17), `db_test test_fn_reset_user_data`/`test_fn_clear_e2e_data`/`test_core_only` |
| **Command-Handler** (WS-5) | NEUER Paket-Slash-Command = Eintrag im Manifest-`commands`-Block mit `dispatch:{agent,task}` (= **CODE-PFAD-Command**, startet einen Agenten) → `build.ps1 $CommandDispatchList` (Union aller Manifeste, Muster `$OnboardingDispatchList`) generiert build-time einen `/xxx`-Switch-Case im Orchestrator-`Command router` + einen Run/Relay-Dispatch-Arm → `agent.<agent>` INLINE (message.text, synthetischer Task, call_depth=1); Fallback ZULETZT. **DISCRIMINANT:** Code-Pfad-Command → Build-Zeit-`Command router`-Switch; reiner Text-/Button-Callback-Prefix → Laufzeit-`core.callback_handlers` (Zeile oben). Core-Commands (`/help`/`/onboarding`/`/start`) haben KEIN `dispatch` = host-bespoke | estate `/notfall`→`agent.estate_advisor` | `command_lint`, `real_ingress` (ri17/ri18) |
| **Agenten-Routing** | Orchestrator-Call-Nodes + Switch + ai_tool-Bindings **build-time generiert** aus `provides.agents[{name,router_description,order,fallback_for?}]` (Union aller Manifeste, `orchestrator` ausgeschlossen, `agent.`-Prefix); das Routing-Wissen eines Pakets = seine `router_description`s, der Core-Prompt bleibt paket-neutral (Phase C) | `agent.orchestrator.ps1` (Build-Gen) + `lib/agent_routing.ps1`; Analog finance/career/estate-Manifest | `contract_lint` 19, `core_literal_lint` (Agent-Namen-Klasse), `real_ingress` (Routen-Verhaltensgleichheit), `orch_test` |
| **Test-Tiers** | neue/`fn_*`→`db_test` (hart) · neues Write-Tool→`mock_route`-Golden (+ `e2e` wo tauglich) · Routing/Prompt→`orch_test`/`n8n_test`/`judge_eval` (weich, owner) | `tests/CLAUDE.md` Blast-Radius-Matrix | Pre-Push-Hook |

### „Bei uns anders" / justified-different (nicht re-litigieren)

- **Typisierte Registries statt einer generischen `package_extensions`-Tabelle (Phase B, arch-challenge Q2 REJECT-mit-Notiz):**
  `context_validators`/`callback_handlers`/`advisors`/`monitor_acquisition_methods`/`app_screens` tragen je eigene Constraints
  (fn-Arity, `member_permeable` fail-closed, Cross-CHECKs) — eine kind/key/fn-Sammeltabelle verloere sie ("DB ist
  Gesetz"). fn-Spalten bleiben `text` + `to_regprocedure` (ein `regprocedure`-Wert in einer Zeile erzeugt kein
  `pg_depend` und blockt `pg_upgrade`, Q5).
- **Bank-To-do klassifiziert selbst (finance `fn_standing_orders`, arch-challenge 2026-10-29):** Summen lesen sonst
  `recurring_cashflow_classified`; diese View kennt aber nur HEUTE laufende Zahlungen, die Bank-To-do und die
  Spar-Deckung brauchen gerade die kommenden. Kredit-Ausschluss über den Ketten-Kopf wie in der View.
- **Reset-Marker am Tabellen-Objekt statt Manifest-Keep-Liste (Phase B, Q1 ADOPT):** SQL liest keine Manifeste; ein
  Manifest-Block braeuchte eine geseedete Registry nur fuer eine Liste. Der Marker sitzt neben der DDL und faellt
  mit `DROP SCHEMA` (PG `pg_extension_config_dump`). E2E-Cleanup bleibt dagegen Paket-Code (Sentinel-Logik).

- **`config`-Kategorie `advisor` ist GETEILT** (Core-Advisor-Engine-Tuning), gelesen von `finance.fn_advisor_review`,
  `career.fn_advisor_review` UND (WS-4) `estate.fn_advisor_review` (1. `fn_config_get`-Arg = Provenienz
  `core|finance|career|estate`, **Kategorie geteilt** — wie die `cron_enable`-Keys `drift_check`/`plan_review`). Der Key
  ist je Paket eigen (`plan_stale_days`/`career_plan_stale_days`/`estate_review_days`; `UNIQUE(category,key)` global).
  **Kein** per-Domäne-Rename der Kategorie — das wäre *weniger* einheitlich.
- **estate als 2. `advisors`-Konsument mit household-`plan_context` OHNE Publish (WS-4, arch-challenge P5 REJECT-mit-Notiz):**
  estate registriert sich in `core.advisors` wie finance/career, aber (a) sein `plan_context` `estate_overview` ist ein
  **render-at-fetch-Lese-Context** (die estate-Register-Tabellen sind die Wahrheit), der **NIE publiziert** wird — anders
  als finance/career, deren `plan_context` das über `agent.advisor_plans`/`publish_plan` geschriebene Soll-Sidecar ist;
  `estate.fn_advisor_review` liest die Register-/Gap-Wahrheit direkt (Staleness je Erwachsenem + `v_directive_gaps` +
  guarded finance-Gaps via `fn_gap_report`), kein Plan-Sidecar. (b) estate erbt **NICHT** die geteilten Advisor-Crons
  (die sind opt-in, publish-getriggert) sondern hat einen **eigenen dünnen always-on Enable-Cron**
  `agent.estate.cron_review_register` (Opus-M4: ohne Publish-Knopf liefe der Review sonst nie) — er ruft
  `core.fn_advisor_review_evaluate('estate', NULL, '{}')` monatlich, self-still über den Latch. household → `person_id`
  NULL (keine `context_scopes`-Zeile, `fn_context_persons('estate_overview')` leer). **Kein** Publish-Ziel, **kein**
  `cron_labels`-Eintrag (always-on, nur Konsole). Seit dem Roten Faden (2026-10-23) trägt estate `advisors.estate.own_review_cron:
  true` → die geteilten Advisor-Crons lassen die Domäne aus (vorher latchte der geteilte Drift-Wächter estate-Alerts
  unter „Plan-Abweichung" und der eigene Cron fand den Latch verbraucht). „Erst einladen, dann mahnen": `estate.fn_advisor_review`
  liefert Alerts erst, wenn mindestens ein estate-Onboarding-Abschnitt `completed` ist.
- **Vision-Modell-Keys distinkt:** finance `model.vision_extract` ≠ career `model.cv_extract` (`UNIQUE(category,key)`
  verbietet Teilen; je Paket eigenes Privacy-getuntes Vision-Modell). Kein Rename.
- **Cron-Toggle-Modell (Owner-Direktive, gelockt 2026-06-28):** ZWEI legitime Muster, unterschieden allein durch den
  `cron_enable`-**Default-Wert** (kein neues Schema). **Opt-in** (`value=false`, z. B. `drift_check`/`plan_review`/
  `learn_context`): startet AUS; SETUP-Aktivierung per Chat-Knopf `cron_on:<key>` (am Publish-/Onboarding-Angebot),
  LAUFZEIT-Abschaltung per `cron_off:<key>` (an Nudge/Karte), RE-AKTIVIEREN per `/reminders` (seit Paket B, s. u.)
  — **kein** `cron_on` am Laufzeit-Nudge. **Always-on** (`value=true`): startet AN; Plumbing (fx/market) nur über die
  Konsole, registrierte Erinnerungen (remind_interest/reconcile) an der Karte und per `/reminders` (s. u.).
  `cron_toggle_lint` erzwingt die Muster (Opt-in braucht beide Knöpfe + eine `cron_labels`-Zeile; nicht registrierte
  always-on-Crons dürfen keinen Knopf haben). **Togglability-SoT seit WS-0c #2/#3 = MITGLIEDSCHAFT in `core.cron_labels`** (statt
  hartkodierter Whitelist): `core.fn_set_cron_enable` ist UPDATE-only und akzeptiert genau die Keys mit cron_labels-Zeile
  (= die Opt-in-Keys der Manifest-Liste `cron_labels.list`; die Toast-/Meldungstexte stehen seit Textkatalog Phase B im
  Katalog `<pkg>.cron.<key>.*` und kommen in der Sprache des Tippenden, fn bleibt rein `{ok,key,enabled}`); die Konsole (`config_cli`) schreibt direkt. Publish bietet **zwei getrennte**
  Aktivierungs-Knöpfe (`drift_check` + `plan_review`, unabhängig schaltbar) — Owner-Entscheid statt eines Sammel-Knopfs.
  **Person-Reminder (Roter Faden 2026-10-23):** Manifest `cron_labels.person: { "<key>": { "default_enabled": bool } }` →
  `core.cron_labels.scope='person'`; jede Person schaltet ihre Zustellung selbst per `rem:on|off:<key>` (Registry-Handler
  `core.fn_handle_reminder_cb`, member_permeable → `agent.reminder_prefs`), die eine Prüf-Adresse ist
  `core.fn_reminder_allowed(key, person_id)` (Notschalter `cron_enable` UND Präferenz/Default). Ihr `cron_enable` ist
  always-on und nur Konsolen-Notschalter; `core.fn_set_cron_enable` lehnt person-Keys ab. Erster Konsument:
  `onboarding_nudge`. **Erinnerungs-Fenster:** nicht zeitkritische Reminder laufen nur in `general.reminders_from..until`
  (Default 10–20 Uhr, Owner-Entscheid): Cron-Defaults liegen im Fenster, der stündliche Wächter hält Datums-/Info-Trigger
  und Problemberichte außerhalb zurück (`core.fn_in_reminder_window`), Wert-Wächter melden sofort.
  **`/reminders` (Roter Faden Paket B, ersetzt „Re-Aktivieren nur Konsole"):** `core.cron_labels` ist jetzt die Registry
  ALLER nutzer-sichtbaren Crons in drei Ebenen — `list` (Haushalt, Default an ODER aus; der Owner schaltet per
  `cron_off:<key>` an der Karte oder per `rem:on|off:<key>:m` im Menü), `person` (s. o.) und `mandatory` (Pflicht,
  z. B. Fristen im Ereignisfall: nur Anzeige, `fn_set_cron_enable` + Handler lehnen ab; CHECK nur household).
  `core.sub_send_reminders_menu` (Knöpfe build-time aus den Manifesten, Stand aus `core.fn_reminders_overview`, Owner
  alles / Mitglied nur `person`) sendet nach jedem Menü-Tipp neu (`route:'reminders'`). `cron_toggle_lint` erzwingt:
  jeder Telegram-sendende Cron ist registriert (Ausnahme: der Wächter-Herzschlag `monitor_triggers`), jede
  Haushalts-Erinnerung lässt sich an ihrer Karte abschalten (`cron_off:<key>` oder Fußzeile `core.reminders.card_footer`
  bei Bestätigungs-Karten), Pflicht ohne Knopf, Default-Zeitplan im Fenster. `score_jobs` ist seit career:V006 ein
  Person-Reminder (Default aus, jede Person für sich).
- **Host-Rollen-Invariante (Callback-Dispatch & dynamic EXECUTE):** ein via Registry dispatchter `handler_fn` (z. B.
  `career.fn_*`) läuft unter der Orchestrator-Cred `N8N_DB_USER`, die per `apply_schema.sh _emit_pkg_owner_grants`
  EXECUTE auf **jedem** `<pkg>.*`-Schema hat — darum funktioniert der Core→Paket-Dispatch trotz D10 (die engen
  `<pkg>_rw/_ro` sind nur für die Agent-/Tool-Workflows). Schema-qualifizierte Aufrufe (kein search_path-Verlass).
- **career WS-1-Asymmetrien (gewollt):** 1 Instruktions-Datei (read-only; `career_agent_instructions` kommt mit
  Write-Tools) · keine Domänen-Crons (erbt die Core-Advisor-Crons über die `core.advisors`-Registrierung) ·
  Validator/Renderer-Asymmetrie (`career_planning` ist raw-authored → validiert; der finance-Plan ist derivativ).
- **career `read_surface`/`catalog` (Phase 0 WS-0d — Paritaet + WS-1-Scaffold):** `read_surface.host_read_role` =
  `core_ro` **wie finance** (Paritaet, **nicht** „bei uns anders") — das ist das unbedingte Core-Host-Aufsichtsfenster
  (`core.fn_provision_package_roles` grantet `core_ro` SELECT auf `career`, §4.1), **nicht** die enge `career_ro`-
  Isolationsrolle; `preferred_views` = `[]` (die Job-Treffer sind person-privat, §4.1 — der Advisor liest die eigenen
  über `read_job_matches` → `career.fn_read_job_matches`). Der `catalog`-Block (`ord` 200)
  rendert die Tail-Sektion „Karriere-Beratung & Planung" **und** seit WS-2 die Kategorie „Jobsuche & Matching" (sie trägt
  jetzt `tool_record_job_match`). **WS-2-Konsumenten der §8-Nähte:** career-Prefix `job:` ist der erste echte
  `callback_handlers`-Eintrag (`career.fn_handle_job_feedback`); `career_preferences` ist der 2. Fakten-Kontext +
  `tool_set_career_preferences` die 2. Bindung des geteilten `agent.tool_set_context_facts` (KI-Name `tool_set_career_preferences`); `cron.score_jobs` der erste career-Opt-in-Cron
  (`cron_labels.score_jobs`); `tool_record_job_match` der neue Write-Verb `record_` (idempotenter UPSERT, arch-challenge).
- **career WS-3 Skill-Gap-Soll im Sidecar (Pattern-Paritaet, NICHT „bei uns anders"):** die Ziel-Skills
  (`target_roles[].required_skills[]{name,min_level?,is_blocker?}`) leben als Block des `targets`-Abschnitts im
  `career_planning`-Sidecar — exakt wie der finance-Soll `target_allocation.blocks[]` im `financial_planning`-Sidecar
  (kein Soll-Tabellen-Konstrukt; HITL ueber den bestehenden `publish_plan`-Pfad). Die 4-stufige Kompetenz-Skala
  (`beginner|intermediate|advanced|expert`) hat EINE Definition: `career.fn_skill_level_rank(text)` (IMMUTABLE,
  RAISE-frei, unbekannt->0), an die Validatoren (Ist+Soll) und die Gap-fn `career.fn_skill_gap` delegieren — kein
  Cross-Schema-ENUM (D4 Typ-USAGE-Falle) und keine Lookup-Tabelle (geschlossene, bereits validierte 4-Werte-Menge).
  min_level-Gueltigkeit + Skill-Unikat je Rolle prueft der `career_planning`-Validator (Backstop auf jsonb-Sub-Feld =
  Validator-Ebene, wie auf der Ist-Seite). Eine dedizierte `role_skill_requirements`-Tabelle ist DEFER (Trigger:
  Multi-Person-Scoping ODER plan-unabhaengige Cross-Role-Abfragen ODER Skill-Volumen sprengt die Hand-Kuratierung).
- **career P0c — `advisor_plans` person-skopiert (NULL=household + NULLS NOT DISTINCT; Pattern-Paritaet + arch-challenge ADOPT):**
  die GETEILTE Plan-Tabelle `agent.advisor_plans` traegt seit P0c `person_id text` — **NULL = Haushalt** (exakt die
  finance-Bestands-Konvention `owner_person_id NULL=Haushalt`, 5 Entitaeten). finance/`financial_planning` bleibt
  household (person_id NULL, kein Backfill, verhaltensneutral); career/`career_planning` ist per_user (reale
  `person_id` aus `fn_resolve_sender`, NIE LLM; Prosa-Doc suffigiert). Die DB-Gesetze "ein active/draft +
  Versions-Audit pro (domain, person_id)" halten ueber **`NULLS NOT DISTINCT`** (PG15+/PG17) AUCH fuer die
  household-NULL-Zeilen (sonst behandelt der Default zwei NULLs als verschieden -> stiller Verlust). Das ist die
  erste Repo-Nutzung von NULLS NOT DISTINCT — SQL:2023-Standard, kein Eigenbau; GUI-Index-Footgun (manche zeigen das
  Flag nicht) -> Verifikation via `\d+` + db_test `test_advisor_plans_person_keying` (2. household-NULL-active wird
  vom CONSTRAINT abgelehnt). arch-challenge A>B>>C: B (Owner-Anker statt NULL) = semantischer Smell + Fremd-Tenant-
  Backfill, C (Sentinel-Slug) = FK-Bruch. Owner-Quelle = `agent.fn_owner_person_id()` (LIMIT 1, RAISE-frei) als EINE
  deterministische Quelle (read_plan-Fallback/Review/refresh_market_signals/Migration). `fn_advisor_read_plan` ist
  jetzt `(text, text)` (chat_id-Person-Scope; `core:V014` droppt 1-Arg, Muster fn_fetch_context/V013). Multi-Person-
  Faecherung (Cron-Schleife, per-Person-Notify, `job_matches.person_id`) = P2.
- **#10 finance_ro/core_ro-Grant-Split = Design, kein Bug:** Agent-Layer-Reads laufen unter `core_ro` (hat `SELECT
  agent.*`), Paket-Tabellen unter `<pkg>_ro` — bewusst getrennt (D10/D12).
- **career P2a — Multi-Person-Fundament (4 Entscheidungen, arch-challenge 5× ADOPT):**
  - **`career.job_matches.person_id` ist `text NOT NULL` + FK `ON DELETE RESTRICT`** (Backfill Owner via
    `career:V003`) — **wholly-per-person** Tabelle (kein Haushalts-Job-Match), darum NOT NULL, **anders** als die
    mixed-scope finance-`owner_person_id` (nullable, NULL=Haushalt). Person-Auflösung in `fn_record_job_match`/
    `fn_handle_job_feedback` IMMER aus dem Sender (`fn_resolve_sender(chat_id)`, NIE LLM); Owner-Fallback, wenn kein
    person_id/chat_id geliefert wird (P2a verhaltensneutral). `fn_handle_job_feedback` filtert `WHERE person_id=sender`
    (Eigentümer-Check; fremd ≡ nicht-existent → kein Enumeration-Leak).
  - **`career.market_signals` bleibt household-global (KEIN person_id)** — öffentlicher datierter Posting-Cache
    (Analog `finance.market_prices`); Person-Scoping lebt im per_user `career_planning` (`fn_market_trend` zieht die
    scope_keys aus dem Personen-Plan), eine person_id-Spalte wäre unechte Isolation (Dup-Zeile je Person).
  - **Notify person-Dimension als Suffix auf `core.notification_state.source`** (`advisor:<domain>:<person_id>`,
    NULL → `advisor:<domain>` byte-gleich), **nicht** als eigene `person_id`-Spalte — einziger Konsument ist
    exakt-match Key-Dedup über PK `(source,key)` (Alertmanager-nflog); `fn_should_notify`/`fn_notify_reconcile`
    bleiben source-agnostisch. Spalte (FK + sargable Filter) erst bei realem person-selektivem Bedarf → BACKLOG.
  - **`agent.fn_person_chat_id(person_id)`** = Umkehrung von `fn_resolve_sender` auf derselben SSOT (family-Facts
    `telegram_user_id` = private chat_id; private-only-Bot), **nicht** `pairing_state.chat_id` (nicht person-eindeutig).
  - **`career.onboarding_state.person_id` ist bewusst NICHT in P2a** (Sektions-Katalog + Haushalts-Status, koordiniert
    mit dem P2b-Onboarding-Gate + Seeder + Core-Onboarding-fns). Multi-Person-Cron-Schleifen/per-Person-Sends = P2b.
- **career P2b-1 — Onboarding pro Person + person-skopiertes Pflicht-Gate (arch-challenge F1 REJECT-extern / F2 ADOPT):**
  - **`career.onboarding_state` ist PRO PERSON** (`person_id text NOT NULL` + FK `agent.persons` ON DELETE RESTRICT +
    composite-PK `(section_key, person_id)`, `career:V004`) — **EINE Tabelle, composite-PK** (F2 ADOPT Citus/Azure-
    Multi-Tenant + byte-Parität `job_matches`/V003), **KEIN** Catalog/State-Split (das wäre die `core.onboarding_sections`-
    Registry, die P1-D1 schon REJECTed hat — Over-Normalisierung von ~6-12 Zeilen). `finance.onboarding_state` +
    `agent.guide_onboarding_state` bleiben household (PK `section_key`, unverändert). Seeder seedet nur Owner-Zeilen;
    weitere Personen lazy via `core.fn_ensure_onboarding_person` beim ersten Schreibzugriff.
  - **Scope-Mechanik = DERIVE aus `core.context_scopes`** (F1 REJECT des externen explicit-manifest-flag-Standards
    Backstage/Eclipse → ADOPT der internen `fn_fetch_context`-Mechanik, 3. Konsument/Rule of Three): die geteilten
    Core-fns leiten per_user-ness ab via `EXISTS(SELECT 1 FROM core.context_scopes WHERE package=<pkg> AND
    scope='per_user')` (career→true; finance/guide→false → byte-gleich household). **Kein** neuer Manifest-Flag
    (`provides.onboarding` bleibt `{agent}`), **kein** `package_registry`-Feld, **kein** neuer Lint (honoriert P1-D1
    durch Wiederverwendung der bestehenden P0a-Registry). person_id IMMER aus `fn_resolve_sender(chat_id)` (NIE LLM);
    `fn_onboarding_status`/`_overview` rechnen das Paket-Bein KATALOG-basiert (fehlende Zeile = `unknown` → kein
    vacuous-true, bleiben STABLE/kein Write); Materialisierung nur im Schreibpfad (`fn_set_onboarding_section` →
    `fn_ensure_onboarding_person`, INVOKER wie set). Arity-Wechsel `(text)→(text,text)` / `()→(text)` via `core:V016`-
    DROP + Grant-Re-Pinning an ALLEN Sites (`util_create_core_ro` core_ro + `fn_provision_package_roles` `<pkg>_rw/_ro`).
  - **Gate flag-gated, Default AN** (Owner-Entscheid): career-eigener Config-Key `feature/career_onboarding_gate`
    (Default `true` = verpflichtend out-of-the-box, per Konsole abschaltbar) — **nicht** finance's `feature/onboarding_gate`
    (UNIQUE(category,key) verbietet Key-Teilen; jedes Paket deklariert seinen Gate-Key im eigenen Manifest — finance seit Phase C). Career-lokales Gate NACH
    `Load Config`, liest `fn_onboarding_status('career', chat_id)` unter Haupt-Cred (offen → Prompt-Abschnitt statt Redirect, s. §3.2); fail-open bei
    DB-Lesefehler (Parität Core-Gate). **BACKLOG-Trigger (Rule of Three):** ein künftiges MIXED-Paket (per_user-Kontexte
    UND household-Onboarding-Wunsch) → dann expliziter `provides.onboarding.scope`-Flag (die EXISTS-any-Ableitung
    mis-derivt sonst). Cron-Fächerung/per-Person-Sends/Isolation-E2E = P2b-2.
