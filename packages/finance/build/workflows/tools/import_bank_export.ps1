#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_import_bank_export (Bank-Import-Modul; aus Broker-CSV Paket B) ---
# Umsatz-Export einer Bank als Datei (CSV oder Excel; Profile in finance.fn_bank_export_profiles) -> Monats-Check OHNE
# Sprachmodell (die Datei geht nicht an Anthropic): Core-Baustein holt die Datei (accept=table: CSV als Text, xlsx als
# Raster ueber Extract From File) -> Leser (Code: CSV-Tokenizer RFC 4180 bzw. xlsx-Raster als Text, kennt keine
# Bedeutung; die Kopfzeile bleibt im Raster) -> finance.fn_replace_takeover_with_lots im Probelauf (core.fn_dry_run):
# gibt es eine Bestandsuebernahme, deren Einzelkaeufe der Export exakt belegt -> Karte 1 "Einzelkaeufe uebernehmen" ->
# Gate -> echter Write -> danach (auch bei Ablehnung oder ohne Kandidat) die geteilte Monats-Check-Kette
# (statement_chain.ps1) mit source:'file' (+ App-Kontostand des Owners, wo die Datei keinen Endstand druckt) -> Karte 2
# -> Gate -> Buchung. Rueckgaben tragen nur Aggregate, nie Export-Zeilen.
function Build-ImportBankExport {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ImportBankExport'
    $trig = Build-Trigger @('file_id', 'account_name', 'closing_balance', 'transfer_account')

    # Datei holen + Tabelle lesen: der geteilte Leser (../bank_export_table.ps1, gleich in tool_get_recurring_suggestions)
    $reader = New-BankExportTableReader -FetchId $idFetch -OnTable 'Precheck statement'
    $tableExpr = $reader.TableExpr
    # account_name optional: ohne Namen waehlt finance.fn_bank_export_resolve_account das Konto nach Bank-Profil
    # (Konto-Waechter, Live-Befund 2026-10-30); der Kartentitel kommt daher aus der DB-Antwort, nie aus dem Start-Input.
    $lotsParams = [ordered]@{
        account_name = "`$('Start').first().json.account_name || null"
        table        = $tableExpr
    }
    # Pool-Regel (Bank-Import-Modul Paket 3): passt GENAU eine Zahlung an/von einem Anbieter-Sammelkonto (Bondora) zu
    # zwei Konten, antwortet die Prepare transfer_choice_required (Kandidaten als Daten, keine Karte); der Agent fragt den
    # Nutzer (Muster account_ambiguous) und ruft erneut mit transfer_account (Kontoname bzw. 'none'). Die Karte zeigt die
    # Zuordnung vor dem Buchen. Bewusst keine wartende Knopf-Frage mitten im Tool (ohne Karte-offen-Sperre liefen sonst
    # parallele Agenten-Laeufe, Vorfall 2026-10-22).
    $stmtParams = [ordered]@{
        source           = "'file'"
        account_name     = "`$('Start').first().json.account_name || null"
        closing_balance  = "`$('Start').first().json.closing_balance === undefined || `$('Start').first().json.closing_balance === null ? null : String(`$('Start').first().json.closing_balance)"
        table            = $tableExpr
        transfer_account = "`$('Start').first().json.transfer_account || null"
    }
    # Vorpruefung (Review 2026-10-30): Karte 1 nur, wenn der Monats-Check danach laufen kann. Jede Rueckfrage der Prepare
    # (closing_balance_required, transfer_choice_required, Konto-Waechter ...) kommt VOR Karte 1 -> der Folgeaufruf mit
    # der Antwort zeigt Karte 1 genau einmal, nie doppelt und nie eine bestaetigte Ersetzung ohne Rueckmeldung. Nicht ok ->
    # direkt in die Kette: deren Prepare meldet denselben Grund als Daten (Statement not ready, eine Adresse).
    $precheck = Build-Pg 'Precheck statement' @(1100, 400) "=SELECT finance.fn_statement_prepare(`$1::jsonb) AS r;" $stmtParams
    $ifPrecheck = Build-If 'Statement can run?' @(1320, 400) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    # Karte 1: Probelauf -> nur wenn eine Uebernahme ersetzt wuerde. Eine Ablehnung des Probelaufs (Profil/Konto) zeigt
    # dieselbe Meldung wie die Prepare -> direkt weiter in die Kette (die meldet sie als Daten).
    $lotsDry = Build-Pg 'Preview lots' @(1100, 0) "=SELECT core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, `$1::jsonb) AS r;" $lotsParams
    $L = "`$('Preview lots').first().json.r"
    $ifLots = Build-If 'Lots to replace?' @(1320, 0) "={{ $L.ok === true && ($L.replaced || []).length > 0 }}" 'true' 'equals' 'boolean'
    $lotsSummary = New-HitlSummary -Name 'Lots summary' -Pos @(1540, -200) -Title 'finance.hitl.replace_takeover_lots' `
        -TitleParams @{ account = "$L.account_name" } -LinesExpr "($L.card_lines || [])"
    $lotsApproval = Build-CallWorkflow 'Request lots approval' @(1760, -200) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Lots summary').item.json.summary }}"; chat_id = "={{ `$('Start').first().json.chat_id }}" })
    $ifLotsOk = Build-If 'Lots approved?' @(1980, -200) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    # echter Write nur mit dem Fingerabdruck der Karte (Plan/Apply wie der Monats-Check: sonst stale_preview, nichts gebucht)
    $lotsApplyParams = [ordered]@{}
    foreach ($k in $lotsParams.Keys) { $lotsApplyParams[$k] = $lotsParams[$k] }
    $lotsApplyParams['fingerprint'] = "$L.fingerprint"
    $lotsApply = Build-Pg 'Replace lots' @(2200, -300) "=SELECT finance.fn_replace_takeover_with_lots(`$1::jsonb) AS r;" $lotsApplyParams
    $ifReplaced = Build-If 'Lots replaced?' @(2420, -300) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $errReplaced = Build-Set 'Lots not replaced' @(2640, -500) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ `$('Replace lots').item.json.r.code || '' }}", 'string')
        ,@('error', "={{ `$('Replace lots').item.json.r.reason }}", 'string')
    )

    $R ="`$('Replace lots').isExecuted ? `$('Replace lots').first().json.r : null"
    $chain = New-StatementGateChain -X 2420 -StmtParams $stmtParams -Title 'finance.hitl.import_bank_export' `
        -CancelAction 'the monthly check from the bank export (no statement was booked)' -ReturnExtra @(
            ,@('trades_booked', "={{ `$('Apply statement').item.json.r.trades_booked || 0 }}", 'number')
            ,@('trades_not_booked', "={{ `$('Apply statement').item.json.r.trades_blocked || [] }}", 'array')
            ,@('unknown_export_rows', "={{ `$('Apply statement').item.json.r.export_unknown || [] }}", 'array')
            ,@('positions_replaced_by_purchases', "={{ (($R) || {}).replaced || [] }}", 'array')
            ,@('positions_not_matching_export', "={{ `$('Preview lots').isExecuted ? ($L.mismatched || []) : [] }}", 'array')
            ,@('purchases_cash_effect', "={{ (($R) || {}).settlement_change || 0 }}", 'number')
            ,@('interest_correction', "={{ `$('Prepare statement').item.json.r.interest_correction || 0 }}", 'number')
            ,@('legacy_returns', "={{ `$('Prepare statement').item.json.r.legacy_returns || 0 }}", 'number')
            ,@('provider_payments_unassigned', "={{ `$('Prepare statement').item.json.r.pool_unassigned || 0 }}", 'number')
        )

    $sticky = Build-Sticky 'Überblick' @(220, -520) `
        'Bank-Export (CSV/Excel) -> (Einzelkäufe übernehmen) -> Monats-Check, ohne Sprachmodell' `
        'Fetch telegram file (Core-Baustein, accept=table: .csv als Text mit entferntem BOM, .xlsx als Raster über Extract From File) -> Read table (CSV: RFC 4180, Trenner aus den ersten 20 Zeilen; xlsx: Zellen als Text; kennt keine Bedeutung, die Kopfzeile bleibt im Raster) -> Precheck statement (finance.fn_statement_prepare; nicht ok -> direkt in die Kette, die den Grund meldet) -> Preview lots =core.fn_dry_run(finance.fn_replace_takeover_with_lots): Positionen mit genau EINER Bestandsübernahme, deren Einzelkäufe der Export exakt belegt (Stück-Summe auf 8 Stellen) -> Karte 1 + Gate -> Replace lots (echter Write; Käufe nach dem bestätigten Kontostand-Tag werden echte Käufe). Konto-Wächter in beiden Schritten (finance.fn_bank_export_resolve_account): passt das genannte Konto nicht zur Bank der Datei -> export_account_mismatch (+ passende Konten), ohne account_name wählt die DB das eine passende Konto (mehrere -> account_ambiguous). Danach immer die geteilte Monats-Check-Kette (statement_chain.ps1, gleich in tool_reconcile_bank_statement) mit source file: finance.fn_bank_export_normalize findet Kopfzeile + Bank-Profil und liest den Export; druckt die Datei Zeitraum + Endstand (Bondora), ist sie ein gedruckter Auszug (Zinskorrektur + Altkredit-Rückflüsse als je eine Summe, Ein-/Auszahlungen über das Verrechnungskonto), sonst ist der App-Kontostand des Owners Pflicht (sonst closing_balance_required, keine Karte, Zeitraum bis gestern); Wertpapier-Zeilen werden gebucht oder gemeldet, unbekannte Zeilen gemeldet. Zahlungen an/von einem Anbieter-Sammelkonto (Bondora) ordnet die Prepare einem P2P-Konto zu; passt genau eine zu zwei Konten, antwortet sie transfer_choice_required (keine Karte) und der Agent ruft nach der Antwort des Nutzers mit transfer_account erneut. Rückgabe: transfers (Gegenkonto, Betrag, Gebühr, Datum je Übertrag), booked_count (alle neuen Vorgänge), rest_outflow/rest_inflow (Rest nach Richtung). PRIVACY: die Datei verlässt n8n nicht, die Rückgabe trägt nur Summen und Namen, nie Export-Zeilen.' 460 600
    $stickyLots = Build-Sticky 'Zwei Karten' @(1320, -560) `
        'Erst Einzelkäufe, dann Monats-Check – nie doppelt gebucht' `
        'Karte 1 kommt nur, wenn die Vorprüfung (Precheck statement = dieselbe Prepare) ok ist und der Probelauf eine Position ersetzen würde: jede Rückfrage (Kontostand, Konto, Pool-Zuordnung) kommt vorher, der Folgeaufruf zeigt Karte 1 genau einmal; der echte Write bekommt den fingerprint des Probelaufs (anderer Plan -> stale_preview, nichts gebucht, Lots not replaced). Ablehnung oder kein Kandidat -> weiter zu Karte 2. Ein Kauf bis zum Übernahme-Datum wird im Monats-Check nie gebucht (covered_by_takeover); nach dem Ersetzen erkennt ihn Stufe 0 als schon gebucht. Abweichende Positionen (lots_mismatch) bleiben unverändert und stehen im Rückgabewert.' 340 320

    $nodes = @($trig) + $reader.Nodes + @($precheck, $ifPrecheck, $lotsDry, $ifLots, $lotsSummary,
               $lotsApproval, $ifLotsOk, $lotsApply, $ifReplaced, $errReplaced) + $chain.Nodes + @($sticky, $stickyLots)
    $conns = [ordered]@{ 'Start' = @{ main = @( ,@( E $reader.Entry ) ) } }
    foreach ($k in $reader.Conns.Keys) { $conns[$k] = $reader.Conns[$k] }
    $rest = [ordered]@{
        'Precheck statement'    = @{ main = @( ,@( E 'Statement can run?' ) ) }
        'Statement can run?'    = @{ main = @( @( E 'Preview lots' ), @( E $chain.Entry ) ) }
        'Preview lots'          = @{ main = @( ,@( E 'Lots to replace?' ) ) }
        'Lots to replace?'      = @{ main = @( @( E 'Lots summary' ), @( E $chain.Entry ) ) }
        'Lots summary'          = @{ main = @( ,@( E 'Request lots approval' ) ) }
        'Request lots approval' = @{ main = @( ,@( E 'Lots approved?' ) ) }
        'Lots approved?'        = @{ main = @( @( E 'Replace lots' ), @( E $chain.Entry ) ) }
        'Replace lots'          = @{ main = @( ,@( E 'Lots replaced?' ) ) }
        'Lots replaced?'        = @{ main = @( @( E $chain.Entry ), @( E 'Lots not replaced' ) ) }
    }
    foreach ($k in $rest.Keys) { $conns[$k] = $rest[$k] }
    foreach ($k in $chain.Conns.Keys) { $conns[$k] = $chain.Conns[$k] }
    return Build-Workflow 'agent.finance.tool_import_bank_export' $nodes $conns @{ Category = 'import' }
}
