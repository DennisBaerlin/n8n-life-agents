#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_fetch_telegram_file ------------------------
# Wiederverwendbarer Baustein (tool = fokussierte Einzweck-Faehigkeit, Eingang->Ausgang):
# Telegram-file_id (Foto ODER Dokument/PDF) -> Download -> Binaer-Validierung (Groesse/MIME/HEIC)
# -> base64 -> { ok, b64, mime, error }. REINES PLUMBING: keine Vision, kein LLM, kein API-Key
# -- die Bezahl-Schluessel-/Vision-Privacy lebt im FINANZ-Konsumenten
# (agent.finance.tool_extract_finance_document), der diesen Baustein inline ruft und das Bild selbst
# per Vision erkennt. DUAL-USE: inline per executeWorkflow ODER als Agent-Tool bindbar (gleicher
# executeWorkflowTrigger-Eingang). Vorbild 1:1: agent.tool_transcribe_telegram_voice.
function Build-FetchTelegramFile {
    # Eingang: file_id (chat_id kommt via Build-Trigger automatisch dazu, hier ungenutzt durchgereicht).
    $trig = Build-Trigger @('file_id') @(-640, 0)

    $ifEmpty = Build-If 'File id empty?' @(-420, 0) `
        "={{ (`$('Start').item.json.file_id || '').trim().length }}" '0' 'equals' 'number'
    # Relaybare DATEN (inline-konsumiert) -- KEIN Build-ToolError (das ist fuer Agent-Tool-Pfade).
    $errEmpty = Build-Set 'No file id' @(-200, -160) @(
        ,@('ok',    'false',            'boolean')
        ,@('error', 'No file_id given.','string')
        ,@('b64',   '',                 'string')
        ,@('mime',  '',                 'string')
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
    # JEDER return liefert ALLE vier Keys (ok/b64/mime/error) -> einheitlicher Shape ueber alle Zweige
    # (sonst null-Refs im Return). runOnceForAllItems -> Array-Return.
    $jsB64 = @'
const item = items[0];
const meta = item.binary && item.binary.data ? item.binary.data : null;
if (!meta) return [{ json: { ok: false, error: 'no binary file received from Telegram', b64: '', mime: '' } }];
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
if (!buf || !buf.length) return [{ json: { ok: false, error: 'empty file', b64: '', mime: '' } }];
if (buf.length > 10 * 1024 * 1024) return [{ json: { ok: false, error: 'file too large (max 10 MB)', b64: '', mime: '' } }];
const mime = meta.mimeType || 'image/jpeg';
if (mime === 'image/heic' || mime === 'image/heif') return [{ json: { ok: false, error: 'HEIC/HEIF images are not supported - ask the user to send it as a normal photo (JPG/PNG) or as PDF', b64: '', mime: '' } }];
const allowed = ['image/jpeg','image/png','image/webp','image/gif','application/pdf'];
if (!allowed.includes(mime)) return [{ json: { ok: false, error: 'unsupported file type ' + mime + ' (send a photo or PDF)', b64: '', mime: '' } }];
if (mime !== 'application/pdf' && Math.ceil(buf.length / 3) * 4 > 5 * 1024 * 1024) return [{ json: { ok: false, error: 'image too large (max 5 MB) - ask the user to send a smaller photo or a PDF', b64: '', mime: '' } }];
return [{ json: { ok: true, b64: buf.toString('base64'), mime, error: '' } }];
'@
    $toB64 = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsB64 }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(20, 60)
        id = (New-Id)
        name = 'To base64'
    }

    # Rueckgabe-Vertrag: { ok, b64, mime, error } -- beide Zweige (No file id / To base64) konvergieren hier.
    $ret = Build-Return @(240, 0) @(
        ,@('ok',    "={{ `$json.ok }}",    'boolean')
        ,@('b64',   "={{ `$json.b64 }}",   'string')
        ,@('mime',  "={{ `$json.mime }}",  'string')
        ,@('error', "={{ `$json.error }}", 'string')
    )

    $sticky = Build-Sticky 'Doc: Telegram-Datei holen' @(-660, -300) -Header 'Ablauf' `
        'agent.tool_fetch_telegram_file (Baustein, KEIN LLM)' `
        'Eingang file_id (Telegram Foto ODER Dokument/PDF) -> Get document (Download, resource=file) -> To base64 (Binär-Validierung: Größe <=10 MB, Bilder <=5 MB als base64 (~3,75 MB roh), MIME jpeg/png/webp/gif + application/pdf — die Grenzen der Claude-Vision; HEIC/HEIF freundlich abgelehnt) -> Return { ok, b64, mime, error }. Leere file_id / unbrauchbare Datei -> { ok:false, error } als DATEN (inline-konsumiert, KEIN Tool-Error). REINES PLUMBING: keine Vision, kein LLM, kein API-Key -- die Bezahl-API-/Vision-Privacy lebt im Finanz-Konsumenten (tool_extract_finance_document). DUAL-USE: inline per executeWorkflow ODER als Agent-Tool bindbar.' 300 560

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
