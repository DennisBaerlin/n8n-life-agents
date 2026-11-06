#Requires -Version 5.1
# Der geteilte Tabellen-Leser fuer Bank-Export-Dateien ("Import zuerst": 2. Konsument -> vereinheitlicht): Fetch telegram
# file (Core-Baustein, accept=table) -> File ok? -> Read table (CSV-Tokenizer RFC 4180 bzw. xlsx-Raster als Text, kennt
# keine Bedeutung; die Kopfzeile bleibt im Raster) -> Table read?. Konsumenten: tool_import_bank_export (Monats-Check) und
# tool_get_recurring_suggestions (Dauerauftrags-Vorschlaege). Die Bedeutung liest die DB (fn_bank_export_load bzw.
# fn_statement_prepare). Helper-Datei ohne Build-* (Builder-Discovery liefert 0 Builder); gelesen nur in
# Funktionskoerpern -> Ladereihenfolge egal.
#
# New-BankExportTableReader -FetchId <Workflow-ID core:fetch_telegram_file> -OnTable <Name des ersten Konsumenten-Knotens>
#   -> @{ Nodes; Conns (inkl. 'Table read?' Ausgang 0 -> OnTable); Entry = 'Fetch telegram file' (an 'Start' haengen);
#      TableExpr = JS-Ausdruck {rows} fuer Build-Pg }. Positionen fest x 220..1100 (der Konsument beginnt ab x 1100).
function New-BankExportTableReader {
    param([Parameter(Mandatory)][string]$FetchId, [Parameter(Mandatory)][string]$OnTable)
    $fetch = Build-CallWorkflow 'Fetch telegram file' @(220, 0) $FetchId 'agent.tool_fetch_telegram_file' `
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
    return @{
        Nodes     = @($fetch, $ifFile, $errFile, $tok, $ifTok, $errTok)
        Conns     = [ordered]@{
            'Fetch telegram file' = @{ main = @( ,@( E 'File ok?' ) ) }
            'File ok?'            = @{ main = @( @( E 'Read table' ), @( E 'File unusable' ) ) }
            'Read table'          = @{ main = @( ,@( E 'Table read?' ) ) }
            'Table read?'         = @{ main = @( @( E $OnTable ), @( E 'Not an export' ) ) }
        }
        Entry     = 'Fetch telegram file'
        TableExpr = "({ rows: `$('Read table').first().json.rows })"
    }
}
