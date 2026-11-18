#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_get_bank_export_facts (intern, nur lesen, kein Agent-Binding) ---
# agent.finance ruft es vor dem Modell auf, wenn der Auftrag eine Tabellen-Datei traegt (Marker ext=csv|xlsx|xls).
# Geteilter Leser (bank_export_table.ps1) -> finance.fn_bank_export_facts unter finance_ro. Eigenes Tool statt Knoten
# im Agenten: die Fehler-Enden des Lesers (File unusable, Not an export) waeren im Agenten-Graphen Sackgassen vor dem
# Modell; hier enden sie als Daten, und der Aufrufer laeuft ohne Abschnitt weiter.
function Build-GetBankExportFacts {
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-GetBankExportFacts'
    $trig = Build-Trigger @('file_id')
    $reader = New-BankExportTableReader -FetchId $idFetch -OnTable 'Read facts'

    $facts = Build-Pg 'Read facts' @(1100, 0) "=SELECT finance.fn_bank_export_facts(`$1::jsonb) AS r;" ([ordered]@{
        table = $reader.TableExpr
    }) -Cred $CRED_FINANCE_RO -ContinueOnError
    $ret = Build-Return @(1320, 0) @(
        ,@('ok', "={{ !!(`$json.r && `$json.r.ok) }}", 'boolean')
        ,@('recognised', "={{ !!(`$json.r && `$json.r.recognised) }}", 'boolean')
        ,@('facts', "={{ `$json.r || {} }}", 'object')
    )

    $sticky = Build-Sticky 'Überblick' @(220, -460) `
        'Tabellen-Datei vor dem Modell erkennen (nur lesen, kein LLM)' `
        'Aufrufer: agent.finance (Knoten Read bank export facts), nur wenn der Auftrag einen Marker mit ext=csv, xlsx oder xls trägt; nur die erste solche Datei. Fetch telegram file + Read table = der geteilte Leser (bank_export_table.ps1). Read facts (finance_ro) = finance.fn_bank_export_facts: Profil, Bank, das Konto der Datei bzw. die Kandidaten (Namen), bestätigt bis, Zeitraum und Zeilenzahl. Nie Zeilen-Inhalte: das Ergebnis landet im System-Prompt. Unbekannte oder kaputte Datei -> recognised false bzw. ok false; der Agent läuft dann ohne Abschnitt weiter.' 460 400

    $nodes = @($trig) + $reader.Nodes + @($facts, $ret, $sticky)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E $reader.Entry ) ) } }
    foreach ($k in $reader.Conns.Keys) { $conns[$k] = $reader.Conns[$k] }
    $conns['Read facts'] = @{ main = @( ,@( E 'Return' ) ) }
    return Build-Workflow 'agent.finance.tool_get_bank_export_facts' $nodes $conns @{ Internal = $true }
}
