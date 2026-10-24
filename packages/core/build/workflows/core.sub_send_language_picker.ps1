#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_language_picker (Textkatalog: Sprache je Person per Knopf) -------
# Schickt EINE Karte "In welcher Sprache soll <Name> feste Nachrichten bekommen?" mit je einem Knopf pro
# unterstuetzter Sprache (Eigenname, z. B. 한국어) an chat_id. Der Tipp (callback_data lang:<person_id>:<code>) laeuft
# ueber den generischen Callback-Dispatch (core.callback_handlers 'lang' -> agent.fn_set_person_language; Owner jede
# Person, Mitglied nur sich selbst). Analog core.sub_send_onboarding_menu: deterministisch, KEIN LLM, sendet selbst.
# Aufrufer: agent.tool_set_context_facts (neu angelegte Person ohne Sprache -> Karte an den Owner, Modus 'other'),
# der Orchestrator bei /language + /sprache (Modus 'self') und nach dem Owner-Confirm eines Mitglieds ohne eigene
# Sprache (Modus 'self' + suggest = Telegram-App-Sprache vom Einloesen).
#
# Eingang: person_id (wessen Sprache), chat_id (Empfaenger der Karte), mode ('self' | leer = 'other'), suggest
# (Sprach-Code, nur Markierung). Ablauf:
#   Start -> Load picker text (core_ro) -> Send language picker (Inline-Knoepfe build-time aus dem Core-Manifest
#   languages.list = die EINE Liste).
#   Modus 'other': Frage "In welcher Sprache soll <Name> …?" in der Sprache des EMPFAENGERS (core.lang.picker).
#   Modus 'self':  Frage core.lang.picker_self in ALLEN Katalogsprachen untereinander (vorgeschlagene zuerst) — wer
#                  seine Sprache waehlt, kann die aktuelle evtl. nicht lesen; so bleibt die Fallback-Kette unberuehrt
#                  und nichts wird ohne Tipp gespeichert.
# n8n-Inline-Keyboard = statische fixedCollection -> Knopf-Anzahl/-Reihenfolge build-time (Sprachliste ist build-time
# bekannt); Laufzeit sind nur die person_id im callback_data und die 👉-Markierung des Vorschlags im Knopf-Text.
function Build-CoreSubSendLanguagePicker {
    $CRED_PG_RO = $CRED_CORE_RO
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $langs = @((([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $u8) | ConvertFrom-Json).languages.list) | Sort-Object ord)
    if ($langs.Count -eq 0) { throw 'core.sub_send_language_picker: Core-Manifest languages.list ist leer' }

    $trig = Build-Trigger @('person_id', 'mode', 'suggest')   # chat_id (Empfaenger) ergaenzt Build-Trigger

    # 'other': Text in der Sprache des Empfaengers (Owner -> Owner-Sprache), Name der Zielperson als {name}. Nicht-
    # numerische chat_id (Test-Sentinel) -> fn_resolve_sender(NULL) -> Owner-Sprache. 'self': alle Sprachen.
    $load = Build-Pg 'Load picker text' @(220, 0) `
        ("=SELECT CASE WHEN (`$1::jsonb)->>'mode' = 'self' THEN " +
         "(SELECT string_agg(core.fn_ui_text('core.lang.picker_self', l.code), E'\n' " +
         "ORDER BY COALESCE(l.code = (`$1::jsonb)->>'suggest', false) DESC, l.ord) FROM core.ui_languages l) " +
         "ELSE core.fn_ui_text('core.lang.picker', " +
         "agent.fn_person_lang(agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}$' " +
         "THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'person_id')->>'lang', " +
         "jsonb_build_object('name', COALESCE((SELECT pp->>'first_name' FROM agent.core_contexts c, " +
         "jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp WHERE c.name = 'family' " +
         "AND pp->>'person_id' = (`$1::jsonb)->>'person_id' LIMIT 1), '?'))) END AS text;") `
        ([ordered]@{
            person_id = "`$('Start').item.json.person_id"
            chat_id   = "String(`$('Start').item.json.chat_id || '')"
            mode      = "String(`$('Start').item.json.mode || '')"
            suggest   = "String(`$('Start').item.json.suggest || '')"
        })
    $load.credentials = @{ postgres = $CRED_PG_RO }

    $buttons = @($langs | ForEach-Object {
        @{ Text = "={{ (String(`$('Start').item.json.suggest || '') === '$($_.code)' ? '👉 ' : '') + '$([string]$_.name)' }}"
           Data = "={{ 'lang:' + `$('Start').item.json.person_id + ':$($_.code)' }}" }
    })
    $send = New-TelegramInlineKeyboardSendNode 'Send language picker' @(440, 0) "={{ `$json.text }}" $buttons `
        -ChatIdExpr "={{ `$('Start').item.json.chat_id }}"

    $sticky = Build-Sticky 'Doc: Überblick' @(-40, -300) -Header 'Ablauf' `
        'core.sub_send_language_picker — Sprache je Person per Knopf' `
        'Deterministisch, kein LLM. Eingang person_id + chat_id + mode + suggest. Load picker text holt die Frage aus dem Textkatalog: Modus other (Owner wählt für eine Person) core.lang.picker in der Sprache des EMPFÄNGERS mit dem Vornamen der Zielperson; Modus self (die Person wählt für sich) core.lang.picker_self in ALLEN Katalogsprachen untereinander, die vorgeschlagene zuerst. Send language picker: ein Knopf je unterstützter Sprache (Eigenname, build-time aus dem Core-Manifest languages.list), der Vorschlag (suggest = Telegram-App-Sprache) mit 👉 markiert, callback_data lang:<person_id>:<code>. Gespeichert wird nur der Tipp: generischer Callback-Dispatch -> agent.fn_set_person_language (Owner jede Person, Mitglied nur sich selbst; Toast in der neuen Sprache). Aufrufer: agent.tool_set_context_facts (neue Person ohne Sprache, other), Orchestrator /language + /sprache (self) und nach dem Owner-Confirm eines Mitglieds ohne Sprache (self + suggest).' 300 560

    $nodes = @($trig, $load, $send, $sticky)
    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Load picker text' ) ) }
        'Load picker text' = @{ main = @( ,@( E 'Send language picker' ) ) }
    }
    return Build-Workflow 'core.sub_send_language_picker' $nodes $conns
}
