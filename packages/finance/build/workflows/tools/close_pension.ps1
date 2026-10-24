#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_close_pension (Altersvorsorge beenden: Smart-Close wie close_savings_plan) ---
function Build-ClosePension {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('pension_name')

    $readPen = Build-Pg 'Read Pension' @(220, 0) `
        "=SELECT p.pension_type::text AS pension_type, p.provider, p.status::text AS pen_status, (SELECT COUNT(*)::int FROM finance.transactions t WHERE t.recurring_payment_id = p.recurring_payment_id) AS tx_count FROM finance.pension p WHERE p.name ILIKE ((`$1::jsonb)->>'pension_name') LIMIT 1;" `
        ([ordered]@{ pension_name = '$(''Start'').item.json.pension_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readPen -KeyField 'tx_count' -IfName 'Pension found?' -ErrName 'Pension not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No pension named '{{ `$('Start').item.json.pension_name }}' exists. List the pensions via postgres_select on finance.pension and ask the user which one to close."

    # "DB ist das Gesetz": fn_close_pension laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_close_pension' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Close pension (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'tx_count')::int AS tx_count" `
        -Params ([ordered]@{ pension_name = '$(''Start'').item.json.pension_name' })

    # Strukturiertes Summary (Textkatalog): Titel + Hinweis haengen an tx_count (Soft-Close vs. Hard-DELETE).
    $S = "`$('Start').item.json"
    $P = "`$('Read Pension').item.json"
    $titleVal = New-HitlValue -Kind key -Value "($P.tx_count > 0 ? 'finance.hitl.close_pension_close' : 'finance.hitl.close_pension_delete')"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.close_pension' -LinesExpr $wg.CardLinesExpr -TitleParams @{ title = $titleVal } -Lines @(
        (New-HitlLine 'finance.label.provision'           "$S.pension_name")
        (New-HitlLine 'core.label.type'                   "$P.pension_type" -Kind enum -Enum 'finance.enum.pension_type')
        (New-HitlLine 'finance.label.provider'            "$P.provider")
        (New-HitlLine 'core.label.status'                 "$P.pen_status" -Kind enum -Enum 'finance.enum.status')
        (New-HitlLine 'finance.label.booked_contributions' "$P.tx_count")
        (New-HitlNote -KeyExpr "($P.tx_count > 0 ? 'finance.note.close_pension_soft' : 'finance.note.close_pension_hard')")
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
        'Smart-Close-Guard: tx_count entscheidet' `
        'fn zählt Transaktionen (recurring_payment_id = pension.rp_id; rp optional). tx_count=0: Hard-DELETE finance.pension dann ggf. finance.recurring_payments (FK-Reihenfolge!); action=deleted. tx_count>0: Soft-Close — pension.status=paused; RP.status=paused + valid_to=heute; action=closed. RAISE bei nicht gefunden/mehrdeutig.' 240 480

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_close_pension mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (korrigierbare Ablehnungen der fn; Altersvorsorge nicht gefunden -> schon vorher Pension not found als Tool-Fehler, mehrdeutig kommt als Exception) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

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
