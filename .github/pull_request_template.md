<!--
  Keep the section headings. Delete the HTML comments and any block that genuinely does not
  apply (write "n/a — <reason>" instead of leaving it blank). This repo treats workflows and the
  database as the primary documentation, so evidence beats prose: show the change behaving in a
  real n8n run, not just that a test passed.
-->

## Summary

<!-- What changed and why, in one or two sentences. Plain language first; jargon only in parentheses. -->

## Linked context

<!-- Issues, BACKLOG.md items, plan files, or prior PRs this builds on. Use "Closes #N" to auto-close. -->

## Real behavior proof

<!--
  REQUIRED. Show the change working against a real n8n / PostgreSQL setup — tests and mocks are
  supplemental, not a substitute. Pick whatever fits the change:
    - a redacted Telegram transcript (agent reply / HITL confirmation),
    - `db_query.ps1` output of the affected row(s),
    - an n8n execution URL or `n8n_executions.ps1 -Id <id> -Dump` excerpt.

  REDACTION (hard rule): never paste the owner's real Telegram chat id. Replace it with
  `__OWNER_CHAT_ID__` exactly as the pull pipeline does, and strip any secret/token/API key.
  No PII or secrets in this PR — same bar as the tracked tree.
-->

## Tests and validation

<!--
  Which gates ran and their result. Note the blast radius (db / behavior / schema-fidelity / none)
  per CLAUDE.md → Testing.
    - [ ] `prek run --all-files` green (commit-stage hooks)
    - [ ] `db_test.ps1` green (touched `fn_*` / schema / trigger / view / CHECK)
    - [ ] LLM suites run + result (routing/prompt/model/tool-description change) — owner-run only
    - [ ] n/a — no testable surface (docs / stickies / encoding)
-->

## Risk checklist

- [ ] Touches secrets, credentials, or auth/multi-user paths
- [ ] Changes network/ingress (reverse proxy, webhook routes, Telegram, Proxmox)
- [ ] DB migration or schema/trigger/CHECK change (irreversible or data-affecting)
- [ ] Changes a `fn_*`, write tool, or HITL gate
- [ ] None of the above

## Current review state

<!--
  Where this PR stands so a reviewer knows what to do:
    - [ ] Ready for review
    - [ ] Draft / WIP — feedback wanted on a specific question (state it)
    - [ ] Step-8 `/code-review` done on this diff, findings folded in
-->
