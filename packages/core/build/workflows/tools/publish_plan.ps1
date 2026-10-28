#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_publish_plan (CROSS-AGENT, HITL-Write) ----------------------
# Publiziert den Draft-Plan der Domain: Vorgaenger -> superseded, Draft -> active,
# Domänen-Plan-Doc (finance -> 'financial_planning', WS-B2c) upserted (lazy/global, Spalte
# managed_by='agent' -> Seeder fasst die Zeile nie an) — alles EINE Transaktion in
# agent.fn_advisor_publish_plan. domain ist beim Aufrufer fixer Binding-Input.
# Die Approval-Summary erklaert das WAS (Versionen aus der DB gelesen, nicht vom LLM
# gerechnet; change_summary liefert der Agent) — nie nur "Plan speichern?".
function Build-PublishPlan {
    $trig = Build-Trigger @('domain', 'plan_md', 'plan_name', 'change_summary', 'context_description')

    # Read-only Pre-State: Context-Name (m2: domaenenneutral aus core.advisors.plan_context, NICHT hardcoded
    # financial_planning) + Draft-/Active-Version + Sektionszahl aus der DB (LLM rechnet nicht). P0c person-
    # skopiert (wie der Write fn_advisor_publish_plan): per_user-Domain -> Vorschau des SENDER-Plans
    # (fn_resolve_sender(chat_id), Numerik-Guard); household -> person_id NULL. Multi-Person = P2.
    $readState = Build-Pg 'Read plan state' @(220, 0) @'
=WITH r AS (
  SELECT COALESCE((SELECT a.plan_context FROM core.advisors a WHERE a.domain = ($1::jsonb)->>'domain'),
                  (($1::jsonb)->>'domain') || '_planning') AS ctx,
         ($1::jsonb)->>'domain' AS dom, ($1::jsonb)->>'chat_id' AS cid
), s AS (
  SELECT r.ctx, r.dom, r.cid,
         COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = r.ctx),'household') AS scope
  FROM r
), p AS (
  SELECT s.ctx, s.dom, s.scope,
         CASE WHEN s.scope = 'per_user' AND s.cid ~ '^[0-9]+$'
              THEN agent.fn_resolve_sender(s.cid::bigint) ->> 'person_id' ELSE NULL END AS pid
  FROM s
)
SELECT p.ctx AS context_name, p.scope AS scope, d.version AS draft_version,
       (SELECT count(*)::int FROM jsonb_object_keys(d.interview_state)) AS section_count, a.version AS active_version
FROM p
LEFT JOIN agent.advisor_plans d ON d.domain = p.dom AND d.person_id IS NOT DISTINCT FROM p.pid AND d.status = 'draft'
LEFT JOIN agent.advisor_plans a ON a.domain = p.dom AND a.person_id IS NOT DISTINCT FROM p.pid AND a.status = 'active';
'@ `
        ([ordered]@{ domain = '$(''Start'').item.json.domain'; chat_id = '$(''Start'').item.json.chat_id' })

    $ifDraft = Build-If 'Draft exists?' @(440, 0) '={{ $json.draft_version != null }}' 'true' 'equals' 'boolean'

    $errNoDraft = Build-ToolError 'No draft' @(660, -200) `
        "=No draft plan exists for domain '{{ `$('Start').item.json.domain }}'. Save at least one section via the tool_save_plan_section tool before publishing."

    # Strukturiertes Summary (Textkatalog): Versionen aus der DB (nie vom LLM gerechnet), Satz-Vorlagen je Fall.
    $R = "`$('Read plan state').item.json"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'core.hitl.publish_plan' -Lines @(
        (New-HitlLine 'core.label.version' "($R.active_version != null ? 'core.tpl.plan_version_replaces' : 'core.tpl.plan_version_first')" `
            -Kind tpl -Params @{ draft = "$R.draft_version"; active = "$R.active_version" })
        (New-HitlLine 'core.label.sections' "$R.section_count")
        (New-HitlLine 'core.label.changes'  "`$('Start').item.json.change_summary")
        (New-HitlLine 'core.label.context_doc' "($R.scope === 'per_user' ? 'core.tpl.plan_doc_personal' : 'core.tpl.plan_doc_shared')" `
            -Kind tpl -Params @{ name = "$R.context_name" })
    )

    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1100, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the publish_plan action'

    $publish = Build-Pg 'Publish plan (atomic)' @(1320, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'plan_id')::int AS plan_id, (r->>'version')::int AS version, (r->>'superseded_plan_id')::int AS superseded_plan_id, r->>'context_name' AS context_name, (r->>'section_count')::int AS section_count FROM agent.fn_advisor_publish_plan(`$1::jsonb) AS r;" `
        ([ordered]@{
            domain              = '$(''Start'').item.json.domain'
            plan_md             = '$(''Start'').item.json.plan_md'
            plan_name           = '$(''Start'').item.json.plan_name'
            context_description = '$(''Start'').item.json.context_description'
            change_summary      = '$(''Start'').item.json.change_summary'   # Plan teilen: Provenienz der Version (+ Owner-Sprache in der fn)
            chat_id             = '$(''Start'').item.json.chat_id'   # WS-5b: owner_only-Backstop (fn_sender_is_member)
        })

    $ifOk = Build-If 'Write ok?' @(1540, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Publish rejected' @(1760, 200) "={{ `$('Publish plan (atomic)').item.json.reason }}"

    # WS-3 Phase A / Phase 0 (Cron-Toggle-Vereinheitlichung): nach erfolgreichem Publish EINMALIG die zwei
    # Plan-Waechter-Crons zur Aktivierung anbieten — der Publish ist der "Setup"-Moment (alle Crons starten
    # AUS). Owner-Modell (gelockt 2026-06-28): beim Setup AKTIVIEREN (cron_on:<key>), zur Laufzeit am Nudge
    # ABSCHALTEN (cron_off:<key>), RE-AKTIVIEREN danach per /reminders (Paket B). ZWEI getrennte Knoepfe, unabhaengig
    # schaltbar (Owner-Entscheid): drift_check (taegliche Abweichungs-Pruefung) + plan_review (regelmaessiger
    # Auffrischungs-Bericht) — der frueher 1-Knopf-Stand versprach beides im Text, schaltete aber nur drift_check.
    # Angebot nur wenn MINDESTENS EINER aus ist (kein Spam bei Re-Publish wenn beide schon an; idempotent re-tap).
    # BEWUSSTE enge Ausnahme zu "tool = keine Seitenkanal-I/O": ein Owner-Notify (kein Domaenen-I/O).
    # Owner-Auth: nur der Owner publiziert (owner_only-Backstop in fn_advisor_publish_plan).
    # Textkatalog Phase C: im selben Read die Angebots-Texte in der Sprache des Absenders (core.fn_ui_texts_for).
    $readCron = Build-Pg 'Read monitor state' @(1980, 0) `
        ("=SELECT COALESCE((SELECT value FROM core.config WHERE category='cron_enable' AND key='drift_check'),'false') AS drift_on, COALESCE((SELECT value FROM core.config WHERE category='cron_enable' AND key='plan_review'),'false') AS review_on, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb(" +
         (Get-UiKeysSql @('core.offer.monitoring', 'core.offer.btn_drift', 'core.offer.btn_review')) + ")))->'t' AS t;") `
        ([ordered]@{ chat_id = "String(`$('Start').item.json.chat_id || '')" })
    $ifMonitorOff = Build-If 'Monitor off?' @(2200, 0) `
        "={{ `$('Read monitor state').item.json.drift_on !== 'true' || `$('Read monitor state').item.json.review_on !== 'true' }}" 'true' 'equals' 'boolean'
    $offerMonitor = New-TelegramInlineKeyboardSendNode 'Offer monitoring' @(2420, -160) `
        (Get-UiTextExpr "`$('Read monitor state').item.json.t" 'core.offer.monitoring') `
        @( @{ Text = (Get-UiTextExpr "`$('Read monitor state').item.json.t" 'core.offer.btn_drift'); Data = 'cron_on:drift_check' },
           @{ Text = (Get-UiTextExpr "`$('Read monitor state').item.json.t" 'core.offer.btn_review'); Data = 'cron_on:plan_review' } )
    $offerMonitor['onError'] = 'continueRegularOutput'   # das Publish ist schon geschehen: ein Send-Fehler darf es nie gescheitert aussehen lassen

    # Plan teilen (2026-10-28): Owner-Karte "Erwachsene informieren?" — nur fuer einen Haushalts-Plan mit Empfaengern
    # (core.fn_plan_share_preview: Owner, Version = aktive, mind. ein Partner mit Chat und nicht abgemeldet). Der Knopf
    # plan:share:<domain>:<version> geht ueber core.fn_handle_plan_cb an den Sub core.sub_share_plan. Texte in der Sprache
    # des Owners; onError continue (Komfort nach einem bereits erfolgreichen Publish).
    $readShare = Build-Pg 'Read share offer' @(2420, 160) `
        ("=SELECT core.fn_plan_share_preview((`$1::jsonb)->>'domain', NULLIF((`$1::jsonb)->>'version', '')::int, (`$1::jsonb)->>'chat_id')::text AS pv, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb(" +
         (Get-UiKeysSql @('core.plan_share.offer', 'core.plan_share.btn_inform')) + ")))->'t' AS t;") `
        ([ordered]@{
            domain  = "String(`$('Start').item.json.domain || '')"
            version = "String(`$('Publish plan (atomic)').item.json.version || '')"
            chat_id = "String(`$('Start').item.json.chat_id || '')"
        })
    $readShare['onError'] = 'continueRegularOutput'
    $PV = "JSON.parse(`$('Read share offer').item.json.pv || '{}')"
    $ifShare = Build-If 'Share offer?' @(2640, 160) "={{ $PV.shareable === true }}" 'true' 'equals' 'boolean'
    $offerShare = New-TelegramInlineKeyboardSendNode 'Offer share' @(2860, 60) `
        (Get-UiTextExpr "`$('Read share offer').item.json.t" 'core.plan_share.offer' @{ names = "($PV.names || []).join(', ')" }) `
        @( @{ Text = (Get-UiTextExpr "`$('Read share offer').item.json.t" 'core.plan_share.btn_inform');
              Data = "={{ 'plan:share:' + String(`$('Start').item.json.domain || '') + ':' + String(`$('Publish plan (atomic)').item.json.version || '') }}" } )
    $offerShare['onError'] = 'continueRegularOutput'

    # Return liest die Post-State-Felder EXPLIZIT aus dem Publish-Node (zwischen Publish und Return liegt jetzt
    # das Monitor-Angebot-Gate -> $json traegt hier nicht mehr den Publish-Output).
    $ret = Build-Return @(3080, 0) @(
        ,@('ok','true','boolean')
        ,@('plan_id', "={{ `$('Publish plan (atomic)').item.json.plan_id }}", 'number')
        ,@('version', "={{ `$('Publish plan (atomic)').item.json.version }}", 'number')
        ,@('superseded_plan_id', "={{ `$('Publish plan (atomic)').item.json.superseded_plan_id || 0 }}", 'number')
        ,@('context_name', "={{ `$('Publish plan (atomic)').item.json.context_name }}", 'string')
        ,@('section_count', "={{ `$('Publish plan (atomic)').item.json.section_count }}", 'number')
    )

    $sticky = Build-Sticky 'Doc Publish Plan' @(120, -340) `
        'HITL + agent.fn_advisor_publish_plan (atomar, 3 Schritte)' `
        'Cross-agent (domain = fixer Binding-Input). fn_advisor_publish_plan in EINER Transaktion: (1) bisheriger active-Plan -> superseded (Versions-Audit, nie gelöscht), (2) Draft -> active + plan_md persistiert, (3) Domänen-Plan-Doc upserted (Context-Name aus core.advisors.plan_context der Domäne; content = neues plan_md + der UNVERÄNDERTE gespeicherte "## Gelernt"-Block [system-verwaltet, core.fn_split_learned_block; ein im plan_md mitgeschickter wird verworfen, auch im Versions-Audit]; lazy, agent_name=NULL, Spalte managed_by=agent -> der Seeder fasst es nie an; löschgeschützt via core.protected_contexts). P0c PERSON-SCOPE: Plan-Schlüssel (domain, person_id); household (finance) -> person_id NULL, Doc am Basis-Namen; per_user (career) -> person_id = Sender (own_user_only) aus chat_id, Doc suffigiert <base>__<pid>. Read plan state (read-only) ist domänenneutral + person-skopiert (Vorschau = der Write). Ein aktiver Plan pro (Domain, Person) = Partial-UNIQUE NULLS NOT DISTINCT (DB-Gesetz). Multi-Person-Fächerung = P2.' 320 480

    $stickyOffer = Build-Sticky 'Doc Monitor-Angebot (WS-3 Phase A / Phase 0)' @(1960, -360) `
        'Owner-Notify nach Publish (bewusste tool-Seitenkanal-Ausnahme)' `
        'Nach erfolgreichem Publish bietet das Tool die Plan-Wächter-Crons zur Aktivierung an — aber NUR wenn mindestens einer aus ist (Read monitor state liest drift_check + plan_review -> Monitor off? = drift_on!=true ODER review_on!=true -> Offer monitoring; kein Spam wenn beide schon an). ZWEI getrennte Knöpfe (Owner-Entscheid, Phase 0): "Abweichungs-Wächter an" (cron_on:drift_check) + "Quartals-Bericht an" (cron_on:plan_review), unabhängig schaltbar. Beide laufen in den Orchestrator-Callback -> core.fn_set_cron_enable (core.config cron_enable.<key>=true). Cron-Toggle-Modell (Owner, gelockt): SETUP=aktivieren (cron_on, hier am Publish), LAUFZEIT=abschalten (cron_off am Nudge), RE-AKTIVIEREN per /reminders (Roter Faden Paket B). Lint scripts/cron_toggle_lint.ps1 erzwingt je Cron beide Knöpfe. BEWUSSTE enge Ausnahme zu "tool = keine Seitenkanal-I/O": owner-facing Notify (kein Domänen-I/O). Return liest die Post-State-Felder explizit aus Publish plan (atomic).' 360 600

    $stickyShare = Build-Sticky 'Doc Erwachsene informieren (Plan teilen)' @(2400, -360) `
        'Owner-Karte nach dem Publish (Plan teilen, 2026-10-28)' `
        'Nach dem Monitor-Angebot (beide Ausgänge von Monitor off?) liest Read share offer core.fn_plan_share_preview(domain, neue Version, chat_id): shareable nur für den Owner, für die aktive Version eines Haushalts-Plans (persönliche Pläne nie) und wenn es mindestens einen Empfänger gibt (Rolle partner, mit Chat, plan_news nicht abgemeldet; Regel core.fn_plan_adult_recipients). Share offer? -> Offer share: Karte in der Sprache des Owners mit den Vornamen und dem Knopf Erwachsene informieren = plan:share:<domain>:<version> (Orchestrator: core.fn_handle_plan_cb -> core.sub_share_plan, einmal je Person und Version). change_summary geht in den Publish (fn speichert sie mit der Owner-Sprache als Provenienz). Alle drei Knoten und Offer monitoring laufen mit onError continue: das Publish ist zu diesem Zeitpunkt schon committet.' 360 560

    $nodes = @($trig, $readState, $ifDraft, $errNoDraft, $summary, $reqApproval, $ifApproved, $retCancelled, $publish, $ifOk, $errWrite,
               $readCron, $ifMonitorOff, $offerMonitor, $readShare, $ifShare, $offerShare, $ret, $sticky, $stickyOffer, $stickyShare)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read plan state' ) ) }
        'Read plan state'        = @{ main = @( ,@( E 'Draft exists?' ) ) }
        'Draft exists?'          = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'No draft' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Publish plan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Publish plan (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Read monitor state' ),   # [true] ok -> Monitor-Angebot-Gate, dann Return
            @( E 'Publish rejected' )      # [false] {ok:false} -> Tool-Error
        ) }
        'Read monitor state'     = @{ main = @( ,@( E 'Monitor off?' ) ) }
        'Monitor off?'           = @{ main = @(
            @( E 'Offer monitoring' ),     # [true] aus -> anbieten -> Share-Angebot
            @( E 'Read share offer' )      # [false] schon aktiv -> kein Monitor-Spam, weiter zum Share-Angebot
        ) }
        'Offer monitoring'       = @{ main = @( ,@( E 'Read share offer' ) ) }
        'Read share offer'       = @{ main = @( ,@( E 'Share offer?' ) ) }
        'Share offer?'           = @{ main = @(
            @( E 'Offer share' ),          # [true] Haushalts-Plan mit Empfaengern -> Owner-Karte -> Return
            @( E 'Return' )                # [false] persoenlicher Plan / niemand zu informieren -> Return
        ) }
        'Offer share'            = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.tool_publish_plan' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
