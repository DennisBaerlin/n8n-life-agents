#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_reconcile_accounts_batch -------------------------
# Mehrere Konten in EINEM Vorgang abgleichen: eine Nutzer-Antwort (alle Staende) -> EIN Sammel-Approval
# -> EIN atomarer Write (fn_reconcile_accounts, delegiert je Konto an fn_reconcile_account).
# Read/Resolve (fn_reconcile_accounts_preview, read-only) -> Build Summary -> Gate -> atomarer Write.
function Build-ReconcileAccountsBatch {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('accounts')

    # accounts kommt vom Agenten als JSON-String -> geschuetztes JSON.parse (ungueltig -> Sentinel -> die fn lehnt mit
    # {ok:false} ab, kein Execution-Abbruch), dann als jsonb in die fn (Standard jsonb-Param).
    $preview = Build-Pg 'Preview reconcile' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->'rows' AS rows, r->'candidates' AS candidates FROM finance.fn_reconcile_accounts_preview(`$1::jsonb) AS r;" `
        ([ordered]@{ accounts = (Get-GuardedJsonExpr 'JSON.parse($(''Start'').item.json.accounts)') })

    $ifPreview = Build-If 'Preview ok?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errPreview = Build-ToolError 'Preview failed' @(660, 200) `
        "={{ `$('Preview reconcile').item.json.reason }}"

    # EINE Approval-Summary (Textkatalog) fuer alle Konten (native Waehrung je Zeile): je Konto eine Zeile, Label =
    # Kontoname (kein Katalog-Key -> das Gate zeigt ihn unveraendert), Wert = Vorlage mit typisierten Betraegen.
    $linesExpr = "`$('Preview reconcile').item.json.rows.map(r => ({ label: r.name, kind: 'tpl', " +
        "value: (r.diff != 0 ? 'finance.tpl.reconcile_row_correction' : 'finance.tpl.reconcile_row_nochange'), " +
        "params: { db: { kind: 'money', value: r.db_balance, currency: r.currency }, confirmed: { kind: 'money', value: r.confirmed, currency: r.currency }, diff: { kind: 'money', value: r.diff, currency: r.currency } } }))" +
        # Wie die Einzel-Karte (tool_reconcile_account): je Konto ein Hinweis, wenn der Abgleich offene regelmaessige
        # Vorkommen <= Stichtag-10 als erledigt markiert (skip_count aus fn_reconcile_open_due, dieselbe Menge wie der Write).
        ".concat(`$('Preview reconcile').item.json.rows.filter(r => Number(r.skip_count) > 0).map(r => ({ kind: 'note', " +
        "value: 'finance.note.reconcile_closes_due_account', params: { name: r.name, n: r.skip_count } })))"
    # "DB ist das Gesetz": fn_reconcile_accounts laeuft als Probelauf VOR der Karte (nach der Read-only-Vorschau);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    # Atomarer Batch-Write ($wg.Write): re-resolved jeden Namen, loopt fn_reconcile_account in EINER Transaktion.
    $wg = New-FnWriteGate -Fn 'finance.fn_reconcile_accounts' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Reconcile batch (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'count')::int AS count, r->'results' AS results" `
        -Params ([ordered]@{ accounts = (Get-GuardedJsonExpr 'JSON.parse($(''Start'').item.json.accounts)') })

    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.reconcile_accounts_batch' -LinesExpr "$linesExpr.concat($($wg.CardLinesExpr))"

    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the reconcile_accounts_batch action'

    # Bestand kann sich zwischen Karte und Tipp aendern -> eine Ablehnung des echten Writes ist KEIN Erfolg (vorher fehlte
    # dieser Knoten: ein {ok:false} nach dem Tipp ging als ok:true an den Agenten).
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Batch rejected' @(2420, 200) "={{ `$('Reconcile batch (atomic)').item.json.reason }}"

    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('count', "={{ `$json.count }}", 'number')
        ,@('results', "={{ `$json.results }}", 'array')
    )

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_reconcile_accounts mit denselben Werten, immer zurückgerollt (nach der Read-only-Vorschau). ok:false (z. B. Konto nicht abgleichbar) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Sammel-Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft die fn erneut.' 200 400

    $stickyFn = Build-Sticky 'fn_reconcile_accounts: atomarer Batch' @(1980, -240) `
        'Two-Pass + Delegation an fn_reconcile_account' `
        'fn_reconcile_accounts atomar: Pass 1 löst ALLE Namen auf (0/>1 -> {ok:false}, kein Write -> kein Teilzustand); Pass 2 ruft je Konto fn_reconcile_account (UPDATE last_reconciled_balance/_at + Korrekturbuchung nur bei Diff!=0; Saldo via Trigger). EIN Gate deckt den ganzen Batch (ein logischer Write, analog Multi-Leg). Native Währung je Konto.' 220 520

    $stickyPreview = Build-Sticky 'Preview = read-only Resolve' @(220, 180) `
        'fn_reconcile_accounts_preview (STABLE)' `
        'Read-only: löst jeden Namen auf, liest Saldo + Währung, berechnet Diff -> baut die Summary VOR dem Write (CQRS-Read). Bei 0/>1 Treffer -> {ok:false, reason} -> Build-ToolError (Agent fragt nach). Der Write (fn_reconcile_accounts) re-resolved selbst -> keine veralteten IDs.' 220 460

    $nodes = @($trig, $preview, $ifPreview, $errPreview) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn, $stickyPreview)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Preview reconcile' ) ) }
        'Preview reconcile'      = @{ main = @( ,@( E 'Preview ok?' ) ) }
        'Preview ok?'            = @{ main = @(
            @( E 'Dry run' ),
            @( E 'Preview failed' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Reconcile batch (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Reconcile batch (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Batch rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_reconcile_accounts_batch' $nodes $conns `
        @{ Category = 'accounts' }
}
