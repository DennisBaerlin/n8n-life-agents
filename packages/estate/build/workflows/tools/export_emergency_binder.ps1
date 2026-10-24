#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_export_emergency_binder (WS-5, Verb export_ = gegateter Read-EGRESS) ------
# Der GROESSTE PII-Egress des Systems: die GANZE Nachlass-Registratur als EIN weiterleitbares Telegram-
# DOKUMENT, damit der ueberlebende Partner alles hat — selbst wenn das System aus ist / beide Partner
# betroffen sind (Owner-Entscheid 8). ERSTES gegatetes READ-Tool (bewusste Ausnahme von "HITL nur vor
# Writes" — der EGRESS wird bestaetigt). Break-Glass: HITL owner_info (Floor 0; owner_approval wuerde bei
# totem Owner DEADLOCKen) + adults_only. Maskierungs-Option (mask_sensitive -> Steuer-ID/RV-Nr. redigiert).
# adults_only DOPPELT: n8n-IF 'Adult?' als UX-Pre-Gate (spart den HITL-Tap) + fn-interner RAISE-Backstop
# (DB-ist-Gesetz). Egress-Pfad: fn_render_emergency_binder -> Convert to File (.md-Binary) -> sendDocument.
# Cred = estate_rw (hat EXECUTE auf core.fn_check_write_permission + Blanket-Grant auf die DEFINER-Binder-fn).
function Build-EstateExportEmergencyBinder {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('mask_sensitive')

    # adults_only-Pre-Gate (UX: blockt VOR dem HITL, spart den Tap; der fn-RAISE ist der DB-Backstop).
    $checkAdult = Build-Pg 'Check adult' @(220, 0) `
        "=SELECT (core.fn_check_write_permission('adults_only', (`$1::jsonb)->>'chat_id', NULL) IS NULL) AS is_adult;" `
        ([ordered]@{ chat_id = '$(''Start'').item.json.chat_id' })
    $ifAdult = Build-If 'Adult?' @(440, 0) "={{ `$('Check adult').item.json.is_adult }}" 'true' 'equals' 'boolean'
    $errChild = Build-ToolError 'Not adult' @(660, 200) `
        '=Only adult household members (owner/partner) may export the emergency binder.'

    $maskExpr = '(String($(''Start'').item.json.mask_sensitive) === "true")'
    # Strukturiertes Summary (Textkatalog): Keys + typisierte Rohwerte, das Gate rendert je Empfaenger-Sprache.
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'estate.hitl.export_emergency_binder' -Lines @(
        (New-HitlLine 'estate.label.scope'         "'estate.value.binder_scope'" -Kind key)
        (New-HitlLine 'estate.label.sensitive_ids' "($maskExpr ? 'estate.value.masked' : 'estate.value.fully_visible')" -Kind key)
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the export_emergency_binder action'

    # Render (DEFINER-fn -> sieht finance; adults_only-RAISE-Backstop drin) -> Text im Feld 'binder'.
    # Textkatalog Phase C: Mappe in der Sprache der ANFORDERNDEN Person (die fn), Begleitzeile + Dateiname im selben
    # Read ueber core.fn_ui_texts_for (an estate_rw gegrantet).
    $render = Build-Pg 'Render binder' @(1320, 0) `
        ("=SELECT estate.fn_render_emergency_binder(`$1::jsonb) AS binder, core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb(" +
         (Get-UiKeysSql @('estate.binder.caption', 'estate.binder.file_name')) + ")))->'t' AS t;") `
        ([ordered]@{
            chat_id        = '$(''Start'').item.json.chat_id'
            mask_sensitive = '$(''Start'').item.json.mask_sensitive'
        })
    # Convert to File: den Register-Text als .md-Binary ('data') — Input fuer sendDocument.
    $toFile = [ordered]@{
        parameters = [ordered]@{
            operation          = 'toText'
            sourceProperty     = 'binder'
            binaryPropertyName = 'data'
            options            = [ordered]@{ fileName = (Get-UiTextExpr "`$('Render binder').item.json.t" 'estate.binder.file_name'); encoding = 'utf8' }
        }
        type = 'n8n-nodes-base.convertToFile'; typeVersion = 1.1; position = @(1540, 0)
        id = (New-Id); name = 'Convert to File'
    }
    $send = New-TelegramSendDocumentNode 'Send binder' @(1760, 0) `
        -ChatIdExpr "={{ `$('Start').item.json.chat_id }}" -BinaryProperty 'data' `
        -Caption (Get-UiTextExpr "`$('Render binder').item.json.t" 'estate.binder.caption')
    $ret = Build-Return @(1980, 0) @(
        ,@('ok','true','boolean')
        ,@('sent','true','boolean')
    )

    $stickyGate = Build-Sticky 'Gegateter Read-Egress + Break-Glass + Maskierung' @(220, -300) `
        'export_emergency_binder (erster gegateter READ-Egress, owner_info Break-Glass)' `
        'GRÖSSTER PII-Egress: das GANZE Register als weiterleitbares Telegram-Dokument (Owner-Entscheid 8). adults_only DOPPELT: n8n-IF Adult? (UX-Pre-Gate vor dem HITL) + fn-interner RAISE (DB-Backstop, entkoppelt vom Tool). HITL owner_info = Break-Glass (Floor 0; owner_approval deadlockte bei totem Owner). Maskierung mask_sensitive -> Steuer-ID/RV-Nr. redigiert (Default voll). Egress: estate.fn_render_emergency_binder (DEFINER -> sieht finance) -> Convert to File (.md-Binary Feld data) -> Telegram sendDocument (caption plain). Kein Write -> Audit = HITL-Tap + Chat-History (Projekt-Stance). estate_rw hat EXECUTE (Fenster + Blanket-Grant).' 300 620
    $nodes = @($trig, $checkAdult, $ifAdult, $errChild, $summary, $reqApproval, $ifApproved,
               $retCancelled, $render, $toFile, $send, $ret, $stickyGate)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Check adult' ) ) }
        'Check adult'            = @{ main = @( ,@( E 'Adult?' ) ) }
        'Adult?'                 = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Not adult' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Render binder' ),
            @( E 'Return cancelled' )
        ) }
        'Render binder'          = @{ main = @( ,@( E 'Convert to File' ) ) }
        'Convert to File'        = @{ main = @( ,@( E 'Send binder' ) ) }
        'Send binder'            = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.estate.tool_export_emergency_binder' $nodes $conns `
        @{ Category = 'register' }
}
