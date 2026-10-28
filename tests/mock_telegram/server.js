// mock_telegram/server.js — lokaler Mock von api.telegram.org fuer die Test-Tiers (Teststrategie Phase 5).
//
// ZWECK: deterministisches, gratis Testen des echten Telegram-Pfads OHNE die Bot-API anzufassen.
//   1) Jeder ausgehende Bot-API-Call (sendMessage, getMe, ...) wird als JSON-Zeile in LOG_FILE
//      aufgezeichnet -> der Harness kann das Payload pruefen (z. B. Markdown-Escaping, das gegen die
//      echte API als 400 crasht) und die HITL-Resume-URL aus den inline_keyboard-Buttons fischen.
//   2) Jede Antwort hat die Telegram-Form { ok:true, result:... } -> n8ns Telegram-Node laeuft normal
//      weiter (sendAndWait suspendiert sauber statt zu erroren).
//
// LAEUFT IM CONTAINER (n8n erreicht ihn ueber 127.0.0.1:<port>); umgebogen wird der Node per
// Credential-baseUrl (telegramApi.data.baseUrl -> http://127.0.0.1:<port>, gesetzt vom Treiber
// scripts/dev/enable_mock_telegram.ps1 per REST-PATCH). Der Telegram-Node baut die URL als
// `${baseUrl}/bot${accessToken}/${method}` (n8n-nodes-base GenericFunctions.js) -> der Pfad-Token
// ist hier egal (der Mock authentifiziert nicht).
//
// Bewusst dependency-frei (nur Node-Core) und winzig: kein npm install, Node ist durch n8n garantiert.
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.N8NTEST_MOCK_TG_PORT || '8089', 10);
const LOG_FILE = process.env.N8NTEST_MOCK_TG_LOG || '/tmp/mock_telegram.jsonl';

// Echte Test-Dokumente je file_id (tests/mock_telegram/docs/<file_id>.<png|pdf>, erzeugt von make_doc_fixtures.ps1,
// kopiert von enable_mock_telegram.ps1): der Echt-LLM-Tier liest damit ein lesbares Dokument statt des 1x1-PNG.
// Fehlt das Dokument, bleibt alles wie bisher (1x1-PNG fuer mock_photo_*).
const DOC_DIR = path.join(__dirname, 'docs');
function docFor(fid) {
  for (const ext of ['pdf', 'png', 'csv']) {
    const p = path.join(DOC_DIR, fid + '.' + ext);
    if (fs.existsSync(p)) return { ext, p };
  }
  return null;
}

let messageId = 1000;

// Befehlsmenues wie die echte Bot-API: setMyCommands speichert je (scope, language_code), getMyCommands liefert
// GENAU diesen Eintrag zurueck (leere Liste, wenn keiner gesetzt ist) -> der Sofort-Verify in deploy_workflows.sh
// und scripts/dev/bot_menu_test.ps1 laufen gegen echtes Verhalten (Textkatalog Phase B: Menue je Sprache).
const menus = new Map();
function menuKey(body) {
  const s = (body && body.scope) || { type: 'default' };
  return JSON.stringify({ type: s.type || 'default', chat_id: s.chat_id === undefined ? null : String(s.chat_id) }) +
    '|' + ((body && body.language_code) || '');
}

// Bot-User, den getMe zurueckliefert (n8ns Credential-Test ruft getMe -> braucht ein User-Objekt).
const BOT_USER = { id: 7000000001, is_bot: true, first_name: 'MockBot', username: 'mock_test_bot' };

// Methoden-spezifische result-Payloads; default = `true` (Telegram liefert bei vielen Methoden result:true).
function buildResult(method, body) {
  switch (method) {
    case 'getMe':
      return BOT_USER;
    case 'sendMessage':
      // Spiegelt die echte Bot-API: das gesendete Message-Objekt enthaelt auch reply_markup zurueck
      // (faithful, falls ein Test je die Node-Antwort statt der Aufzeichnung prueft).
      return {
        message_id: ++messageId,
        from: BOT_USER,
        chat: { id: body && body.chat_id, type: 'private' },
        date: Math.floor(Date.now() / 1000),
        text: body && body.text,
        reply_markup: body && body.reply_markup,
      };
    case 'getFile':
      // Sprach-Test-Dateien (file_id mock_voice_*): file_path traegt die file_id wie bei Telegram ('voice/file_12.oga')
      // -> der Download liefert markierte Bytes, an denen der Mock-LLM die Gemini-Transkription erkennt
      // (Marker-Liste GEMINI_FILES in tests/mock_llm/server.js). Foto-Test-Dateien (file_id mock_photo_*) -> 'photos/<id>.png'
      // -> der Download liefert ein echtes 1x1-PNG (Vision-Import-Pfad: tool_extract_finance_document, die Antwort des
      // Vision-Aufrufs kommt aus dem Mock-LLM-Szenario). Liegt ein echtes Dokument unter docs/, zeigt der Pfad darauf
      // (PDF -> 'documents/<id>.pdf', Broker-CSV-Export -> 'documents/<id>.csv'). Alle anderen file_ids unveraendert.
      {
        const fid = (body && body.file_id) || '';
        const doc = /^mock_photo_\w+$/.test(fid) ? docFor(fid) : null;
        const fp = /^mock_voice_\w+$/.test(fid) ? 'voice/' + fid + '.oga'
          : (doc && doc.ext === 'pdf') ? 'documents/' + fid + '.pdf'
          : (doc && doc.ext === 'csv') ? 'documents/' + fid + '.csv'
          : (/^mock_photo_\w+$/.test(fid) ? 'photos/' + fid + '.png' : 'mock/path');
        return { file_id: fid, file_unique_id: 'mock', file_size: 1, file_path: fp };
      }
    case 'setMyCommands':
      menus.set(menuKey(body), Array.isArray(body && body.commands) ? body.commands : []);
      return true;
    case 'getMyCommands':
      return menus.get(menuKey(body)) || [];
    case 'getWebhookInfo':
      // Bestaetigen im Chat (n8n Telegram hitl/setup.js) fragt vor jedem Chat-Knopf-Send, wem der Bot-Webhook gehoert.
      // Leere url = 'kein Webhook' -> n8n registriert seinen festen Endpunkt per setWebhook (Mock: true) und sendet
      // callback_data-Knoepfe. (Echte Instanz: der Orchestrator-Trigger besitzt den Webhook -> kein setWebhook.)
      return { url: '', has_custom_certificate: false, pending_update_count: 0, allowed_updates: [] };
    default:
      return true;
  }
}

// Fehler-Schalter je Bot-API-Methode (Tests fuer Fehlerwege, z. B. sendMessageDraft abgelehnt -> die Antwort muss
// trotzdem kommen): GET /__fail?method=<m> schaltet an, /__fail?method=<m>&off=1 aus. Antwort dann HTTP 400 wie Telegram.
const failMethods = new Set();

const server = http.createServer((req, res) => {
  // Kontroll-Endpunkt fuer die Readiness-Probe des Treibers.
  if (req.url === '/__health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }
  if (req.url.startsWith('/__fail?')) {
    const q = new URLSearchParams(req.url.split('?')[1] || '');
    const m = q.get('method') || '';
    if (q.get('off')) failMethods.delete(m); else if (m) failMethods.add(m);
    res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end([...failMethods].join(',')); return;
  }

  // Download einer Sprach-Test-Datei (Telegram-Node: GET <baseUrl>/file/bot<token>/<file_path>) -> Pseudo-Audio-Bytes
  // mit der file_id. Andere Downloads laufen unveraendert durch den generischen Zweig unten.
  const dl = req.url.match(/^\/file\/bot[^/]*\/voice\/(mock_voice_\w+)\.oga$/);
  if (dl) {
    res.writeHead(200, { 'Content-Type': 'audio/ogg' });
    res.end(Buffer.from('mock-audio:' + dl[1], 'utf8'));
    return;
  }

  // Download einer Foto-/Dokument-Test-Datei: echtes Dokument aus docs/, sonst ein gueltiges 1x1-PNG (image/png),
  // damit agent.tool_fetch_telegram_file es annimmt.
  const dd = req.url.match(/^\/file\/bot[^/]*\/(?:photos|documents)\/(mock_photo_\w+)\.(png|pdf|csv)$/);
  if (dd) {
    const doc = docFor(dd[1]);
    if (doc && doc.ext === dd[2]) {
      res.writeHead(200, { 'Content-Type': doc.ext === 'pdf' ? 'application/pdf' : doc.ext === 'csv' ? 'text/csv' : 'image/png' });
      res.end(fs.readFileSync(doc.p));
      return;
    }
  }
  if (/^\/file\/bot[^/]*\/photos\/mock_photo_\w+\.png$/.test(req.url)) {
    res.writeHead(200, { 'Content-Type': 'image/png' });
    res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64'));
    return;
  }

  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const raw = Buffer.concat(chunks).toString('utf8');
    // Bot-API-Pfad: /bot<token>/<method>  (token egal). Query getrennt aufzeichnen.
    const [path, query = ''] = req.url.split('?');
    const m = path.match(/^\/bot[^/]*\/([A-Za-z]+)/);
    const method = m ? m[1] : path;

    let body = raw;
    const ct = req.headers['content-type'] || '';
    if (raw && ct.indexOf('application/json') !== -1) { try { body = JSON.parse(raw); } catch (e) { /* roh lassen */ } }

    const result = buildResult(method, typeof body === 'object' ? body : {});
    // Aufzeichnung anhaengen (eine JSON-Zeile je Call; der Harness liest sie via `docker exec cat`). result_message_id =
    // die vergebene message_id (Chat-Knopf-Tests bauen damit das callback_query-Update wie Telegram es schickt).
    try {
      fs.appendFileSync(LOG_FILE, JSON.stringify({ t: new Date().toISOString(), method, query, body,
        result_message_id: (result && typeof result === 'object' && result.message_id) || undefined }) + '\n');
    } catch (e) { /* Logging-Fehler nie den Mock-Response kippen lassen */ }

    // Per /__fail eingeschaltete Methode (mock_route_test [draft-fail]) -> HTTP 400 wie die echte Bot-API.
    if (failMethods.has(method)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error_code: 400, description: 'Bad Request: mock failure (' + method + ')' }));
      return;
    }
    // Magischer Fehler-Ausloeser (Modell-Phase 2, infra_cases Voice-Fehlerweg): getFile mit der file_id
    // 'mock_bad_file' antwortet wie die echte Bot-API bei einer unbekannten Datei (HTTP 400) -> der
    // Download-Node des Transkriptions-Tools nimmt seinen Fehler-Ausgang.
    if (method === 'getFile' && body && body.file_id === 'mock_bad_file') {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error_code: 400, description: 'Bad Request: invalid file_id' }));
      return;
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, result }));
  });
});

server.listen(PORT, '127.0.0.1', () => {
  // Startzeile selbst aufzeichnen (Lebenszeichen + Marker fuer den ersten Lauf).
  try { fs.appendFileSync(LOG_FILE, JSON.stringify({ t: new Date().toISOString(), method: '__start', port: PORT }) + '\n'); } catch (e) { /* noop */ }
  process.stdout.write('mock-telegram listening on 127.0.0.1:' + PORT + '\n');
});
