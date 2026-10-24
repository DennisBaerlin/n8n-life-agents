#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_account_interest (set_*: Kontozins setzen/aendern) ---
function Build-SetAccountInterest {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name','annual_rate','schedule_interval','schedule_unit',
                           'schedule_day_of_month','day_count_convention','posting_day_of_month','auto_post','valid_from')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', NULL, TRUE);" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # Read-only Vorschau der WIRKSAMEN Werte aus derselben fn wie die Buchung (Audit Paket 2: fn_interest_rate_preview
    # -> Karte = Buchung): geerbte Kadenz/Tage/auto_post bei reinem Satzwechsel, Zinsmethode samt Grund, und die
    # korrigierbaren Ablehnungen (Konto nicht zins-faehig, Satz negativ, Datum vor offener Zeile oder vor der juengsten
    # verzinsten Periode) schon VOR der Karte.
    $resInt = Build-Pg 'Resolve interest defaults' @(660, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'day_count_convention' AS conv, (r->>'auto_post')::boolean AS auto_post, r->>'conv_reason' AS conv_reason, r->>'schedule_unit' AS schedule_unit, (r->>'schedule_interval')::int AS schedule_interval, (r->>'schedule_day_of_month')::int AS schedule_day_of_month, (r->>'posting_day_of_month')::int AS posting_day_of_month, r->>'first_credit_date' AS first_credit_date FROM finance.fn_interest_rate_preview(`$1::jsonb) AS r;" `
        ([ordered]@{
            account_id            = '$(''Resolve Account'').item.json.id'
            annual_rate           = '$(''Start'').item.json.annual_rate'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            day_count_convention  = '$(''Start'').item.json.day_count_convention'
            posting_day_of_month  = '$(''Start'').item.json.posting_day_of_month'
            auto_post             = '$(''Start'').item.json.auto_post'
            valid_from            = '$(''Start'').item.json.valid_from'
        })

    $ifPreOk = Build-If 'Preview ok?' @(770, -160) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errPre = Build-ToolError 'Interest rejected' @(880, 240) "={{ `$('Resolve interest defaults').item.json.reason }}"

    # "DB ist das Gesetz": fn_set_account_interest laeuft als Probelauf VOR der Karte (nach der Read-only-Vorschau);
    # derselbe Param-Satz geht nach dem Gate in den echten Write (offene Zeile schliessen (valid_to) + neue Zeile).
    $wg = New-FnWriteGate -Fn 'finance.fn_set_account_interest' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Set interest (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'interest_rate_id')::int AS interest_rate_id, (r->>'closed_previous')::boolean AS closed_previous" `
        -Params ([ordered]@{
            account_id            = '$(''Resolve Account'').item.json.id'
            annual_rate           = '$(''Start'').item.json.annual_rate'
            schedule_interval     = '$(''Start'').item.json.schedule_interval'
            schedule_unit         = '$(''Start'').item.json.schedule_unit'
            schedule_day_of_month = '$(''Start'').item.json.schedule_day_of_month'
            day_count_convention  = '$(''Start'').item.json.day_count_convention'
            posting_day_of_month  = '$(''Start'').item.json.posting_day_of_month'
            auto_post             = '$(''Start'').item.json.auto_post'
            valid_from            = '$(''Start'').item.json.valid_from'
        })

    # Strukturiertes Summary (Textkatalog): Zinssatz als Prozent, Zinsmethode samt Grund (Code aus dem SQL, im Katalog
    # uebersetzt), Hinweis auf das automatische Beenden des bisher offenen Satzes.
    $S = "`$('Start').item.json"
    $D = "`$('Resolve interest defaults').item.json"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.set_account_interest' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account'       "$S.account_name")
        (New-HitlLine 'finance.label.interest_rate' "'finance.tpl.percent_pa'" -Kind tpl -Params @{ value = "$S.annual_rate" })
        (New-HitlLine 'finance.label.valid_from'    "($S.valid_from ? 'finance.tpl.plain' : 'finance.value.today')" -Kind tpl -Params @{
            value = (New-HitlValue -Kind date -Value "$S.valid_from") })
        (Get-FinanceInterestScheduleLines -Unit "$D.schedule_unit" -Interval "$D.schedule_interval" -Dom "$D.schedule_day_of_month" `
            -Pdom "$D.posting_day_of_month" -FirstCredit "$D.first_credit_date" -Conv "$D.conv" -ConvReason "$D.conv_reason")
        (New-HitlLine 'finance.label.auto_post'     "($D.auto_post ? 'finance.value.auto_post_yes' : 'finance.value.auto_post_no')" -Kind key)
        (New-HitlNote -Key 'finance.note.set_interest_closes_open')
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the set_account_interest action'

    # Atomarer Write via fn_set_account_interest ($wg.Write, 'Set interest (atomic)'): offene Zeile schliessen + neue Zeile.
    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Update rejected' @(2640, 240) `
        "={{ `$('Set interest (atomic)').item.json.reason }}"

    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('interest_rate_id', "={{ `$('Set interest (atomic)').item.json.interest_rate_id }}", 'number')
        ,@('closed_previous', "={{ `$('Set interest (atomic)').item.json.closed_previous }}", 'boolean')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_set_account_interest mit denselben Werten, immer zurückgerollt (nach der Vorschau Preview ok?). ok:false (Satz negativ, Datum vor der offenen Zeile oder vor der jüngsten verzinsten Periode, Rhythmus/Tag fehlt oder passt nicht bei neuem Raster) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception (z. B. EXCLUDE-Verletzung) -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyOv = Build-Sticky 'Doc set_account_interest' @(2200, -240) `
        'fn_set_account_interest: Validity-Row + EXCLUDE-Constraint' `
        'fn_create_account legt nur die ERSTE Zinszeile an; dies ist der Nachtrag/Änderungs-Pfad. ZWINGEND: offene Zeile (valid_to IS NULL) zuerst per valid_to=neues valid_from schliessen, dann INSERT (sonst finance_account_interest_rates_no_overlap EXCLUDE-Verletzung). Ein reiner Satzwechsel erbt Rhythmus/Tage/auto_post der offenen Zeile; ein Rhythmuswechsel verankert das Zins-Raster neu (keine Gutschrift am Wechseltag, der Rest laeuft in die erste neue Periode). {ok:false} bei rate<0, valid_from <= offener Zeile oder vor der jüngsten verzinsten Periode sowie ohne Rhythmus/Tag bei einem neuen Raster (fn_interest_schedule_reason; Tag und Arrears werden nur bei gleicher Einheit geerbt).' 230 460

    $stickyResInt = Build-Sticky 'Doc Resolve interest defaults' @(560, -260) `
        'Vorschau = Buchung (fn_interest_rate_preview)' `
        'Resolve interest defaults ruft dieselbe fn, die fn_set_account_interest für die wirksamen Werte nutzt: Rhythmus/Tage/auto_post geerbt oder neu, day_count_convention = Override > Vorgängerzeile > Kontotyp (mit Grund). Preview ok? false -> ToolError VOR der Karte (der Owner bestätigt nie, was danach abgelehnt würde). KEIN dupliziertes Mapping im Workflow.' 260 480

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct, $resInt, $ifPreOk, $errPre) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyOv, $stickyResInt)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'          = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'          = @{ main = @(
            @( E 'Resolve interest defaults' ),
            @( E 'Account ambiguous' )
        ) }
        'Resolve interest defaults' = @{ main = @( ,@( E 'Preview ok?' ) ) }
        'Preview ok?'              = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Interest rejected' )
        ) }
        'Dry run'                  = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'              = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Set interest (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set interest (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_account_interest' $nodes $conns `
        @{ Category = 'accounts' }
}
