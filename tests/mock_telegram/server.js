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
// Dateien OHNE Endung im Pfad (echte Telegram-Dokumente ohne Namensendung; Download hart application/octet-stream),
// file_id mock_noext_<art>. Typ-Erkennung am Inhalt: agent.tool_fetch_telegram_file (infra_cases). Text erfunden.
function utf16(s) { return Buffer.from(s, 'utf16le'); }
// Dateien MIT Endung .xls im Pfad (Name .xls, Inhalt je nach Art), file_id mock_xlsname_<art>: book = xlsx-Workbook
// (Bondora-Form, erfunden), ole = echtes altes .xls (OLE), zip = ZIP ohne xl/workbook. Download hart application/vnd.ms-excel.
function noExtBytes(kind) {
  const ole = Buffer.from([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
  switch (kind) {
    case 'pdf': return Buffer.from('%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n', 'latin1');
    case 'png': return Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
    case 'jpeg': return Buffer.from([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0]);
    case 'heic': return Buffer.concat([Buffer.from([0, 0, 0, 0x18]), Buffer.from('ftypheic0000mif1heic', 'latin1')]);
    case 'xlsx': { const p = path.join(DOC_DIR, 'mock_photo_084.xlsx'); return fs.existsSync(p) ? fs.readFileSync(p) : Buffer.alloc(0); }
    case 'zip': return Buffer.concat([Buffer.from([0x50, 0x4B, 3, 4]), Buffer.from('word/document.xml', 'latin1')]);
    case 'xls': return Buffer.concat([ole, Buffer.alloc(32), utf16('Workbook')]);
    case 'doc': return Buffer.concat([ole, Buffer.alloc(32), utf16('WordDocument')]);
    case 'csv': return Buffer.from('Datum;Betrag;Zweck\n01.10.2026;-12,50;Testkauf\n02.10.2026;100,00;Testeingang\n', 'utf8');
    case 'text': return Buffer.from('Hallo, das ist nur ein Satz.\nUnd noch einer ohne Trenner.\n', 'utf8');
    default: return Buffer.from([1, 2, 0, 3, 4, 0, 5, 6, 7, 8, 9]);
  }
}
// Grosse Dateien (Last-Test des Mehrfach-Lesers): file_id mock_big_<MB>_<x>, gueltige PDF-Kennung + Fuellbytes.
function bigBytes(mb, tag) { const b = Buffer.alloc(mb * 1024 * 1024, tag); b.write('%PDF-1.4\n', 0, 'latin1'); return b; }

function docFor(fid) {
  for (const ext of ['pdf', 'png', 'csv', 'xlsx']) {
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

// Profilbild des Bots (provisioning/lib/bootstrap_owner.sh _ensure_bot_profile_photo): getUserProfilePhotos meldet die Zahl,
// ein gueltiger setMyProfilePhoto erhoeht sie. Steuerung GET /__profile?count=N&odd=<art>&stuck=0|1&bot_id=N (odd = schiefe
// Antwort: leer = keine, nofield/string/float/negative/notok; stuck = der Upload aendert die Zahl nicht). Die Form-Regeln
// folgen der Bot-API-Doku (InputProfilePhotoStatic), die Fehlertexte sind erfunden: das Verhalten des echten Telegram belegt
// dieser Mock nicht.
const menuButtons = {};
const profile = { count: 0, odd: '', stuck: false };
const ODD_PROFILE = { nofield: {}, string: { total_count: '0' }, float: { total_count: 0.5 }, negative: { total_count: -1 } };

// Alle Teile einer multipart-Anfrage, Inhalt als Buffer (der Dateiinhalt ist binaer, also nie ueber einen String).
function parseMultipart(buf, contentType) {
  const bm = String(contentType).match(/boundary=(?:"([^"]+)"|([^;\s]+))/);
  if (!bm) return [];
  const delim = Buffer.from('--' + (bm[1] || bm[2]), 'latin1');
  const parts = [];
  let at = buf.indexOf(delim);
  while (at !== -1) {
    const start = at + delim.length + 2; // CRLF nach dem Trenner
    const next = buf.indexOf(delim, start);
    if (next === -1) break;
    const headEnd = buf.indexOf('\r\n\r\n', start, 'latin1');
    if (headEnd !== -1 && headEnd < next) {
      const head = buf.slice(start, headEnd).toString('latin1');
      const name = (head.match(/name="([^"]*)"/) || [])[1] || '';
      const filename = (head.match(/filename="([^"]*)"/) || [])[1] || null;
      parts.push({ name, filename, data: buf.slice(headEnd + 4, next - 2) });
    }
    at = next;
  }
  return parts;
}

// Prueft einen Upload wie die Doku ihn beschreibt: photo = JSON {type:static, photo:"attach://<name>"} plus Dateiteil <name>
// mit JPEG-Bytes. Liefert die Zeile fuers Protokoll (nur Felder + Groesse, nie Bytes); problem gesetzt = HTTP 400.
function inspectProfileUpload(parts) {
  const out = { photo: null, file_field: null, file_name: null, file_size: 0, file_is_jpeg: false, problem: null };
  const field = parts.find((p) => p.name === 'photo' && p.filename === null);
  if (!field) { out.problem = 'photo field missing'; return out; }
  try { out.photo = JSON.parse(field.data.toString('utf8')); } catch (e) { out.problem = 'photo is not JSON'; return out; }
  if (!out.photo || out.photo.type !== 'static') { out.problem = 'photo type must be static'; return out; }
  const am = String(out.photo.photo || '').match(/^attach:\/\/(\w+)$/);
  if (!am) { out.problem = 'photo must reference attach://<name>'; return out; }
  const file = parts.find((p) => p.name === am[1] && p.filename !== null);
  if (!file) { out.problem = 'attached file missing'; return out; }
  out.file_field = file.name;
  out.file_name = file.filename;
  out.file_size = file.data.length;
  out.file_is_jpeg = file.data.length > 3 && file.data[0] === 0xFF && file.data[1] === 0xD8 && file.data[2] === 0xFF;
  if (!out.file_is_jpeg) out.problem = 'photo must be a JPG';
  return out;
}

// Methoden-spezifische result-Payloads; default = `true` (Telegram liefert bei vielen Methoden result:true).
function buildResult(method, body) {
  switch (method) {
    case 'getMe':
      return BOT_USER;
    case 'setChatMenuButton':
      menuButtons[String(body && body.chat_id)] = body && body.menu_button;
      return true;
    case 'getChatMenuButton':
      return menuButtons[String(body && body.chat_id)] || { type: 'default' };
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
      // (PDF -> 'documents/<id>.pdf', Bank-Export -> 'documents/<id>.csv' bzw. '.xlsx'). Alle anderen file_ids unveraendert.
      {
        const fid = (body && body.file_id) || '';
        const doc = /^mock_photo_\w+$/.test(fid) ? docFor(fid) : null;
        const fp = /^mock_noext_\w+$/.test(fid) ? 'documents/' + fid
          : /^mock_xlsname_\w+$/.test(fid) ? 'documents/' + fid + '.xls'
          : /^mock_big_\d+_\w+$/.test(fid) ? 'documents/' + fid + '.pdf'
          : /^mock_voice_\w+$/.test(fid) ? 'voice/' + fid + '.oga'
          : (doc && doc.ext === 'pdf') ? 'documents/' + fid + '.pdf'
          : (doc && doc.ext === 'csv') ? 'documents/' + fid + '.csv'
          : (doc && doc.ext === 'xlsx') ? 'documents/' + fid + '.xlsx'
          : (/^mock_photo_\w+$/.test(fid) ? 'photos/' + fid + '.png' : 'mock/path');
        return { file_id: fid, file_unique_id: 'mock', file_size: 1, file_path: fp };
      }
    case 'sendSticker':
      // Persona-Sticker ueber den Telegram-Relay des LLM-Gateways: Erst-Versand als Upload (multipart -> body.sticker_file =
      // Dateiname, z. B. 'butler_top.webp'), danach per file_id. Die file_id traegt den Dateinamen (mock_fid_<datei>) ->
      // Tests sehen den Sticker in beiden Faellen ('butler_top' im Log).
      {
        const src = (body && (body.sticker_file || body.sticker)) || '';
        return { message_id: ++messageId, from: BOT_USER, chat: { id: body && body.chat_id, type: 'private' },
          date: Math.floor(Date.now() / 1000),
          sticker: { file_id: /^mock_fid_/.test(src) ? src : 'mock_fid_' + src, file_unique_id: 'mock', type: 'regular', width: 512, height: 512 } };
      }
    case 'setMessageReaction':
      return true;
    case 'getUserProfilePhotos':
      if (ODD_PROFILE[profile.odd]) return ODD_PROFILE[profile.odd];
      return { total_count: profile.count,
        photos: profile.count > 0 ? [[{ file_id: 'mock_profile_photo', file_unique_id: 'mock', width: 640, height: 640 }]] : [] };
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
// trotzdem kommen): GET /__fail?method=<m> schaltet an, /__fail?method=<m>&off=1 aus. Antwort dann HTTP 400 wie Telegram;
// optional &code=429&retry_after=30&desc=<text>; &markup=1 = nur Aufrufe mit reply_markup (Knopf-Send scheitert, der Text-
// Fallback ohne Knopf geht durch). GET /__hang?method=<m> laesst Aufrufe unbeantwortet (Zeitgrenzen), &off=1 aus.
const failMethods = new Map();
const hangMethods = new Set();

const server = http.createServer((req, res) => {
  // Kontroll-Endpunkt fuer die Readiness-Probe des Treibers.
  if (req.url === '/__health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }
  if (req.url.startsWith('/__fail?')) {
    const q = new URLSearchParams(req.url.split('?')[1] || '');
    const m = q.get('method') || '';
    if (q.get('off')) failMethods.delete(m);
    else if (m) failMethods.set(m, { code: Number(q.get('code') || 400), retry_after: q.get('retry_after'), desc: q.get('desc'), markup: q.get('markup') === '1' });
    res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end([...failMethods.keys()].join(',')); return;
  }
  if (req.url.startsWith('/__hang?')) {
    const q = new URLSearchParams(req.url.split('?')[1] || '');
    const m = q.get('method') || '';
    if (q.get('off')) hangMethods.delete(m); else if (m) hangMethods.add(m);
    res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end([...hangMethods].join(',')); return;
  }
  if (req.url === '/__profile' || req.url.startsWith('/__profile?')) {
    const q = new URLSearchParams(req.url.split('?')[1] || '');
    if (q.has('count')) profile.count = Number(q.get('count'));
    if (q.has('odd')) profile.odd = q.get('odd');
    if (q.has('stuck')) profile.stuck = q.get('stuck') === '1';
    if (q.has('bot_id')) BOT_USER.id = Number(q.get('bot_id'));
    res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end(String(profile.count)); return;
  }

  // Download einer Sprach-Test-Datei (Telegram-Node: GET <baseUrl>/file/bot<token>/<file_path>) -> Pseudo-Audio-Bytes
  // mit der file_id. Andere Downloads laufen unveraendert durch den generischen Zweig unten.
  const dl = req.url.match(/^\/file\/bot[^/]*\/voice\/(mock_voice_\w+)\.oga$/);
  if (dl) {
    res.writeHead(200, { 'Content-Type': 'audio/ogg' });
    res.end(Buffer.from('mock-audio:' + dl[1], 'utf8'));
    return;
  }

  const ne = req.url.match(/^\/file\/bot[^/]*\/documents\/mock_noext_(\w+)$/);
  if (ne) {
    res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
    res.end(noExtBytes(ne[1]));
    return;
  }
  const xn = req.url.match(/^\/file\/bot[^/]*\/documents\/mock_xlsname_(\w+)\.xls$/);
  if (xn) {
    res.writeHead(200, { 'Content-Type': 'application/vnd.ms-excel' });
    res.end(noExtBytes(xn[1] === 'book' ? 'xlsx' : xn[1]));
    return;
  }
  const bg = req.url.match(/^\/file\/bot[^/]*\/documents\/mock_big_(\d+)_(\w+)\.pdf$/);
  if (bg) {
    res.writeHead(200, { 'Content-Type': 'application/pdf' });
    res.end(bigBytes(Number(bg[1]), bg[2]));
    return;
  }

  // Download einer Foto-/Dokument-Test-Datei: echtes Dokument aus docs/, sonst ein gueltiges 1x1-PNG (image/png),
  // damit agent.tool_fetch_telegram_file es annimmt.
  const dd = req.url.match(/^\/file\/bot[^/]*\/(?:photos|documents)\/(mock_photo_\w+)\.(png|pdf|csv|xlsx)$/);
  if (dd) {
    const doc = docFor(dd[1]);
    if (doc && doc.ext === dd[2]) {
      res.writeHead(200, { 'Content-Type': doc.ext === 'pdf' ? 'application/pdf' : doc.ext === 'csv' ? 'text/csv' : doc.ext === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'image/png' });
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
    // multipart (Sticker-Upload des Gateway-Relays): nie die Bytes loggen, nur Felder + Dateiname.
    if (raw && ct.indexOf('multipart/form-data') !== -1) {
      const latin = Buffer.concat(chunks).toString('latin1');
      const fileM = latin.match(/name="(\w+)"; filename="([^"]+)"/);
      const chatM = latin.match(/name="chat_id"\r\n\r\n(-?\d+)\r\n/);
      body = { chat_id: chatM ? chatM[1] : null, multipart_field: fileM ? fileM[1] : null, sticker_file: fileM ? fileM[2] : null };
    }
    // Profilbild: eigene Pruefung; ohne multipart (ein JSON-Body kann keine Datei tragen) ist es immer ein Fehler.
    const upload = method === 'setMyProfilePhoto'
      ? inspectProfileUpload(ct.indexOf('multipart/form-data') !== -1 ? parseMultipart(Buffer.concat(chunks), ct) : [])
      : null;
    if (upload) body = upload;

    const result = buildResult(method, typeof body === 'object' ? body : {});
    // Aufzeichnung anhaengen (eine JSON-Zeile je Call; der Harness liest sie via `docker exec cat`). result_message_id =
    // die vergebene message_id (Chat-Knopf-Tests bauen damit das callback_query-Update wie Telegram es schickt).
    try {
      fs.appendFileSync(LOG_FILE, JSON.stringify({ t: new Date().toISOString(), method, query, body,
        result_message_id: (result && typeof result === 'object' && result.message_id) || undefined }) + '\n');
    } catch (e) { /* Logging-Fehler nie den Mock-Response kippen lassen */ }

    // Per /__fail eingeschaltete Methode (mock_route_test [draft-fail]) -> HTTP 400 wie die echte Bot-API.
    if (hangMethods.has(method)) return;
    const fm = failMethods.get(method);
    if (fm && (!fm.markup || (body && typeof body === 'object' && body.reply_markup))) {
      const f = fm;
      res.writeHead(f.code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(Object.assign({ ok: false, error_code: f.code, description: f.desc || ('Bad Request: mock failure (' + method + ')') },
        f.retry_after ? { parameters: { retry_after: Number(f.retry_after) } } : {})));
      return;
    }
    if (upload) {
      if (upload.problem) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error_code: 400, description: 'Bad Request: ' + upload.problem }));
        return;
      }
      if (!profile.stuck) profile.count += 1;
    }
    // Fremde Kennung statt der eigenen: wie „user not found“. Erkennt einen falsch gebauten Aufruf des Installers.
    if (method === 'getUserProfilePhotos' && !(body && body.user_id === BOT_USER.id)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error_code: 400, description: 'Bad Request: user not found' }));
      return;
    }
    if (method === 'getUserProfilePhotos' && profile.odd === 'notok') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: false, result: { total_count: 0 } }));
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
