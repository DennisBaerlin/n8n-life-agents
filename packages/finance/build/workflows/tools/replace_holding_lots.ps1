#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_replace_holding_lots -----------------------------
# Eine uebernommene Position (Bestand) durch die einzeln eingetippten Kaeufe ersetzen: Probelauf der DB -> eine Karte ->
# Gate -> ein atomarer Write (fn_replace_holding_lots). Die DB prueft zuerst und tauscht alles in einer Transaktion
# (die Position vorher zu stornieren und die Liste erst danach zu pruefen, ist nicht atomar).
# Position per Depot-Name + Symbol/ISIN wird in der fn gesucht (fn_find_holding, eine Adresse); 0/mehrdeutig kommt als
# {ok:false, code, candidates} aus dem Probelauf (Dry run rejected, keine Karte).
function Build-ReplaceHoldingLots {
    # Enge Paket-Schreibrolle (finance_rw) statt Owner-Cred; Build-Pg liest $CRED_POSTGRES per Dynamic-Scope.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('depot_name','position','lots')

    # lots kommt vom Agenten als JSON-String -> geschuetztes JSON.parse (ungueltig -> Sentinel -> die fn lehnt mit
    # {ok:false, code:'invalid_lots'} ab, kein Execution-Abbruch), dann als jsonb in die fn.
    $wg = New-FnWriteGate -Fn 'finance.fn_replace_holding_lots' -DryPos @(220, 0) -WritePos @(1540, 0) `
        -WriteName 'Replace lots (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'holding_id')::int AS holding_id, r->>'group_id' AS group_id, (r->>'shares_before')::numeric AS shares_before, (r->>'total_shares')::numeric AS total_shares, (r->>'avg_before')::numeric AS avg_before, (r->>'avg_purchase_price')::numeric AS avg_purchase_price, (r->>'settlement_balance')::numeric AS settlement_balance, (r->>'settlement_change')::numeric AS settlement_change" `
        -Params ([ordered]@{
            depot_name = '$(''Start'').item.json.depot_name'
            position   = '$(''Start'').item.json.position'
            lots       = (Get-GuardedJsonExpr 'JSON.parse($(''Start'').item.json.lots)')
        })

    # Karte = die Zeilen der fn (je Lot eine Zeile, Stueck/Einstand alt -> neu, Wirkung aufs Verrechnungskonto) -- eine Adresse.
    $summary = New-HitlSummary -Pos @(880, 0) -Title 'finance.hitl.replace_holding_lots' -LinesExpr $wg.CardLinesExpr

    $reqApproval = Build-CallWorkflow 'Request Approval' @(1100, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1320, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1540, 200) 'the replace_holding_lots action'

    # Bestand kann sich zwischen Karte und Tipp aendern -> eine Ablehnung des echten Writes ist kein Erfolg.
    $ifWriteOk = Build-If 'Write ok?' @(1760, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Replace rejected' @(1980, 200) "={{ `$('Replace lots (atomic)').item.json.reason }}"

    $ret = Build-Return @(1980, 0) @(
        ,@('ok','true','boolean')
        ,@('holding_id', "={{ `$('Replace lots (atomic)').item.json.holding_id }}", 'number')
        ,@('group_id', "={{ `$('Replace lots (atomic)').item.json.group_id }}", 'string')
        ,@('shares_before', "={{ `$('Replace lots (atomic)').item.json.shares_before }}", 'number')
        ,@('total_shares', "={{ `$('Replace lots (atomic)').item.json.total_shares }}", 'number')
        ,@('avg_before', "={{ `$('Replace lots (atomic)').item.json.avg_before }}", 'number')
        ,@('avg_purchase_price', "={{ `$('Replace lots (atomic)').item.json.avg_purchase_price }}", 'number')
        ,@('settlement_balance', "={{ `$('Replace lots (atomic)').item.json.settlement_balance }}", 'number')
        ,@('settlement_change', "={{ `$('Replace lots (atomic)').item.json.settlement_change }}", 'number')
    )

    $stickyOv = Build-Sticky 'Überblick' @(220, -520) `
        'Bestand durch eingetippte Einzelkäufe ersetzen - erst prüfen, dann tauschen' `
        'Ersetzt die Bestandsübernahme einer Position durch die einzeln genannten Käufe. Die Datenbank prüft die ganze Liste im Probelauf (Position gefunden? nur Übernahme-Buchungen? jedes Datum bis zum Übernahme-Tag? Bestand danach nicht negativ?). Erst wenn alles passt, gibt es EINE Karte; der alte Bestand bleibt bis zum Tipp unberührt. Danach tauscht ein einziger atomarer Write: neue Käufe als Übernahme-Paare, alte Übernahme raus. Das Verrechnungskonto ändert sich nie. Echte Folgekäufe/-verkäufe der Position bleiben stehen. Löst den früheren Umweg Stornieren, dann neu eintippen ab (dabei fehlte die Position zwischendurch).' 340 520

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(220, -220) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_replace_holding_lots mit denselben Werten, immer zurückgerollt. ok:false (Position unbekannt oder mehrdeutig, Liste ungültig, Datum nach dem Übernahme-Tag, echte Käufe in der Übernahme, Bestand würde negativ) -> Dry run rejected: KEINE Karte, card_sent:false + reason/code/candidates an den Agenten. ok:true -> Karte aus card_lines. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write bekommt die aufgelösten Lots (effective.lots: ISO-Datum, Kurs je Stück) fest, so bucht er nach Mitternacht dieselben Daten wie die Karte zeigt.' 220 400

    $stickyFn = Build-Sticky 'fn_replace_holding_lots: atomarer Tausch' @(1540, -240) `
        'Lots buchen, dann alte Übernahme voiden (fn_replace_takeover_apply)' `
        'Eine Transaktion: Position + Verrechnungskonto sperren; alle Lots als Übernahme-Paare in EINER neuen group_id (Kauf + Gegenbuchung = Konto bleibt gleich); danach die alten Übernahme-Gruppen über fn_void_transaction (Audit replaced_by_lots). shares/average_purchase_price pflegen die DB-Trigger. Die Stückzahl darf sich ändern, die Karte zeigt alt -> neu. Der Baustein ist derselbe wie im Export-Weg (fn_replace_takeover_with_lots).' 220 400

    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret,
               $stickyOv, $stickyDry, $stickyFn)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Replace lots (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Replace lots (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Replace rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_replace_holding_lots' $nodes $conns `
        @{ Category = 'securities' }
}
