#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 7. tool_create_real_estate (NEW) -------------------------
function Build-CreateRealEstate {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $trig = Build-Trigger @('name','current_value','value_updated_at','owner_person','status','notes')

    # Dedup-Guard (Name, aktive Immobilien) — Block vor dem Gate
    $checkDup = Build-Pg 'Check duplicate name' @(220, -200) `
        "=SELECT COUNT(*)::int AS hit_count FROM finance.real_estate WHERE name = (`$1::jsonb)->>'name' AND status = 'active';" `
        ([ordered]@{ name = '$(''Start'').item.json.name' })

    $ifExists = Build-If 'Real estate exists?' @(440, -200) `
        "={{ `$('Check duplicate name').item.json.hit_count }}" '1' 'largerEqual' 'number'

    $errExists = Build-ToolError 'Real estate exists' @(660, -300) `
        "=An active real-estate asset named '{{ `$('Start').item.json.name }}' already exists. I will NOT create a duplicate. Use a different name or the dedicated update tool."

    # WS-4: typisierte Eigentuemer-Person aufloesen (Name -> Slug via core.fn_resolve_person; leer=Haushalt).
    $resPerson = Build-ResolvePerson 'Resolve Person' @(220, 180) 'owner_person'

    $ifPersonBad = Build-If 'Person invalid?' @(440, 180) `
        "={{ !!`$('Start').item.json.owner_person && `$('Resolve Person').item.json.hit_count !== 1 }}" 'true' 'equals' 'boolean'

    $errPerson = Build-ToolError 'Person unresolved' @(660, 320) `
        "=The owner person '{{ `$('Start').item.json.owner_person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Candidates: {{ JSON.stringify(`$('Resolve Person').item.json.candidates) }}. Ask which household member, or leave empty for a joint/household asset."

    # "DB ist das Gesetz": fn_create_real_estate laeuft als Probelauf VOR der Karte (korrigierbare Ablehnungen -> {ok:false} ohne Karte);
    # derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'finance.fn_create_real_estate' -DryPos @(660, 0) -WritePos @(1980, 0) `
        -WriteName 'Create real estate (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'real_estate_id')::int AS real_estate_id" `
        -Params ([ordered]@{
            name             = '$(''Start'').item.json.name'
            current_value    = '$(''Start'').item.json.current_value'
            value_updated_at = '$(''Start'').item.json.value_updated_at'
            owner_person_id  = '$(''Resolve Person'').item.json.person_id'
            status           = '$(''Start'').item.json.status'
            notes            = '$(''Start'').item.json.notes'
        })

    # --- HITL approval gate (before the write) ---
    # Strukturiertes Summary (Textkatalog): Wert in EUR-Konvention (vorher hart " €" an der Rohzahl), Bewertungsdatum formatiert.
    $S = "`$('Start').item.json"
    $P = "`$('Resolve Person').item.json"
    # Zeilen aus der geteilten Felddefinition (../hitl_lines.ps1, dieselbe wie die Import-Karte).
    $summary = New-HitlSummary -Pos @(1320, 0) -Title 'finance.hitl.create_real_estate' -LinesExpr $wg.CardLinesExpr -Lines (Get-FinanceHitlLines -Entity real_estate -S $S -D @{
        Person = "$P.full_name" })

    $gateId = $GateId
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1540, 0) $gateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1760, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1980, 200) 'the create_real_estate action'


    # Import-Haertung 2026-10-22: die fn lehnt z. B. einen unbekannten Status mit {ok:false} ab -> nie "angelegt" melden.
    $ifWriteOk = Build-If 'Write ok?' @(2200, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Create rejected' @(2420, 240) `
        "={{ `$('Create real estate (atomic)').item.json.reason }}"

    $ret = Build-Return @(2420, 0) @(
        ,@('ok','true','boolean')
        ,@('real_estate_id', "={{ `$json.real_estate_id }}", 'number')
        ,@('name', "={{ `$('Start').item.json.name }}", 'string')
    )

    $stickyDoc = Build-Sticky 'Doc HITL + atomar' @(1980, -200) `
        'Human-in-the-Loop + finance.fn_create_real_estate' `
        'Vor dem Write: Werteliste -> agent.tool_human_approval (Approve/Decline). Approve -> finance.fn_create_real_estate atomar (1 INSERT). Unbekannter Status -> {ok:false} ohne Write -> Write ok? -> Create rejected (reason an den Agenten). Eine Immobilie hat keinen Saldo/Trigger (kein finance.account_balances-Eintrag) -> hier keine DB-Automatik-Sticky nötig.' 200 380

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -480) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = fn_create_real_estate mit denselben Werten wie der echte Write, immer zurückgerollt. Ablehnung ok:false (unbekannter Status und weitere korrigierbare Ablehnungen) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte; Hinweis-Zeilen der fn (card_lines) hängen unten an. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 220 440

    $nodes = @($trig, $checkDup, $ifExists, $errExists, $resPerson, $ifPersonBad, $errPerson) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDoc,
               $stickyDry)

    $conns = [ordered]@{
        'Start'                     = @{ main = @( ,@( E 'Check duplicate name' ) ) }
        'Check duplicate name'      = @{ main = @( ,@( E 'Real estate exists?' ) ) }
        'Real estate exists?'       = @{ main = @(
            @( E 'Real estate exists' ),
            @( E 'Resolve Person' )
        ) }
        'Resolve Person'            = @{ main = @( ,@( E 'Person invalid?' ) ) }
        'Person invalid?'           = @{ main = @(
            @( E 'Person unresolved' ),
            @( E 'Dry run' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary'    = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'          = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'                 = @{ main = @(
            @( E 'Create real estate (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Create real estate (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'                   = @{ main = @(
            @( E 'Return' ),
            @( E 'Create rejected' )
        ) }
    }

    return Build-Workflow 'agent.finance.tool_create_real_estate' $nodes $conns `
        @{ Category = 'real_estate' }
}

