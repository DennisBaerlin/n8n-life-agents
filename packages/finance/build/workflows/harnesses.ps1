#Requires -Version 5.1
# Finance-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
$script:Harnesses += @(
    [ordered]@{ name='agent.finance.test_harness';         targetName='agent.finance';          path='finance-test'; inputMap=$null }
    [ordered]@{ name='agent.finance_advisor.test_harness'; targetName='agent.finance_advisor';  path='advisor-test'; inputMap=$null }
)
