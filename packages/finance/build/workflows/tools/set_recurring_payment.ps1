#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_recurring_payment (set_*: standalone wiederkehrende Zahlung aendern) ---
function Build-SetRecurringPayment {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('payment_name','new_name','amount','valid_from','status','valid_to',
                           'schedule_day_of_month','notes')

    # Resolve ueber ALLE Status (active_only=false): findet auch pausierte (resume) und nach Split
    # mehrere gleichnamige -> Ambiguitaet zeigt Kandidaten (status/valid_from/valid_to) zum Auswaehlen.
    $resRp = Build-Pg 'Resolve Payment' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_recurring_payment((`$1::jsonb)->>'payment_name', FALSE);" `
        ([ordered]@{ payment_name = '$(''Start'').item.json.payment_name' })

    $ifRp = Build-If 'Payment unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errRp = Build-ToolError 'Payment ambiguous' @(660, 200) `
        "=Recurring payment '{{ `$('Start').item.json.payment_name }}' resolves to {{ `$('Resolve Payment').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Payment').item.json.candidates) }}. Ask the user which exact entry (by valid_from / status)."

    $readCur = Build-Pg 'Read Current' @(660, 0) `
        "=SELECT rp.amount, rp.valid_from, rp.status::text AS status, a.currency FROM finance.recurring_payments rp JOIN finance.accounts a ON a.id = rp.account_id WHERE rp.id = ((`$1::jsonb)->>'id')::int;" `
        ([ordered]@{ id = '$(''Resolve Payment'').item.json.id' })

    # "DB ist das Gesetz": fn_set_recurring_payment laeuft als Probelauf VOR der Karte (Standalone-Guard, Stichtag nach
    # der letzten gebuchten Rate usw. -> {ok:false} ohne Karte); derselbe Param-Satz geht nach dem Gate in den echten
    # Write (Betrag -> Validity-Split; sonst In-Place).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_recurring_payment' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set payment (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'recurring_payment_id')::int AS recurring_payment_id, (r->>'split')::boolean AS split, COALESCE(r->'cashflow_coverage'->>'note', '') AS cashflow_coverage" `
        -Params ([ordered]@{
            recurring_payment_id  = '$(''Resolve Payment'').item.json.id'
            amount                = '$(''Start'').item.json.amount'
            valid_from            = '$(''Start'').item.json.valid_from'
            status                = '$(''Start'').item.json.status'
            valid_to              = '$(''Start'').item.json.valid_to'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            name                  = '$(''Start'').item.json.new_name'
            notes                 = '$(''Start'').item.json.notes'
        })

    # Strukturiertes Summary (Textkatalog): nur gelieferte Felder (-If je Zeile). Betrag in der Konto-Waehrung (Read Current).
    $S = "`$('Start').item.json"
    $R = "`$('Read Current').item.json"
    $dom = Get-FinanceDomTpl "$S.schedule_day_of_month"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_recurring_payment' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.payment'    "$S.payment_name")
        (New-HitlLine 'finance.label.new_amount' "($S.valid_from ? 'finance.tpl.new_amount_from_date' : 'finance.tpl.new_amount_from_today')" -Kind tpl -If "$S.amount" -Params @{
            amount = (New-HitlValue -Kind money -Value "$S.amount" -Currency "$R.currency")
            date   = (New-HitlValue -Kind date -Value "$S.valid_from") })
        (New-HitlLine 'finance.label.new_name'   "$S.new_name" -If "$S.new_name")
        (New-HitlLine 'core.label.status'        "'finance.tpl.change'" -Kind tpl -If "$S.status" -Params @{
            from = (New-HitlValue -Kind enum -Value "$R.status" -Enum 'finance.enum.status')
            to   = (New-HitlValue -Kind enum -Value "$S.status" -Enum 'finance.enum.status') })
        (New-HitlLine 'finance.label.valid_to'   "$S.valid_to" -Kind date -If "$S.valid_to")
        (New-HitlLine 'finance.label.debit_day'  $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" } -If "$S.schedule_day_of_month")
        (New-HitlLine 'core.label.note'          "$S.notes" -If "$S.notes")
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the set_recurring_payment action'

    # Atomarer Write via fn_set_recurring_payment ($wg.Write, 'Set payment (atomic)').
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2640, 240) `
        "={{ `$('Set payment (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('recurring_payment_id', "={{ `$('Set payment (atomic)').item.json.recurring_payment_id }}", 'number')
        ,@('split', "={{ `$('Set payment (atomic)').item.json.split }}", 'boolean')
        ,@('cashflow_coverage', "={{ `$('Set payment (atomic)').item.json.cashflow_coverage }}", 'string')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_recurring_payment mit denselben Werten, immer zurückgerollt. ok:false (entitäts-besessene Zeile, Stichtag vor der letzten gebuchten Rate u. ä.) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?); cashflow_coverage kommt nur aus diesem echten Write.' 200 400

    $stickyOv = Build-Sticky 'Doc set_recurring_payment' @(2200, -240) `
        'fn_set_recurring_payment: Split vs In-Place + Standalone-Guard + Cashflow-Fold' `
        'Betrags-Änderung = Validity-Split über fn_split_recurring_payment (alte Zeile valid_to=Stichtag, neue ab Stichtag; Vorzeichen, Ziel-Konto, Status, Ende, Rhythmus-Anker geerbt; Stichtag nach der letzten gebuchten Rate). Sonst In-Place (status/valid_to/name/tag/notes). valid_to-Eingabe = letzter gültiger Tag (inklusiv, so zeigt es die Karte); die fn speichert +1 Tag (halboffen). NUR standalone: entitäts-besessene Zeile (insurance/loan/savings_goal/pension) -> {ok:false} (über das set_<entity>-Tool ändern). monthly_equivalent ist GENERATED. Phase L WS-3 / Audit Paket 3: nach dem Write liest die fn monthly_free (frei nach Konsum + Kreditraten, Sparraten zählen nicht); frei<0 -> Note in cashflow_coverage (M3: zukünftig-datierter Split -> KEIN Sofort-Hinweis, der Cron fängt es; bei Stichtag heute schon). Bookkeeper relayed.' 240 470

    $nodes = @($trig, $resRp, $ifRp, $errRp, $readCur) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Payment' ) ) }
        'Resolve Payment'        = @{ main = @( ,@( E 'Payment unique?' ) ) }
        'Payment unique?'        = @{ main = @(
            @( E 'Read Current' ),
            @( E 'Payment ambiguous' )
        ) }
        'Read Current'           = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set payment (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set payment (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_recurring_payment' $nodes $conns `
        @{ Category = 'recurring' }
}
