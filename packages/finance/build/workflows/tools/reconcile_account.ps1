#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 7. tool_reconcile_account (Playbook 5.9) ---------------
function Build-ReconcileAccount {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name','confirmed_balance','reconciliation_date','notes')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name');" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # Saldo ZUM STICHTAG + Kontowaehrung + korrigierbare Ablehnung aus denselben fns wie die Buchung (Audit Paket 2,
    # Punkt 6/7): fn_get_balance_as_of (vorher heutiger Saldo -> eine spaetere Buchung galt als Differenz),
    # fn_reconcile_blocker (Depot-/Kreditkonto, Stichtag Zukunft / vor letztem Abgleich), bestaetigter Saldo auf die
    # Waehrungseinheit gerundet, Differenz von der DB gerechnet. Fehlendes Datum = heute (wie die fn).
    $readBal = Build-Pg 'Read DB Balance' @(660, 0) `
        "=WITH x AS (SELECT a.id, a.currency, c.minor_unit, COALESCE(NULLIF((`$1::jsonb)->>'reconciliation_date', '')::date, core.fn_today()) AS d FROM finance.accounts a JOIN finance.currencies c ON c.code = a.currency WHERE a.id = ((`$1::jsonb)->>'account_id')::int) SELECT finance.fn_get_balance_as_of(x.id, x.d) AS db_balance, x.currency, x.d::text AS reconciliation_date, finance.fn_reconcile_blocker(x.id, x.d) AS blocker, ROUND(((`$1::jsonb)->>'confirmed_balance')::numeric, x.minor_unit) AS confirmed, ROUND(((`$1::jsonb)->>'confirmed_balance')::numeric, x.minor_unit) - finance.fn_get_balance_as_of(x.id, x.d) AS diff, (SELECT count(*) FROM finance.fn_reconcile_open_due(x.id, x.d))::int AS skip_count FROM x;" `
        ([ordered]@{
            account_id          = '$(''Resolve Account'').item.json.id'
            confirmed_balance   = '$(''Start'').item.json.confirmed_balance'
            reconciliation_date = '$(''Start'').item.json.reconciliation_date'
        })

    $ifOk = Build-If 'Reconcilable?' @(770, -160) "={{ !`$json.blocker }}" 'true' 'equals' 'boolean'
    $errBlocked = Build-ToolError 'Reconcile blocked' @(880, 240) "={{ `$('Read DB Balance').item.json.blocker }}"

    # "DB ist das Gesetz": fn_reconcile_account laeuft als Probelauf VOR der Karte (nach dem Read-only-Blocker-Check);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    # Atomarer Write via fn_reconcile_account:
    # 1. UPDATE finance.accounts.last_reconciled_balance + last_reconciled_at
    # 2. Korrekturbuchung (category=reconciliation) NUR bei Differenz != 0; Saldo via Trigger.
    $wg = New-FnWriteGate -Fn 'finance.fn_reconcile_account' -DryPos @(880, 0) -WritePos @(2200, 0) `
        -WriteName 'Reconcile (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'db_balance_before')::numeric AS db_balance_before, (r->>'confirmed_balance')::numeric AS confirmed_balance, (r->>'difference')::numeric AS difference, (r->>'reconciliation_tx_id') AS reconciliation_tx_id, r->>'currency' AS currency, (r->>'balance_after')::numeric AS balance_after" `
        -Params ([ordered]@{
            account_id           = '$(''Resolve Account'').item.json.id'
            confirmed_balance    = '$(''Start'').item.json.confirmed_balance'
            reconciliation_date  = '$(''Start'').item.json.reconciliation_date'
            notes                = '$(''Start'').item.json.notes'
        })

    # --- HITL approval gate --- (Betraege in der KONTOWAEHRUNG, nicht hart EUR)
    # Strukturiertes Summary (Textkatalog); die Differenz-Zeile traegt den Hinweis "Korrekturbuchung" bzw. "kein Unterschied".
    $S = "`$('Start').item.json"
    $B = "`$('Read DB Balance').item.json"
    $diff = "Number($B.diff)"
    $summary = New-HitlSummary -Pos @(1540, 0) -Title 'finance.hitl.reconcile_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account'           "$S.account_name")
        (New-HitlLine 'finance.label.db_balance'        "$B.db_balance" -Kind money -Currency "$B.currency")
        (New-HitlLine 'finance.label.confirmed_balance' "$B.confirmed" -Kind money -Currency "$B.currency")
        (New-HitlLine 'finance.label.difference'        "($diff !== 0 ? 'finance.tpl.diff_correction' : 'finance.tpl.diff_none')" -Kind tpl -Params @{
            value = (New-HitlValue -Kind money -Value $diff -Currency "$B.currency") })
        (New-HitlLine 'core.label.date'                 "$B.reconciliation_date" -Kind date)
        (New-HitlLine 'core.label.note'                 "$S.notes")
        # 2026-10-23: der Abgleich markiert offene Dauerauftrags-/Sparplan-/Zins-Vorkommen bis Stichtag-10 als erledigt
        # (fn_reconcile_open_due, dieselbe Menge wie der Write) -> vorher sichtbar machen
        (New-HitlNote -Key 'finance.note.reconcile_closes_due' -If "Number($B.skip_count) > 0" -Params @{ n = "$B.skip_count" })
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1760, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1980, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2200, 200) 'the reconcile_account action'

    $ifWriteOk = Build-If 'Write ok?' @(2420, -160) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Reconcile rejected' @(2640, 200) "={{ `$('Reconcile (atomic)').item.json.reason }}"

    $R = "`$('Reconcile (atomic)').item.json"
    $ret = Build-Return @(2640, 0) @(
        ,@('ok','true','boolean')
        ,@('db_balance_before', "={{ $R.db_balance_before }}", 'number')
        ,@('confirmed_balance', "={{ $R.confirmed_balance }}", 'number')
        ,@('difference', "={{ $R.difference }}", 'number')
        ,@('reconciliation_tx_id', "={{ $R.reconciliation_tx_id }}", 'string')
        ,@('currency', "={{ $R.currency }}", 'string')
        ,@('balance_after', "={{ $R.balance_after }}", 'number')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(880, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_reconcile_account mit denselben Werten, immer zurückgerollt (nach dem Read-only-Check Reconcilable?). ok:false (z. B. Konto nicht abgleichbar, Stichtag in der Zukunft/vor dem letzten Abgleich) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 200 400

    $stickyFn = Build-Sticky 'fn_reconcile_account: Abgleich zum Stichtag' @(2200, -260) `
        'trg_finance_balance_update (bei Korrekturbuchung)' `
        'Karte und Buchung lesen dieselben fns: Saldo ZUM STICHTAG (fn_get_balance_as_of; Buchungen danach zählen nicht als Differenz), Ablehnungen aus fn_reconcile_blocker (Depot-/Kreditkonto, Stichtag in der Zukunft oder vor dem letzten Abgleich) schon VOR der Karte, bestätigter Saldo auf die Währungseinheit gerundet. fn_reconcile_account atomar: (1) UPDATE finance.accounts.last_reconciled_balance/_at, (2) nur bei Differenz != 0: INSERT reconciliation-Transaktion am Stichtag (amount=Diff). DB-Trigger pflegt den Saldo; balance_after = heutiger Saldo danach.' 240 520

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct, $readBal, $ifOk, $errBlocked) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'        = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'        = @{ main = @(
            @( E 'Read DB Balance' ),
            @( E 'Account ambiguous' )
        ) }
        'Read DB Balance'        = @{ main = @( ,@( E 'Reconcilable?' ) ) }
        'Reconcilable?'          = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Reconcile blocked' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Reconcile (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Reconcile (atomic)'     = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Reconcile rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_reconcile_account' $nodes $conns `
        @{ Category = 'accounts' }
}
