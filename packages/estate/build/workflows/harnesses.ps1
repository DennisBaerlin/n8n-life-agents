#Requires -Version 5.1
# Estate-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
$script:Harnesses += @(
    [ordered]@{ name='agent.estate_advisor.test_harness'; targetName='agent.estate_advisor'; path='estate-test'; inputMap=$null }
)
