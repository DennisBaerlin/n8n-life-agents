#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_sell_real_estate (Immobilienverkauf buchen: +Erloes, status=sold, Allow+Hinweis bei Kredit) ---
function Build-SellRealEstate {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('real_estate_name','proceeds_account_name','sale_date','sale_price')

    $resAcc = Build-Pg 'Resolve Proceeds Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'proceeds_account_name', ARRAY['cash']);" `
        ([ordered]@{ proceeds_account_name = '$(''Start'').item.json.proceeds_account_name' })

    $ifAcc = Build-If 'Proceeds unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcc = Build-ToolError 'Proceeds ambiguous' @(660, 240) `
        "=Proceeds account '{{ `$('Start').item.json.proceeds_account_name }}' resolves to {{ `$('Resolve Proceeds Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Proceeds Account').item.json.candidates) }}. Ask the user which exact account to use."

    $readRe = Build-Pg 'Read Property' @(660, 0) `
        "=SELECT re.current_value, rep.full_name AS owner, re.status::text AS re_status, (SELECT COUNT(*)::int FROM finance.loans l WHERE l.real_estate_id = re.id AND l.status = 'active') AS loan_count FROM finance.real_estate re LEFT JOIN core.fn_household_persons() rep ON rep.person_id = re.owner_person_id WHERE re.name = ((`$1::jsonb)->>'real_estate_name') ORDER BY re.id LIMIT 1;" `
        ([ordered]@{ real_estate_name = '$(''Start'').item.json.real_estate_name' })
    # Unbekannter Name -> Tool-Fehler statt stillem Ende (New-RequiredRowGate, 2026-10-24).
    $found = New-RequiredRowGate -Read $readRe -KeyField 're_status' -IfName 'Property found?' -ErrName 'Property not found' `
        -IfPos @(770, -160) -ErrPos @(880, 240) `
        -NotFoundExpr "=No property named '{{ `$('Start').item.json.real_estate_name }}' exists. List them via postgres_select on finance.real_estate_overview and ask the user which one is meant."

    # "DB ist das Gesetz": fn_sell_real_estate laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_sell_real_estate' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Sell property (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'real_estate_id')::int AS real_estate_id, (r->>'proceeds_tx_id')::int AS proceeds_tx_id, (r->>'sale_price')::numeric AS sale_price, (r->>'linked_loan_count')::int AS linked_loan_count, r->'linked_loans' AS linked_loans, r->>'note' AS note" `
        -Params ([ordered]@{
            real_estate_name    = '$(''Start'').item.json.real_estate_name'
            proceeds_account_id = '$(''Resolve Proceeds Account'').item.json.id'
            sale_date           = '$(''Start'').item.json.sale_date'
            sale_price          = '$(''Start'').item.json.sale_price'
        })

    # Strukturiertes Summary (Textkatalog): Betraege in EUR-Konvention (entity-Werte in EUR erfasst); Haushalts-
    # Eigentuemer-Fallback kommt aus dem Katalog (SQL liefert NULL).
    $S = "`$('Start').item.json"
    $R = "`$('Read Property').item.json"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.sell_real_estate' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.real_estate'   "$S.real_estate_name")
        (New-HitlLine 'finance.label.owner'         "($R.owner ? 'finance.tpl.plain' : 'finance.value.household')" -Kind tpl -Params @{ value = "$R.owner" })
        (New-HitlLine 'finance.label.previous_value' "($R.current_value || null)" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.sale_price'    "$S.sale_price" -Kind money -EurByModel)
        (New-HitlLine 'finance.label.credited_to'   "$S.proceeds_account_name")
        (New-HitlLine 'core.label.date'             "`$('Dry run').item.json.r.effective.sale_date" -Kind date)   # DB-Default heute (Probelauf)
        (New-HitlNote -Key 'finance.note.sell_re_action')
        (New-HitlNote -Key 'finance.note.sell_re_loans' -If "$R.loan_count > 0" -Params @{ count = "$R.loan_count" })
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 240) 'the sell_real_estate action'


    $ifWriteOk = Build-If 'Write ok?' @(2420, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Sell rejected' @(2640, 240) `
        "={{ `$('Sell property (atomic)').item.json.reason }}"

    # Hinweis-Felder mitgeben (linked_loans = [{name, remaining_debt}]) -> der Agent kann offene
    # Kredite konkret benennen, ohne zweiten Lookup.
    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('real_estate_id', "={{ `$('Sell property (atomic)').item.json.real_estate_id }}", 'number')
        ,@('sale_price', "={{ `$('Sell property (atomic)').item.json.sale_price }}", 'number')
        ,@('linked_loan_count', "={{ `$('Sell property (atomic)').item.json.linked_loan_count }}", 'number')
        ,@('linked_loans', "={{ `$('Sell property (atomic)').item.json.linked_loans }}", 'array')
        ,@('note', "={{ `$('Sell property (atomic)').item.json.note }}", 'string')
    )

    $stickyFn = Build-Sticky 'fn_sell_real_estate: Verkauf + Allow+Hinweis' @(2200, -300) `
        'Erlös einbeinig; status=sold; offene Kredite nur Hinweis' `
        'fn_sell_real_estate bucht den Erlös einbeinig (+sale_price, category other, Saldo via Trigger) und setzt die Immobilie auf sold (current_value=Verkaufspreis). Verknüpfte AKTIVE Kredite werden NICHT abgelöst: linked_loans (Name + Restschuld) + note kommen zurück, der Agent weist den Nutzer hin (separat settle_loan). Bereits verkauft / sale_price<=0 -> {ok:false}. RAISE bei nicht gefunden/mehrdeutig (nicht gefunden fängt vorher das Found?-Gate des Tools) (Resolver p_active_only=FALSE).' 260 540

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_sell_real_estate mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (Immobilie bereits verkauft, sale_price kleiner/gleich 0) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $resAcc, $ifAcc, $errAcc, $readRe, $found.If, $found.Err) + $wg.Nodes + @($summary, $reqApproval, $ifApproved,
               $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyFn,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve Proceeds Account' ) ) }
        'Resolve Proceeds Account' = @{ main = @( ,@( E 'Proceeds unique?' ) ) }
        'Proceeds unique?'         = @{ main = @(
            @( E 'Read Property' ),
            @( E 'Proceeds ambiguous' )
        ) }
        'Read Property'            = @{ main = @( ,@( E 'Property found?' ) ) }
        'Property found?'        = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Property not found' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Sell property (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Sell property (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Sell rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_sell_real_estate' $nodes $conns `
        @{ Category = 'real_estate' }
}
