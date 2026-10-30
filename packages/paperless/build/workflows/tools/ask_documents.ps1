#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope; Bausteine aus ../paperless_common.ps1).

# --- agent.paperless.tool_ask_documents (read-only, kein HITL) ---------------------------------------
# Inhaltsfrage an die Paperless-eigene Dokumenten-KI (E3): POST /api/documents/chat/ {q, document_id?} — der einzige
# POST, er LIEST nur (E8). Paperless antwortet als text/event-stream mit reinem Text + Trailer
# '__PAPERLESS_CHAT_METADATA__{"references":[{id,title}]}' (Spike (d), Paperless 3.3.2; ~23 s) -> Antwort als Text
# lesen, am Trailer splitten. Die KI laeuft IN Paperless mit dem dort eingestellten Anbieter (ausserhalb dieses
# Systems — Setup-Hilfe sagt es). Aufruf NUR ueber den Core-Vermittler (Service 'paperless:ask_documents', adults_only).
function Build-PaperlessAskDocuments {
    # Paperless-ids beginnen bei 1: '0' kam frueher durch (truthy String -> document_id 0) und Paperless fragte dann ueber
    # ALLE Dokumente (Live-Befund 2026-10-30, Platzhalter-Aufruf eines Agenten).
    $extra ="if (out.document_id !== undefined && !/^[1-9][0-9]{0,11}`$/.test(out.document_id)) return bad('document_id must be the numeric Paperless id from search_documents, or empty');"
    $head = New-PaperlessToolHead 'ask_documents' 'Ask Paperless' $extra

    $bodyJs = "JSON.stringify(Object.assign({ q: `$('Parse args').first().json.question }, " +
              "`$('Parse args').first().json.document_id ? { document_id: Number(`$('Parse args').first().json.document_id) } : {}))"
    $ask = New-PaperlessHttp 'Ask Paperless' @(1000, 0) "$($script:PaperlessBaseJs) + '/api/documents/chat/'" `
        -Method 'POST' -JsonBodyExpr $bodyJs -TimeoutMs 180000 -ResponseFormat 'text' -NoRetry

    $shapeJs = $script:PaperlessErrJs + "`nconst BASE = $($script:PaperlessBaseJs);`n" + @"
const UNTRUSTED = '$($script:PaperlessUntrusted)';
"@ + @'

const r = $('Ask Paperless').first().json;
const e = pErr(r);
if (e) return [{ json: e }];
// HTTP 200, aber eine HTML-Seite (Login-/Proxy-Seite unter der Adresse) -> Fehler, NIE als KI-Antwort ausgeben.
const ctype = String(((r.headers || {})['content-type']) || '');
if (/text\/html/i.test(ctype)) return [{ json: { ok: false, error: 'paperless_error', hint: 'The address did not answer like the Paperless API (wrong address, login page or proxy page?). Do not retry; tell the user the document archive seems misconfigured (owner: lifeagents reconfigure paperless).' } }];
const raw = typeof r.body === 'string' ? r.body : (typeof r.data === 'string' ? r.data : JSON.stringify(r.body || r.data || ''));
const MARK = '__PAPERLESS_CHAT_METADATA__';
const at = raw.indexOf(MARK);
let answer = (at >= 0 ? raw.slice(0, at) : raw).trim();
let references = [];
if (at >= 0) {
  try {
    const m = JSON.parse(raw.slice(at + MARK.length).trim());
    references = (Array.isArray(m.references) ? m.references : [])
      .filter(x => x && x.id != null)
      .map(x => ({ id: String(x.id), title: x.title || '', link: BASE + '/documents/' + x.id + '/details' }));
  } catch (err) { references = []; }
}
const CAP = 6000;
const truncated = answer.length > CAP;
answer = answer.slice(0, CAP);
if (!answer) return [{ json: { ok: false, error: 'paperless_error', hint: 'The Paperless document AI returned no answer. Try search_documents and get_document instead.' } }];
return [{ json: { ok: true, untrusted: UNTRUSTED, answer, truncated, references,
  note: 'This answer comes from the Paperless AI. Name the source documents (title + link) and do not add facts that are not in it.' } }];
'@
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = $shapeJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1200, 0); id = (New-Id); name = 'Shape answer'
    }

    $sticky = Build-Sticky 'Doc: Überblick' @(0, -420) 'agent.paperless.tool_ask_documents — Frage an die Paperless-KI (read-only)' (@'
Wird NUR ueber den Core-Vermittler agent.sub_dispatch_tool gerufen (Service paperless:ask_documents; Paket aktiv + nur Erwachsene prueft core.fn_resolve_service). Eingang: args (JSON) + chat_id (ungenutzt).
**Eingabe:** question (Pflicht), document_id (optional, Paperless-id ab 1 -> Frage nur zu diesem Dokument; 0 wird abgewiesen, sonst fragte Paperless über alle Dokumente).
**Paperless:** POST /api/documents/chat/ {q, document_id?} — liest nur. Antwort = text/event-stream mit reinem Text + Trailer __PAPERLESS_CHAT_METADATA__{references} -> als TEXT gelesen und am Trailer getrennt. Dauer ~20-60 s -> Timeout 180 s, KEIN Retry.
**KI-Anbieter:** der in Paperless eingestellte (ausserhalb dieses Systems). KI in Paperless aus -> HTTP 400 -> paperless_ai_disabled (Suche/Lesen gehen weiter).
**Ausgabe:** {ok:true, untrusted, answer (max 6000 Zeichen), truncated, references[{id,title,link}]}.
'@) 400 560 'Ablauf'

    $nodes = @($head.Nodes) + @($ask, $shape, $sticky, (New-PaperlessErrorSticky @(1000, 300)))
    $conns = [ordered]@{}
    foreach ($k in $head.Connections.Keys) { $conns[$k] = $head.Connections[$k] }
    $conns['Ask Paperless'] = @{ main = @( ,@( E 'Shape answer' ) ) }
    return Build-Workflow 'agent.paperless.tool_ask_documents' $nodes $conns @{ Category = 'documents' }
}
