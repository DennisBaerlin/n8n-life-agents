#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_close_insurance (Versicherung beenden: Smart-Close wie close_savings_plan) ---
function Build-CloseInsurance {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('insurance_name')

    # Details + Buchungsanzahl fuer dynamischen HITL-Summary
    $readIns = Build-Pg 'Read Insurance' @(220, 0) `
        "=SELECT i.insurance_company, ip.full_name AS policyholder, i.annual_premium, i.status::text AS ins_status, (SELECT COUNT(*)::int FROM finance.transactions t WHERE t.recurring_payment_id = i.recurring_payment_id) AS tx_count FROM finance.insurances i LEFT JOIN core.fn_household_persons() ip ON ip.person_id = i.policyholder_person_id WHERE i.name ILIKE ((`$1::jsonb)->>'insurance_name') LIMIT 1;" `
        ([ordered]@{ insurance_name = '$(''Start'').item.json.insurance_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readIns -KeyField 'tx_count' -IfName 'Insurance found?' -ErrName 'Insurance not found' `
        -IfPos @(330, -160) -ErrPos @(440, 240) `
        -NotFoundExpr "=No insurance named '{{ `$('Start').item.json.insurance_name }}' exists. List the insurances via postgres_select on finance.active_insurances and ask the user which one to close."

    # "DB ist das Gesetz": fn_close_insurance laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_close_insurance' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Close insurance (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'action' AS action, (r->>'tx_count')::int AS tx_count" `
        -Params ([ordered]@{ insurance_name = '$(''Start'').item.json.insurance_name' })

    # Strukturiertes Summary (Textkatalog): Titel + Hinweis haengen an tx_count (Soft-Close vs. Hard-DELETE).
    # Jahrespraemie in EUR-Konvention. Haushalts-Police: Fallback-Text kommt aus dem Katalog (SQL liefert NULL).
    $S = "`$('Start').item.json"
    $I = "`$('Read Insurance').item.json"
    $titleVal = New-HitlValue -Kind key -Value "($I.tx_count > 0 ? 'finance.hitl.close_insurance_close' : 'finance.hitl.close_insurance_delete')"
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'finance.hitl.close_insurance' -LinesExpr $wg.CardLinesExpr -TitleParams @{ title = $titleVal } -Lines @(
        (New-HitlLine 'finance.label.insurance'      "$S.insurance_name")
        (New-HitlLine 'finance.label.company'        "$I.insurance_company")
        (New-HitlLine 'finance.label.policyholder'   "($I.policyholder ? 'finance.tpl.plain' : 'finance.value.household')" -Kind tpl -Params @{ value = "$I.policyholder" })
        (New-HitlLine 'finance.label.annual_contribution' "$I.annual_premium" -Kind money -EurByModel)
        (New-HitlLine 'core.label.status'            "$I.ins_status" -Kind enum -Enum 'finance.enum.insurance_status')
        (New-HitlLine 'finance.label.booked_payments' "$I.tx_count")
        (New-HitlNote -KeyExpr "($I.tx_count > 0 ? 'finance.note.close_insurance_soft' : 'finance.note.close_insurance_hard')")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 240) 'the close_insurance action'


    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Close rejected' @(2200, 240) `
        "={{ `$('Close insurance (atomic)').item.json.reason }}"

    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('action', "={{ `$('Close insurance (atomic)').item.json.action }}", 'string')
        ,@('tx_count', "={{ `$('Close insurance (atomic)').item.json.tx_count }}", 'number')
    )

    $stickyFn = Build-Sticky 'fn_close_insurance: Hard-DELETE vs. Soft-Close' @(1760, -260) `
        'Smart-Close-Guard: tx_count entscheidet' `
        'fn zählt Transaktionen (recurring_payment_id = insurance.rp_id). tx_count=0: Hard-DELETE finance.insurances dann finance.recurring_payments (FK-Reihenfolge!); action=deleted. tx_count>0: Soft-Close — insurance.status=cancelled + valid_to=heute; RP.status=paused + valid_to=heute; action=closed. RAISE EXCEPTION bei nicht gefunden/mehrdeutig.' 240 480

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_close_insurance mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (korrigierbare Ablehnungen der fn; Versicherung nicht gefunden -> schon vorher Insurance not found als Tool-Fehler, mehrdeutig kommt als Exception) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $readIns, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled,
               $ifWriteOk, $errWrite, $ret, $stickyFn,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read Insurance' ) ) }
        'Read Insurance'         = @{ main = @( ,@( E 'Insurance found?' ) ) }
        'Insurance found?'       = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Insurance not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Close insurance (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Close insurance (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_close_insurance' $nodes $conns `
        @{ Category = 'insurance' }
}
