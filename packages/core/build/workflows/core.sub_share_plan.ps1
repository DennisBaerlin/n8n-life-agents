#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_share_plan (Plan teilen, 2026-10-28) -------
# Die EINE Stelle, die erwachsene Mitglieder ueber einen neuen Haushalts-Plan informiert — deterministisch, kein LLM.
# Aufgerufen vom Orchestrator nach dem Owner-Tipp plan:share:<domain>:<version> (core.fn_handle_plan_cb hat Owner +
# aktuelle Version geprueft). Laeuft unter der Core-Cred.
#
# Eingang: domain, version, chat_id (Tapper = Owner, build-fix aus dem Callback, nie LLM).
# Ablauf:
#   Load targets (core.fn_plan_share_targets, read-only: prueft erneut Owner/Version, liefert Empfaenger ohne Merker)
#   -> Split targets (ein Item je Empfaenger; keiner -> ein Skip-Item)
#   -> Has targets? -> Load member texts (Texte in der Sprache der Person) -> Send plan news (3 Knoepfe, onError continue)
#   -> Collect results (zugestellt vs. gescheitert) -> Mark delivered (core.fn_plan_share_mark: nur Zugestellte als
#      informiert merken) -> Result {ok, sent, failed, already, none, reason}; ohne Empfaenger direkt Result skip.
function Build-CoreSubSharePlan {
    $start = [ordered]@{
        parameters  = [ordered]@{ workflowInputs = [ordered]@{ values = @(
            [ordered]@{ name = 'domain' }, [ordered]@{ name = 'version' }, [ordered]@{ name = 'chat_id' } ) } }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(-1100, 0)
        id          = (New-Id)
        name        = 'Start'
    }

    # kill_switch = das Notschalter-Literal, das contract_lint (7) je cron_enable-Key in einem Postgres-Knoten verlangt;
    # wirksam ist er ueber die Empfaenger-Regel (core.fn_reminder_allowed in core.fn_plan_adult_recipients).
    $targets = Build-Pg 'Load targets' @(-880, 0) `
        ("=SELECT core.fn_plan_share_targets(`$1::jsonb)::text AS r, core.fn_config_get('core','cron_enable','plan_news') AS kill_switch;") `
        ([ordered]@{
            domain  = "String(`$('Start').item.json.domain || '')"
            version = "String(`$('Start').item.json.version || '')"
            chat_id = "String(`$('Start').item.json.chat_id || '')"
        })

    $splitJs = @'
let r = {};
try { r = JSON.parse($('Load targets').first().json.r || '{}'); } catch (e) { r = {}; }
const t = Array.isArray(r.targets) ? r.targets : [];
if (r.ok !== true || t.length === 0) { return [{ json: { skip: true } }]; }
return t.map(x => ({ json: { skip: false, person_id: String(x.person_id), chat_id: String(x.chat_id), lang: String(x.lang || ''),
  show_summary: x.show_summary === true, summary: String(r.summary || ''), version: Number(r.version), package: String(r.package || ''),
  domain: String($('Start').first().json.domain || '') } }));
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-660, 0)
        id = (New-Id); name = 'Split targets'
    }
    $ifTargets = Build-If 'Has targets?' @(-440, 0) "={{ `$json.skip !== true }}" 'true' 'equals' 'boolean'

    # Texte je Person in IHRER Sprache; Bereichsname <pkg>.package.name aller Plan-Pakete (build-time aus $AdvisorPlanStepList).
    $pkgNameKeys = @($AdvisorPlanStepList | ForEach-Object { "$($_.Package).package.name" } | Sort-Object -Unique)
    $msgKeys = Get-UiKeysSql (@('core.plan_share.member_title', 'core.plan_share.member_summary', 'core.plan_share.member_other_lang',
        'core.plan_share.btn_explain', 'core.plan_share.btn_wish', 'core.plan_share.btn_stop') + $pkgNameKeys)
    $memberTexts = Build-Pg 'Load member texts' @(-220, -120) `
        ("=SELECT core.fn_ui_texts(NULLIF((`$1::jsonb)->>'lang', ''), $msgKeys) AS t;") `
        ([ordered]@{ lang = "String(`$json.lang || '')" })
    $memberTexts['onError'] = 'continueRegularOutput'   # ohne Texte stehen die Katalog-Keys da; der Send geht trotzdem raus
    $T = "`$('Load member texts').item.json.t"
    $SP = "`$('Split targets').item.json"
    $area = "(($T || {})[$SP.package + '.package.name'] || $SP.package)"
    $text = "={{ " + (Get-UiTextJs $T 'core.plan_share.member_title' @{ area = $area; version = "$SP.version" }) + " + '\n\n' + (" +
            "$SP.show_summary ? " + (Get-UiTextJs $T 'core.plan_share.member_summary' @{ summary = "$SP.summary" }) + " : " +
            (Get-UiTextJs $T 'core.plan_share.member_other_lang') + ") }}"
    $send = New-TelegramInlineKeyboardSendNode 'Send plan news' @(0, -120) $text -Rows @(
        ,@( @{ Text = (Get-UiTextExpr $T 'core.plan_share.btn_explain'); Data = "={{ 'plan:explain:' + $SP.domain }}" } )
        ,@( @{ Text = (Get-UiTextExpr $T 'core.plan_share.btn_wish');    Data = "={{ 'plan:wish:' + $SP.domain }}" } )
        ,@( @{ Text = (Get-UiTextExpr $T 'core.plan_share.btn_stop');    Data = 'rem:off:plan_news' } )
    ) -ChatIdExpr "={{ String($SP.chat_id) }}"
    $send['onError'] = 'continueRegularOutput'   # ein gescheiterter Send (Bot blockiert) stoppt die anderen nicht

    $collectJs = @'
const sent = $input.all();
const targets = $('Split targets').all();
const delivered = [];
let failed = 0;
sent.forEach((it, i) => {
  const j = it.json || {};
  const pid = String(((targets[i] || {}).json || {}).person_id || '');
  if (j.error || j.ok === false || !(j.message_id || (j.result && j.result.message_id))) { failed++; }
  else if (pid) { delivered.push(pid); }
});
let r = {};
try { r = JSON.parse($('Load targets').first().json.r || '{}'); } catch (e) { r = {}; }
return [{ json: { ok: true, sent: delivered.length, delivered, failed, already: Number(r.already || 0),
  domain: String($('Start').first().json.domain || ''), plan_id: String(r.plan_id || '') } }];
'@
    $collect = [ordered]@{
        parameters = [ordered]@{ jsCode = $collectJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(220, -120)
        id = (New-Id); name = 'Collect results'
    }
    # Merken erst NACH dem Send (core.fn_plan_share_mark): nur zugestellte Nachrichten zaehlen als informiert.
    $mark = Build-Pg 'Mark delivered' @(440, -120) `
        "=SELECT core.fn_plan_share_mark(`$1::jsonb)::text AS r;" `
        ([ordered]@{
            domain     = "`$('Collect results').item.json.domain"
            plan_id    = "`$('Collect results').item.json.plan_id"
            person_ids = "`$('Collect results').item.json.delivered"
        })
    $mark['onError'] = 'continueRegularOutput'
    $resultSent = Build-Set 'Result sent' @(660, -120) @(
        ,@('ok', 'true', 'boolean')
        ,@('sent', "={{ `$('Collect results').item.json.sent }}", 'number')
        ,@('failed', "={{ `$('Collect results').item.json.failed }}", 'number')
        ,@('already', "={{ `$('Collect results').item.json.already }}", 'number')
        ,@('none', 'false', 'boolean')
        ,@('reason', '', 'string')
    )
    $LT = "JSON.parse(`$('Load targets').first().json.r || '{}')"
    $resultSkip = Build-Set 'Result skip' @(-220, 160) @(
        ,@('ok', "={{ $LT.ok === true }}", 'boolean')
        ,@('sent', '0', 'number')
        ,@('failed', '0', 'number')
        ,@('already', "={{ Number($LT.already || 0) }}", 'number')
        ,@('none', "={{ $LT.none === true }}", 'boolean')
        ,@('reason', "={{ String($LT.reason || '') }}", 'string')
    )

    $sticky = Build-Sticky 'Überblick' @(-1140, -420) -Header 'Ablauf' `
        'core.sub_share_plan — Erwachsene über einen neuen Haushalts-Plan informieren (deterministisch, kein LLM)' `
        'Gerufen vom Orchestrator nach dem Owner-Tipp plan:share:<domain>:<version> (core.fn_handle_plan_cb: Owner + aktuelle Version). Load targets = core.fn_plan_share_targets (read-only: prüft Owner/Version erneut, Empfänger-Regel core.fn_plan_adult_recipients: Rolle partner, mit Chat, plan_news nicht abgemeldet inkl. Notschalter; wer für diese plan_id schon gemerkt ist, zählt als already). Split targets -> je Empfänger ein Item (keiner -> Result skip mit already/none/reason für den Owner-Toast). Load member texts = Katalog in der Sprache der PERSON. Send plan news: Titel mit Bereich + Version, darunter die Änderungs-Zusammenfassung NUR wenn die Person die Sprache der gespeicherten Zusammenfassung spricht (show_summary; nie übersetzt), sonst der Hinweis, dass der Berater sie in ihrer Sprache erklärt; Knöpfe plan:explain:<domain>, plan:wish:<domain>, rem:off:plan_news (statisch, Abmelden; wieder an per /reminders). onError continue: ein gescheiterter Send stoppt die anderen nicht. Collect results zählt nur zugestellte Nachrichten; Mark delivered = core.fn_plan_share_mark merkt NUR die Zugestellten (Merker plan_news <pid>:<domain>:p<plan_id>, einmal je Plan-Version) -> Gescheiterte erreicht ein zweiter Owner-Tipp; stirbt der Lauf zwischen Send und Merken, kommt eine Nachricht im schlimmsten Fall doppelt (lieber doppelt als nie). Result sent/skip = Rückgabe an den Orchestrator (Toast an den Owner).' 420 900

    $nodes = @($start, $targets, $split, $ifTargets, $memberTexts, $send, $collect, $mark, $resultSent, $resultSkip, $sticky)
    $conns = [ordered]@{
        'Start'             = @{ main = @( ,@( E 'Load targets' ) ) }
        'Load targets'      = @{ main = @( ,@( E 'Split targets' ) ) }
        'Split targets'     = @{ main = @( ,@( E 'Has targets?' ) ) }
        'Has targets?'      = @{ main = @( @( E 'Load member texts' ), @( E 'Result skip' ) ) }
        'Load member texts' = @{ main = @( ,@( E 'Send plan news' ) ) }
        'Send plan news'    = @{ main = @( ,@( E 'Collect results' ) ) }
        'Collect results'   = @{ main = @( ,@( E 'Mark delivered' ) ) }
        'Mark delivered'    = @{ main = @( ,@( E 'Result sent' ) ) }
    }
    return Build-Workflow 'core.sub_share_plan' $nodes $conns
}
