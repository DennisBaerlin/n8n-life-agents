#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_set_asset_classes (set_*: Anlageklassen mehrerer Depot-Positionen, EINE Karte) ---
# Owner-Entscheid 2026-10-23: die Anlageklasse wird in der Finanzplanung geklaert -> der Finanzberater (und der
# Buchhalter) ordnet alle offenen Positionen mit EINER Karte zu. Setzt NUR asset_class; die Pruef-/Write-Logik
# liegt allein in finance.fn_set_asset_classes (je Zeile fn_find_holding + fn_set_holding).
function Build-SetAssetClasses {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('assignments')

    # assignments kommt vom Agenten als JSON-String -> geschuetztes JSON.parse (ungueltig -> Sentinel -> die fn lehnt
    # mit {ok:false} ab, kein Execution-Abbruch). "DB ist das Gesetz": fn_set_asset_classes laeuft als Probelauf VOR
    # der Karte (Position unbekannt/mehrdeutig, Key-Format, doppelte Position -> {ok:false} ohne Karte) und liefert
    # die Kartenzeilen (Name, Depot, alt -> neu); derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_set_asset_classes' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Set asset classes (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->'updated' AS updated" `
        -Params ([ordered]@{ assignments = (Get-GuardedJsonExpr 'JSON.parse($(''Start'').item.json.assignments)') })

    $summary = New-HitlSummary -Pos @(660, 0) -Title 'finance.hitl.set_asset_classes' -LinesExpr $wg.CardLinesExpr

    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the set_asset_classes action'

    # Bestand kann sich zwischen Karte und Tipp aendern (Position verkauft/geloescht) -> ein {ok:false} des echten
    # Writes ist KEIN Erfolg.
    $ifWriteOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Update rejected' @(1760, 200) "={{ `$('Set asset classes (atomic)').item.json.reason }}"

    $ret = Build-Return @(1760, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('count', "={{ (`$json.updated || []).length }}", 'number')
        ,@('updated', "={{ `$json.updated || [] }}", 'array')
    )

    $stickyOv = Build-Sticky 'Doc set_asset_classes' @(220, -320) `
        'fn_set_asset_classes: nur Anlageklassen, EINE Karte' `
        'Eingabe assignments = JSON-Liste {depot_name, position (Symbol oder ISIN), asset_class} (1..50). Dry run = fn_set_asset_classes, immer zurückgerollt: Pass 1 löst JEDE Zeile über fn_find_holding auf und prüft den Key (lowercase snake), doppelte Positionen -> eine Ablehnung = KEINE Karte, card_sent:false + reason/candidates an den Agenten. Sonst liefert die fn je Position eine Kartenzeile (Name, Depot, alt -> neu). Nach dem Tipp: echter Write in EINER Transaktion, je Zeile fn_set_holding({holding_id, asset_class}) (eine Adresse für Format + Update). Reservierter Key outside_plan = bewusst außerhalb des Haushaltsplans (z. B. Kinder-Depot): fn_advisor_review meldet solche Positionen nicht als unzugeordnet. Gebunden an agent.finance UND agent.finance_advisor (einzige Schreib-Ausnahme des Beraters, Owner 2026-10-23).' 380 520

    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyOv)

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
            @( E 'Set asset classes (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set asset classes (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Update rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_set_asset_classes' $nodes $conns `
        @{ Category = 'securities' }
}