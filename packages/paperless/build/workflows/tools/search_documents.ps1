#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope; Bausteine aus ../paperless_common.ps1).

# --- agent.paperless.tool_search_documents (read-only, kein HITL) -------------------------------------
# Volltextsuche in der Paperless-Instanz des Haushalts (E1). Aufruf NUR ueber den Core-Vermittler
# agent.sub_dispatch_tool (Service 'paperless:search_documents', permission adults_only) — Eingang args (JSON) + chat_id.
# Ablauf: Parse args (Manifest-inputs: query Pflicht, limit Default 5) -> Adresse lesen -> GET /api/documents/?query=
# -> Suche ok? -> Namensaufloesung (3 GETs) -> Shape results ({ok:true, untrusted, total, documents[]}).
function Build-PaperlessSearchDocuments {
    $extra = "out.limit = Math.max(1, Math.min(20, Math.round(out.limit || 5)));"
    $head = New-PaperlessToolHead 'search_documents' 'Search' $extra

    $search = New-PaperlessHttp 'Search' @(1000, 0) "$($script:PaperlessBaseJs) + '/api/documents/'" -Query ([ordered]@{
        query     = "={{ `$('Parse args').first().json.query }}"
        page_size = "={{ String(`$('Parse args').first().json.limit) }}"
        fields    = 'id,title,created,correspondent,document_type,tags,__search_hit__'
    })
    $searchOk = Build-If 'Search ok?' @(1200, 0) "={{ Number(`$json.statusCode) }}" '200' 'equals' 'number'

    $docsJs = "((`$('Search').first().json.body || {}).results || [])"
    $lookups = New-PaperlessNameLookups $docsJs 'Shape results' 1400 0

    $failJs = $script:PaperlessErrJs + @'

const e = pErr($('Search').first().json) || { ok: false, error: 'paperless_error', hint: 'Unexpected search answer from Paperless. Do not retry; tell the user.' };
return [{ json: e }];
'@
    $fail = [ordered]@{
        parameters = [ordered]@{ jsCode = $failJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1400, 180); id = (New-Id); name = 'Search failed'
    }

    $shapeJs = "const BASE = $($script:PaperlessBaseJs);`n" + $script:PaperlessNamesJs + @"

const UNTRUSTED = '$($script:PaperlessUntrusted)';
"@ + @'

const body = $('Search').first().json.body || {};
// HTTP 200, aber keine Paperless-API-Antwort (z. B. Login-/Proxy-Seite unter der Adresse) -> Fehler, NIE "0 Treffer".
if (!Array.isArray(body.results)) return [{ json: { ok: false, error: 'paperless_error', hint: 'The address did not answer like the Paperless API (wrong address, login page or proxy page?). Do not retry; tell the user the document archive seems misconfigured (owner: lifeagents reconfigure paperless).' } }];
const results = body.results;
const strip = (h) => String(h || '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim().slice(0, 300);
const documents = results.map(d => {
  const o = meta(d);
  const hit = d.__search_hit__ || {};
  const snip = strip(hit.highlights);
  if (snip) o.snippet = snip;
  return o;
});
return [{ json: { ok: true, untrusted: UNTRUSTED, total: Number(body.count) || documents.length, returned: documents.length, documents,
  note: documents.length ? 'Use get_document with an id to read a document; cite title, date and link.' : 'No document matched. Try other or fewer search words (e.g. the insurer or the document type).' } }];
'@
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = $shapeJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(2000, 0); id = (New-Id); name = 'Shape results'
    }

    $sticky = Build-Sticky 'Doc: Überblick' @(0, -420) 'agent.paperless.tool_search_documents — Volltextsuche (read-only)' (@'
Wird NUR ueber den Core-Vermittler agent.sub_dispatch_tool gerufen (Service paperless:search_documents; dort prueft core.fn_resolve_service Paket aktiv + nur Erwachsene). Eingang: args (JSON-String der Modell-Felder) + chat_id (hier ungenutzt).
**Eingabe-Pruefung:** Regeln aus manifest.json provides.services.search_documents.inputs (eine Quelle mit dem Modell-Schema); limit auf 1-20 begrenzt.
**Adresse:** zur Laufzeit core.fn_config_get (paperless_ro) — leer -> not_configured.
**Paperless:** GET /api/documents/?query=… (Accept version=10, Token-Credential). Danach Namen fuer Korrespondent/Typ/Tags; was der Paperless-Nutzer nicht sehen darf, wird weggelassen.
**Ausgabe:** {ok:true, untrusted, total, documents[{id,title,created,correspondent?,document_type?,tags?,snippet?,link}]} — Treffer-Hervorhebungen ohne HTML.
'@) 400 560 'Ablauf'
    $stickyErr = New-PaperlessErrorSticky

    $nodes = @($head.Nodes) + @($search, $searchOk, $fail) + @($lookups.Nodes) + @($shape, $sticky, $stickyErr)
    $conns = [ordered]@{}
    foreach ($k in $head.Connections.Keys) { $conns[$k] = $head.Connections[$k] }
    $conns['Search']     = @{ main = @( ,@( E 'Search ok?' ) ) }
    $conns['Search ok?'] = @{ main = @( @( E $lookups.First ), @( E 'Search failed' ) ) }
    foreach ($k in $lookups.Connections.Keys) { $conns[$k] = $lookups.Connections[$k] }
    return Build-Workflow 'agent.paperless.tool_search_documents' $nodes $conns @{ Category = 'documents' }
}
