#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_import_stage_rows --------------------------------
# BULK-IMPORT Schritt 1/3 (Phase 2 Onboarding-Plan): viele Entitaeten auf einmal stagen.
# KEIN HITL — Staging ist keine Domaenen-Daten (propose-Store); jede Row wird sofort
# validiert (Pflichtfelder, Enums, Dubletten-Backstop, Referenzen inkl. In-Batch-Konten).
# Der echte Write passiert erst in tool_commit_import (EIN Gate fuer den ganzen Batch).
function Build-ImportStageRows {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @((Get-ImportToolSpec 'tool_import_stage_rows') | ForEach-Object { $_[0] })   # Feldliste aus ../import_tool_specs.ps1 (EINE Quelle, Review A5)

    # rows kommt als JSON-String vom Agenten -> geschuetztes JSON.parse (ungueltig -> Sentinel -> die fn lehnt mit
    # {ok:false} ab, kein Execution-Abbruch); batch_id leer = neuer Batch.
    $stage = Build-Pg 'Stage + validate' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'batch_id' AS batch_id, (r->>'staged')::int AS staged, (r->>'total')::int AS total, (r->>'valid')::int AS valid, (r->>'invalid')::int AS invalid, r->'errors' AS errors FROM finance.fn_import_stage(`$1::jsonb) AS r;" `
        ([ordered]@{
            rows     = (Get-GuardedJsonExpr 'JSON.parse($(''Start'').item.json.rows)')
            batch_id = '$(''Start'').item.json.batch_id || null'
            source   = '$(''Start'').item.json.source || null'
        })

    $ifOk = Build-If 'Stage ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $err = Build-ToolError 'Stage failed' @(660, 200) `
        "={{ `$('Stage + validate').item.json.reason }}"

    $ret = Build-Return @(660, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('batch_id', "={{ `$json.batch_id }}", 'string')
        ,@('staged',   "={{ `$json.staged }}", 'number')
        ,@('total',    "={{ `$json.total }}", 'number')
        ,@('valid',    "={{ `$json.valid }}", 'number')
        ,@('invalid',  "={{ `$json.invalid }}", 'number')
        ,@('errors',   "={{ `$json.errors }}", 'array')
    )

    $sticky = Build-Sticky 'Staging = propose-Store, kein Write' @(220, -260) `
        'fn_import_stage: Insert + sofortige Validierung' `
        'Rows landen ROH (Namen statt IDs) in finance.import_staging; fn_import_validate prüft je Row Pflichtfelder/Enums/Datums-Casts, Dubletten-Backstop (fn_resolve_* + In-Batch) und Konto-Referenzen (Bestand ODER account-Row im selben Batch). KEIN Domänen-Write, KEIN Gate — Korrekturen laufen VOR dem Gate per tool_update_staging_row; der atomare Commit ist tool_commit_import. Nicht-committete Batches verfallen nach 7 Tagen.' 240 480

    $nodes = @($trig, $stage, $ifOk, $err, $ret, $sticky)

    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Stage + validate' ) ) }
        'Stage + validate' = @{ main = @( ,@( E 'Stage ok?' ) ) }
        'Stage ok?'        = @{ main = @(
            @( E 'Return' ),
            @( E 'Stage failed' )
        ) }
    }

    # Kein /help-Beispiel fuer Import (Review L5): der einzige Import-Case ist eine lange, verschachtelte
    # Bulk-Utterance mit Dedup-Suffix ("…Neu") — als nachahmbares /help-Beispiel ungeeignet. Die
    # Kategorie-Beschreibung (finance.help.import.description) traegt die Bedeutung; der Vision-Foto-Pfad ist der
    # primaere Import-Weg. Saubere kurze Import-Goldens -> BACKLOG.
    return Build-Workflow 'agent.finance.tool_import_stage_rows' $nodes $conns `
        @{ Category = 'import' }
}
