#Requires -Version 5.1
# Finance-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
$script:Harnesses += @(
    [ordered]@{ name='agent.finance.test_harness';         targetName='agent.finance';          path='finance-test'; inputMap=$null }
    [ordered]@{ name='agent.finance_advisor.test_harness'; targetName='agent.finance_advisor';  path='advisor-test'; inputMap=$null }
    # Mehrfach-Leser der Vision-Tools ohne Agent davor (infra_cases): Ueberlappung, Gruppen, Fehler je Datei.
    [ordered]@{ name='agent.finance.tool_extract_finance_document.test_harness'; targetName='agent.finance.tool_extract_finance_document'; path='extract-doc-test'; inputMap=[ordered]@{ file_id='body.file_id'; more_file_ids='body.more_file_ids'; doc_hint='body.doc_hint'; chat_id='body.chat_id' } }
    [ordered]@{ name='agent.finance.tool_reconcile_bank_statement.test_harness'; targetName='agent.finance.tool_reconcile_bank_statement'; path='reconcile-doc-test'; inputMap=[ordered]@{ file_id='body.file_id'; more_file_ids='body.more_file_ids'; doc_hint='body.doc_hint'; chat_id='body.chat_id' } }
)
