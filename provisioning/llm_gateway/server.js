// llm_gateway/server.js — lokaler LLM-Gateway: Prompt-Caching fuer alle Claude-Agenten + Nutzungs-Messung.
//
// WARUM: der lmChatAnthropic-Node v1.5 (unser Pin; geprueft 2.21.7 + 2.44.4) kennt keine Caching-Option; sein einziger Hebel ist die
// Credential-"Base URL" (`credentials.url` -> anthropicApiUrl). inject_credentials.sh biegt sie auf diesen
// Dienst (127.0.0.1). Er setzt die Cache-Haltepunkte und reicht die Anfrage unveraendert an Anthropic weiter —
// Inhalte gehen NUR an Anthropic (Privacy-Hard-Rule), dieser Dienst speichert nichts davon (nur Zahlen, s. MESSUNG).
// Ab n8n 2.37 gibt es eine eingebaute Option, die setzt aber nur den mitwandernden oberen Haltepunkt → kein
// Treffer ueber Gespraeche/Testfaelle hinweg (Anthropic schreibt Cache-Eintraege NUR an Haltepunkten).
//
// WANN gecacht wird: nur POST /v1/messages MIT mindestens einem eigenen Werkzeug (input_schema) = Agenten-
//   Anfrage (Denk-Schleife ueber denselben Anfang). Einmal-Aufrufe (direkte HTTP-Knoten, Ketten ohne Werkzeuge)
//   bleiben unberuehrt — ein Cache-Eintrag wuerde dort 1,25x/2x kosten und nie gelesen.
// WIE (max. 3 von 4 Haltepunkten):
//   1) letztes eigenes Werkzeug, ttl STATIC_TTL (Standard 1h) — von allen Gespraechen geteilt;
//   2) Ende des System-Prompts, ttl STATIC_TTL — ueberlebt einen Wechsel der Nutzer-Nachricht;
//   3) oberer automatischer Haltepunkt (5 Min, wandert mit) — Denk-Schleife + Folge-Nachrichten.
//   1+2 nur ohne eigene Block-Marker der Anfrage, 3 nur ohne eigenen oberen Marker (unabhaengig → bleibt
//   korrekt, falls n8n spaeter selbst einen oberen Marker setzt). Nie den letzten Block markieren → kein
//   TTL-Konflikt (1h-Eintraege stehen immer vor dem 5-Min-Eintrag am Ende).
// KEEP-ALIVE: Agenten-Anfaenge (Werkzeuge+System) werden bis LLM_GATEWAY_KEEPALIVE_HOURS (Standard 24, 0 = aus) nach
//   der letzten echten Nutzung alle 55 Min mit max_tokens 0 angestupst -> der 1h-Cache laeuft nicht ab (nur
//   Lesepreis statt erneutem 2x-Schreiben). Gemerkt NUR im Arbeitsspeicher, ohne Gespraech (Details am Abschnitt).
// EIN WERKZEUG JE ANTWORT: Agenten-Anfragen bekommen tool_choice.disable_parallel_tool_use (applySerialTools) —
//   parallele tool_use-Bloecke kamen im n8n-Agenten mit leeren Argumenten an (Begruendung an der Funktion).
// AUSFALLSICHER: Body nicht lesbar → Original-Bytes weiter. Anthropic-400 mit "cache_control"/"tool_choice" →
//   EINMAL ohne Einfuegen wiederholen (400er werden nicht berechnet), Zeile fallback:true.
// MESSUNG (12-Factor): je Anfrage EINE JSON-Zeile {"ev":"usage",...} auf stdout → systemd-Journal. Bewusst die
//   Anthropic-Feldnamen (input_tokens = UNGECACHTER Rest; Gesamt-Eingabe = input + cache_creation + cache_read),
//   nicht OTel-GenAI (dort noch "Development"). Zusaetzlich haengt sie (mit id + Workflow) an
//   $STATE_DIRECTORY/usage.jsonl (systemd StateDirectory, 62 Tage, atomar gekuerzt); der /kosten-Sub holt sie per
//   GET /__usage (nur 127.0.0.1) nach core.llm_usage (core.fn_import_llm_usage), die DB rechnet die Kosten.
// WORKFLOW-KENNUNG (Kosten je Workflow): HTTP-Knoten senden Header x-lifeagents-workflow; lmChatAnthropic kann keinen
//   Header je Knoten setzen (n8n-Quirk) -> der Build setzt eine KONSTANTE Kennzeile `<<la-wf:NAME>>` an den Anfang der
//   System-Nachricht. stripWfTag entfernt sie direkt nach dem Parsen, VOR Caching/Keep-Alive-Schluessel, und der
//   bereinigte Body ist das "Original" aller Rueckfallpfade -> Anthropic und das Modell sehen byte-gleiche Prompts,
//   der gecachte Anfang aendert sich nicht. Header und Kennzeile gehen nie an Anthropic.
// PRIVACY: es werden NIE Header, Schluessel, Prompt- oder Antwort-Inhalte geloggt oder gespeichert (der Keep-Alive haelt
//   den Anfang einer Agenten-Anfrage samt Auth-Header nur im Arbeitsspeicher, nie das Gespraech; usage.jsonl traegt nur
//   Zahlen, Modell, Workflow-Name, Zeit) — Fehler nur als feste Codes (nie err.message: Node-Parse-Fehler zitieren
//   Eingabe-Stuecke).
//
// TELEGRAM-RELAY (zweite Aufgabe, Bot mit Gesicht 2026-10-30): POST /__telegram/<methode> fuer genau die Bot-API-
//   Aufrufe, die n8n nicht (Reaktion) bzw. nicht mit Zeitlimit (Sticker vor der Antwort) kann. Allowlist, Token je
//   Anfrage im Header (nie geloggt, nie an Anthropic), 3-s-Zeitlimit, Sticker-Dateien nur aus LLM_GATEWAY_STICKER_DIR.
//   Details am Abschnitt "Telegram-Relay".
//
// Bewusst dependency-frei (nur Node-Core): Node ist durch n8n garantiert, kein npm install, keine Lieferkette.
'use strict';
const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const pathMod = require('path');

const PORT = parseInt(process.env.LLM_GATEWAY_PORT || '8090', 10);
const UPSTREAM = new URL(process.env.LLM_GATEWAY_UPSTREAM || 'https://api.anthropic.com');
const STATIC_TTL = process.env.LLM_GATEWAY_STATIC_TTL === '5m' ? '5m' : '1h';
// Keep-Alive (Owner 2026-10-23): Fenster in Stunden nach der letzten echten Nutzung eines Anfangs (0 = aus).
// Nur mit 1h-TTL. EVERY_MS ist nur fuer llm_gateway_test kuerzer (Standard 55 Min, 5 Min Puffer zur 1h-TTL).
const KA_HOURS = (() => { const v = parseFloat(process.env.LLM_GATEWAY_KEEPALIVE_HOURS || '24'); return isFinite(v) && v >= 0 && v <= 48 ? v : 24; })();
const KA_ON = STATIC_TTL === '1h' && KA_HOURS > 0;
const KA_EVERY_MS = Math.max(1000, parseInt(process.env.LLM_GATEWAY_KEEPALIVE_EVERY_MS || String(55 * 60 * 1000), 10) || 55 * 60 * 1000);
const KA_TICK_MS = Math.max(200, Math.min(60 * 1000, Math.floor(KA_EVERY_MS / 10)));
const KA_MAX = 16;                            // Obergrenze gemerkter Anfaenge (aelteste Nutzung faellt raus)
const KA_HEADERS = ['x-api-key', 'authorization', 'anthropic-version', 'anthropic-beta'];
const MAX_BODY = 32 * 1024 * 1024;           // Anfrage-Deckel (PDF-Belege als base64)
const MAX_USAGE_SCAN = 16 * 1024 * 1024;     // JSON-Antworten nur bis hierhin fuer usage puffern
// Hop-by-hop + von uns neu gesetzte Header (RFC 9110 §7.6.1); accept-encoding → identity, damit usage lesbar bleibt.
// x-lifeagents-workflow = unsere Workflow-Kennung (nur fuer die Messung, nie an Anthropic).
const WF_HEADER = 'x-lifeagents-workflow';
// Telegram-Relay (Bot mit Gesicht 2026-10-30): Bot-Token je Anfrage in diesem Header (n8n-Credential httpHeaderAuth).
// Er steht in DROP_REQ -> forward() reicht ihn NIE an Anthropic weiter, auch nicht bei einem Routing-Fehler.
const TG_TOKEN_HEADER = 'x-telegram-bot-token';
const DROP_REQ = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'te', 'trailer',
  'upgrade', 'host', 'content-length', 'accept-encoding', WF_HEADER, TG_TOKEN_HEADER]);
// Mitschrift fuer den Kosten-Report: systemd StateDirectory= setzt STATE_DIRECTORY; fehlt es (Test-Units ohne
// LLM_GATEWAY_USAGE_DIR), wird nur ins Journal geschrieben. 62 Tage = 30-Tage-Fenster + Vorperiode + Puffer.
const USAGE_DIR = process.env.LLM_GATEWAY_USAGE_DIR || process.env.STATE_DIRECTORY || '';
const USAGE_FILE = USAGE_DIR ? pathMod.join(USAGE_DIR.split(':')[0], 'usage.jsonl') : '';
const USAGE_KEEP_MS = 62 * 24 * 3600 * 1000;
const USAGE_PAGE_MAX = 5000;
// Zeilen-id: 13-stellige Epoch-ms + Prozess-Kennung + Zaehler -> sortierbar und eindeutig ueber Neustarts
// (dieselbe Form prueft core.llm_usage per CHECK).
const PROC_ID = crypto.randomBytes(3).toString('hex');
let usageSeq = 0;
const WF_TAG = /^<<la-wf:([^>\n]{0,120})>>(?:\n|$)/;
const WF_NAME = /^[a-z0-9._-]{1,80}$/;
const DROP_RES = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'te', 'trailer', 'upgrade']);

const client = UPSTREAM.protocol === 'http:' ? http : https;
const agent = new client.Agent({ keepAlive: true });

// ---- Telegram-Relay: Konstanten (Abschnitt unten) --------------------------------------------------------------
const TG_UPSTREAM = new URL(process.env.LLM_GATEWAY_TELEGRAM_API || 'https://api.telegram.org');
const tgClient = TG_UPSTREAM.protocol === 'http:' ? http : https;
// Ohne Keep-Alive: jede Anfrage auf frischer Verbindung (der bekannte Haenger sitzt auf wiederverwendeten Sockets).
const tgAgent = new tgClient.Agent({ keepAlive: false });
const TG_METHODS = new Set(['setMessageReaction', 'sendSticker']);
const TG_TOKEN_RE = /^\d{5,15}:[A-Za-z0-9_-]{30,64}$/;
const TG_CHAT_RE = /^-?\d{1,20}$/;
const TG_STICKER_RE = /^[a-z_]{1,32}_(hallo|top|hmm|yay)$/;
const TG_REACTIONS = new Set(['❤', '👌', '🎉']);   // ❤ (ohne VS16, Telegram-Liste), 👌, 🎉
const TG_MAX_BODY = 4096;
const TG_TIMEOUT_MS = Math.max(500, Math.min(10000, parseInt(process.env.LLM_GATEWAY_TELEGRAM_TIMEOUT_MS || '3000', 10) || 3000));
const TG_STICKER_DIR = process.env.LLM_GATEWAY_STICKER_DIR || '';

function emit(obj) {
  try { process.stdout.write(JSON.stringify(Object.assign({ t: new Date().toISOString() }, obj)) + '\n'); }
  catch (e) { /* Logging darf nie den Request kippen */ }
}
function diag(code) { emit({ ev: 'error', code: String(code || 'unknown') }); }

// ---- Mitschrift (Kosten-Report) ------------------------------------------------------------------
// Eine usage-Zeile: Journal (wie bisher) + an usage.jsonl angehaengt. appendFileSync: geordnet, ohne Puffer, der beim
// Kuerzen verloren ginge; bei wenigen hundert Zeilen am Tag vernachlaessigbar. Fehler nur als fester Code.
function recordUsage(obj) {
  const t = new Date();
  usageSeq = (usageSeq + 1) % 1000000;
  const id = String(t.getTime()).padStart(13, '0') + '-' + PROC_ID + '-' + String(usageSeq).padStart(6, '0');
  const line = Object.assign({ t: t.toISOString(), ev: 'usage', id }, obj);
  try { process.stdout.write(JSON.stringify(line) + '\n'); } catch (e) { /* Logging darf nie den Request kippen */ }
  if (!USAGE_FILE) return;
  try { fs.appendFileSync(USAGE_FILE, JSON.stringify(line) + '\n', { mode: 0o600 }); }
  catch (e) { diag('usage_write_' + (e && e.code ? e.code : 'error')); }
}
// Zeilen aelter als USAGE_KEEP_MS entfernen: tmp-Datei + rename (atomar); synchron, damit kein appendFileSync
// dazwischen in die alte Datei geht.
function trimUsageFile() {
  if (!USAGE_FILE) return;
  try {
    let raw;
    try { raw = fs.readFileSync(USAGE_FILE, 'utf8'); } catch (e) { if (e && e.code === 'ENOENT') return; throw e; }
    const cutoff = Date.now() - USAGE_KEEP_MS;
    const lines = raw.split('\n').filter(Boolean);
    const keep = lines.filter((l) => {
      try { return Date.parse(JSON.parse(l).t) >= cutoff; } catch (e) { return false; }
    });
    if (keep.length === lines.length) return;
    const tmp = USAGE_FILE + '.tmp';
    fs.writeFileSync(tmp, keep.length ? keep.join('\n') + '\n' : '', { mode: 0o600 });
    fs.renameSync(tmp, USAGE_FILE);
  } catch (e) { diag('usage_trim_' + (e && e.code ? e.code : 'error')); }
}
// GET /__usage?after=<id-Praefix>&limit=<n>: Zeilen mit id > after (Text-Vergleich; ids sind sortierbar), aelteste
// zuerst, hoechstens limit. Antwort {rows, next_after, has_more} = die Pagination des n8n-HTTP-Knotens.
function usagePage(query) {
  const after = /^[0-9a-f-]{0,40}$/.test(query.get('after') || '') ? (query.get('after') || '') : '';
  const lim = Math.min(USAGE_PAGE_MAX, Math.max(1, parseInt(query.get('limit') || '2000', 10) || 2000));
  let raw = '';
  if (USAGE_FILE) { try { raw = fs.readFileSync(USAGE_FILE, 'utf8'); } catch (e) { if (!e || e.code !== 'ENOENT') diag('usage_read_' + (e && e.code ? e.code : 'error')); } }
  // Nur die id je Zeile ausschneiden (recordUsage schreibt sie an fester Stelle, 27 Zeichen) — voll geparst werden nur
  // die ausgelieferten Zeilen: der Abruf blockiert die Weiterleitung auch bei 60 000 Zeilen nur Millisekunden.
  const cand = [];
  for (const l of raw.split('\n')) {
    const i = l.indexOf('"id":"');
    if (i < 0) continue;
    const id = l.slice(i + 6, i + 33);
    if (id.length === 27 && id > after) cand.push([id, l]);
  }
  cand.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const page = [];
  for (const [, l] of cand.slice(0, lim)) { try { page.push(JSON.parse(l)); } catch (e) { /* kaputte Zeile auslassen */ } }
  const lastId = cand.length ? cand[Math.min(lim, cand.length) - 1][0] : null;
  return { rows: page, next_after: lastId || after || null, has_more: cand.length > lim };
}

// ---- Workflow-Kennung ----------------------------------------------------------------------------
// Entfernt die Kennzeile `<<la-wf:NAME>>` vom Anfang der System-Nachricht (String oder erster Text-Block) und
// liefert { found, wf } (wf = NAME nur bei gueltiger Form, sonst null — die Zeile wird trotzdem entfernt). Bleibt
// danach kein System-Text, faellt das Feld bzw. der Block weg -> exakt der Body ohne Kennzeile. Veraendert in-place.
function stripWfTag(body) {
  const take = (text) => {
    const m = WF_TAG.exec(text);
    if (!m) return null;
    return { rest: text.slice(m[0].length), wf: WF_NAME.test(m[1]) ? m[1] : null };
  };
  if (typeof body.system === 'string') {
    const r = take(body.system);
    if (!r) return { found: false, wf: null };
    if (r.rest) body.system = r.rest; else delete body.system;
    return { found: true, wf: r.wf };
  }
  if (Array.isArray(body.system)) {
    const i = body.system.findIndex((b) => b && b.type === 'text' && typeof b.text === 'string');
    if (i < 0) return { found: false, wf: null };
    const r = take(body.system[i].text);
    if (!r) return { found: false, wf: null };
    if (r.rest) body.system[i] = Object.assign({}, body.system[i], { text: r.rest });
    else body.system.splice(i, 1);
    if (body.system.length === 0) delete body.system;
    return { found: true, wf: r.wf };
  }
  return { found: false, wf: null };
}
function headerWf(reqHeaders) {
  const v = reqHeaders[WF_HEADER];
  return typeof v === 'string' && WF_NAME.test(v) ? v : null;
}

// ---- Haltepunkte ---------------------------------------------------------------------------------
function hasMarker(b) { return !!(b && typeof b === 'object' && b.cache_control); }
function hasBlockMarker(body) {
  if (Array.isArray(body.tools) && body.tools.some(hasMarker)) return true;
  if (Array.isArray(body.system) && body.system.some(hasMarker)) return true;
  for (const m of (Array.isArray(body.messages) ? body.messages : [])) {
    if (m && Array.isArray(m.content) && m.content.some(hasMarker)) return true;
  }
  return false;
}
// Eigenes Werkzeug = hat input_schema; Server-Werkzeuge (web_search_*) haben keins.
function isCustomTool(t) { return !!(t && typeof t === 'object' && t.input_schema && (!t.type || t.type === 'custom')); }

// Veraendert body in-place; true = mindestens ein Haltepunkt gesetzt.
function applyCaching(body) {
  const tools = Array.isArray(body.tools) ? body.tools : [];
  let last = -1;
  for (let i = 0; i < tools.length; i++) if (isCustomTool(tools[i])) last = i;
  if (last < 0) return false;                                  // keine Agenten-Anfrage
  let changed = false;
  if (!hasBlockMarker(body)) {
    const cc = { type: 'ephemeral', ttl: STATIC_TTL };
    tools[last] = Object.assign({}, tools[last], { cache_control: cc });
    if (typeof body.system === 'string') {
      if (body.system.trim()) body.system = [{ type: 'text', text: body.system, cache_control: cc }];
    } else if (Array.isArray(body.system)) {
      for (let i = body.system.length - 1; i >= 0; i--) {
        const b = body.system[i];
        if (b && b.type === 'text' && typeof b.text === 'string' && b.text.trim()) {
          body.system[i] = Object.assign({}, b, { cache_control: cc });
          break;
        }
      }
    }
    changed = true;
  }
  if (!hasMarker(body)) { body.cache_control = { type: 'ephemeral' }; changed = true; }
  return changed;
}

// ---- Ein Werkzeug je Antwort ---------------------------------------------------------------------
// WARUM: schickt das Modell in EINER Antwort mehrere tool_use-Bloecke (z. B. zwei Buchungen), kommen sie im
// n8n-Agenten (Tools-Agent, lmChatAnthropic v1.5 auf 2.44.4) mit LEEREN Argumenten beim Werkzeug an ->
// "Received tool input did not match expected schema" -> Wiederholungen bis maxIterations -> Fehler statt Antwort
// (bezahlter Lauf 2026-10-23, e2e29: Modell schickte {account_name, amount:100, ...}, das Werkzeug bekam {}).
// Belegt auf 2.44.4; ob n8n 2.45 (#41241) die Ursache mitbehebt, ist offen -> BACKLOG „Gateway-Erzwingen pruefen".
// Anthropic-Option tool_choice.disable_parallel_tool_use: hoechstens ein Werkzeug je Antwort, das Modell
// arbeitet die Schritte nacheinander ab. Nur Agenten-Anfragen (eigenes Werkzeug), nur bei tool_choice auto/
// fehlend; ein eigener Wert der Anfrage (none/any/tool oder schon gesetzt) bleibt unangetastet.
// Veraendert body in-place; true = gesetzt.
function applySerialTools(body) {
  const tools = Array.isArray(body.tools) ? body.tools : [];
  if (!tools.some(isCustomTool)) return false;
  const tc = body.tool_choice;
  if (tc === undefined || tc === null) { body.tool_choice = { type: 'auto', disable_parallel_tool_use: true }; return true; }
  if (tc && typeof tc === 'object' && tc.type === 'auto' && tc.disable_parallel_tool_use === undefined) {
    body.tool_choice = Object.assign({}, tc, { disable_parallel_tool_use: true });
    return true;
  }
  return false;
}

// ---- Keep-Alive (Cache warm halten) --------------------------------------------------------------
// WARUM: Anthropic haelt einen Cache-Eintrag hoechstens 1h. Der Bot wird ueber den Tag verteilt genutzt -> fast jede
// Nutzung schrieb den ~48k-Token-Anfang von agent.finance neu (2x Preis, ~0,19 $; 68 % der API-Kosten, gemessen
// 2026-10-23). Ein Lesezugriff verlaengert die TTL ohne Aufpreis -> kurz vor Ablauf denselben Anfang mit
// max_tokens 0 schicken (offizielles Anthropic-Muster "keep-alive"/Pre-warming): kostet nur den Lesepreis (~0,005 $).
// WAS gemerkt wird (NUR im Arbeitsspeicher, nie geloggt, nie auf Platte): je Anfang (Modell + Werkzeuge + System +
// Denk-Einstellungen) der Anfrage-Body OHNE Gespraech (messages -> Platzhalter) + die Auth-Header. Ein Anfang wird
// nur angestupst, solange er in den letzten KA_HOURS echt genutzt wurde; Fehler -> Eintrag verworfen (kein Sturm).
const keepAlive = new Map();   // key -> { buf, headers, model, lastUse, lastRefresh, busy }

// Liefert den Keep-Alive-Body (oder null, wenn die Anfrage dafuer nicht taugt): alles ausser Gespraech/Streaming/
// oberem Marker (der wuerde den Eintrag an den Platzhalter binden) — Denk-/Effort-Einstellungen bleiben gleich, sonst
// trifft der Anstupser einen anderen Eintrag als die echten Anfragen.
function keepAliveBody(body) {
  if (body.thinking && body.thinking.type === 'enabled') return null;              // max_tokens 0 lehnt das ab
  if (body.output_config && body.output_config.format) return null;
  if (body.tool_choice && (body.tool_choice.type === 'any' || body.tool_choice.type === 'tool')) return null;
  const ka = {};
  for (const k of Object.keys(body)) {
    if (k === 'messages' || k === 'stream' || k === 'cache_control' || k === 'max_tokens') continue;
    ka[k] = body[k];
  }
  ka.max_tokens = 0;
  ka.messages = [{ role: 'user', content: 'keep-alive' }];
  return ka;
}
function keepAliveKey(body) {
  return crypto.createHash('sha256').update(JSON.stringify([body.model, body.tools, body.system, body.thinking,
    body.output_config, body.tool_choice])).digest('hex');
}
function keepAliveRecord(key, ka, reqHeaders, model, wf) {
  const now = Date.now();
  let e = keepAlive.get(key);
  if (!e) {
    if (keepAlive.size >= KA_MAX) {
      let oldest = null;
      for (const [k, v] of keepAlive) if (!oldest || v.lastUse < oldest[1].lastUse) oldest = [k, v];
      if (oldest) keepAlive.delete(oldest[0]);
    }
    e = { busy: false };
    keepAlive.set(key, e);
  }
  const headers = {};
  for (const h of KA_HEADERS) if (reqHeaders[h] !== undefined) headers[h] = reqHeaders[h];
  e.buf = Buffer.from(JSON.stringify(ka), 'utf8');
  e.headers = headers;
  e.model = model;
  e.wf = wf;             // Workflow der letzten echten Nutzung -> Kosten der Anstupser landen bei ihm
  e.lastUse = now;
  e.lastRefresh = now;   // die echte Anfrage hat den Eintrag gerade gelesen/geschrieben
}
function keepAliveSend(key, e) {
  e.busy = true;
  const started = Date.now();
  const headers = Object.assign({}, e.headers, { 'content-type': 'application/json', 'content-length': String(e.buf.length),
    host: UPSTREAM.host, 'accept-encoding': 'identity' });
  const drop = (code) => { diag(code); keepAlive.delete(key); };
  const upReq = client.request(new URL(UPSTREAM.origin + '/v1/messages'), { method: 'POST', headers, agent });
  upReq.on('response', (up) => {
    const parts = [];
    let len = 0;
    up.on('data', (c) => { if (len < MAX_USAGE_SCAN) { parts.push(c); len += c.length; } });
    up.on('end', () => {
      e.busy = false;
      const status = up.statusCode || 502;
      const usage = emptyUsage();
      try { mergeUsage(usage, JSON.parse(Buffer.concat(parts).toString('utf8')).usage); } catch (x) { /* Nullen */ }
      recordUsage(Object.assign({ wf: e.wf, model: e.model, stream: false, cached: true, fallback: false, keepalive: true,
        status, ms: Date.now() - started }, usage));
      if (status === 200) e.lastRefresh = started; else drop('keepalive_' + status);
    });
    up.on('error', () => { e.busy = false; drop('keepalive_stream_error'); });
  });
  upReq.on('error', (x) => { e.busy = false; drop('keepalive_' + (x && x.code ? x.code : 'upstream_error')); });
  upReq.end(e.buf);
}
function keepAliveTick() {
  const now = Date.now();
  for (const [key, e] of keepAlive) {
    if (now - e.lastUse > KA_HOURS * 3600 * 1000) { keepAlive.delete(key); continue; }
    if (!e.busy && now - e.lastRefresh >= KA_EVERY_MS) keepAliveSend(key, e);
  }
}

// ---- Usage-Extraktion (Whitelist, nur Zahlen) ----------------------------------------------------
function isNum(v) { return typeof v === 'number' && isFinite(v); }
// Nur ZAHLEN uebernehmen: message_delta kann Felder als null tragen (SDK: Optional) — die duerfen die Werte aus
// message_start nicht mit 0 ueberschreiben.
function mergeUsage(acc, u) {
  if (!u || typeof u !== 'object') return;
  for (const k of ['input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens']) {
    if (isNum(u[k])) acc[k] = u[k];
  }
  if (u.cache_creation && typeof u.cache_creation === 'object') {
    if (isNum(u.cache_creation.ephemeral_5m_input_tokens)) acc.ephemeral_5m_input_tokens = u.cache_creation.ephemeral_5m_input_tokens;
    if (isNum(u.cache_creation.ephemeral_1h_input_tokens)) acc.ephemeral_1h_input_tokens = u.cache_creation.ephemeral_1h_input_tokens;
  }
  if (u.server_tool_use && typeof u.server_tool_use === 'object' && isNum(u.server_tool_use.web_search_requests)) {
    acc.web_search_requests = u.server_tool_use.web_search_requests;
  }
}
function emptyUsage() {
  return { input_tokens: 0, cache_creation_input_tokens: 0, ephemeral_5m_input_tokens: 0,
    ephemeral_1h_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0, web_search_requests: 0 };
}

// SSE: usage kommt in message_start (Eingabe-/Cache-Felder) und message_delta (Ausgabe, Server-Tools).
function sseTap(acc) {
  let buf = '';
  return (chunk) => {
    buf += chunk.toString('utf8');
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (line.indexOf('data:') !== 0) continue;
      let ev;
      try { ev = JSON.parse(line.slice(5)); } catch (e) { continue; }
      if (ev && ev.type === 'message_start' && ev.message) mergeUsage(acc, ev.message.usage);
      else if (ev && ev.type === 'message_delta') mergeUsage(acc, ev.usage);
    }
  };
}

// ---- Weiterleitung -------------------------------------------------------------------------------
function upstreamHeaders(reqHeaders, len) {
  const h = {};
  for (const k of Object.keys(reqHeaders)) if (!DROP_REQ.has(k.toLowerCase())) h[k] = reqHeaders[k];
  h.host = UPSTREAM.host;
  h['content-length'] = String(len);
  h['accept-encoding'] = 'identity';
  return h;
}
function responseHeaders(upHeaders) {
  const h = {};
  for (const k of Object.keys(upHeaders)) if (!DROP_RES.has(k.toLowerCase())) h[k] = upHeaders[k];
  return h;
}

// meta: { measure, model, stream, cached, fallback, started }
// staleRetry: einmalige Wiederholung, wenn eine wiederverwendete Keep-Alive-Verbindung schon vor der Antwort
// zurueckgesetzt wurde (Node-Doku request.reusedSocket) — upstream wurde dann nichts verarbeitet.
function forward(req, res, buf, meta, retryBuf, staleRetry = true) {
  // Ziel = UPSTREAM.origin + Pfad (req.url ist durch den Pfad-Waechter im Handler garantiert '/…', nie '//…').
  const target = new URL(UPSTREAM.origin + req.url);
  const upReq = client.request(target, { method: req.method, headers: upstreamHeaders(req.headers, buf.length), agent });
  let done = false;
  let gotResponse = false;
  res.on('close', () => { if (!res.writableEnded) upReq.destroy(); });

  upReq.on('response', (up) => {
    gotResponse = true;
    const status = up.statusCode || 502;
    // 400 nach Einfuegen: Body (klein) lesen, bei Bezug auf etwas Eingefuegtes (cache_control / tool_choice)
    // einmal ohne Einfuegen wiederholen.
    if (status === 400 && retryBuf) {
      const parts = [];
      up.on('data', (c) => parts.push(c));
      up.on('end', () => {
        const errBody = Buffer.concat(parts);
        const errText = errBody.toString('utf8');
        const hit = errText.indexOf('cache_control') !== -1 ? 'cache_control'
          : (errText.indexOf('tool_choice') !== -1 || errText.indexOf('disable_parallel_tool_use') !== -1) ? 'tool_choice' : null;
        if (hit) {
          diag('upstream_400_' + hit);
          forward(req, res, retryBuf, Object.assign({}, meta, { cached: false, fallback: true }), null);
          return;
        }
        res.writeHead(status, responseHeaders(up.headers));
        res.end(errBody);
        finish(status, emptyUsage());
      });
      return;
    }
    res.writeHead(status, responseHeaders(up.headers));
    const usage = emptyUsage();
    const isSse = String(up.headers['content-type'] || '').indexOf('text/event-stream') !== -1;
    const tap = meta.measure && isSse ? sseTap(usage) : null;
    const jsonParts = [];
    let jsonLen = 0;
    up.on('data', (c) => {
      res.write(c);
      if (!meta.measure) return;
      if (tap) tap(c);
      else if (jsonLen < MAX_USAGE_SCAN) { jsonParts.push(c); jsonLen += c.length; }
    });
    up.on('end', () => {
      res.end();
      if (meta.measure && !tap && jsonLen < MAX_USAGE_SCAN) {
        try { mergeUsage(usage, JSON.parse(Buffer.concat(jsonParts).toString('utf8')).usage); }
        catch (e) { /* kein JSON (z. B. Fehlerseite) → Nullen */ }
      }
      finish(status, usage);
    });
    up.on('error', (e) => { diag(e && e.code ? e.code : 'upstream_stream_error'); res.destroy(); finish(status, usage); });
  });

  upReq.on('error', (e) => {
    if (staleRetry && !gotResponse && upReq.reusedSocket && e && e.code === 'ECONNRESET' && !res.headersSent) {
      diag('stale_socket_retry');
      forward(req, res, buf, meta, retryBuf, false);
      return;
    }
    diag(e && e.code ? e.code : 'upstream_error');
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'api_error', message: 'llm-gateway: upstream unreachable' } }));
    } else { res.destroy(); }
    finish(502, emptyUsage());
  });
  upReq.end(buf);

  function finish(status, usage) {
    if (done || !meta.measure) return;
    done = true;
    // Keep-Alive merkt sich den Anfang nur nach Erfolg MIT den eingefuegten Haltepunkten (nicht nach dem Fallback).
    if (status === 200 && meta.cached && meta.onOk) { try { meta.onOk(); } catch (e) { diag('keepalive_record_error'); } }
    recordUsage(Object.assign({ wf: meta.wf, model: meta.model, stream: meta.stream, cached: meta.cached,
      fallback: meta.fallback, status, ms: Date.now() - meta.started }, usage));
  }
}

// ---- Telegram-Relay (Bot mit Gesicht 2026-10-30) ---------------------------------------------------------------
// WARUM hier: n8n 2.45.4 kann keine Reaktion setzen (kein Node-Op), der telegramApi-Credential hat kein authenticate
// (Token im URL-Pfad) -> ein HTTP-Knoten kaeme nicht an das Token; Telegram-Node-Sends haben kein Zeitlimit (bekannter
// 3-5-Min-Haenger) -> ein Sticker VOR der Antwort darf nicht ueber den Node laufen. arch-challenge 2026-10-30.
// POST /__telegram/<methode>, exakte Allowlist, Token im Header TG_TOKEN_HEADER (Form geprueft, nie geloggt, nie an
// Anthropic), Body klein + nur die noetigen Felder, Ziel fest TG_UPSTREAM (nur Tests biegen es auf den Mock),
// Zeitlimit TG_TIMEOUT_MS, keine Wiederholung. Antwort an n8n nur {ok, code?}.
// sendSticker: n8n schickt {chat_id, sticker:"<set>_<ausdruck>"}; die Datei kommt aus TG_STICKER_DIR (nie aus der
// Anfrage), erster Versand per Upload, danach die von Telegram vergebene file_id (nur RAM, je Bot-Token getrennt).
const tgStickerIds = new Map();

function tgReply(res, status, obj) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
}

function tgCall(token, method, body, contentType, cb) {
  let finished = false;
  const done = (status, json) => { if (!finished) { finished = true; cb(status, json); } };
  const target = new URL(TG_UPSTREAM.origin + '/bot' + token + '/' + method);
  const upReq = tgClient.request(target, { method: 'POST', agent: tgAgent,
    headers: { 'content-type': contentType, 'content-length': String(body.length) } });
  upReq.setTimeout(TG_TIMEOUT_MS, () => { diag('tg_timeout'); upReq.destroy(); done(504, null); });
  upReq.on('response', (up) => {
    const parts = [];
    up.on('data', (c) => { if (parts.length < 64) parts.push(c); });
    up.on('end', () => {
      let json = null;
      try { json = JSON.parse(Buffer.concat(parts).toString('utf8')); } catch (e) { /* kein JSON */ }
      done(up.statusCode || 502, json);
    });
    up.on('error', () => { diag('tg_stream_error'); done(502, null); });
  });
  upReq.on('error', (e) => { diag(e && e.code ? 'tg_' + e.code : 'tg_upstream_error'); done(502, null); });
  upReq.end(body);
}

function tgMultipart(fields, fileField, fileName, fileBytes) {
  const boundary = '----lifeagents' + crypto.randomBytes(12).toString('hex');
  const parts = [];
  for (const k of Object.keys(fields)) {
    parts.push(Buffer.from('--' + boundary + '\r\nContent-Disposition: form-data; name="' + k + '"\r\n\r\n' + fields[k] + '\r\n', 'utf8'));
  }
  parts.push(Buffer.from('--' + boundary + '\r\nContent-Disposition: form-data; name="' + fileField + '"; filename="' + fileName +
    '"\r\nContent-Type: image/webp\r\n\r\n', 'utf8'), fileBytes, Buffer.from('\r\n--' + boundary + '--\r\n', 'utf8'));
  return { body: Buffer.concat(parts), contentType: 'multipart/form-data; boundary=' + boundary };
}

function handleTelegram(req, res) {
  const m = /^\/__telegram\/([A-Za-z]{1,40})$/.exec(req.url);
  if (!m || !TG_METHODS.has(m[1])) { diag('tg_unknown_method'); tgReply(res, 404, { ok: false, code: 'unknown_method' }); req.resume(); return; }
  if (req.method !== 'POST') { tgReply(res, 405, { ok: false, code: 'method_not_allowed' }); req.resume(); return; }
  const method = m[1];
  const token = String(req.headers[TG_TOKEN_HEADER] || '');
  const chunks = [];
  let size = 0;
  let tooBig = false;
  req.on('data', (c) => { size += c.length; if (size > TG_MAX_BODY) tooBig = true; else chunks.push(c); });
  req.on('end', () => {
    if (tooBig) { tgReply(res, 413, { ok: false, code: 'too_large' }); return; }
    if (!TG_TOKEN_RE.test(token)) { diag('tg_bad_token'); tgReply(res, 400, { ok: false, code: 'bad_token' }); return; }
    let p;
    try { p = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch (e) { p = null; }
    if (!p || typeof p !== 'object' || !TG_CHAT_RE.test(String(p.chat_id))) { tgReply(res, 400, { ok: false, code: 'bad_request' }); return; }
    const chatId = String(p.chat_id);
    const answer = (status, json) => {
      const ok = status === 200 && !!(json && json.ok);
      if (!ok) diag('tg_' + method + '_' + status);
      tgReply(res, ok ? 200 : (status === 504 ? 504 : 502), ok ? { ok: true } : { ok: false, code: status === 504 ? 'timeout' : 'upstream_' + status });
    };

    if (method === 'setMessageReaction') {
      const emoji = p.emoji === undefined ? '❤' : String(p.emoji);
      if (!/^\d{1,12}$/.test(String(p.message_id)) || !TG_REACTIONS.has(emoji)) { tgReply(res, 400, { ok: false, code: 'bad_request' }); return; }
      const body = Buffer.from(JSON.stringify({ chat_id: chatId, message_id: Number(p.message_id),
        reaction: [{ type: 'emoji', emoji }] }), 'utf8');
      tgCall(token, method, body, 'application/json', answer);
      return;
    }

    // sendSticker
    const name = String(p.sticker || '');
    if (!TG_STICKER_RE.test(name) || !TG_STICKER_DIR) { tgReply(res, 400, { ok: false, code: 'bad_sticker' }); return; }
    const cacheKey = crypto.createHash('sha256').update(token).digest('hex').slice(0, 16) + ':' + name;
    // Upload: Datei asynchron lesen (der Dienst reicht parallel Claude-Streams durch -> kein readFileSync).
    const upload = () => fs.readFile(pathMod.join(TG_STICKER_DIR, name + '.webp'), (err, bytes) => {
      if (err) { diag('tg_sticker_missing'); tgReply(res, 404, { ok: false, code: 'sticker_missing' }); return; }
      const mp = tgMultipart({ chat_id: chatId }, 'sticker', name + '.webp', bytes);
      tgCall(token, method, mp.body, mp.contentType, (status, json) => {
        const fid = json && json.ok && json.result && json.result.sticker && json.result.sticker.file_id;
        if (status === 200 && typeof fid === 'string' && fid.length < 256) tgStickerIds.set(cacheKey, fid);
        answer(status, json);
      });
    });
    const cached = tgStickerIds.get(cacheKey);
    if (!cached) { upload(); return; }
    tgCall(token, method, Buffer.from(JSON.stringify({ chat_id: chatId, sticker: cached }), 'utf8'), 'application/json', (status, json) => {
      // 400 = Telegram kennt die file_id nicht (mehr) -> vergessen und GLEICH als Upload senden. Zeitlimit/Netzfehler:
      // file_id behalten (Telegram hat evtl. zugestellt), keine Wiederholung (sonst doppelt).
      if (status === 400) { diag('tg_sticker_fileid_stale'); tgStickerIds.delete(cacheKey); upload(); return; }
      answer(status, json);
    });
  });
  req.on('error', () => { diag('tg_client_error'); });
}

const server = http.createServer((req, res) => {
  // Telegram-Relay ZUERST: ein /__telegram/-Pfad faellt nie bis zur Anthropic-Weiterleitung durch.
  if (typeof req.url === 'string' && req.url.indexOf('/__telegram/') === 0) { handleTelegram(req, res); return; }
  if (req.method === 'GET' && req.url === '/__health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, upstream: UPSTREAM.origin, static_ttl: STATIC_TTL,
      keepalive: { on: KA_ON, hours: KA_HOURS, entries: keepAlive.size }, usage_file: !!USAGE_FILE,
      telegram: { upstream: TG_UPSTREAM.origin, sticker_dir: !!TG_STICKER_DIR && fs.existsSync(TG_STICKER_DIR) } }));
    return;
  }
  // Abruf der Mitschrift (nur 127.0.0.1, wie /__health) — VOR der Weiterleitung, sonst ginge der GET an Anthropic.
  if (req.method === 'GET' && typeof req.url === 'string' && (req.url === '/__usage' || req.url.indexOf('/__usage?') === 0)) {
    let page;
    try { page = usagePage(new URL(req.url, 'http://127.0.0.1').searchParams); }
    catch (e) { diag('usage_page_error'); page = { rows: [], next_after: null, has_more: false }; }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(page));
    return;
  }
  // Pfad-Waechter: nur origin-form ('/…'). Absolute-form oder '//host' wuerde in new URL() den Host ersetzen
  // bzw. werfen (-> uncaughtException -> Prozess-Neustart fuer ALLE laufenden Anfragen).
  if (typeof req.url !== 'string' || req.url[0] !== '/' || req.url[1] === '/') {
    diag('bad_request_target');
    res.writeHead(400, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'llm-gateway: bad request target' } }));
    return;
  }
  const chunks = [];
  let size = 0;
  let tooBig = false;
  req.on('data', (c) => {
    if (tooBig) return;
    size += c.length;
    if (size > MAX_BODY) { tooBig = true; return; }
    chunks.push(c);
  });
  req.on('end', () => {
    if (tooBig) {
      diag('request_too_large');
      res.writeHead(413, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'request_too_large', message: 'llm-gateway: request too large' } }));
      return;
    }
    const original = Buffer.concat(chunks);
    const path = (req.url || '').split('?')[0];
    const meta = { measure: false, model: null, stream: false, cached: false, fallback: false, started: Date.now() };
    if (req.method !== 'POST' || path !== '/v1/messages') { forward(req, res, original, meta, null); return; }

    meta.measure = true;
    meta.wf = headerWf(req.headers);
    let body;
    try { body = JSON.parse(original.toString('utf8')); }
    catch (e) { diag('parse_error'); forward(req, res, original, meta, null); return; }
    if (!body || typeof body !== 'object') { forward(req, res, original, meta, null); return; }
    meta.model = typeof body.model === 'string' ? body.model : null;
    meta.stream = body.stream === true;
    // Kennzeile ZUERST entfernen: ab hier ist der bereinigte Body das "Original" fuer jeden Pfad (Einmal-Aufruf,
    // inject_error, 400-Wiederholung) — die Kennzeile erreicht Anthropic nie, Cache-Anfang + Keep-Alive-Schluessel
    // bleiben byte-gleich zu einer Anfrage ohne Kennzeile.
    let clean = original;
    try {
      const tag = stripWfTag(body);
      if (tag.found) {
        if (tag.wf) meta.wf = tag.wf;
        clean = Buffer.from(JSON.stringify(body), 'utf8');
      }
    } catch (e) { diag('wf_tag_error'); forward(req, res, original, meta, null); return; }
    let cached = false;
    let serial = false;
    try { cached = applyCaching(body); serial = applySerialTools(body); }
    catch (e) { diag('inject_error'); forward(req, res, clean, meta, null); return; }
    if (!cached && !serial) { forward(req, res, clean, meta, null); return; }
    meta.cached = cached;
    if (cached && KA_ON) {
      try {
        const ka = keepAliveBody(body);
        if (ka) { const key = keepAliveKey(body); meta.onOk = () => keepAliveRecord(key, ka, req.headers, meta.model, meta.wf); }
      } catch (e) { diag('keepalive_prepare_error'); }
    }
    forward(req, res, Buffer.from(JSON.stringify(body), 'utf8'), meta, clean);
  });
  req.on('error', () => { diag('client_error'); });
});

// Laenger als der Leerlauf des Anthropic-SDK/undici-Pools, sonst zufaellige ECONNRESET auf wiederverwendeten
// Verbindungen. requestTimeout 0: Opus-Antworten mit Denken koennen Minuten dauern.
server.keepAliveTimeout = 75000;
server.headersTimeout = 76000;
server.requestTimeout = 0;

process.on('uncaughtException', (e) => { diag(e && e.code ? e.code : 'uncaught'); process.exit(1); });

if (KA_ON) setInterval(keepAliveTick, KA_TICK_MS).unref();
trimUsageFile();
setInterval(trimUsageFile, 24 * 3600 * 1000).unref();

server.listen(PORT, '127.0.0.1', () => {
  emit({ ev: 'start', port: PORT, upstream: UPSTREAM.origin, static_ttl: STATIC_TTL, keepalive_hours: KA_ON ? KA_HOURS : 0,
    usage_file: !!USAGE_FILE });
});
