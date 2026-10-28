#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_fetch_telegram_file ------------------------
# Wiederverwendbarer Baustein (tool = fokussierte Einzweck-Faehigkeit, Eingang->Ausgang):
# Telegram-file_id (Foto ODER Dokument/PDF) -> Download -> Binaer-Validierung (Groesse/MIME/HEIC)
# -> base64 -> { ok, b64, mime, text, error }. Opt-in accept='csv' (Broker-CSV Paket B): zusaetzlich eine Textdatei mit
# Endung .csv -> text (UTF-8, BOM entfernt) statt b64; ohne accept unveraendert (text immer leer).
# REINES PLUMBING: keine Vision, kein LLM, kein API-Key
# -- die Bezahl-Schluessel-/Vision-Privacy lebt im FINANZ-Konsumenten
# (agent.finance.tool_extract_finance_document), der diesen Baustein inline ruft und das Bild selbst
# per Vision erkennt. DUAL-USE: inline per executeWorkflow ODER als Agent-Tool bindbar (gleicher
# executeWorkflowTrigger-Eingang). Vorbild 1:1: agent.tool_transcribe_telegram_voice.
function Build-FetchTelegramFile {
    # Eingang: file_id, accept (opt, 'csv'; chat_id kommt via Build-Trigger automatisch dazu, hier ungenutzt durchgereicht).
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
    # JEDER return liefert ALLE fuenf Keys (ok/b64/mime/text/error) -> einheitlicher Shape ueber alle Zweige
    # (sonst null-Refs im Return). runOnceForAllItems -> Array-Return.
    # CSV (nur mit accept='csv'): n8n leitet mimeType aus der Endung des Telegram-Dateipfads ab (Telegram-Node:
    # lookup(fileName) || application/octet-stream) -> Endung .csv entscheidet, der Inhalt muss Text sein (kein NUL-Byte).
    $jsB64 = @'
const item = items[0];
const res = (o) => [{ json: Object.assign({ ok: false, b64: '', mime: '', text: '', error: '' }, o) }];
const meta = item.binary && item.binary.data ? item.binary.data : null;
if (!meta) return res({ error: 'no binary file received from Telegram' });
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
if (!buf || !buf.length) return res({ error: 'empty file' });
if (buf.length > 10 * 1024 * 1024) return res({ error: 'file too large (max 10 MB)' });
const mime = meta.mimeType || 'image/jpeg';
const accept = String($('Start').first().json.accept || '').toLowerCase();
const ext = String(meta.fileExtension || (meta.fileName || '').split('.').pop() || '').toLowerCase();
const csvMimes = ['text/csv', 'text/comma-separated-values', 'text/plain', 'application/vnd.ms-excel', 'application/octet-stream'];
if (accept === 'csv' && ext === 'csv' && csvMimes.includes(mime)) {
  if (buf.includes(0)) return res({ error: 'the CSV file is not a text file' });
  return res({ ok: true, mime: 'text/csv', text: buf.toString('utf8').replace(/^﻿/, '') });
}
// ohne accept=csv: CSV als Fehler, aber mit mime text/csv -> der Konsument kann auf seinen CSV-Weg verweisen
if (ext === 'csv') return res({ mime: 'text/csv', error: 'this is a CSV file, not a photo or PDF' });
if (mime === 'image/heic' || mime === 'image/heif') return res({ error: 'HEIC/HEIF images are not supported - ask the user to send it as a normal photo (JPG/PNG) or as PDF' });
const allowed = ['image/jpeg','image/png','image/webp','image/gif','application/pdf'];
if (!allowed.includes(mime)) return res({ error: 'unsupported file type ' + mime + (accept === 'csv' ? ' (send the CSV export file)' : ' (send a photo or PDF)') });
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

    # Rueckgabe-Vertrag: { ok, b64, mime, text, error } -- beide Zweige (No file id / To base64) konvergieren hier.
    $ret = Build-Return @(240, 0) @(
        ,@('ok',    "={{ `$json.ok }}",    'boolean')
        ,@('b64',   "={{ `$json.b64 }}",   'string')
        ,@('mime',  "={{ `$json.mime }}",  'string')
        ,@('text',  "={{ `$json.text }}",  'string')
        ,@('error', "={{ `$json.error }}", 'string')
    )

    $sticky = Build-Sticky 'Doc: Telegram-Datei holen' @(-660, -300) -Header 'Ablauf' `
        'agent.tool_fetch_telegram_file (Baustein, KEIN LLM)' `
        'Eingang file_id (Telegram Foto ODER Dokument/PDF) -> Get document (Download, resource=file) -> To base64 (Binär-Validierung: Größe <=10 MB, Bilder <=5 MB als base64 (~3,75 MB roh), MIME jpeg/png/webp/gif + application/pdf — die Grenzen der Claude-Vision; HEIC/HEIF freundlich abgelehnt; mit accept=csv zusätzlich eine Datei mit Endung .csv als Text, BOM entfernt) -> Return { ok, b64, mime, text, error } (text nur bei CSV, sonst leer). Leere file_id / unbrauchbare Datei -> { ok:false, error } als DATEN (inline-konsumiert, KEIN Tool-Error). REINES PLUMBING: keine Vision, kein LLM, kein API-Key -- die Bezahl-API-/Vision-Privacy lebt im Finanz-Konsumenten (tool_extract_finance_document). DUAL-USE: inline per executeWorkflow ODER als Agent-Tool bindbar.' 300 560

    $nodes = @($trig, $ifEmpty, $errEmpty, $getFile, $toB64, $ret, $sticky)

    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'File id empty?' ) ) }
        'File id empty?' = @{ main = @(
            @( E 'No file id' ),
            @( E 'Get document' )
        ) }
        'Get document'   = @{ main = @( ,@( E 'To base64' ) ) }
        'To base64'      = @{ main = @( ,@( E 'Return' ) ) }
        'No file id'     = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.tool_fetch_telegram_file' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
