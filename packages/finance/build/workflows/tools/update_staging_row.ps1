#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_update_staging_row -------------------------------
# BULK-IMPORT Schritt 2/3: Korrektur EINER Staging-Row VOR dem Gate ("Zeile 7: Saldo 5.230").
# KEIN HITL (Staging ist keine Domaenen-Daten) — genau dieses Muster loest die
# Buttons-only-HITL-Limitation fuer den Import-Fall (Plan §3).
function Build-UpdateStagingRow {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @((Get-ImportToolSpec 'tool_update_staging_row') | ForEach-Object { $_[0] })   # Feldliste aus ../import_tool_specs.ps1 (EINE Quelle, Review A5)

    $update = Build-Pg 'Update row + revalidate' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'row_no')::int AS row_no, r->>'status' AS status, r->>'validation_error' AS validation_error, (r->>'deleted_row')::int AS deleted_row, (r->>'valid')::int AS valid, (r->>'invalid')::int AS invalid FROM finance.fn_import_update_row(`$1::jsonb) AS r;" `
        ([ordered]@{
            batch_id      = '$(''Start'').item.json.batch_id'
            row_no        = '$(''Start'').item.json.row_no'
            payload_merge = (Get-GuardedJsonExpr '$(''Start'').item.json.payload_merge ? JSON.parse($(''Start'').item.json.payload_merge) : null')   # ungueltig -> Sentinel -> fn {ok:false}
            delete_row    = '$(''Start'').item.json.delete_row === true || $(''Start'').item.json.delete_row === ''true'''
        })

    $ifOk = Build-If 'Update ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $err = Build-ToolError 'Update failed' @(660, 200) `
        "={{ `$('Update row + revalidate').item.json.reason }}"

    $ret = Build-Return @(660, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('row_no', "={{ `$json.row_no }}", 'number')
        ,@('status', "={{ `$json.status }}", 'string')
        ,@('validation_error', "={{ `$json.validation_error }}", 'string')
        ,@('deleted_row', "={{ `$json.deleted_row }}", 'number')
        ,@('valid',   "={{ `$json.valid }}", 'number')
        ,@('invalid', "={{ `$json.invalid }}", 'number')
    )

    $sticky = Build-Sticky 'Korrektur VOR dem Gate' @(220, -240) `
        'fn_import_update_row: Key-Merge/Delete + Batch-Revalidate' `
        'payload_merge merged Keys in den Row-Payload (JSON-null entfernt einen Key), delete_row entfernt die Row; danach läuft fn_import_validate über den GANZEN Batch (Referenzen können sich ändern). Kein Gate: Staging ist Arbeitskopie — der Nutzer korrigiert im Chat, approved wird erst der Commit (tool_commit_import).' 240 420

    $nodes = @($trig, $update, $ifOk, $err, $ret, $sticky)

    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Update row + revalidate' ) ) }
        'Update row + revalidate' = @{ main = @( ,@( E 'Update ok?' ) ) }
        'Update ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update failed' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_update_staging_row' $nodes $conns `
        @{ Category = 'import' }
}
