#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_get_recurring_suggestions (Lese-Tool, kein HITL; "Import zuerst") ---
# Bank-Export (CSV/Excel, Profile in finance.fn_bank_export_profiles) ueber mehrere Monate -> wiederkehrende Zahlungen,
# die noch kein Dauerauftrag abdeckt, als Vorschlaege im Format der Write-Tools. Schreibt nichts: der Agent fragt je
# Vorschlag, angelegt wird ueber tool_create_recurring_payment / tool_create_recurring_transfer (Karte). Der geteilte
# Leser (../bank_export_table.ps1) holt die Datei; Rhythmus, Betrag, Tag, Startdatum und den Bekannt-Filter rechnet
# finance.fn_get_recurring_suggestions (kein LLM, die Datei geht nicht an Anthropic; die Rueckgabe traegt nur je Reihe
# Name, Gegen-IBAN und Betraege, nie Export-Zeilen).
function Build-GetRecurringSuggestions {
    $CRED_POSTGRES = $CRED_FINANCE_RO
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-GetRecurringSuggestions'
    $trig = Build-Trigger @('file_id', 'account_name')
    $reader = New-BankExportTableReader -FetchId $idFetch -OnTable 'Get suggestions'

    $sug = Build-Pg 'Get suggestions' @(1100, 0) "=SELECT finance.fn_get_recurring_suggestions(`$1::jsonb) AS r;" ([ordered]@{
        account_name = "`$('Start').first().json.account_name || null"
        table        = $reader.TableExpr
    })
    $ifOk = Build-If 'Suggestions ok?' @(1320, 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $R = "`$('Get suggestions').item.json.r"
    $err = Build-Set 'Export not usable' @(1540, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ $R.code }}", 'string')
        ,@('error', "={{ $R.reason }}", 'string')
        ,@('candidates', "={{ $R.candidates || [] }}", 'array')
        ,@('bank', "={{ $R.bank || '' }}", 'string')
        ,@('account_name', "={{ $R.account_name || '' }}", 'string')
    )
    $ret = Build-Return @(1540, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('account_name', "={{ $R.account_name }}", 'string')
        ,@('period_first', "={{ $R.period_first }}", 'string')
        ,@('period_last', "={{ $R.period_last }}", 'string')
        ,@('span_days', "={{ $R.span_days }}", 'number')
        ,@('hint', "={{ $R.hint || '' }}", 'string')
        ,@('reason', "={{ $R.reason || '' }}", 'string')
        ,@('suggestions', "={{ $R.suggestions || [] }}", 'array')
        ,@('known_elsewhere', "={{ $R.known_elsewhere || [] }}", 'array')
    )

    $sticky = Build-Sticky 'Überblick' @(220, -520) `
        'Daueraufträge aus einem Bank-Export vorschlagen (Lese-Tool, kein Write, kein LLM)' `
        'Fetch telegram file + Read table = der geteilte Leser (bank_export_table.ps1, gleich in tool_import_bank_export). Get suggestions (finance_ro) = finance.fn_get_recurring_suggestions: fn_bank_export_load (Bank-Profil, Konto-Wächter, ein Sub-Konto je Datei; kein Startpunkt nötig, es wird nichts gebucht) -> Geldzeilen je Gegenkonto/IBAN/Name -> Betrags-Cluster (Ausgaben ±7,5 %, Preisstufe = eine Reihe) -> Rhythmus (Woche, Monat 1/3/6, Jahr; Termin ±3 Tage, 80 % Treffer, reif ab 3 bzw. 2 Terminen, noch aktiv) -> Startdatum nach dem letzten Termin und nach dem Abgleich-Tag -> Bekannt-Filter gegen laufende Daueraufträge (IBAN-Schlüssel, Transfer-Gegenkonto, exakter Betrag, Name + Betrag; auf einem anderen Konto -> known_elsewhere). Datei unter 90 Tagen -> nur hint export_too_short. Kein HITL: der Agent fragt je Vorschlag, angelegt wird über tool_create_recurring_payment (mit counterparty_iban als Schlüssel) bzw. tool_create_recurring_transfer, jeweils mit Karte.' 460 520
    $stickyPriv = Build-Sticky 'Privacy' @(1100, -300) `
        'Nur Aggregate an das Modell' `
        'Die Datei verlässt n8n nicht. Die Rückgabe trägt je Reihe nur Name (Gegenpart wie gedruckt; ohne Gegenpart die ersten drei Wörter ohne Ziffern des Buchungstexts), Gegen-IBAN (nicht bei einer IBAN, die sich mehrere Händler teilen), Beträge, Rhythmus und Termine – nie Export-Zeilen oder ganze Verwendungszwecke. Fehlertexte der DB zitieren keine Zellinhalte.' 300 240

    $nodes = @($trig) + $reader.Nodes + @($sug, $ifOk, $err, $ret, $sticky, $stickyPriv)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E $reader.Entry ) ) } }
    foreach ($k in $reader.Conns.Keys) { $conns[$k] = $reader.Conns[$k] }
    $conns['Get suggestions'] = @{ main = @( ,@( E 'Suggestions ok?' ) ) }
    $conns['Suggestions ok?'] = @{ main = @( @( E 'Return' ), @( E 'Export not usable' ) ) }
    return Build-Workflow 'agent.finance.tool_get_recurring_suggestions' $nodes $conns @{ Category = 'recurring' }
}
