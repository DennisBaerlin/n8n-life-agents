#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_import_broker_csv (Broker-CSV Paket B) ---
# Umsatz-Export einer Bank als CSV-Datei (heute: Trade Republic) -> Monats-Check des Cashkontos OHNE Sprachmodell (die
# Datei geht nicht an Anthropic): Core-Baustein holt die Datei als Text (accept=csv) -> generischer RFC-4180-Tokenizer
# (Code, kennt keine Bedeutung) -> finance.fn_replace_takeover_with_lots im Probelauf (core.fn_dry_run): gibt es eine
# Bestandsuebernahme, deren Einzelkaeufe der Export exakt belegt -> Karte 1 "Einzelkaeufe uebernehmen" -> Gate -> echter
# Write -> danach (auch bei Ablehnung oder ohne Kandidat) die geteilte Monats-Check-Kette (statement_chain.ps1) mit
# source:'csv' + dem App-Kontostand des Owners (Pflicht) -> Karte 2 -> Gate -> Buchung. Rueckgaben tragen nur Aggregate,
# nie Export-Zeilen.
function Build-ImportBrokerCsv {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ImportBrokerCsv'
    $trig = Build-Trigger @('file_id', 'account_name', 'closing_balance')

    $fetch = Build-CallWorkflow 'Fetch telegram file' @(220, 0) $idFetch 'agent.tool_fetch_telegram_file' `
        ([ordered]@{ file_id = "={{ `$('Start').item.json.file_id }}"; accept = 'csv' })
    $ifFile = Build-If 'File ok?' @(440, 0) "={{ `$('Fetch telegram file').item.json.ok }}" 'true' 'equals' 'boolean'
    $errFile = Build-ToolError 'File unusable' @(660, 200) "={{ `$('Fetch telegram file').item.json.error }}"

    # RFC 4180: Felder in "..." (darin "" = "), Trenner aus der Kopfzeile (mehr ';' als ',' -> ';', Muster Portfolio
    # Performance: erst ',' dann ';'), CRLF/LF. Ein Bild/PDF (text leer) ist kein Export -> Hinweis auf den Auszug-Weg.
    $jsTok = @'
const f = $('Fetch telegram file').first().json;
const fail = (code, m) => [{ json: { ok: false, code, error: m, header: [], rows: [] } }];
const t = String(f.text || '');
if (!t.trim()) return fail('not_a_csv', 'This file is not a CSV export (it is a photo or PDF). A printed bank statement goes to tool_reconcile_bank_statement.');
const first = t.split(/\r?\n/, 1)[0] || '';
const delim = first.split(';').length > first.split(',').length ? ';' : ',';
const rows = []; let row = []; let fld = ''; let q = false;
for (let i = 0; i < t.length; i++) {
  const c = t[i];
  if (q) { if (c === '"') { if (t[i + 1] === '"') { fld += '"'; i++; } else q = false; } else fld += c; }
  else if (c === '"') q = true;
  else if (c === delim) { row.push(fld); fld = ''; }
  else if (c === '\n' || c === '\r') { if (c === '\r' && t[i + 1] === '\n') i++; row.push(fld); rows.push(row); row = []; fld = ''; }
  else fld += c;
}
if (fld !== '' || row.length) { row.push(fld); rows.push(row); }
const header = rows.shift() || [];
if (header.length < 2) return fail('csv_invalid', 'The file has no readable table (header row missing).');
if (rows.length > 20000) return fail('csv_invalid', 'The export is too long (more than 20000 rows) - ask the user to export a shorter period (this year).');
return [{ json: { ok: true, header, rows, row_count: rows.length } }];
'@
    $tok = [ordered]@{ parameters = [ordered]@{ jsCode = $jsTok }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(660, 0); id = (New-Id); name = 'Tokenize CSV' }
    $ifTok = Build-If 'Table read?' @(880, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errTok = Build-Set 'Not a CSV' @(1100, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ `$('Tokenize CSV').item.json.code }}", 'string')
        ,@('error', "={{ `$('Tokenize CSV').item.json.error }}", 'string')
    )

    $T = "`$('Tokenize CSV').first().json"
    $csvExpr = "({ header: $T.header, rows: $T.rows })"
    $lotsParams = [ordered]@{
        account_name = "`$('Start').first().json.account_name || null"
        csv          = $csvExpr
    }
    # Karte 1: Probelauf -> nur wenn eine Uebernahme ersetzt wuerde. Eine Ablehnung des Probelaufs (Profil/Konto) zeigt
    # dieselbe Meldung wie die Prepare -> direkt weiter in die Kette (die meldet sie als Daten).
    $lotsDry = Build-Pg 'Preview lots' @(1100, 0) "=SELECT core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, `$1::jsonb) AS r;" $lotsParams
    $L = "`$('Preview lots').first().json.r"
    $ifLots = Build-If 'Lots to replace?' @(1320, 0) "={{ $L.ok === true && ($L.replaced || []).length > 0 }}" 'true' 'equals' 'boolean'
    $lotsSummary = New-HitlSummary -Name 'Lots summary' -Pos @(1540, -200) -Title 'finance.hitl.replace_takeover_lots' `
        -TitleParams @{ account = "`$('Start').first().json.account_name" } -LinesExpr "($L.card_lines || [])"
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

    $stmtParams = [ordered]@{
        source          = "'csv'"
        account_name    = "`$('Start').first().json.account_name || null"
        closing_balance = "`$('Start').first().json.closing_balance === undefined || `$('Start').first().json.closing_balance === null ? null : String(`$('Start').first().json.closing_balance)"
        csv             = $csvExpr
    }
    $R = "`$('Replace lots').isExecuted ? `$('Replace lots').first().json.r : null"
    $chain = New-StatementGateChain -X 2420 -StmtParams $stmtParams -Title 'finance.hitl.import_broker_csv' `
        -CancelAction 'the monthly check from the CSV export (no statement was booked)' -ReturnExtra @(
            ,@('trades_booked', "={{ `$('Apply statement').item.json.r.trades_booked || 0 }}", 'number')
            ,@('trades_not_booked', "={{ `$('Apply statement').item.json.r.trades_blocked || [] }}", 'array')
            ,@('unknown_export_rows', "={{ `$('Apply statement').item.json.r.csv_unknown || [] }}", 'array')
            ,@('positions_replaced_by_purchases', "={{ (($R) || {}).replaced || [] }}", 'array')
            ,@('positions_not_matching_export', "={{ ($L.mismatched || []) }}", 'array')
            ,@('purchases_cash_effect', "={{ (($R) || {}).settlement_change || 0 }}", 'number')
        )

    $sticky = Build-Sticky 'Überblick' @(220, -520) `
        'Broker-CSV: Export -> (Einzelkäufe übernehmen) -> Monats-Check, ohne Sprachmodell' `
        'Fetch telegram file (Core-Baustein, accept=csv: Datei mit Endung .csv als Text, BOM entfernt) -> Tokenize CSV (RFC 4180, Trenner aus der Kopfzeile; kennt keine Bedeutung) -> Preview lots = core.fn_dry_run(finance.fn_replace_takeover_with_lots): Positionen mit genau EINER Bestandsübernahme, deren Einzelkäufe der Export exakt belegt (Stück-Summe auf 8 Stellen) -> Karte 1 + Gate -> Replace lots (echter Write; Käufe nach dem bestätigten Kontostand-Tag werden echte Käufe). Danach immer die geteilte Monats-Check-Kette (statement_chain.ps1, gleich in tool_reconcile_bank_statement) mit source csv: finance.fn_broker_csv_normalize liest den Export (Profil per Kopfzeile), der App-Kontostand des Owners ist Pflicht (sonst closing_balance_required, keine Karte), Zeitraum bis gestern, Wertpapier-Zeilen werden gebucht oder gemeldet, unbekannte Zeilen gemeldet. PRIVACY: die Datei verlässt n8n nicht, die Rückgabe trägt nur Summen und Namen, nie Export-Zeilen.' 380 600
    $stickyLots = Build-Sticky 'Zwei Karten' @(1320, -560) `
        'Erst Einzelkäufe, dann Monats-Check – nie doppelt gebucht' `
        'Karte 1 kommt nur, wenn der Probelauf eine Position ersetzen würde; der echte Write bekommt den fingerprint des Probelaufs (anderer Plan -> stale_preview, nichts gebucht, Lots not replaced). Ablehnung oder kein Kandidat -> weiter zu Karte 2. Ein Kauf bis zum Übernahme-Datum wird im Monats-Check nie gebucht (covered_by_takeover); nach dem Ersetzen erkennt ihn Stufe 0 als schon gebucht. Abweichende Positionen (lots_mismatch) bleiben unverändert und stehen im Rückgabewert.' 320 300

    $nodes = @($trig, $fetch, $ifFile, $errFile, $tok, $ifTok, $errTok, $lotsDry, $ifLots, $lotsSummary, $lotsApproval,
               $ifLotsOk, $lotsApply, $ifReplaced, $errReplaced) + $chain.Nodes + @($sticky, $stickyLots)
    $conns = [ordered]@{
        'Start'                 = @{ main = @( ,@( E 'Fetch telegram file' ) ) }
        'Fetch telegram file'   = @{ main = @( ,@( E 'File ok?' ) ) }
        'File ok?'              = @{ main = @( @( E 'Tokenize CSV' ), @( E 'File unusable' ) ) }
        'Tokenize CSV'          = @{ main = @( ,@( E 'Table read?' ) ) }
        'Table read?'           = @{ main = @( @( E 'Preview lots' ), @( E 'Not a CSV' ) ) }
        'Preview lots'          = @{ main = @( ,@( E 'Lots to replace?' ) ) }
        'Lots to replace?'      = @{ main = @( @( E 'Lots summary' ), @( E $chain.Entry ) ) }
        'Lots summary'          = @{ main = @( ,@( E 'Request lots approval' ) ) }
        'Request lots approval' = @{ main = @( ,@( E 'Lots approved?' ) ) }
        'Lots approved?'        = @{ main = @( @( E 'Replace lots' ), @( E $chain.Entry ) ) }
        'Replace lots'          = @{ main = @( ,@( E 'Lots replaced?' ) ) }
        'Lots replaced?'        = @{ main = @( @( E $chain.Entry ), @( E 'Lots not replaced' ) ) }
    }
    foreach ($k in $chain.Conns.Keys) { $conns[$k] = $chain.Conns[$k] }
    return Build-Workflow 'agent.finance.tool_import_broker_csv' $nodes $conns @{ Category = 'import' }
}
