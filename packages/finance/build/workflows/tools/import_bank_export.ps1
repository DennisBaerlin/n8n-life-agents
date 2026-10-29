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
    $trig = Build-Trigger @('file_id', 'account_name', 'closing_balance')

    $fetch = Build-CallWorkflow 'Fetch telegram file' @(220, 0) $idFetch 'agent.tool_fetch_telegram_file' `
        ([ordered]@{ file_id = "={{ `$('Start').item.json.file_id }}"; accept = 'table' })
    $ifFile = Build-If 'File ok?' @(440, 0) "={{ `$('Fetch telegram file').item.json.ok }}" 'true' 'equals' 'boolean'
    $errFile = Build-ToolError 'File unusable' @(660, 200) "={{ `$('Fetch telegram file').item.json.error }}"

    # xlsx: Raster kommt fertig (Zellen -> Text, Zahlen unformatiert). CSV: RFC 4180, Felder in "..." (darin "" = "),
    # Trenner aus den ersten 20 Zeilen (mehr ';' als ',' -> ';', Muster Portfolio Performance; ueber mehrere Zeilen,
    # weil die Kopfzeile hinter einem Vorspann stehen darf), CRLF/LF. Ein Bild/PDF (weder text noch rows) ist kein
    # Export -> Hinweis auf den Auszug-Weg.
    $jsTok = @'
const f = $('Fetch telegram file').first().json;
const fail = (code, m) => [{ json: { ok: false, code, error: m, rows: [] } }];
const cell = (v) => (v === null || v === undefined) ? '' : String(v);
if (Array.isArray(f.rows) && f.rows.length) {
  const grid = f.rows.map((r) => (Array.isArray(r) ? r : []).map(cell));
  if (grid.length > 20000) return fail('export_invalid', 'The export is too long (more than 20000 rows) - ask the user to export a shorter period (this year).');
  return [{ json: { ok: true, rows: grid, row_count: grid.length } }];
}
const t = String(f.text || '');
if (!t.trim()) return fail('not_an_export', 'This file is not a bank export (it is a photo or PDF). A printed bank statement goes to tool_reconcile_bank_statement.');
const head = t.split(/\r?\n/, 20).join('\n');
const delim = head.split(';').length > head.split(',').length ? ';' : ',';
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
if (rows.length < 2 || !rows.some((r) => r.length >= 2)) return fail('export_invalid', 'The file has no readable table (header row missing).');
if (rows.length > 20000) return fail('export_invalid', 'The export is too long (more than 20000 rows) - ask the user to export a shorter period (this year).');
return [{ json: { ok: true, rows, row_count: rows.length } }];
'@
    $tok = [ordered]@{ parameters = [ordered]@{ jsCode = $jsTok }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(660, 0); id = (New-Id); name = 'Read table' }
    $ifTok = Build-If 'Table read?' @(880, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errTok = Build-Set 'Not an export' @(1100, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ `$('Read table').item.json.code }}", 'string')
        ,@('error', "={{ `$('Read table').item.json.error }}", 'string')
    )

    $tableExpr = "({ rows: `$('Read table').first().json.rows })"
    $lotsParams = [ordered]@{
        account_name = "`$('Start').first().json.account_name || null"
        table        = $tableExpr
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
        source          = "'file'"
        account_name    = "`$('Start').first().json.account_name || null"
        closing_balance = "`$('Start').first().json.closing_balance === undefined || `$('Start').first().json.closing_balance === null ? null : String(`$('Start').first().json.closing_balance)"
        table           = $tableExpr
    }
    $R = "`$('Replace lots').isExecuted ? `$('Replace lots').first().json.r : null"
    $chain = New-StatementGateChain -X 2420 -StmtParams $stmtParams -Title 'finance.hitl.import_bank_export' `
        -CancelAction 'the monthly check from the bank export (no statement was booked)' -ReturnExtra @(
            ,@('trades_booked', "={{ `$('Apply statement').item.json.r.trades_booked || 0 }}", 'number')
            ,@('trades_not_booked', "={{ `$('Apply statement').item.json.r.trades_blocked || [] }}", 'array')
            ,@('unknown_export_rows', "={{ `$('Apply statement').item.json.r.export_unknown || [] }}", 'array')
            ,@('positions_replaced_by_purchases', "={{ (($R) || {}).replaced || [] }}", 'array')
            ,@('positions_not_matching_export', "={{ ($L.mismatched || []) }}", 'array')
            ,@('purchases_cash_effect', "={{ (($R) || {}).settlement_change || 0 }}", 'number')
            ,@('interest_correction', "={{ `$('Prepare statement').item.json.r.interest_correction || 0 }}", 'number')
            ,@('legacy_returns', "={{ `$('Prepare statement').item.json.r.legacy_returns || 0 }}", 'number')
        )

    $sticky = Build-Sticky 'Überblick' @(220, -520) `
        'Bank-Export (CSV/Excel) -> (Einzelkäufe übernehmen) -> Monats-Check, ohne Sprachmodell' `
        'Fetch telegram file (Core-Baustein, accept=table: .csv als Text mit entferntem BOM, .xlsx als Raster über Extract From File) -> Read table (CSV: RFC 4180, Trenner aus der ersten Zeile; xlsx: Zellen als Text; kennt keine Bedeutung, die Kopfzeile bleibt im Raster) -> Preview lots = core.fn_dry_run(finance.fn_replace_takeover_with_lots): Positionen mit genau EINER Bestandsübernahme, deren Einzelkäufe der Export exakt belegt (Stück-Summe auf 8 Stellen) -> Karte 1 + Gate -> Replace lots (echter Write; Käufe nach dem bestätigten Kontostand-Tag werden echte Käufe). Danach immer die geteilte Monats-Check-Kette (statement_chain.ps1, gleich in tool_reconcile_bank_statement) mit source file: finance.fn_bank_export_normalize findet Kopfzeile + Bank-Profil und liest den Export; druckt die Datei Zeitraum + Endstand (Bondora), ist sie ein gedruckter Auszug (Zinskorrektur + Altkredit-Rückflüsse als je eine Summe, Ein-/Auszahlungen über das Verrechnungskonto), sonst ist der App-Kontostand des Owners Pflicht (sonst closing_balance_required, keine Karte, Zeitraum bis gestern); Wertpapier-Zeilen werden gebucht oder gemeldet, unbekannte Zeilen gemeldet. PRIVACY: die Datei verlässt n8n nicht, die Rückgabe trägt nur Summen und Namen, nie Export-Zeilen.' 380 600
    $stickyLots = Build-Sticky 'Zwei Karten' @(1320, -560) `
        'Erst Einzelkäufe, dann Monats-Check – nie doppelt gebucht' `
        'Karte 1 kommt nur, wenn der Probelauf eine Position ersetzen würde; der echte Write bekommt den fingerprint des Probelaufs (anderer Plan -> stale_preview, nichts gebucht, Lots not replaced). Ablehnung oder kein Kandidat -> weiter zu Karte 2. Ein Kauf bis zum Übernahme-Datum wird im Monats-Check nie gebucht (covered_by_takeover); nach dem Ersetzen erkennt ihn Stufe 0 als schon gebucht. Abweichende Positionen (lots_mismatch) bleiben unverändert und stehen im Rückgabewert.' 320 300

    $nodes = @($trig, $fetch, $ifFile, $errFile, $tok, $ifTok, $errTok, $lotsDry, $ifLots, $lotsSummary, $lotsApproval,
               $ifLotsOk, $lotsApply, $ifReplaced, $errReplaced) + $chain.Nodes + @($sticky, $stickyLots)
    $conns = [ordered]@{
        'Start'                 = @{ main = @( ,@( E 'Fetch telegram file' ) ) }
        'Fetch telegram file'   = @{ main = @( ,@( E 'File ok?' ) ) }
        'File ok?'              = @{ main = @( @( E 'Read table' ), @( E 'File unusable' ) ) }
        'Read table'          = @{ main = @( ,@( E 'Table read?' ) ) }
        'Table read?'           = @{ main = @( @( E 'Preview lots' ), @( E 'Not an export' ) ) }
        'Preview lots'          = @{ main = @( ,@( E 'Lots to replace?' ) ) }
        'Lots to replace?'      = @{ main = @( @( E 'Lots summary' ), @( E $chain.Entry ) ) }
        'Lots summary'          = @{ main = @( ,@( E 'Request lots approval' ) ) }
        'Request lots approval' = @{ main = @( ,@( E 'Lots approved?' ) ) }
        'Lots approved?'        = @{ main = @( @( E 'Replace lots' ), @( E $chain.Entry ) ) }
        'Replace lots'          = @{ main = @( ,@( E 'Lots replaced?' ) ) }
        'Lots replaced?'        = @{ main = @( @( E $chain.Entry ), @( E 'Lots not replaced' ) ) }
    }
    foreach ($k in $chain.Conns.Keys) { $conns[$k] = $chain.Conns[$k] }
    return Build-Workflow 'agent.finance.tool_import_bank_export' $nodes $conns @{ Category = 'import' }
}
