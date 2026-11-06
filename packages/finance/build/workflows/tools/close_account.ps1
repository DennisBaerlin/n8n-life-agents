#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 8. tool_close_account (Playbook 5.10) ---------------
function Build-CloseAccount {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('account_name','closure_date','notes')

    $resAcct = Build-Pg 'Resolve Account' @(220, 0) `
        "=SELECT id, hit_count, candidates FROM finance.fn_resolve_account((`$1::jsonb)->>'account_name', NULL, TRUE);" `
        ([ordered]@{ account_name = '$(''Start'').item.json.account_name' })

    $ifAcct = Build-If 'Account unique?' @(440, 0) "={{ `$json.hit_count }}" '1'

    $errAcct = Build-ToolError 'Account ambiguous' @(660, 200) `
        "=Account '{{ `$('Start').item.json.account_name }}' resolves to {{ `$('Resolve Account').item.json.hit_count }} matches. Candidates: {{ JSON.stringify(`$('Resolve Account').item.json.candidates) }}. Ask the user which exact account."

    # Audit F6: Vorpruefung VOR der Karte ueber dieselbe fn wie der Guard in fn_close_account (Saldo, Depot,
    # Sparplan, Kredit, laufende Dauerauftraege) -> der Owner bestaetigt nie etwas, das danach abgelehnt wird.
    $checkBlk = Build-Pg 'Check close blockers' @(660, 0) `
        "=SELECT (b->>'blocked')::boolean AS blocked, b->>'reason' AS reason FROM finance.fn_get_account_close_blockers(((`$1::jsonb)->>'account_id')::int) AS b;" `
        ([ordered]@{ account_id = '$(''Resolve Account'').item.json.id' })

    $ifFree = Build-If 'Closable?' @(880, 0) "={{ `$json.blocked }}" 'false' 'equals' 'boolean'

    $errBlk = Build-ToolError 'Close not possible' @(1100, 240) `
        "={{ `$('Check close blockers').item.json.reason }}"

    # Aktueller Saldo + Kontotyp + Waehrung (fuer informativen HITL-Summary; currency -> Betrag-Formatierung).
    $readBal = Build-Pg 'Read Current Balance' @(1100, 0) `
        "=SELECT b.balance, a.account_type::text AS account_type, a.currency FROM finance.account_balances b JOIN finance.accounts a ON a.id = b.account_id WHERE b.account_id = ((`$1::jsonb)->>'account_id')::int;" `
        ([ordered]@{ account_id = '$(''Resolve Account'').item.json.id' })

    # "DB ist das Gesetz": fn_close_account laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_close_account' -DryPos @(1320, 0) -WritePos @(2640, 0) `
        -WriteName 'Close account (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'account_id')::int AS account_id, r->>'status' AS status" `
        -Params ([ordered]@{
            account_id    = '$(''Resolve Account'').item.json.id'
            closure_date  = '$(''Start'').item.json.closure_date'
            notes         = '$(''Start'').item.json.notes'
        })

    # --- HITL approval gate ---
    # Strukturiertes Summary (Textkatalog); Saldo in der Konto-Waehrung (Read Current Balance).
    $S = "`$('Start').item.json"
    $B = "`$('Read Current Balance').item.json"
    $summary = New-HitlSummary -Pos @(1980, 0) -Title 'finance.hitl.close_account' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'finance.label.account'         "$S.account_name")
        (New-HitlLine 'core.label.type'               "$B.account_type" -Kind enum -Enum 'finance.enum.account_type')
        (New-HitlLine 'finance.label.current_balance' "$B.balance" -Kind money -Currency "$B.currency")
        (New-HitlLine 'finance.label.closing_date'    "`$('Dry run').item.json.r.effective.closure_date" -Kind date)   # DB-Default heute (Probelauf)
        (New-HitlLine 'core.label.note'               "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'finance.note.close_account_warning')
    )

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(2200, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(2420, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(2640, 240) 'the close_account action'

    # Atomarer Write via fn_close_account:
    # UPDATE finance.accounts.status = 'closed' + Closure-Notiz anhaengen.
    # DB: trg_finance_reject_closed_account blockiert danach jeden INSERT auf dieses Konto.
    # fn liefert ok/reason: Blocker (fn_get_account_close_blockers, Race-Backstop zur Vorpruefung) -> {ok:false}.

    # Korrigierbare Ablehnung aus der fn -> weiche Rueckfrage (kein Owner-Alert).
    $ifWriteOk = Build-If 'Write ok?' @(2860, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Close rejected' @(3080, 240) `
        "={{ `$('Close account (atomic)').item.json.reason }}"

    $ret = Build-Return @(3080, 0) @(
        ,@('ok','true','boolean')
        ,@('account_id', "={{ `$('Close account (atomic)').item.json.account_id }}", 'number')
        ,@('status', "={{ `$('Close account (atomic)').item.json.status }}", 'string')
    )

    $stickyTrigger = Build-Sticky 'trg_finance_reject_closed_account' @(2640, -220) `
        'DB-Trigger blockiert neue Buchungen' `
        'fn_close_account setzt status=''closed'' und hängt einen Schliessungs-Vermerk an notes. Danach blockiert der DB-Trigger trg_finance_reject_closed_account jeden INSERT auf dieses Konto (RAISE EXCEPTION). Kein separates Flag nötig.' 180 380

    $stickyOk = Build-Sticky 'Write ok? (korrigierbare Ablehnung)' @(3080, -220) `
        'fn-Rückgabe {ok:false, reason}' `
        'Backstop zur Vorprüfung: findet fn_close_account zwischen Karte und Freigabe doch einen Blocker (fn_get_account_close_blockers: Saldo, Verrechnungskonto aktiver Depots, Depotbestand, Sparplan, Kredit, laufende Daueraufträge), liefert sie {ok:false, reason} -> Close rejected reicht reason an den Agenten (weiche Rückfrage). Nur ok=true schliesst wirklich.' 200 400

    $stickyBlk = Build-Sticky 'Vorprüfung vor der Karte' @(660, -260) `
        'fn_get_account_close_blockers' `
        'Bevor der Owner eine Karte sieht, prüft dieselbe fn, die fn_close_account als Guard nutzt, was das Schließen verhindert: Saldo ungleich 0 (Geld würde aus dem Vermögen verschwinden), Verrechnungskonto aktiver Depots, Depot mit Bestand, aktiver Sparplan, Kredit (Kredit- oder Belastungskonto), laufende oder pausierte Daueraufträge als Quelle/Ziel (sonst feuert später der Closed-Konto-Trigger). blocked=true -> Close not possible reicht den reason an den Agenten.' 240 480

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(1320, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_close_account mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (Blocker: Saldo ungleich 0, Verrechnungskonto aktiver Depots, Depot mit Bestand, Sparplan, Kredit, laufende Daueraufträge) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $resAcct, $ifAcct, $errAcct, $checkBlk, $ifFree, $errBlk, $readBal) + $wg.Nodes + @($summary, $reqApproval,
               $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyTrigger, $stickyOk, $stickyBlk,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                    = @{ main = @( ,@( E 'Resolve Account' ) ) }
        'Resolve Account'          = @{ main = @( ,@( E 'Account unique?' ) ) }
        'Account unique?'          = @{ main = @(
            @( E 'Check close blockers' ),
            @( E 'Account ambiguous' )
        ) }
        'Check close blockers'     = @{ main = @( ,@( E 'Closable?' ) ) }
        'Closable?'                = @{ main = @(
            @( E 'Read Current Balance' ),
            @( E 'Close not possible' )
        ) }
        'Read Current Balance'     = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'   = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'         = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                = @{ main = @(
            @( E 'Close account (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Close account (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                = @{ main = @(
            @( E 'Return' ),
            @( E 'Close rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_close_account' $nodes $conns `
        @{ Category = 'accounts' }
}
