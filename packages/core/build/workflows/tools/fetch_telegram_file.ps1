#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_fetch_telegram_file ------------------------
# Wiederverwendbarer Baustein (tool = fokussierte Einzweck-Faehigkeit, Eingang->Ausgang):
# Telegram-file_id (Foto ODER Dokument/PDF) -> Download -> Binaer-Validierung (Groesse/MIME/HEIC)
# -> base64 -> { ok, b64, mime, text, rows, error }. Opt-in accept='table' (Bank-Import-Modul): zusaetzlich eine
# Textdatei mit Endung .csv -> text (UTF-8, BOM entfernt) bzw. eine Excel-Datei .xlsx -> rows (rohes Raster aus dem
# ersten Blatt, Extract From File) statt b64; ohne accept unveraendert (text leer, rows []).
# REINES PLUMBING: keine Vision, kein LLM, kein API-Key
# -- die Bezahl-Schluessel-/Vision-Privacy lebt im FINANZ-Konsumenten
# (agent.finance.tool_extract_finance_document), der diesen Baustein inline ruft und das Bild selbst
# per Vision erkennt. DUAL-USE: inline per executeWorkflow ODER als Agent-Tool bindbar (gleicher
# executeWorkflowTrigger-Eingang). Vorbild 1:1: agent.tool_transcribe_telegram_voice.
function Build-FetchTelegramFile {
    # Eingang: file_id, accept (opt, 'table'; chat_id kommt via Build-Trigger automatisch dazu, hier ungenutzt durchgereicht).
    $trig = Build-Trigger @('file_id', 'accept') @(-640, 0)

    $ifEmpty = Build-If 'File id empty?' @(-420, 0) `
        "={{ (`$('Start').item.json.file_id || '').trim().length }}" '0' 'equals' 'number'
    # Relaybare DATEN (inline-konsumiert) -- KEIN Build-ToolError (das ist fuer Agent-Tool-Pfade).
    $errEmpty = Build-Set 'No file id' @(-200, -160) @(
        ,@('ok',    'false',            'boolean')
        ,@('error', 'No file_id given.','string')
        ,@('b64',   '',                 'string')
        ,@('mime',  '',                 'string')
        ,@('text',  '',                 'string')
    )

    # Telegram-Download (resource=file) -- Form 1:1 aus dem alten Monolithen.
    $getFile = [ordered]@{
        parameters = [ordered]@{
            resource = 'file'
            fileId   = "={{ `$('Start').item.json.file_id }}"
            additionalFields = @{}
        }
        type = 'n8n-nodes-base.telegram'
        typeVersion = 1.2
        position = @(-200, 60)
        id = (New-Id)
        name = 'Get document'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 3000
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }

    # Binary -> base64 (helpers.getBinaryDataBuffer deckt memory- UND filesystem-BinaryMode ab).
    # JEDER return liefert ALLE Keys (ok/b64/mime/text/rows/error) -> einheitlicher Shape ueber alle Zweige
    # (sonst null-Refs im Return). runOnceForAllItems -> Array-Return.
    # Tabellen (nur mit accept='table'): n8n leitet mimeType aus der Endung des Telegram-Dateipfads ab (Telegram-Node:
    # lookup(fileName) || application/octet-stream) -> die Endung entscheidet. .csv: Inhalt muss Text sein (kein NUL-Byte).
    # .xlsx: Inhalt muss ein ZIP sein ('PK'); der Code reicht das Binary mit sheet:true weiter -> Read sheet liest es.
    $jsB64 = @'
const item = items[0];
const res = (o, bin) => [Object.assign({ json: Object.assign({ ok: false, b64: '', mime: '', text: '', rows: [], error: '' }, o) }, bin ? { binary: bin } : {})];
const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const meta = item.binary && item.binary.data ? item.binary.data : null;
if (!meta) return res({ error: 'no binary file received from Telegram' });
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
if (!buf || !buf.length) return res({ error: 'empty file' });
if (buf.length > 10 * 1024 * 1024) return res({ error: 'file too large (max 10 MB)' });
const mime = meta.mimeType || 'image/jpeg';
const accept = String($('Start').first().json.accept || '').toLowerCase();
const ext = String(meta.fileExtension || (meta.fileName || '').split('.').pop() || '').toLowerCase();
const csvMimes = ['text/csv', 'text/comma-separated-values', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream'];
if (accept === 'table' && ext === 'csv' && csvMimes.includes(mime)) {
  if (buf.includes(0)) return res({ error: 'the CSV file is not a text file' });
  return res({ ok: true, mime: 'text/csv', text: buf.toString('utf8').replace(/^﻿/, '') });
}
if (accept === 'table' && ext === 'xlsx') {
  if (buf[0] !== 0x50 || buf[1] !== 0x4B) return res({ error: 'the Excel file is damaged (not an .xlsx workbook)' });
  return res({ ok: true, mime: XLSX, sheet: true }, item.binary);
}
if (accept === 'table' && ext === 'xls') return res({ error: 'old Excel format (.xls) - ask the user to export the file as .xlsx or CSV' });
// ohne accept=table: Tabellen-Datei als Fehler, aber mit ihrem mime -> der Konsument kann auf den Export-Weg verweisen
if (ext === 'csv') return res({ mime: 'text/csv', error: 'this is a CSV file, not a photo or PDF' });
if (ext === 'xlsx' || ext === 'xls') return res({ mime: XLSX, error: 'this is an Excel file, not a photo or PDF' });
if (mime === 'image/heic' || mime === 'image/heif') return res({ error: 'HEIC/HEIF images are not supported - ask the user to send it as a normal photo (JPG/PNG) or as PDF' });
const allowed = ['image/jpeg','image/png','image/webp','image/gif','application/pdf'];
if (!allowed.includes(mime)) return res({ error: 'unsupported file type ' + mime + (accept === 'table' ? ' (send the export file: CSV or Excel)' : ' (send a photo or PDF)') });
if (mime !== 'application/pdf' && Math.ceil(buf.length / 3) * 4 > 5 * 1024 * 1024) return res({ error: 'image too large (max 5 MB) - ask the user to send a smaller photo or a PDF' });
return res({ ok: true, b64: buf.toString('base64'), mime });
'@
    $toB64 = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsB64 }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(20, 60)
        id = (New-Id)
        name = 'To base64'
    }

    # xlsx (nur accept='table'): Extract From File liest das ERSTE Blatt als Raster. headerRow=false -> je Zeile ein Item
    # {row:[...]} (sheet_to_json header:1), includeEmptyCells -> leere Zellen als '' (sonst verrutschen die Spalten).
    # typeVersion 1.2: echte Excel-Datumszellen kommen als ISO-Text (formatSpreadsheetDates). EIN Ausgang fuer alles:
    # kaputte Datei -> continueRegularOutput (Item mit json.error), leeres Blatt -> alwaysOutputData (leeres Item);
    # Collect rows unterscheidet beides (kein zweiter Fehler-Ausgang, sonst liefen beide Zweige bis Return).
    $ifSheet = Build-If 'Spreadsheet?' @(240, 60) "={{ `$json.sheet === true }}" 'true' 'equals' 'boolean'
    $readSheet = [ordered]@{
        parameters = [ordered]@{
            operation = 'xlsx'
            binaryPropertyName = 'data'
            options = [ordered]@{ headerRow = $false; includeEmptyCells = $true }
        }
        type = 'n8n-nodes-base.extractFromFile'
        typeVersion = 1.2
        position = @(460, 160)
        id = (New-Id)
        name = 'Read sheet'
        alwaysOutputData = $true
        onError = 'continueRegularOutput'
    }
    # alle Zeilen-Items -> EIN Item (sonst liefe der Aufrufer je Zeile einmal)
    $jsCollect = @'
const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const all = $input.all();
const out = (ok, rows, error) => [{ json: { ok, b64: '', mime: XLSX, text: '', rows, error } }];
if (all.some((i) => i.json && i.json.error)) return out(false, [], 'the Excel file could not be read');
const rows = all.map((i) => i.json.row).filter((r) => Array.isArray(r));
if (!rows.length) return out(false, [], 'the Excel file has no rows on its first sheet');
return out(true, rows, '');
'@
    $collect = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsCollect }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(680, 100)
        id = (New-Id)
        name = 'Collect rows'
    }

    # Rueckgabe-Vertrag: { ok, b64, mime, text, rows, error } -- alle Zweige konvergieren hier.
    $ret = Build-Return @(900, 0) @(
        ,@('ok',    "={{ `$json.ok }}",    'boolean')
        ,@('b64',   "={{ `$json.b64 }}",   'string')
        ,@('mime',  "={{ `$json.mime }}",  'string')
        ,@('text',  "={{ `$json.text }}",  'string')
        ,@('rows',  "={{ `$json.rows || [] }}", 'array')
        ,@('error', "={{ `$json.error }}", 'string')
    )

    $sticky = Build-Sticky 'Doc: Telegram-Datei holen' @(-660, -300) -Header 'Ablauf' `
        'agent.tool_fetch_telegram_file (Baustein, KEIN LLM)' `
        'Eingang file_id (Telegram Foto ODER Dokument/PDF) -> Get document (Download, resource=file) -> To base64 (Binär-Validierung: Größe <=10 MB, Bilder <=5 MB als base64 (~3,75 MB roh), MIME jpeg/png/webp/gif + application/pdf — die Grenzen der Claude-Vision; HEIC/HEIF freundlich abgelehnt; mit accept=table zusätzlich .csv als Text (BOM entfernt) und .xlsx als Raster) -> Return { ok, b64, mime, text, rows, error } (text nur bei CSV, rows nur bei Excel). Leere file_id / unbrauchbare Datei -> { ok:false, error } als DATEN (inline-konsumiert, KEIN Tool-Error). REINES PLUMBING: keine Vision, kein LLM, kein API-Key -- die Bezahl-API-/Vision-Privacy lebt im Finanz-Konsumenten (tool_extract_finance_document). DUAL-USE: inline per executeWorkflow ODER als Agent-Tool bindbar.' 300 560
    $stickySheet = Build-Sticky 'Excel-Zweig' @(240, 320) `
        'xlsx -> Raster (nur accept=table)' `
        'To base64 prüft Endung + ZIP-Kennung und reicht das Binary mit sheet:true weiter. Read sheet (Extract From File, erstes Blatt, headerRow aus, leere Zellen als leerer Text) liefert je Zeile ein Item; Collect rows fasst sie zu EINEM Rückgabe-Item rows[][] zusammen. Die Bedeutung (Kopfzeile, Bank) kennt dieser Baustein nicht, die erkennt der Konsument. Kaputte Datei oder leeres Blatt -> Collect rows liefert ok:false als Daten (ein Ausgang, nie zwei Rückgaben).' 400 260

    $nodes = @($trig, $ifEmpty, $errEmpty, $getFile, $toB64, $ifSheet, $readSheet, $collect, $ret, $sticky, $stickySheet)

    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'File id empty?' ) ) }
        'File id empty?' = @{ main = @(
            @( E 'No file id' ),
            @( E 'Get document' )
        ) }
        'Get document'   = @{ main = @( ,@( E 'To base64' ) ) }
        'To base64'      = @{ main = @( ,@( E 'Spreadsheet?' ) ) }
        'Spreadsheet?'   = @{ main = @( @( E 'Read sheet' ), @( E 'Return' ) ) }
        'Read sheet'     = @{ main = @( ,@( E 'Collect rows' ) ) }
        'Collect rows'   = @{ main = @( ,@( E 'Return' ) ) }
        'No file id'     = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.tool_fetch_telegram_file' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
