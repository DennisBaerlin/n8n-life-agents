#Requires -Version 5.1
# Paperless-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
# Die drei Werkzeug-Harnesses rufen die Paket-Werkzeuge DIREKT (infra_cases: Eingabe-Pruefung, Fehler-Mapping gegen den
# Mock-Paperless) — die Berechtigungs-Pruefstelle testet der Vermittler-Harness agent.sub_dispatch_tool.test_harness.
$script:Harnesses += @(
    [ordered]@{ name='agent.paperless_assistant.test_harness';             targetName='agent.paperless_assistant';             path='paperless-test';         inputMap=$null }
    [ordered]@{ name='agent.paperless.tool_search_documents.test_harness'; targetName='agent.paperless.tool_search_documents'; path='paperless-search-test';  inputMap=[ordered]@{ args='body.args'; chat_id='body.chat_id' } }
    [ordered]@{ name='agent.paperless.tool_get_document.test_harness';     targetName='agent.paperless.tool_get_document';     path='paperless-get-test';     inputMap=[ordered]@{ args='body.args'; chat_id='body.chat_id' } }
    [ordered]@{ name='agent.paperless.tool_ask_documents.test_harness';    targetName='agent.paperless.tool_ask_documents';    path='paperless-ask-test';     inputMap=[ordered]@{ args='body.args'; chat_id='body.chat_id' } }
)
