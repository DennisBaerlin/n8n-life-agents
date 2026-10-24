# Security Policy

This is a personal, self-hosted system that handles financial data and credentials. Please treat
any weakness that could expose secrets, PII, or allow unauthorized writes as a security issue.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Report it privately through GitHub's
**private vulnerability reporting** — the "Report a vulnerability" button under the repository's
*Security* tab (Security advisories). It opens a private thread visible only to the maintainer; no
email address is needed. Include a description, the affected path/component, and a deterministic
reproduction if you have one.

Please allow a reasonable window for a fix before any public disclosure. There is no bounty — this is
a personal project — but credit is given on request.

## Scope

The supported version is the current `main` branch. n8n is pinned to **2.44.4** and PostgreSQL to
**17**; issues that only reproduce on other versions are still welcome but may not be actionable.

Highest-value areas: anything touching credentials, the Telegram ingress (reverse proxy / webhook routes),
the HITL approval gate, the PostgreSQL roles and `fn_*` write path, the local LLM gateway, and the
provisioning / multi-user bootstrap.

**Local LLM gateway** (`provisioning/llm_gateway/server.js`, unit `lifeagents-llm-gateway`): every Claude
request from n8n passes through it (127.0.0.1:8090 only) so it can add prompt-caching breakpoints. It forwards
to `api.anthropic.com` unchanged otherwise, adds no key of its own (the caller's `x-api-key` is passed
through), stores nothing on disk (`DynamicUser`), and logs only token counts plus fixed error codes — never
headers, keys, prompt or response content. A log line containing prompt text or a key is a security bug.
For the cache keep-alive it holds, **in memory only**, the shared prefix of recent agent requests (tool
definitions + system prompt, never the conversation) together with the caller's auth headers, for up to
`LLM_GATEWAY_KEEPALIVE_HOURS` (default 24, `0` = off) after the last real use, and re-sends that prefix to
`api.anthropic.com` with `max_tokens: 0` every 55 minutes.

## What keeps secrets out

These are the mechanisms already in place — understanding them helps when reporting:

- **No secrets in the repo.** Tokens / OAuth / API keys live in the n8n credential store; local
  author/test secrets (`TEST_*`) live in `.env` (gitignored). Install and update need no GitHub token (anonymous
  download from the public repo, SHA256-verified). The backup encryption key lives in `core.backup_key`
  (database), set out-of-band — never through the chat or the repo. Installer secrets on the instance
  live in `/etc/lifeagents/<pkg>.env` (`core.env` = host; one file per package, removed on `--purge`).
- **PII redaction.** The pull pipeline rewrites the owner's Telegram chat id to `__OWNER_CHAT_ID__`
  before anything is tracked; the personal-data contexts mirror stays local (`.local/`). The tracked
  tree contains no PII.
- **`detect-private-key`** runs as a commit-stage hook (see
  [.pre-commit-config.yaml](.pre-commit-config.yaml)) and blocks committed private keys.
- **`gitleaks`** is the broader secret scanner (hundreds of token/credential patterns) — a second
  net beside `detect-private-key`. It runs locally on every commit (staged diff) and in CI over the
  **full git history** (the [`gitleaks` CI job](.github/workflows/ci.yml)). Verified non-secrets
  (the redaction placeholder, synthetic test-crypto keys) are allowlisted with reasons in
  [config/.gitleaks.toml](config/.gitleaks.toml).
- **`zizmor` + `actionlint`** audit our own GitHub Actions for supply-chain and misconfiguration
  issues; third-party actions are SHA-pinned, and [Dependabot](.github/dependabot.yml) keeps those
  pins current (with a cooldown so a freshly published/compromised version is not proposed on day
  zero).

If you find a path where any of the above can be bypassed, that is exactly the kind of report we
want.
