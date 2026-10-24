#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.career.tool_record_job_match (WS-2) -------------------------------
# Merkt eine MANUELL WEITERGELEITETE Stelle vor (source='forwarded'). NEUER Verb record_ (arch-challenge
# REJECT-mit-Notiz: idempotenter Tracking-Eintrag, UPSERT auf external_id -> bewusst nicht create_ [dessen
# lokaler Vertrag "nur NEUES + Pflicht-Dubletten-Node" widerspricht UPSERT] und nicht book_ [Finanz]).
# HITL owner_info (additiv, kein Identitaets-/Plan-Write). Cred = Haupt-RW (wie Core/Monitor/Guide-Tools;
# nur finance nutzt finance_rw, WS-B0). Nach dem Write: Zero-Spam-Angebot, den werktäglichen Job-Scan zu
# aktivieren (rem:on:score_jobs = nur fuer die Person selbst, Roter Faden Paket B) — neben /reminders der Chat-Pfad, den
# Scan fuer sich einzuschalten. Strukturell wie ein finance-Write-Tool (Resolve entfaellt -> direkter
# fn-Call), aber READ-frei: die Felder kommen aus der vom Advisor extrahierten Weiterleitung.
function Build-RecordJobMatch {
    $trig = Build-Trigger @('title', 'employer', 'location', 'url', 'external_id')

    # --- HITL approval gate (vor dem Write); approval_tier=owner_info injiziert build.ps1 (approval_matrix) ---
    # Strukturiertes Summary (Textkatalog): das Gate rendert es in der Sprache des Empfaengers.
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(420, 0) -Title 'career.hitl.record_job_match' -Lines @(
        (New-HitlLine 'career.label.job_title' "$S.title")
        (New-HitlLine 'career.label.employer'  "$S.employer")
        (New-HitlLine 'career.label.location'  "$S.location")
        (New-HitlLine 'career.label.link'      "$S.url")
    )
    $reqApproval = Build-CallWorkflow 'Request Approval' @(640, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(860, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1080, 200) 'the record_job_match action'

    # source FIX 'forwarded' (nie $fromAI); external_id optional (NULL -> reiner INSERT, kein Dedup).
    $record = Build-Pg 'Record match' @(1080, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'job_match_id')::bigint AS job_match_id, (r->>'created')::boolean AS created FROM career.fn_record_job_match(`$1::jsonb) AS r;" `
        ([ordered]@{
            source   = "'forwarded'"
            title    = '$(''Start'').item.json.title'
            employer = '$(''Start'').item.json.employer'
            location = '$(''Start'').item.json.location'
            url      = '$(''Start'').item.json.url'
            external_id    = '$(''Start'').item.json.external_id'
        })

    $ifWriteOk = Build-If 'Write ok?' @(1300, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Record rejected' @(1520, 240) "={{ `$('Record match').item.json.reason }}"

    # Zero-Spam-Angebot: nach erfolgreichem Vormerken den werktäglichen Job-Scan anbieten — aber NUR wenn der Notschalter
    # cron_enable.score_jobs an ist (sonst haette ein Einschalten keine Wirkung) UND er fuer DIESE
    # Person aus ist (Roter Faden Paket B: Job-Vorschlaege je Person, core.fn_reminder_allowed = Notschalter UND eigene
    # Einstellung). Der Knopf rem:on:score_jobs laeuft ueber den Registry-Handler core.fn_handle_reminder_cb und schaltet
    # NUR die Karten der tippenden Person ein (agent.reminder_prefs) — auch ein Mitglied kann ihn bedienen.
    # Textkatalog Phase C: im selben Read die Angebots-Texte in der Sprache des Absenders (core.fn_ui_texts_for).
    $readScan = Build-Pg 'Read scan flag' @(1520, 0) `
        ("=SELECT CASE WHEN COALESCE(core.fn_config_get('career', 'cron_enable', 'score_jobs'), 'false') <> 'true' " +
         "OR COALESCE(core.fn_reminder_allowed('score_jobs', agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}`$' " +
         "THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'person_id'), false) THEN 'true' ELSE 'false' END AS scan_on, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb(" +
         (Get-UiKeysSql @('career.offer.scan', 'career.offer.btn_scan')) + ")))->'t' AS t;") `
        ([ordered]@{ chat_id = "String(`$('Start').item.json.chat_id || '')" })
    $ifOffer = Build-If 'Offer scan?' @(1740, 0) "={{ `$('Read scan flag').item.json.scan_on !== 'true' }}" 'true' 'equals' 'boolean'
    $offerScan = New-TelegramInlineKeyboardSendNode 'Offer scan' @(1960, -160) `
        (Get-UiTextExpr "`$('Read scan flag').item.json.t" 'career.offer.scan') `
        @( @{ Text = (Get-UiTextExpr "`$('Read scan flag').item.json.t" 'career.offer.btn_scan'); Data = 'rem:on:score_jobs' } ) `
        -ChatIdExpr "={{ String(`$('Start').item.json.chat_id) }}"

    $ret = Build-Return @(2180, 0) @(
        ,@('ok','true','boolean')
        ,@('job_match_id', "={{ `$('Record match').item.json.job_match_id }}", 'number')
        ,@('created', "={{ `$('Record match').item.json.created }}", 'boolean')
    )

    $stickyBalance = Build-Sticky 'DB-Automatik (UPSERT)' @(1080, -220) `
        'career.fn_record_job_match (atomar, source=forwarded)' `
        'Schreibt career.fn_record_job_match atomar: UPSERT auf den partial-UNIQUE-Index external_id (Re-Forward derselben external_id aktualisiert; forwarded OHNE external_id = reiner INSERT, kein Dedup). updated_at pflegt der Trigger career.touch_updated_at. Korrigierbare Ablehnung (leerer Titel) -> {ok:false, reason} (kein RAISE/Owner-Alert). source ist FIX forwarded (nie $fromAI); der Cron-Pfad nutzt dieselbe fn mit source=bundesagentur + score.' 220 420

    $stickyOffer = Build-Sticky 'Doc Job-Scan-Angebot (rem:on)' @(1740, -360) `
        'Angebot an den Absender nach Write (Seitenkanal-Ausnahme, Muster publish_plan)' `
        'Nach erfolgreichem Vormerken UND wenn der Notschalter cron_enable.score_jobs an ist UND der Scan fuer DIESE Person aus ist (Read scan flag: Notschalter + core.fn_reminder_allowed(score_jobs, Person aus chat_id) -> Offer scan?; bei ausgeschaltetem Notschalter kein Angebot, ein Einschalten wirkte nicht): [Job-Suche aktivieren] (callback_data rem:on:score_jobs) -> generischer Dispatch -> core.fn_handle_reminder_cb -> agent.reminder_prefs der TIPPENDEN Person (Roter Faden Paket B: Job-Vorschläge je Person, auch für Mitglieder). Zero-Spam: für die Person schon an -> kein Angebot. Abschalten per Knopf an jeder Treffer-Karte (rem:off:score_jobs) oder in /reminders; der Notschalter für alle bleibt die Konsole (lifeagents config set cron_enable score_jobs false). Return liest die Post-State-Felder explizit aus Record match.' 320 540

    $nodes = @($trig, $summary, $reqApproval, $ifApproved, $retCancelled, $record,
               $ifWriteOk, $errWrite, $readScan, $ifOffer, $offerScan, $ret,
               $stickyBalance, $stickyOffer)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Build Approval Summary' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Record match' ),
            @( E 'Return cancelled' )
        ) }
        'Record match'           = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Read scan flag' ),
            @( E 'Record rejected' )
        ) }
        'Read scan flag'         = @{ main = @( ,@( E 'Offer scan?' ) ) }
        'Offer scan?'            = @{ main = @(
            @( E 'Offer scan' ),   # [true] scan aus -> anbieten -> Return
            @( E 'Return' )        # [false] schon an -> direkt Return
        ) }
        'Offer scan'             = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.career.tool_record_job_match' $nodes $conns `
        @{ Category = 'job_search' }
}
