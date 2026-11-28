#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_close_pension (Altersvorsorge beenden: Smart-Close wie close_savings_plan) ---
function Build-ClosePension {
    # Enge Paket-Schreibrolle (finance_rw) statt Owner-Cred; Build-Pg liest $CRED_POSTGRES per Dynamic-Scope.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('pension_name')

    $readPen = Build-Pg 'Read Pension' @(220, 0) `
        "=SELECT CASE WHEN r.hit_count > 0 THEN r.hit_count END AS hits, p.pension_type::text AS pension_type, p.provider, p.status::text AS pen_status, (SELECT COUNT(*)::int FROM finance.pension_statements s WHERE s.pension_id = p.id) AS statement_count FROM finance.fn_resolve_pension((`$1::jsonb)->>'pension_name', FALSE) r LEFT JOIN finance.pension p ON p.id = r.id;" `
        ([ordered]@{ pension_name = '$(''Start'').item.json.pension_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate).
    $found = New-RequiredRowGate -Read $readPen -KeyField 'hits' -IfName 'Pension found?' -ErrName 'Pension not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No pension named '{{ `$('Start').item.json.pension_name }}' exists. List the pensions via postgres_select on finance.pension and ask the user which one to close."

    $wg = New-FnWriteGate -Fn 'finance.fn_close_pension' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Close pension (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'tx_count')::int AS tx_count" `
        -Params ([ordered]@{ pension_name = '$(''Start'').item.json.pension_name' })

    # Titel, Hinweis und Buchungszahl aus dem Probelauf (fn_close_pension zaehlt ueber die ganze Beitrags-Kette): action closed =
    # Soft-Close, deleted = Hard-DELETE. Ein eigener Zaehler im Workflow saehe nach einer Beitragsaenderung nur das juengste Glied.
    $S = "`$('Start').item.json"
    $P = "`$('Read Pension').item.json"
    $D = "`$('Dry run').item.json.r"
    $titleVal = New-HitlValue -Kind key -Value "($D.action === 'closed' ? 'finance.hitl.close_pension_close' : 'finance.hitl.close_pension_delete')"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.close_pension' -LinesExpr $wg.CardLinesExpr -TitleParams @{ title = $titleVal } -Lines @(
        (New-HitlLine 'finance.label.provision'           "$S.pension_name")
        (New-HitlLine 'core.label.type'                   "$P.pension_type" -Kind enum -Enum 'finance.enum.pension_type')
        (New-HitlLine 'finance.label.provider'            "$P.provider")
        (New-HitlLine 'core.label.status'                 "$P.pen_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.booked_contributions' "$D.tx_count")
        (New-HitlLine 'finance.label.pension_statements' "$P.statement_count" -If "$P.statement_count > 0")
        (New-HitlNote -KeyExpr "($D.action === 'closed' ? 'finance.note.close_pension_soft' : 'finance.note.close_pension_hard')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the close_pension action'


    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Close rejected' @(2200, 240) `
        "={{ `$('Close pension (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Close pension (atomic)').item.json.action }}", 'string')
        ,@('tx_count', "={{ `$('Close pension (atomic)').item.json.tx_count }}", 'number')
    )

    $stickyFn = Build-Sticky 'fn_close_pension: Hard-DELETE vs. Soft-Close' @(1760, -260) `
        'Smart-Close-Guard: Historie entscheidet' `
        'fn zählt Transaktionen an jedem Glied der Beitrags-Kette (fn_recurring_lineage; rp optional) und Standmitteilungen; die Karte liest action und tx_count aus dem Probelauf. Keine Historie: Hard-DELETE finance.pension dann ggf. finance.recurring_payments (FK-Reihenfolge!); action=deleted. Historie vorhanden: Soft-Close — pension.status=paused; RP.status=paused + valid_to=heute; action=closed. Nicht gefunden/mehrdeutig: {ok:false, code}.' 240 480

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_close_pension mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (korrigierbare Ablehnungen der fn; Altersvorsorge nicht gefunden -> schon vorher Pension not found als Tool-Fehler über denselben Auflöser, mehrdeutig mit Kandidaten) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $readPen, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyFn,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Pension' ) ) }
        'Read Pension'           = @{ main = @( ,@( E 'Pension found?' ) ) }
        'Pension found?'         = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Pension not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Close pension (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Close pension (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_close_pension' $nodes $conns `
        @{ Category = 'pension' }
}
