#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_cancel_case (WS-3, Break-Glass owner_info; NEUES Verb cancel Floor 0) --------
# Bricht einen OFFENEN Ereignisfall ab (status -> cancelled; die case_tasks bleiben als Verlauf).
# Danach ist die partial-UNIQUE(subject) WHERE open frei -> Fall-Korrektur = cancel + create. HITL
# owner_info (Break-Glass wie create_case). adults_only-DB-Backstop in der fn. Cred = estate_rw.
function Build-EstateCancelCase {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('case_id')

    $readCase = Build-Pg 'Read case' @(220, 0) `
        "=SELECT c.case_type, c.event_date, c.status, COALESCE(hp.full_name, 'Haushalt') AS subject FROM estate.cases c LEFT JOIN LATERAL (SELECT full_name FROM core.fn_household_persons() WHERE person_id = c.subject_person_id) hp ON true WHERE c.id = (`$1::jsonb->>'case_id')::bigint;" `
        ([ordered]@{ case_id = '$(''Start'').item.json.case_id' })
    $ifOpen = Build-If 'Case open?' @(440, 0) "={{ `$('Read case').item.json.status }}" 'open' 'equals' 'string'
    $errNotOpen = Build-ToolError 'Case not open' @(660, 200) `
        "=Case {{ `$('Start').item.json.case_id }} is not an open case (it may not exist, or is already closed/cancelled). Nothing to cancel."

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $S = "`$('Start').item.json"
    $R = "`$('Read case').item.json"
    # "DB ist das Gesetz": estate.fn_cancel_case laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_cancel_case' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Cancel case (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'case_id')::bigint AS case_id" `
        -Params ([ordered]@{ chat_id = '$(''Start'').item.json.chat_id'; case_id = '$(''Start'').item.json.case_id' })
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'estate.hitl.cancel_case' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.case_no'         "$S.case_id")
        (New-HitlLine 'estate.label.case_type'       "$R.case_type" -Kind enum -Enum 'estate.enum.case_type')
        (New-HitlLine 'estate.label.affected_person' "$R.subject")
        (New-HitlLine 'estate.label.event_date'      "$R.event_date" -Kind date)
        (New-HitlNote -Key 'estate.note.cancel_case_history')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the cancel_case action (the case stays open)'
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Cancel rejected' @(2420, 200) "={{ `$('Cancel case (atomic)').item.json.reason }}"
    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('case_id', "={{ `$('Cancel case (atomic)').item.json.case_id }}", 'number')
        ,@('status','cancelled','string')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -280) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_cancel_case mit denselben Werten, immer zurückgerollt. ok:false (z. B. Fall nicht offen, nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'Break-Glass owner_info (Verb cancel Floor 0)' @(1320, -280) `
        'estate.fn_cancel_case (offener Fall -> cancelled, Verlauf bleibt)' `
        'Read case zeigt Typ/Person/Datum für die Bestätigung; "Case open?" blockt vor dem Gate, wenn der Fall nicht (mehr) offen ist. Nach Approve setzt estate.fn_cancel_case status=cancelled + closed_at (die case_tasks bleiben als Audit). Verb cancel = NEUES Floor-0-Verb (owner_info-fähig, Break-Glass; ein erwachsenes Mitglied kann allein abbrechen, Owner-Info=Audit). adults_only-DB-Backstop.' 300 640
    $nodes = @($trig, $readCase, $ifOpen, $errNotOpen) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read case' ) ) }
        'Read case'              = @{ main = @( ,@( E 'Case open?' ) ) }
        'Case open?'             = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Case not open' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Cancel case (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Cancel case (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Cancel rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_cancel_case' $nodes $conns `
        @{ Category = 'register' }
}
