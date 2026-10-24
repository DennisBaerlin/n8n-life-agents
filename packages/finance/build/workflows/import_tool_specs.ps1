#Requires -Version 5.1
# Shared InputSpecs der 4 Bulk-Import-Tools des finance-Pakets (Review A5, Hardening-Phase Session 1;
# Phase D: aus der Engine scripts/build/lib/ ins besitzende Paket gezogen). Helper-Datei ohne Build-*
# (die Builder-Discovery liefert hier 0 Builder); gelesen nur in Funktionskoerpern -> Ladereihenfolge egal.
#
# Die FELDNAMEN-Listen sind eine harte Kopplung an den Start-Trigger des jeweiligen Tool-Sub-Workflows:
# ein neues Feld muss im Tool (Build-Trigger) UND im Binder (agent.finance, New-ToolWorkflowNode)
# ankommen, sonst kommt es als undefined an (Build-Gotcha "Input an ZWEI Stellen"; contract_lint
# prueft das zusaetzlich statisch). Darum leben die Specs HIER genau einmal; Tool + Binder lesen sie
# ueber Get-ImportToolSpec (unbekannter Key -> throw statt still leerer Liste).
#
# Format je Eintrag: @(name, fromAI-description, type[, default]) -- 4. Element = optional.

$script:IMPORT_TOOL_SPECS = @{
    tool_import_stage_rows  = @(
        ,@('rows', 'JSON array string of rows, each {entity_type, ...raw fields with NAMES not ids}', 'string')
        ,@('batch_id', 'Existing batch UUID to extend. Empty = start a new batch.', 'string', '')
        ,@('source', 'Where the data came from: chat (default), vision or csv', 'string', '')
    )
    tool_update_staging_row = @(
        ,@('batch_id', 'Batch UUID from tool_import_stage_rows', 'string')
        ,@('row_no', 'Internal row number to correct (from the staged list; never shown to the user, who names the row by its name)', 'string')
        ,@('payload_merge', 'JSON object string of keys to merge, e.g. {"opening_balance": 5230}. JSON null removes a key.', 'string', '')
        ,@('delete_row', 'true to remove the row entirely', 'string', '')
    )
    tool_commit_import      = @(
        ,@('batch_id', 'Batch UUID to commit', 'string')
    )
    tool_extract_finance_document = @(
        ,@('file_id', 'Telegram file_id from the [attachment ...] marker in the task', 'string')
        ,@('doc_hint', 'Short user context about the document (type, bank, which depot/pension it belongs to)', 'string', '')
        ,@('batch_id', 'Existing batch UUID to add the rows to. Empty = new batch.', 'string', '')
    )
}

function Get-ImportToolSpec([string]$Key) {
    $spec = $script:IMPORT_TOOL_SPECS[$Key]
    if ($null -eq $spec) { throw "Get-ImportToolSpec: unbekannter Key '$Key' (packages/finance/build/workflows/import_tool_specs.ps1)." }
    return , $spec
}
