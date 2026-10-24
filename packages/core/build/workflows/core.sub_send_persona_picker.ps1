#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_persona_picker (Bot-Persona je Person per Knopf) -------
# Schickt EINE Karte "Wie soll ich mit dir sprechen?" mit je einem Knopf pro Persona (Name aus dem Textkatalog in der
# Sprache der Person, aktuelle Persona mit ✓) an chat_id. Der Tipp (callback_data persona:<person_id>:<code>) laeuft
# ueber den generischen Callback-Dispatch (core.callback_handlers 'persona' -> agent.fn_set_person_persona; Owner jede
# Person, Mitglied nur sich selbst). Analog core.sub_send_language_picker: deterministisch, KEIN LLM, sendet selbst.
# Abweichung vom Sprach-Picker: nur EIN Modus (die Person waehlt fuer sich) und die Frage nur in IHRER Sprache — die
# Persona aendert die Sprache nicht, die Person kann die Karte also lesen.
# Aufrufer: der Orchestrator bei /persona.
#
# Eingang: person_id (wessen Persona, zugleich Sprach-Quelle), chat_id (Empfaenger der Karte). Ablauf:
#   Start -> Load picker text (core_ro: Frage + Knopf-Namen + aktuelle Persona) -> Send persona picker (Inline-
#   Knoepfe build-time aus dem Core-Manifest personas.list = die EINE Liste; 2 je Zeile, damit lange Namen passen).
# n8n-Inline-Keyboard = statische fixedCollection -> Knopf-Anzahl/-Reihenfolge build-time; Laufzeit sind nur die
# person_id im callback_data, der Knopf-Text aus der t-Map und die ✓-Markierung.
function Build-CoreSubSendPersonaPicker {
    $CRED_PG_RO = $CRED_CORE_RO
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $personas = @((([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $u8) | ConvertFrom-Json).personas.list) | Sort-Object ord)
    if ($personas.Count -eq 0) { throw 'core.sub_send_persona_picker: Core-Manifest personas.list ist leer' }
    $nameKeys = @($personas | ForEach-Object { "core.persona.name.$($_.code)" })

    $trig = Build-Trigger @('person_id')   # chat_id (Empfaenger) ergaenzt Build-Trigger

    # Sprache = die der Person (agent.fn_person_lang: eigene -> Owner -> en). current = gespeicherte Persona, fehlt
    # der Key -> neutral (dieselbe Regel wie agent.fn_resolve_sender).
    $load = Build-Pg 'Load picker text' @(220, 0) `
        ("=SELECT core.fn_ui_text('core.persona.picker', y.lang) AS text, " +
         "core.fn_ui_texts(y.lang, $(Get-UiKeysSql $nameKeys)) AS t, " +
         "COALESCE((SELECT pp->>'persona' FROM agent.core_contexts c, " +
         "jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp WHERE c.name = 'family' " +
         "AND pp->>'person_id' = (`$1::jsonb)->>'person_id' LIMIT 1), 'neutral') AS current " +
         "FROM (SELECT agent.fn_person_lang((`$1::jsonb)->>'person_id')->>'lang' AS lang) y;") `
        ([ordered]@{
            person_id = "`$('Start').item.json.person_id"
        })
    $load.credentials = @{ postgres = $CRED_PG_RO }

    $buttons = @($personas | ForEach-Object {
        $key = "core.persona.name.$($_.code)"
        @{ Text = "={{ (`$json.current === '$($_.code)' ? '✓ ' : '') + $(Get-UiTextJs '$json.t' $key) }}"
           Data = "={{ 'persona:' + `$('Start').item.json.person_id + ':$($_.code)' }}" }
    })
    $rows = @()
    for ($i = 0; $i -lt $buttons.Count; $i += 2) { $rows += ,@($buttons[$i..([Math]::Min($i + 1, $buttons.Count - 1))]) }
    $send = New-TelegramInlineKeyboardSendNode 'Send persona picker' @(440, 0) "={{ `$json.text }}" -Rows $rows `
        -ChatIdExpr "={{ `$('Start').item.json.chat_id }}"

    $sticky = Build-Sticky 'Doc: Überblick' @(-40, -300) -Header 'Ablauf' `
        'core.sub_send_persona_picker — Bot-Persona je Person per Knopf' `
        'Deterministisch, kein LLM. Eingang person_id + chat_id. Load picker text holt in der Sprache der Person (agent.fn_person_lang) die Frage core.persona.picker, die Knopf-Namen core.persona.name.<code> als t-Map und die aktuelle Persona (fehlt -> neutral). Send persona picker: ein Knopf je Persona (build-time aus dem Core-Manifest personas.list, 2 je Zeile), die aktuelle mit ✓, callback_data persona:<person_id>:<code>. Gespeichert wird nur der Tipp: generischer Callback-Dispatch -> agent.fn_set_person_persona (Owner jede Person, Mitglied nur sich selbst; neutral = Key entfernt; Toast in der Sprache des Tippenden). Wirkung: der Orchestrator liest die Persona per agent.fn_resolve_sender als Runtime-Flag persona (Rahmen-Regeln persona_styles.md); Fach-Agenten und feste Texte sehen sie nie. Aufrufer: Orchestrator /persona.' 300 520

    $nodes = @($trig, $load, $send, $sticky)
    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Load picker text' ) ) }
        'Load picker text' = @{ main = @( ,@( E 'Send persona picker' ) ) }
    }
    return Build-Workflow 'core.sub_send_persona_picker' $nodes $conns
}
