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
    $trig = Build-Trigger @('domain', 'plan_md', 'plan_name', 'change_summary', 'context_description', 'check_findings', 'check_passes', 'reminders', 'declined', 'retire', 'watch_candidates')

    # Read-only Pre-State: Scope des Plan-Dokuments (m2: domaenenneutral aus core.advisors.plan_context, NICHT hardcoded
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
SELECT p.scope AS scope, d.version AS draft_version,
       (SELECT count(*)::int FROM jsonb_object_keys(d.interview_state)) AS section_count, a.version AS active_version
FROM p
LEFT JOIN agent.advisor_plans d ON d.domain = p.dom AND d.person_id IS NOT DISTINCT FROM p.pid AND d.status = 'draft'
LEFT JOIN agent.advisor_plans a ON a.domain = p.dom AND a.person_id IS NOT DISTINCT FROM p.pid AND a.status = 'active';
'@ `
        ([ordered]@{ domain = '$(''Start'').item.json.domain'; chat_id = '$(''Start'').item.json.chat_id' })

    $ifDraft = Build-If 'Draft exists?' @(440, 0) '={{ $json.draft_version != null }}' 'true' 'equals' 'boolean'

    $errNoDraft = Build-ToolError 'No draft' @(660, -200) `
        "=No draft plan exists for domain '{{ `$('Start').item.json.domain }}'. Save at least one section via the tool_save_plan_section tool before publishing."

    # "DB ist das Gesetz": agent.fn_advisor_publish_plan laeuft als Probelauf VOR der Karte; derselbe Param-Satz geht nach dem
    # Gate in den echten Write. Sonst lehnt die fn erst nach dem Tipp ab (Muster tool_save_plan_section, Befund 2026-11-02).
    $wg = New-FnWriteGate -Fn 'agent.fn_advisor_publish_plan' -DryPos @(660, 0) -WritePos @(1760, 0) `
        -WriteName 'Publish plan (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'plan_id')::int AS plan_id, (r->>'version')::int AS version, (r->>'superseded_plan_id')::int AS superseded_plan_id, r->>'context_name' AS context_name, (r->>'section_count')::int AS section_count, r->'sync' AS sync" `
        -Params ([ordered]@{
            domain              = '$(''Start'').item.json.domain'
            plan_md             = '$(''Start'').item.json.plan_md'
            plan_name           = '$(''Start'').item.json.plan_name'
            context_description = '$(''Start'').item.json.context_description'
            change_summary      = '$(''Start'').item.json.change_summary'   # Plan teilen: Provenienz der Version (+ Owner-Sprache in der fn)
            check_findings      = '$(''Start'').item.json.check_findings'   # Gesamtcheck (JSON-String, leer = nicht angegeben); Pflicht und Kartenzahlen entscheidet die fn
            check_passes        = '$(''Start'').item.json.check_passes'
            reminders           = '$(''Start'').item.json.reminders'          # Plan-Durchlauf (JSON-Strings, leer = nicht angegeben): core.fn_plan_sync in derselben Transaktion
            declined            = '$(''Start'').item.json.declined'
            retire              = '$(''Start'').item.json.retire'
            watch_candidates    = '$(''Start'').item.json.watch_candidates'
            chat_id             = '$(''Start'').item.json.chat_id'   # WS-5b: owner_only-Backstop (fn_sender_is_member)
        })

    # Strukturiertes Summary (Textkatalog): Versionen aus der DB (nie vom LLM gerechnet), Satz-Vorlagen je Fall.
    $R = "`$('Read plan state').item.json"
    # -RepeatKey: change_summary formuliert das Modell je Aufruf neu, gleich bleibt der Plan der Domain.
    $summary = New-HitlSummary -Pos @(1100, 0) -Title 'core.hitl.publish_plan' -LinesExpr $wg.CardLinesExpr `
        -RepeatKey "String(`$('Start').item.json.domain || '')" -Lines @(
        (New-HitlLine 'core.label.version' "($R.active_version != null ? 'core.tpl.plan_version_replaces' : 'core.tpl.plan_version_first')" `
            -Kind tpl -Params @{ draft = "$R.draft_version"; active = "$R.active_version" })
        (New-HitlLine 'core.label.sections' "$R.section_count")
        (New-HitlLine 'core.label.changes'  "`$('Start').item.json.change_summary")
        (New-HitlLine 'core.label.context_doc' "($R.scope === 'per_user' ? 'core.tpl.plan_doc_personal' : 'core.tpl.plan_doc_shared')" `
            -Kind tpl -Params @{ name = (Get-PlanNameValue "`$('Start').item.json.domain") })
    )

    $reqApproval = Build-CallWorkflow 'Request Approval' @(1320, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1540, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1760, 200) 'the publish_plan action'

    $ifOk = Build-If 'Write ok?' @(1980, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Publish rejected' @(2200, 200) "={{ `$('Publish plan (atomic)').item.json.reason }}"

    # Return liest die Post-State-Felder EXPLIZIT aus dem Publish-Node .
    $ret = Build-Return @(3520, 0) @(
        ,@('ok','true','boolean')
        ,@('plan_id', "={{ `$('Publish plan (atomic)').item.json.plan_id }}", 'number')
        ,@('version', "={{ `$('Publish plan (atomic)').item.json.version }}", 'number')
        ,@('superseded_plan_id', "={{ `$('Publish plan (atomic)').item.json.superseded_plan_id || 0 }}", 'number')
        ,@('context_name', "={{ `$('Publish plan (atomic)').item.json.context_name }}", 'string')
        ,@('section_count', "={{ `$('Publish plan (atomic)').item.json.section_count }}", 'number')
        ,@('sync', "={{ `$('Publish plan (atomic)').item.json.sync || null }}", 'object')
    )

    $sticky = Build-Sticky 'Doc Publish Plan' @(120, -340) `
        'HITL + agent.fn_advisor_publish_plan (atomar, 3 Schritte)' `
        'Cross-agent (domain = fixer Binding-Input). Dry run = dieselbe fn VOR der Karte, immer zurückgerollt (core.fn_dry_run): ok:false -> Dry run rejected, KEINE Karte, reason an den Berater; der echte Write prüft erneut. fn_advisor_publish_plan in EINER Transaktion: (1) bisheriger active-Plan -> superseded (Versions-Audit, nie gelöscht), (2) Draft -> active + plan_md persistiert, (3) Domänen-Plan-Doc upserted (Context-Name aus core.advisors.plan_context der Domäne; content = neues plan_md + der UNVERÄNDERTE gespeicherte "## Gelernt"-Block [system-verwaltet, core.fn_split_learned_block; ein im plan_md mitgeschickter wird verworfen, auch im Versions-Audit]; lazy, agent_name=NULL, Spalte managed_by=agent -> der Seeder fasst es nie an; löschgeschützt via core.protected_contexts). P0c PERSON-SCOPE: Plan-Schlüssel (domain, person_id); household (finance) -> person_id NULL, Doc am Basis-Namen; per_user (career) -> person_id = Sender (own_user_only) aus chat_id, Doc suffigiert <base>__<pid>. Read plan state (read-only) ist domänenneutral + person-skopiert (Vorschau = der Write). Ein aktiver Plan pro (Domain, Person) = Partial-UNIQUE NULLS NOT DISTINCT (DB-Gesetz). Multi-Person-Fächerung = P2. KARTE: zeigt den Plannamen aus dem Textkatalog (<domain>.plan.name) statt des Kontextnamens. GESAMTCHECK: check_findings ({text, outcome resolved|deferred|accepted} je Fund, [] = keine Funde) + check_passes gehen in die fn; ist core.config <paket>.advisor.final_check_required = true (finance), lehnt schon der Probelauf ohne Gesamtcheck oder mit einem Fund ohne outcome ab. Die fn speichert beides an der Version und liefert die Kartenzeilen (card_lines): Gesamtcheck mit den von der DB gezählten Punkten, Durchgängen, geklärt und bewusst offen, darunter jeder nicht geklärte Fund einzeln. SENDET NICHTS MEHR: Wächter-Angebot, Erwachsene informieren und Übergabe-Liste kommen aus der geführten Abfolge (core.sub_plan_rollout_next), immer nur eine Nachricht zur Zeit. PLAN-DURCHLAUF: reminders, declined, retire, watch_candidates gehen in dieselbe fn (core.fn_plan_sync vor Schritt 1, eine Transaktion); ihre Zeilen stehen in den card_lines, eine Karte für alles; reminders ist Pflicht, wenn das Paket advisor.plan_sync_required setzt. WIEDERHOL-SPERRE: repeat_key = Domain, nach Abbrechen kommt im selben Lauf keine zweite Karte, auch wenn change_summary anders lautet.' 320 540

    $nodes = @($trig, $readState, $ifDraft, $errNoDraft) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read plan state' ) ) }
        'Read plan state'        = @{ main = @( ,@( E 'Draft exists?' ) ) }
        'Draft exists?'          = @{ main = @(
            @( E 'Dry run' ),
            @( E 'No draft' )
        ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Publish plan (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Publish plan (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),               # [true] ok -> Rueckgabe; die Schritte danach sendet die gefuehrte Abfolge
            @( E 'Publish rejected' )      # [false] {ok:false} -> Tool-Error
        ) }
    }
    return Build-Workflow 'agent.tool_publish_plan' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
