# PSScriptAnalyzer settings for scripts/**/*.ps1 — used by scripts/ps_lint.ps1 (prek hook `ps-lint`
# + CI). Curated baseline (Phase 3, 2026-06-14): every excluded rule carries a one-line reason.
# Severity is Error+Warning only (Information rules are stylistic noise for our dev-tooling scripts).
# KEPT ON (high value): PSUseBOMForUnicodeEncodedFile — enforces our UTF-8-BOM convention for *.ps1
# (the 3 violators were fixed in the baseline pass), plus all other correctness rules.
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Dev CLI scripts deliberately print colored progress/output to the console; they are
        # interactive tooling, not library/pipeline code that should emit objects. (PSSA docs cite
        # exactly this as the legitimate Write-Host exception.)
        'PSAvoidUsingWriteHost'

        # Both naming rules stay off because they fundamentally conflict with this repo's build
        # convention "the constructor function name mirrors its n8n workflow/tool name" (scripts/build):
        #   PSUseApprovedVerbs — the build system uses Build-<Workflow> for every workflow/tool/cron
        #     constructor. "Build" (and "Deploy") were added to the approved-verb Lifecycle group in
        #     PowerShell 6.0; PSSA only flags them here because the gate host is Windows PowerShell 5.1,
        #     whose Get-Verb predates that addition (verify: `Get-Verb Build` is empty on 5.1, present on 7+).
        #     The genuinely-unapproved "Make-*" node helpers were renamed to Build-* (Phase 5b); the
        #     dev one-offs were renamed to approved verbs. Only Build-* and one Sort-* helper remain.
        #   PSUseSingularNouns — the mirror convention legitimately yields plural nouns where the
        #     workflow/tool name is plural (cron.refresh_fx_rates, reconcile_accounts, set_household_facts,
        #     import_stage_rows, monitor_check_triggers). Singularizing those would diverge the function
        #     from its workflow file. The generic collection helpers (Get-ToolCall, Get-StringValue, ...)
        #     WERE singularized in Phase 5b; only the workflow-mirroring Build-* names stay plural.

        # Same rationale: internal helpers, not user-facing cmdlets with a -WhatIf/-Confirm contract.
        'PSUseApprovedVerbs'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'

        # Excluded repo-wide (acceptable: these are dev/test/build tooling scripts, not production
        # cmdlets with a user-facing error contract). The pattern is best-effort diagnostic/cleanup
        # swallows in test teardown / probe paths (verified in e2e_test.ps1:
        # `try { <optional diagnostic> } catch { }`) — intentional, not hidden errors.
        'PSAvoidUsingEmptyCatchBlock'

        # False positive: the flagged params are named *Cred*/*CredType*/*CredName* and hold n8n
        # credential-REFERENCE metadata (id + name), never a plaintext secret — the rule matches the
        # name substring. Actual secrets live in the n8n credential store, never in these params.
        'PSAvoidUsingPlainTextForPassword'

        # False positive from our build architecture: build.ps1 dot-sources the workflow defs into
        # SCRIPT scope (see scripts/build/CLAUDE.md), so $CRED_* / $AiModels are consumed cross-file
        # and read as "assigned but unused" per-file; likewise ForEach-Object inner-scope assignments.
        'PSUseDeclaredVarsMoreThanAssignments'

        # Known false positives: switch params consumed via preference vars or passed through
        # scriptblocks (e.g. $WriteTools/$Verify are documented, used params the analyzer can't trace).
        'PSReviewUnusedParameter'

        # The sole hit is Get-FileHash -Algorithm MD5 in db_apply.ps1 — a migration content-IDENTITY
        # hash compared against core.schema_version (change detection), NOT security. The stored
        # hashes require the algorithm stay stable, so this is intentional and must not change.
        'PSAvoidUsingBrokenHashAlgorithms'

        # The sole hit is $AllNodes, which is an automatic variable ONLY inside DSC configurations.
        # This repo authors no DSC; the local variable (workflow nodes) is safe.
        'PSAvoidAssignmentToAutomaticVariable'
    )
}
