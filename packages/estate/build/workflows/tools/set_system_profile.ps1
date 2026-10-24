#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_set_system_profile (WS-5, set_ = Haushalts-Singleton-UPSERT) ----------
# Erfasst/aendert den System-Steckbrief + den FUNDORT der Offline-Kopie des core.backup_key
# (Owner-Entscheid 9). GEHEIMNISSE NIE — nur Fundort-Verweise. Haushalts-Singleton (1 Zeile,
# scope='household' CHECK-fixiert) -> kein person_id/-Resolve. HITL owner_approval (Verb set_ Floor 1).
# adults_only-DB-Backstop in der fn. Cred = estate_rw. Sticky: Singleton-UPSERT + adults_only + Grenzregel.
function Build-EstateSetSystemProfile {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('backup_key_location','system_location','admin_access','restore_hint','notes')

    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    # Nur genannte Felder erscheinen (-If); der Hinweis "unveraendert" steht als Note darunter.
    $S = "`$('Start').item.json"
    # "DB ist das Gesetz": estate.fn_set_system_profile laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem Gate in den echten Write.
    $wg = New-FnWriteGate -Fn 'estate.fn_set_system_profile' -DryPos @(440, 0) -WritePos @(1760, 0) `
        -WriteName 'Set profile (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'created')::boolean AS created" `
        -Params ([ordered]@{
            chat_id             = '$(''Start'').item.json.chat_id'
            backup_key_location = '$(''Start'').item.json.backup_key_location'
            system_location     = '$(''Start'').item.json.system_location'
            admin_access        = '$(''Start'').item.json.admin_access'
            restore_hint        = '$(''Start'').item.json.restore_hint'
            notes               = '$(''Start'').item.json.notes'
        })
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'estate.hitl.set_system_profile' -LinesExpr $wg.CardLinesExpr -Lines @(
        (New-HitlLine 'estate.label.system_location'   "$S.system_location" -If "$S.system_location")
        (New-HitlLine 'estate.label.admin_access'      "$S.admin_access" -If "$S.admin_access")
        (New-HitlLine 'estate.label.backup_key_location' "$S.backup_key_location" -If "$S.backup_key_location")
        (New-HitlLine 'estate.label.restore_hint'      "$S.restore_hint" -If "$S.restore_hint")
        (New-HitlLine 'estate.label.hints'             "$S.notes" -If "$S.notes")
        (New-HitlNote -Key 'estate.note.unchanged_fields')
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1540, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 200) 'the set_system_profile action'
    $ifWriteOk = Build-If 'Write ok?' @(1980, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Set rejected' @(2200, 200) "={{ `$('Set profile (atomic)').item.json.reason }}"
    $ret = Build-Return @(2200, 0) @(
        ,@('ok','true','boolean')
        ,@('created', "={{ `$('Set profile (atomic)').item.json.created }}", 'boolean')
    )
    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(440, -280) `
        'core.fn_dry_run (DB ist das Gesetz)' `
        'Dry run = estate.fn_set_system_profile mit denselben Werten, immer zurückgerollt. ok:false (z. B. Person nicht erwachsen/berechtigt) -> Dry run rejected: KEINE Karte, card_sent:false + reason an den Agenten. ok:true -> Karte. Echte Exception -> Abbruch + errorWorkflow-Alarm. Der echte Write nach dem Tipp prüft erneut (Write ok?).' 300 400
    $stickyFn = Build-Sticky 'Singleton-UPSERT + adults_only + Grenzregel' @(1760, -280) `
        'estate.fn_set_system_profile (Haushalts-Singleton, atomar)' `
        'Schreibt estate.fn_set_system_profile atomar: UPSERT auf die EINE Haushalts-Zeile (scope=household, CHECK-fixiert -> strukturell 0/1 Zeile; created=true beim ersten Write) + partiell (COALESCE, nicht gesendet = unverändert). KEIN person_id/-Resolve (Household-Singleton). adults_only-DB-Backstop (Kind -> {ok:false} ohne Write). GRENZREGEL: nur Fundort-Verweise (backup_key-Offline-Kopie-FUNDORT, Admin/Restore-Weg) — NIE das Geheimnis selbst. updated_at pflegt der Touch-Trigger.' 260 560
    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifWriteOk, $errWrite, $ret, $stickyDry, $stickyFn)
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
            @( E 'Set profile (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set profile (atomic)'   = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Set rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_set_system_profile' $nodes $conns `
        @{ Category = 'register' }
}
