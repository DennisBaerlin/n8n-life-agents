// mock_paperless/server.js — lokaler Mock einer Paperless-NGX-v3-Instanz fuer die Infra-Tiers (paperless Phase 2).
//
// ZWECK: deterministisches, gratis Testen der drei read-only Paperless-Werkzeuge (agent.paperless.tool_*) OHNE
//   echte Instanz. Die Antwort-Formen spiegeln den Spike (d) gegen Paperless 3.3.2 (Plan quiet-watching-meadow):
//   - GET  /api/documents/?query=…&page_size=…&fields=…   -> {count, results[{…, __search_hit__.highlights mit <b>}]}
//   - GET  /api/documents/<id>/                          -> Dokument inkl. content (Volltext)
//   - GET  /api/{correspondents,document_types,tags}/?id__in=…  -> nur SICHTBARE Objekte (Objekt-Rechte!)
//   - POST /api/documents/chat/ {q, document_id?}        -> text/event-stream, REINER Text + Trailer
//                                                           __PAPERLESS_CHAT_METADATA__{"references":[…]}
//   Auth: Header 'Authorization: Token <MOCK_TOKEN>' (sonst 401); Accept muss 'version=10' tragen (sonst 406).
//
// MAGISCHE AUSLOESER (die Werkzeuge senden immer gueltigen Token + Version — ohne Ausloeser waeren 401/406 nie
// erreichbar, Plan-Reviewer F5):
//   Suche  query '__reset__' -> Socket-Abbruch (Netzfehler)   query '__500__' -> HTTP 500   query '__empty__' -> 0 Treffer
//          query '__html__' -> HTTP 200 mit HTML-Seite (falsche Adresse / Login-Seite)
//   Lesen  id 404 -> 404   id 401 -> 401   id 406 -> 406   id 11 -> langer Text (> 15 000 Zeichen)
//   Chat   q enthaelt '__ai_off__' -> 400 "AI is required"   '__no_trailer__' -> Antwort ohne Trailer
//
// LAEUFT IM CONTAINER (127.0.0.1:<port>); der Treiber scripts/dev/enable_mock_paperless.ps1 setzt
// general.paperless_url auf den Mock + die Token-Credential auf den Mock-Token. Jede Anfrage wird als JSON-Zeile
// in LOG_FILE aufgezeichnet. Bewusst dependency-frei (nur Node-Core).
'use strict';
const http = require('http');
const fs = require('fs');

const PORT = parseInt(process.env.N8NTEST_MOCK_PL_PORT || '8092', 10);
const LOG_FILE = process.env.N8NTEST_MOCK_PL_LOG || '/tmp/mock_paperless.jsonl';
const MOCK_TOKEN = process.env.N8NTEST_MOCK_PL_TOKEN || 'mock-paperless-token';

const CORRESPONDENTS = { 3: 'Hausverwaltung Muster', 4: 'Finanzamt Musterstadt' };
const DOC_TYPES = { 5: 'Vertrag', 6: 'Brief' };          // 95 existiert, ist aber fuer den Bot-Nutzer UNSICHTBAR
const TAGS = { 1: 'Wohnung', 2: 'Wichtig' };              // 77 existiert, ist aber UNSICHTBAR

const DOCS = {
  11: { id: 11, title: 'Mietvertrag Wohnung', created: '2021-03-01', correspondent: 3, document_type: 5, tags: [1, 2, 77],
        original_file_name: 'mietvertrag.pdf', content: 'Mietvertrag zwischen Hausverwaltung Muster und Erika Mustermann. ' + 'Paragraph. '.repeat(1600) },
  12: { id: 12, title: 'Bescheid Einkommensteuer', created: '2024-06-12', correspondent: 4, document_type: 95, tags: [77],
        original_file_name: 'bescheid.pdf', content: 'Einkommensteuerbescheid fuer 2023. Erstattung 312,00 EUR.' },
};

function log(entry) {
  try { fs.appendFileSync(LOG_FILE, JSON.stringify(Object.assign({ ts: new Date().toISOString() }, entry)) + '\n'); } catch (e) { /* Log ist best effort */ }
}
function send(res, status, body, type) {
  const isText = typeof body === 'string';
  res.writeHead(status, { 'Content-Type': type || (isText ? 'text/plain' : 'application/json') });
  res.end(isText ? body : JSON.stringify(body));
}
function listOf(map, idsParam) {
  const ids = String(idsParam || '').split(',').map(s => parseInt(s, 10)).filter(n => !isNaN(n));
  const results = ids.filter(id => map[id]).map(id => ({ id, name: map[id] }));
  return { count: results.length, next: null, previous: null, results };
}

const server = http.createServer((req, res) => {
  let raw = '';
  req.on('data', c => { raw += c; });
  req.on('end', () => {
    const url = new URL(req.url, 'http://mock');
    const path = url.pathname;
    log({ method: req.method, path, query: Object.fromEntries(url.searchParams), auth: req.headers['authorization'] ? 'set' : 'missing', accept: req.headers['accept'] || '', body: raw.slice(0, 500) });

    if (path === '/__health') return send(res, 200, 'ok');
    if (req.headers['authorization'] !== 'Token ' + MOCK_TOKEN) return send(res, 401, { detail: 'Invalid token.' });
    if (!/version=10/.test(String(req.headers['accept'] || ''))) return send(res, 406, { detail: 'Invalid version in "Accept" header.' });

    // --- Suche ---
    if (req.method === 'GET' && path === '/api/documents/') {
      const q = url.searchParams.get('query') || '';
      if (q === '__reset__') { req.socket.destroy(); return; }
      if (q === '__500__') return send(res, 500, { detail: 'Server error' });
      if (q === '__html__') return send(res, 200, '<html><body>Login</body></html>', 'text/html');   // falsche Adresse/Login-Seite
      const size = Math.max(1, parseInt(url.searchParams.get('page_size') || '25', 10));
      const hits = q === '__empty__' ? [] : Object.values(DOCS);
      const results = hits.slice(0, size).map(d => ({
        id: d.id, title: d.title, created: d.created, correspondent: d.correspondent, document_type: d.document_type, tags: d.tags,
        __search_hit__: { score: 1, highlights: 'Der <b>' + q + '</b> regelt die <b>Miete</b> fuer die Wohnung.', rank: 1 },
      }));
      return send(res, 200, { count: hits.length, next: null, previous: null, results });
    }

    // --- Ein Dokument ---
    const m = path.match(/^\/api\/documents\/(\d+)\/$/);
    if (req.method === 'GET' && m) {
      const id = parseInt(m[1], 10);
      if (id === 401) return send(res, 401, { detail: 'Invalid token.' });
      if (id === 406) return send(res, 406, { detail: 'Invalid version in "Accept" header.' });
      const d = DOCS[id];
      if (!d) return send(res, 404, { detail: 'No Document matches the given query.' });
      return send(res, 200, d);
    }

    // --- Namensaufloesung (nur Sichtbares) ---
    if (req.method === 'GET' && path === '/api/correspondents/') return send(res, 200, listOf(CORRESPONDENTS, url.searchParams.get('id__in')));
    if (req.method === 'GET' && path === '/api/document_types/') return send(res, 200, listOf(DOC_TYPES, url.searchParams.get('id__in')));
    if (req.method === 'GET' && path === '/api/tags/') return send(res, 200, listOf(TAGS, url.searchParams.get('id__in')));

    // --- Dokumenten-Chat (Paperless-KI) ---
    if (req.method === 'POST' && path === '/api/documents/chat/') {
      let body = {};
      try { body = JSON.parse(raw || '{}'); } catch (e) { return send(res, 400, { detail: 'Invalid JSON' }); }
      const q = String(body.q || '');
      if (q.includes('__ai_off__')) return send(res, 400, { detail: 'AI is required for this feature' });
      const answer = 'Laut Mietvertrag betraegt die Kuendigungsfrist drei Monate.';
      if (q.includes('__no_trailer__')) return send(res, 200, answer + ' (ohne Quellen)', 'text/event-stream');
      const refs = [{ id: 11, title: 'Mietvertrag Wohnung' }];
      return send(res, 200, answer + '\n\n__PAPERLESS_CHAT_METADATA__' + JSON.stringify({ references: refs }), 'text/event-stream');
    }

    return send(res, 404, { detail: 'Not found.' });
  });
});

server.listen(PORT, '127.0.0.1', () => { log({ event: 'listening', port: PORT }); });
