# config/

Checked-in configuration for the linters wired into the enforcement gates. One file per tool
(shellcheck, PSScriptAnalyzer, markdownlint, sqlfluff, gitleaks, …).

The **authoritative list** of which tools are active, on which paths, and at which stage is
[.pre-commit-config.yaml](../.pre-commit-config.yaml) (→ CI) — not duplicated here, to avoid drift.
Each file in this directory documents its own rule choices and any suppressions (with reasons) in a
header comment; open the one you need.
