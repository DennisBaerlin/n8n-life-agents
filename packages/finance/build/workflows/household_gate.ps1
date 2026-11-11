#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Def-Discovery nimmt jede Datei unter build/workflows/; ein Helfer, kein Build-*).
# --- Tor "Haushalts-Sicht" vor agent.finance und agent.finance_advisor ---
# Nur owner/partner sehen die Haushaltsfinanzen im Chat (Regel der Mini-App, core.fn_app_sees_household). Die Entscheidung
# trifft allein finance.fn_sender_sees_household (Test-chat_ids durchgelassen); der Graph liest sie VOR jedem LLM-Lauf.
# Fail-closed: nur sees === true laesst durch, ohne onError -> ein Lesefehler stoppt den Lauf (errorWorkflow alarmiert),
# statt Daten zu zeigen (anders als die fail-open Paket-Gates, weil hier Privatsphaere auf dem Spiel steht).
# Haupt-Credential wie 'Onboarding gate read' des Beraters: die fn ist REVOKE PUBLIC, die engen Paket-Rollen haben kein EXECUTE.
function New-FinanceHouseholdGate {
    param(
        [Parameter(Mandatory)][string]$StartNode,
        [Parameter(Mandatory)][string]$NextNode,
        [Parameter(Mandatory)][int[]]$ReadPos,
        [Parameter(Mandatory)][int[]]$GatePos,
        [Parameter(Mandatory)][int[]]$DenyPos
    )
    $keys = Get-UiKeysSql @('finance.gate.household_only')
    $read = Build-Pg 'Household view read' $ReadPos `
        ("=SELECT finance.fn_sender_sees_household((`$1::jsonb)->>'chat_id') AS sees, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb($keys)))->'t' AS t;") `
        ([ordered]@{ chat_id = "String(`$('$StartNode').item.json.chat_id || '')" })
    $gate = Build-If 'Household view gate' $GatePos "={{ `$('Household view read').item.json.sees === true }}" 'true' 'equals' 'boolean'
    $deny = Build-Set 'Household view denied' $DenyPos @(
        ,@('ok', 'false', 'boolean')
        ,@('output', ('={{ ' + (Get-UiTextJs "`$('Household view read').item.json.t" 'finance.gate.household_only') + ' }}'), 'string')
    )
    $sticky = Build-Sticky 'Doc: Haushalts-Sicht' @(($ReadPos[0] - 40), ($ReadPos[1] - 420)) `
        'Tor Haushalts-Sicht (vor dem LLM)' `
        'Household view read fragt finance.fn_sender_sees_household(chat_id): owner/partner (Regel der Mini-App, core.fn_app_sees_household) oder nicht-numerische Test-chat_id -> true. Household view gate: nur true laesst weiter, sonst Household view denied {ok:false, output = finance.gate.household_only in der Sprache des Absenders}; kein LLM, kein Werkzeug, keine Karte. Fail-closed: kein onError, ein Lesefehler stoppt den Lauf. Andere Wege eines Kindes zu Finanzdaten (Guide, Monitor, Kontexte anderer Pakete) deckt dieses Tor nicht ab.' 300 380
    $conns = [ordered]@{}
    $conns['Household view read'] = @{ main = @( ,@( E 'Household view gate' ) ) }
    $conns['Household view gate'] = @{ main = @(
        @( E $NextNode ),               # true: owner/partner/Test -> weiter
        @( E 'Household view denied' )  # false: fester Hinweis, Ende
    ) }
    @{ Nodes = @($read, $gate, $deny, $sticky); Connections = $conns; EntryNode = 'Household view read' }
}
