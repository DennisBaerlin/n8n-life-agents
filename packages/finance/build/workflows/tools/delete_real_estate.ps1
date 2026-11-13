#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_delete_real_estate (Immobilie loeschen: Hard-DELETE einer Fehlanlage) ---
function Build-DeleteRealEstate {
    # Enge Paket-Schreibrolle (finance_rw) statt Owner-Cred; Build-Pg liest $CRED_POSTGRES per Dynamic-Scope.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('real_estate_name')

    $readRe = Build-Pg 'Read Property' @(220, 0) `
        "=SELECT re.current_value, rep.full_name AS owner, re.status::text AS re_status, (SELECT COUNT(*)::int FROM finance.loans l WHERE l.real_estate_id = re.id) AS loan_count FROM finance.real_estate re LEFT JOIN core.fn_household_persons() rep ON rep.person_id = re.owner_person_id WHERE re.name ILIKE ((`$1::jsonb)->>'real_estate_name') LIMIT 1;" `
        ([ordered]@{ real_estate_name = '$(''Start'').item.json.real_estate_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate).
    $found = New-RequiredRowGate -Read $readRe -KeyField 're_status' -IfName 'Property found?' -ErrName 'Property not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No property named '{{ `$('Start').item.json.real_estate_name }}' exists. List them via postgres_select on finance.real_estate_overview and ask the user which one is meant."

    # Wert in EUR-Konvention; Haushalts-Eigentuemer-Fallback kommt aus dem Katalog (SQL liefert NULL).
    $wg = New-FnWriteGate -Fn 'finance.fn_delete_real_estate' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Delete property (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'real_estate_id')::int AS real_estate_id" `
        -Params ([ordered]@{ real_estate_name = '$(''Start'').item.json.real_estate_name' })

    $S = "`$('Start').item.json"
    $R = "`$('Read Property').item.json"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.delete_real_estate' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.real_estate'  "$S.real_estate_name")
        (New-HitlLine 'finance.label.value'        "($R.current_value || null)" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.owner'        "($R.owner ? 'finance.tpl.plain' : 'finance.value.household')" -Kind tpl -Params @{ value = "$R.owner" })
        (New-HitlLine 'core.label.status'          "$R.re_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.linked_loans' "$R.loan_count")
        (New-HitlNote -KeyExpr "($R.loan_count > 0 ? 'finance.note.delete_re_rejected' : 'finance.note.delete_re_hard')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the delete_real_estate action'

    # Der Write prueft erneut, falls sich seit dem Probelauf etwas geaendert hat.
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Delete rejected' @(2200, 240) `
        "={{ `$('Delete property (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Delete property (atomic)').item.json.action }}", 'string')
        ,@('real_estate_id', "={{ `$('Delete property (atomic)').item.json.real_estate_id }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_delete_real_estate mit denselben Werten, immer zurückgerollt. ok:false (Immobilie hat noch verknüpfte Kredite) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (mehrdeutig; nicht gefunden fängt vorher das Found?-Gate als Tool-Fehler) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_delete_real_estate: Hard-DELETE-if-empty' @(1760, -260) `
        'Löschen nur ohne verknüpfte Kredite' `
        'fn zählt verknüpfte Kredite (finance.loans.real_estate_id). loan_count>0: {ok:false, reason, loan_count} OHNE Write -> Delete rejected (weiche Rückfrage, erst Kredite ablösen). loan_count=0: DELETE finance.real_estate; action=deleted. RAISE bei nicht gefunden/mehrdeutig (nicht gefunden fängt vorher das Found?-Gate des Tools). Kein Soft-Close (Status sold braucht eine Verkaufsbuchung -> vertagt: sell_real_estate).' 240 500

    $nodes = @($trig, $readRe, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Property' ) ) }
        'Read Property'          = @{ main = @( ,@( E 'Property found?' ) ) }
        'Property found?'        = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Property not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Delete property (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Delete property (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Delete rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_delete_real_estate' $nodes $conns `
        @{ Category = 'real_estate' }
}
