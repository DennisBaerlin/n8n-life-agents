#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_onboarding_progress (Roter Faden 2026-10-23) -------
# Die EINE Stelle, die nach einem Onboarding-Schritt die naechste Karte schickt — deterministisch statt LLM-Text.
# Aufgerufen von JEDEM tool_set_onboarding_section (core/finance/career/estate) ueber den Core-Dienst
# core:onboarding_progress (fire-and-forget, New-OnboardingProgressCallNode), aber NUR wenn der Schritt einen Bereich
# gerade geschlossen hat (area_completed_now aus core.fn_set_onboarding_section). Laeuft unter der Core-Cred.
#
# Eingang: chat_id (build-fix aus dem Tool, nie LLM), package, area_completed_now, area_all_skipped.
# Ablauf:
#   Area done? (nein -> Ende) -> Progress event (core.fn_onboarding_progress_event: Einmal-Latches all_done /
#   household_ready + Lern-Angebots-Entscheid; Texte des Angebots in der Sprache des Tippenden)
#   -> Send progress card (core.sub_send_onboarding_menu: Uebersicht mit Kopfzeile "<Bereich> eingerichtet" /
#      "uebersprungen" / "alles eingerichtet" + der bestehende Weiter-Knopf auf den naechsten offenen Abschnitt)
#   -> Learn offer? -> Offer learning (cron_on:learn_context, nur Owner, nur beim allerersten "alles eingerichtet",
#      nur wenn das Lernen aus ist — frueher kam das Angebot schon nach dem Haushalt und bei jedem Core-complete)
#   -> Members? -> je gepairtem Mitglied "Es kann losgehen" in SEINER Sprache (nur wenn der Haushalt mit diesem
#      Schritt fertig wurde, genau einmal ueberhaupt); gibt es persoenliche Bereiche (per_user), mit Knopf dorthin.
function Build-CoreSubOnboardingProgress {
    $start = [ordered]@{
        parameters  = [ordered]@{ workflowInputs = [ordered]@{ values = @(
            [ordered]@{ name = 'chat_id' }, [ordered]@{ name = 'package' },
            [ordered]@{ name = 'area_completed_now' }, [ordered]@{ name = 'area_all_skipped' } ) } }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(-1100, 0)
        id          = (New-Id)
        name        = 'Start'
    }

    $ifDone = Build-If 'Area done?' @(-880, 0) "={{ String(`$json.area_completed_now) === 'true' }}" 'true' 'equals' 'boolean'
    $nothing = Build-NoOp 'Nothing to do' @(-660, 200)

    # Einmal-Ereignisse (DB-Latches) + die Angebots-Texte des Tippenden in EINER Anweisung.
    $offerKeys = Get-UiKeysSql @('core.offer.learning', 'core.offer.btn_learning')
    $event = Build-Pg 'Progress event' @(-660, 0) `
        ("=SELECT core.fn_onboarding_progress_event(`$1::jsonb)::text AS ev, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb($offerKeys)))->'t' AS t;") `
        ([ordered]@{
            chat_id            = "String(`$('Start').item.json.chat_id || '')"
            package            = "String(`$('Start').item.json.package || '')"
            area_completed_now = 'true'
        })
    $event['onError'] = 'continueRegularOutput'

    # Karte: das bestehende Onboarding-Menue (Uebersicht) mit Kopfzeile je Ereignis. Fehler -> weiter (die Agent-
    # Antwort und das Menue per /onboarding bleiben der Rueckweg).
    $idMenu = Get-RequiredWorkflowId 'core.sub_send_onboarding_menu' -Caller 'Build-CoreSubOnboardingProgress'
    $card = Build-CallWorkflow 'Send progress card' @(-440, 0) $idMenu 'core.sub_send_onboarding_menu' ([ordered]@{
        chat_id   = "={{ `$('Start').item.json.chat_id }}"
        area      = ''
        done_area = "={{ `$('Start').item.json.package }}"
        done_mode = "={{ (JSON.parse(`$('Progress event').item.json.ev || '{}').send_all_done === true) ? 'all' : ((String(`$('Start').item.json.area_all_skipped) === 'true') ? 'skipped' : 'done') }}"
    })
    $card['onError'] = 'continueRegularOutput'

    $ifLearn = Build-If 'Learn offer?' @(-220, 0) `
        "={{ JSON.parse(`$('Progress event').item.json.ev || '{}').send_learn_offer === true }}" 'true' 'equals' 'boolean'
    $offer = New-TelegramInlineKeyboardSendNode 'Offer learning' @(0, -160) `
        (Get-UiTextExpr "`$('Progress event').item.json.t" 'core.offer.learning') `
        @( @{ Text = (Get-UiTextExpr "`$('Progress event').item.json.t" 'core.offer.btn_learning'); Data = 'cron_on:learn_context' } ) `
        -ChatIdExpr "={{ String(`$('Start').item.json.chat_id) }}"
    $offer['onError'] = 'continueRegularOutput'

    # Mitglieder: nur wenn das Ereignis welche nennt (sonst endet der Lauf an 'No members' MIT Item — ein Aufrufer,
    # der auf das Ergebnis wartet, bekaeme sonst "no item to return"). Danach eine Zeile je Telegram-id.
    $ifMembers = Build-If 'Members?' @(110, 0) `
        "={{ (JSON.parse(`$('Progress event').item.json.ev || '{}').member_chats || []).length > 0 }}" 'true' 'equals' 'boolean'
    $noMembers = Build-NoOp 'No members' @(330, 200)
    $splitJs = @'
let ev = {};
try { ev = JSON.parse($('Progress event').first().json.ev || '{}'); } catch (e) { ev = {}; }
const chats = Array.isArray(ev.member_chats) ? ev.member_chats : [];
return chats.map(c => ({ json: { chat_id: String(c), have_areas: ev.members_have_areas === true } }));
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(220, 0)
        id = (New-Id); name = 'Split members'
    }
    $readyKeys = Get-UiKeysSql @('core.onboarding.ready.member', 'core.onboarding.ready.member_areas', 'core.onboarding.ready.btn_areas')
    $memberTexts = Build-Pg 'Load member texts' @(440, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb($readyKeys)))->'t' AS t;") `
        ([ordered]@{ chat_id = "String(`$json.chat_id || '')" })
    $memberTexts['onError'] = 'continueRegularOutput'
    $ifAreas = Build-If 'Has own areas?' @(660, 0) "={{ `$('Split members').item.json.have_areas === true }}" 'true' 'equals' 'boolean'
    $memberChat = "={{ String(`$('Split members').item.json.chat_id) }}"
    $sendAreas = New-TelegramInlineKeyboardSendNode 'Send member ready (areas)' @(880, -120) `
        ("={{ " + (Get-UiTextJs "`$('Load member texts').item.json.t" 'core.onboarding.ready.member') + " + '\n\n' + " +
         (Get-UiTextJs "`$('Load member texts').item.json.t" 'core.onboarding.ready.member_areas') + " }}") `
        @( @{ Text = (Get-UiTextExpr "`$('Load member texts').item.json.t" 'core.onboarding.ready.btn_areas'); Data = 'onboarding:_area:' } ) `
        -ChatIdExpr $memberChat
    $sendAreas['onError'] = 'continueRegularOutput'
    $sendPlain = New-TelegramSendNode 'Send member ready' @(880, 120) `
        (Get-UiTextExpr "`$('Load member texts').item.json.t" 'core.onboarding.ready.member') -ChatIdExpr $memberChat
    $sendPlain['onError'] = 'continueRegularOutput'

    $sticky = Build-Sticky 'Überblick' @(-1140, -400) -Header 'Ablauf' `
        'core.sub_onboarding_progress — nächste Karte nach einem Onboarding-Schritt (deterministisch, kein LLM)' `
        'Gerufen von jedem tool_set_onboarding_section (core/finance/career/estate) über den Dienst core:onboarding_progress, fire-and-forget. Area done? = core.fn_set_onboarding_section meldete area_completed_now (der Schritt hat einen Bereich geschlossen; unter Advisory-Lock genau einmal je Übergang). Progress event = core.fn_onboarding_progress_event (DEFINER): Latches all_done:<pid> (re-armt, sobald wieder etwas offen ist) und household_ready (genau einmal überhaupt) in core.notification_state, Lern-Angebot nur Owner + Lernen aus. Send progress card = das Onboarding-Menü mit Kopfzeile (done_mode done/skipped/all) und dem Weiter-Knopf auf den nächsten offenen Abschnitt. Offer learning = cron_on:learn_context (zog aus agent.guide.tool_set_onboarding_section hierher: das Angebot kommt jetzt am Ende ALLER Bereiche und nur einmal). Members? (keine -> No members, Lauf endet mit Item) -> Split members -> je gepairtem Mitglied Es kann losgehen in seiner Sprache, mit Knopf onboarding:_area: wenn ein aktives per_user-Paket existiert. Jeder Send onError=continue: ein Telegram-Fehler darf den Onboarding-Schritt nie stören (der Agent und /onboarding bleiben der Rückweg).' 400 820

    $nodes = @($start, $ifDone, $nothing, $event, $card, $ifLearn, $offer, $ifMembers, $noMembers, $split, $memberTexts, $ifAreas, $sendAreas, $sendPlain, $sticky)
    $conns = [ordered]@{
        'Start'              = @{ main = @( ,@( E 'Area done?' ) ) }
        'Area done?'         = @{ main = @( @( E 'Progress event' ), @( E 'Nothing to do' ) ) }
        'Progress event'     = @{ main = @( ,@( E 'Send progress card' ) ) }
        'Send progress card' = @{ main = @( ,@( E 'Learn offer?' ) ) }
        'Learn offer?'       = @{ main = @( @( E 'Offer learning' ), @( E 'Members?' ) ) }
        'Offer learning'     = @{ main = @( ,@( E 'Members?' ) ) }
        'Members?'           = @{ main = @( @( E 'Split members' ), @( E 'No members' ) ) }
        'Split members'      = @{ main = @( ,@( E 'Load member texts' ) ) }
        'Load member texts'  = @{ main = @( ,@( E 'Has own areas?' ) ) }
        'Has own areas?'     = @{ main = @( @( E 'Send member ready (areas)' ), @( E 'Send member ready' ) ) }
    }
    return Build-Workflow 'core.sub_onboarding_progress' $nodes $conns
}
