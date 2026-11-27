#Requires -Version 5.1
# Finance-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
$script:Harnesses += @(
    [ordered]@{ name='agent.finance.test_harness';         targetName='agent.finance';          path='finance-test'; inputMap=$null }
    [ordered]@{ name='agent.finance_advisor.test_harness'; targetName='agent.finance_advisor';  path='advisor-test'; inputMap=$null }
    # Mehrfach-Leser der Vision-Tools ohne Agent davor (infra_cases): Ueberlappung, Gruppen, Fehler je Datei.
    [ordered]@{ name='agent.finance.tool_extract_finance_document.test_harness'; targetName='agent.finance.tool_extract_finance_document'; path='extract-doc-test'; inputMap=[ordered]@{ file_id='body.file_id'; more_file_ids='body.more_file_ids'; doc_hint='body.doc_hint'; chat_id='body.chat_id' } }
    # Abbruch einer Eintrags-Karte ohne Agent davor (hitl_gate_test hitlT7): Text ans Modell und Freigabe des Eintrags.
    [ordered]@{ name='agent.finance.tool_cancel_handoff_task.test_harness'; targetName='agent.finance.tool_cancel_handoff_task'; path='cancel-handoff-test'; inputMap=[ordered]@{ handoff_task_id='body.handoff_task_id'; reason='body.reason'; ref_type='body.ref_type'; ref_name='body.ref_name'; chat_id='body.chat_id' } }
    [ordered]@{ name='agent.finance.tool_reconcile_bank_statement.test_harness'; targetName='agent.finance.tool_reconcile_bank_statement'; path='reconcile-doc-test'; inputMap=[ordered]@{ file_id='body.file_id'; more_file_ids='body.more_file_ids'; doc_hint='body.doc_hint'; chat_id='body.chat_id' } }
)
