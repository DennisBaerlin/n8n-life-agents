#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope; Bausteine aus ../paperless_common.ps1).

# --- agent.paperless.tool_get_document (read-only, kein HITL) ----------------------------------------
# EIN Dokument lesen (E2): Metadaten + Volltext (Cap 15 000 Zeichen, truncated:true). Aufruf NUR ueber den Core-
# Vermittler agent.sub_dispatch_tool (Service 'paperless:get_document', permission adults_only).
# Ablauf: Parse args (document_id Pflicht, nur Ziffern) -> Adresse lesen -> GET /api/documents/<id>/ -> ok? ->
# Namensaufloesung -> Shape document.
function Build-PaperlessGetDocument {
    $extra = "if (!/^[1-9][0-9]{0,11}`$/.test(out.document_id)) return bad('document_id must be the numeric Paperless id from search_documents');"
    $head = New-PaperlessToolHead 'get_document' 'Get document' $extra

    $get = New-PaperlessHttp 'Get document' @(1000, 0) "$($script:PaperlessBaseJs) + '/api/documents/' + `$('Parse args').first().json.document_id + '/'"
    $getOk = Build-If 'Document ok?' @(1200, 0) "={{ Number(`$json.statusCode) }}" '200' 'equals' 'number'

    $docsJs = "[`$('Get document').first().json.body || {}]"
    $lookups = New-PaperlessNameLookups $docsJs 'Shape document' 1400 0

    $failJs = $script:PaperlessErrJs + @'

const e = pErr($('Get document').first().json) || { ok: false, error: 'paperless_error', hint: 'Unexpected answer from Paperless. Do not retry; tell the user.' };
return [{ json: e }];
'@
    $fail = [ordered]@{
        parameters = [ordered]@{ jsCode = $failJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1400, 180); id = (New-Id); name = 'Document failed'
    }

    $shapeJs = "const BASE = $($script:PaperlessBaseJs);`n" + $script:PaperlessNamesJs + @"

const UNTRUSTED = '$($script:PaperlessUntrusted)';
"@ + @'

const CAP = 15000;
const d = $('Get document').first().json.body || {};
// HTTP 200, aber keine Paperless-API-Antwort (z. B. Login-/Proxy-Seite unter der Adresse) -> Fehler, NIE leeres Dokument.
if (typeof d !== 'object' || d.id == null) return [{ json: { ok: false, error: 'paperless_error', hint: 'The address did not answer like the Paperless API (wrong address, login page or proxy page?). Do not retry; tell the user the document archive seems misconfigured (owner: lifeagents reconfigure paperless).' } }];
const o = meta(d);
const text = String(d.content || '');
o.truncated = text.length > CAP;
o.content = text.slice(0, CAP);
if (d.original_file_name) o.file_name = d.original_file_name;
return [{ json: Object.assign({ ok: true, untrusted: UNTRUSTED }, o,
  o.truncated ? { note: 'The text was cut after ' + CAP + ' characters. For a question about the full document use ask_documents with this document_id.' } : {}) }];
'@
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = $shapeJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(2000, 0); id = (New-Id); name = 'Shape document'
    }

    $sticky = Build-Sticky 'Doc: Überblick' @(0, -420) 'agent.paperless.tool_get_document — ein Dokument lesen (read-only)' (@'
Wird NUR ueber den Core-Vermittler agent.sub_dispatch_tool gerufen (Service paperless:get_document; Paket aktiv + nur Erwachsene prueft core.fn_resolve_service). Eingang: args (JSON) + chat_id (ungenutzt).
**Eingabe:** document_id (Pflicht, nur Ziffern — die id aus search_documents).
**Paperless:** GET /api/documents/<id>/ (Accept version=10). 404 = gibt es nicht ODER fuer den Paperless-Nutzer unsichtbar (Objekt-Rechte) -> not_found.
**Ausgabe:** {ok:true, untrusted, id, title, created, correspondent?, document_type?, tags?, link, content, truncated} — Volltext auf 15 000 Zeichen gekappt (truncated:true + Hinweis auf ask_documents).
'@) 400 560 'Ablauf'

    $nodes = @($head.Nodes) + @($get, $getOk, $fail) + @($lookups.Nodes) + @($shape, $sticky, (New-PaperlessErrorSticky))
    $conns = [ordered]@{}
    foreach ($k in $head.Connections.Keys) { $conns[$k] = $head.Connections[$k] }
    $conns['Get document'] = @{ main = @( ,@( E 'Document ok?' ) ) }
    $conns['Document ok?'] = @{ main = @( @( E $lookups.First ), @( E 'Document failed' ) ) }
    foreach ($k in $lookups.Connections.Keys) { $conns[$k] = $lookups.Connections[$k] }
    return Build-Workflow 'agent.paperless.tool_get_document' $nodes $conns @{ Category = 'documents' }
}
