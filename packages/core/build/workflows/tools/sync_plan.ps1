#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_sync_plan (CROSS-AGENT, HITL-Write) --------------------------
function Build-SyncPlan {
    $trig = Build-Trigger @('domain', 'reminders', 'declined', 'retire', 'watch_candidates')

    $wg = New-FnWriteGate -Fn 'core.fn_plan_sync' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Sync plan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'code' AS code, (r->>'plan_id')::int AS plan_id, r->>'synced_at' AS synced_at, r->'created' AS created, r->'moved' AS moved, r->'retired' AS retired, r->'skipped' AS skipped, (r->>'changes')::int AS changes" `
        -Params ([ordered]@{
            domain           = '$(''Start'').item.json.domain'
            reminders        = '$(''Start'').item.json.reminders'
            declined         = '$(''Start'').item.json.declined'
            retire           = '$(''Start'').item.json.retire'
            watch_candidates = '$(''Start'').item.json.watch_candidates'
            chat_id          = '$(''Start'').item.json.chat_id'
        })

    $ifChanges = Build-If 'Anything to confirm?' @(660, -100) "={{ `$('Dry run').item.json.r.changes }}" '0' 'larger' 'number'

    $summary = New-HitlSummary -Pos @(880, -200) -Title 'core.hitl.sync_plan' -LinesExpr $wg.CardLinesExpr `
        -RepeatKey "String(`$('Start').item.json.domain || '')" -Lines @()

    $reqApproval = Build-CallWorkflow 'Request Approval' @(1100, -200) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1320, -200) '={{ $json.approved }}' 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1540, -360) 'the sync_plan action'
    $ifOk = Build-If 'Write ok?' @(1540, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Sync rejected' @(1760, 200) "={{ `$('Sync plan (atomic)').item.json.reason }}"

    $W = "`$('Sync plan (atomic)').item.json"
    $ret = Build-Return @(1760, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('plan_id', "={{ $W.plan_id }}", 'number')
        ,@('synced_at', "={{ $W.synced_at }}", 'string')
        ,@('created', "={{ $W.created }}", 'array')
        ,@('moved', "={{ $W.moved }}", 'array')
        ,@('retired', "={{ $W.retired }}", 'array')
        ,@('skipped', "={{ $W.skipped }}", 'array')
        ,@('changes', "={{ $W.changes }}", 'number')
    )

    $sticky = Build-Sticky 'Doc Sync Plan' @(120, -560) `
        'Plan-Durchlauf auf dem veröffentlichten Plan (core.fn_plan_sync)' `
        'Gleicht die Erinnerungen des aktiven Plans mit dem Bestand ab, ohne neue Version. Dieselbe fn läuft im Publish in derselben Transaktion. Dry run prüft vor der Karte und liefert changes (Neu + Verschoben + Weg + neu Abgelehnt). changes = 0: Anything to confirm? geht ohne Karte direkt zum Write, der nur den Stempel synced_at und watch_candidates speichert; kein Nutzer-Datenbestand ändert sich, darum kein Gate. Sonst eine Karte aus den card_lines der fn. effective.reminders_checked_on geht in den Write: Ein Tipp nach Mitternacht lehnt ein Datum von heute nicht ab. Wiederhol-Sperre je Domain. ok:false als Daten.' 340 300

    $nodes = @($trig) + $wg.Nodes + @($ifChanges, $summary, $reqApproval, $ifApproved, $retCancelled, $ifOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @( @( E 'Anything to confirm?' ), @( E 'Dry run rejected' ) ) }
        'Anything to confirm?'   = @{ main = @( @( E 'Build Approval Summary' ), @( E 'Sync plan (atomic)' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @( @( E 'Sync plan (atomic)' ), @( E 'Return cancelled' ) ) }
        'Sync plan (atomic)'     = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @( @( E 'Return' ), @( E 'Sync rejected' ) ) }
    }
    return Build-Workflow 'agent.tool_sync_plan' $nodes $conns @{ Internal = $true }
}
