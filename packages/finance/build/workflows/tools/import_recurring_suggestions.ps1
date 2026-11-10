#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_import_recurring_suggestions (Staging-Write ohne HITL; "Import zuerst") ---
# Bank-Export (CSV/Excel, Profile in finance.fn_bank_export_profiles) ueber mehrere Monate -> wiederkehrende Zahlungen,
# die noch kein Dauerauftrag abdeckt, landen im Vorschlags-Stapel des Chats (finance.fn_import_stage_recurring mode export,
# Erkennung in finance.fn_get_recurring_candidates, dieselbe Regel wie beim Kontoauszug). Gebucht und angelegt wird nichts:
# der Agent ruft danach tool_send_recurring_suggestions (je Vorschlag eine Nachricht mit Knoepfen), angelegt wird nur per
# Knopf. Kein LLM, die Datei geht nicht an Anthropic; die Rueckgabe traegt nur Anzahlen, Namen und Hinweise.
function Build-ImportRecurringSuggestions {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ImportRecurringSuggestions'
    $trig = Build-Trigger @('file_id', 'account_name')
    $reader = New-BankExportTableReader -FetchId $idFetch -OnTable 'Stage suggestions'

    $stage = Build-Pg 'Stage suggestions' @(1100, 0) "=SELECT finance.fn_import_stage_recurring(`$1::jsonb) AS r;" ([ordered]@{
        mode         = "'export'"
        chat_id      = "String(`$('Start').first().json.chat_id || '')"
        account_name = "`$('Start').first().json.account_name || null"
        table        = $reader.TableExpr
    })
    $ifOk = Build-If 'Suggestions ok?' @(1320, 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $R = "`$('Stage suggestions').item.json.r"
    $err = Build-Set 'Export not usable' @(1540, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ $R.code }}", 'string')
        ,@('error', "={{ $R.reason }}", 'string')
        ,@('row_no', "={{ $R.row_no === undefined || $R.row_no === null ? '' : String($R.row_no) }}", 'string')
        ,@('candidates', "={{ $R.candidates || [] }}", 'array')
        ,@('bank', "={{ $R.bank || '' }}", 'string')
        ,@('account_name', "={{ $R.account_name || '' }}", 'string')
    )
    $ret = Build-Return @(1540, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('account_name', "={{ $R.account_name || '' }}", 'string')
        ,@('hint', "={{ $R.hint || '' }}", 'string')
        ,@('reason', "={{ $R.reason || '' }}", 'string')
        ,@('staged', "={{ $R.staged || 0 }}", 'number')
        ,@('open_count', "={{ $R.open_count || 0 }}", 'number')
        ,@('unsent_count', "={{ $R.unsent_count || 0 }}", 'number')
        ,@('names', "={{ ($R.rows || []).map((x) => x.name) }}", 'array')
        ,@('hints', "={{ $R.hints || [] }}", 'array')
        ,@('household', "={{ $R.household || [] }}", 'array')
        ,@('known_elsewhere', "={{ $R.known_elsewhere || [] }}", 'array')
    )

    $sticky = Build-Sticky 'Überblick' @(220, -520) `
        'Daueraufträge aus einem Bank-Export vorschlagen (Stapel, kein Write in Domänen-Daten, kein LLM)' `
        'Fetch telegram file + Read table = der geteilte Leser (bank_export_table.ps1, gleich in tool_import_bank_export). Stage suggestions (finance_rw) = finance.fn_import_stage_recurring mode export: fn_get_recurring_suggestions (fn_bank_export_load mit Bank-Profil, Konto- und Sub-Konto-Wächter; Datei unter 75 Tagen -> nur hint export_too_short) -> Erkennung fn_get_recurring_candidates (Schlüssel, Betrags-Cluster, Rhythmus, Reife, Startdatum, Bekannt-Filter) -> der EINE offene Vorschlags-Stapel des Chats (import_staging, origin recurring_suggestion; ergänzt statt neu, abgelehnte bleiben abgelehnt). Kein HITL: Staging ist keine Domänen-Daten. Angelegt wird erst per Knopf unter der Vorschlags-Nachricht, die tool_send_recurring_suggestions schickt.' 460 480
    $stickyPriv = Build-Sticky 'Privacy' @(1100, -300) `
        'Nur Aggregate an das Modell' `
        'Die Datei verlässt n8n nicht. Die Rückgabe trägt nur Anzahlen, bereinigte Namen und Hinweise, nie Export-Zeilen oder Verwendungszwecke. Im Stapel liegen je Vorschlag Name, Gegen-IBAN, Termine und Beträge, spätestens 7 Tage nach dem letzten Ergänzen gelöscht.' 300 240

    $nodes = @($trig) + $reader.Nodes + @($stage, $ifOk, $err, $ret, $sticky, $stickyPriv)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E $reader.Entry ) ) } }
    foreach ($k in $reader.Conns.Keys) { $conns[$k] = $reader.Conns[$k] }
    $conns['Stage suggestions'] = @{ main = @( ,@( E 'Suggestions ok?' ) ) }
    $conns['Suggestions ok?'] = @{ main = @( @( E 'Return' ), @( E 'Export not usable' ) ) }
    return Build-Workflow 'agent.finance.tool_import_recurring_suggestions' $nodes $conns @{ Category = 'recurring' }
}
