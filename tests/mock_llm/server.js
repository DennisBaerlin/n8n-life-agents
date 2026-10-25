// mock_llm/server.js — lokaler LLM-Stub fuer die Test-Tiers (Teststrategie Phase 6 / 6b, Modell-Phase 2).
//
// ZWECK: deterministisches, GRATIS Testen des Agent-Tool-Pfads (ingress -> orchestrator -> agent ->
//   tool -> gate -> DB) OHNE echtes LLM. Der Stub spielt den naechsten "Model-Turn" gescriptet:
//   entweder einen Tool-Call oder eine finale Textantwort.
//
// DIALEKT: Anthropic (`/v1/messages`) — seit Modell-Phase 2 laufen ALLE Chat-Agenten auf Claude
//   (Orchestrator Haiku, Finance/Guide/Monitor Sonnet, Berater Opus). Der lmChatAnthropic-Node liest
//   `credentials.url` -> `anthropicApiUrl` (Node-Source Z.412/493); die Credential zeigt fest auf den lokalen
//   LLM-Gateway (provisioning/llm_gateway), und enable_mock_llm.ps1 biegt dessen UPSTREAM auf diesen Stub ->
//   der Stub sieht die Anfragen MIT den Cache-Haltepunkten des Gateways (aufgezeichnet als `markers`) und
//   bekommt auch die direkten HTTP-Aufrufe (JSON-Schema -> Platzhalter, s. fromSchema). Recherche-verifiziert (Live-Probe gegen Wegwerf-Stub mit
//   n8ns gebundeltem @langchain/anthropic: POST /v1/messages NON-streaming, `tools[].name` angeboten,
//   Anthropic `tool_use`-Bloecke sauber zu LangChain-tool_calls geparst).
//   GEMINI-TRANSKRIPTION (Credential-host biegt enable_mock_llm optional auf den Stub): der Stub spielt den
//   Upload-+generateContent-Ablauf des n8n-Gemini-Audio-Knotens (helpers/utils.ts uploadFile, n8n 2.44.4) nach,
//   aber NUR fuer Audio-Bytes mit Marker (der Telegram-Mock liefert 'mock-audio:<file_id>'; Marker-Liste =
//   GEMINI_FILES unten); jede andere Datei -> HTTP 404 -> Fehlerweg (voice_unavailable). Jeder sonstige Pfad -> 404.
//   Nie ein echter Google-Call.
//
// WARUM Endpunkt-Umbiegung (wie der Mock-Telegram-Server Phase 5): wir biegen nur den ENDPUNKT
//   BEREITS in Prod existierender Nodes um -> KEIN neuer Node, KEINE ai_models-/Builder-Aenderung,
//   Prod-Workflows zu 100% unangetastet.
//
// DETERMINISTISCHES MAPPING (Eingabe -> Tool-Call), zustandsfrei ueber Requests:
//   - n8n schickt bei jedem Agent-Call die VOLLE History mit. Daraus leitet der Stub den Turn ab
//     (Anzahl bereits emittierter assistant-tool_use-Turns in DIESER Konversation = k).
//   - Szenario-Auswahl: der Task-Text (alle user-text-Parts) gegen scenarios.json `match`
//     (case-insensitive substring). Mehrere Treffer -> der laengste `match` gewinnt (spezifischster).
//   - Namespace-aware (Multi-Agent): Orchestrator-Calls bieten Tools wie "Call 'agent.finance'",
//     Agent-Calls bieten "tool_*". Der Stub filtert scenario.calls auf die im Request ANGEBOTENEN Tools
//     und emittiert davon den k-ten -> derselbe Szenario-Eintrag treibt Orchestrator UND Sub-Agent.
//   - Alle angebotenen Calls emittiert -> finale Textantwort. Kein Szenario -> finale Textantwort
//     (der Agent bricht sauber ab, kein Crash).
//
// Anthropic-tool_use.input ist ein OBJEKT (nicht stringified wie OpenAI).
// Bewusst dependency-frei (nur Node-Core) und winzig: kein npm install, Node ist durch n8n garantiert.
'use strict';
const http = require('http');
const fs = require('fs');

const PORT = parseInt(process.env.MOCK_LLM_PORT || '8088', 10);
const LOG_FILE = process.env.MOCK_LLM_LOG || '/tmp/mock_llm.jsonl';
const SCENARIOS_FILE = process.env.MOCK_LLM_SCENARIOS || '/opt/mock_llm/scenarios.json';

function loadScenarios() {
  try { return JSON.parse(fs.readFileSync(SCENARIOS_FILE, 'utf8')); }
  catch (e) { return []; }
}

function isAnthropic(url) { return (url || '').indexOf('/v1/messages') !== -1; }

// ---- Gemini-Audio (nur Transkription) -----------------------------------------------------------
// Ablauf wie der n8n-Knoten: (1) POST /upload/v1beta/files -> Header x-goog-upload-url, (2) POST <upload-url>
// mit den Bytes -> { file: { name, uri, mimeType, state:'ACTIVE' } }, (3) POST /v1beta/models/<m>:generateContent
// mit fileData.fileUri -> { candidates: [{ content: { parts: [{ text }] } }] } (die echte API-Form: der Text
// steht verschachtelt, NICHT als Top-Level-.text).
// Marker-file_id -> Gemini-Dateiname: mock-speech antwortet mit MOCK_TRANSCRIPT, mock-silent mit einem Kandidaten
// ohne Text (stille Aufnahme).
const MOCK_TRANSCRIPT = 'Mock-Transkript: Wie hoch ist mein Kontostand?';
const GEMINI_FILES = { mock_voice_speech: 'files/mock-speech', mock_voice_silent: 'files/mock-silent' };
let uploadSeq = 0;
function geminiRoute(req, raw) {
  const path = (req.url || '').split('?')[0];
  const base = 'http://127.0.0.1:' + PORT;
  if (req.method === 'POST' && path === '/upload/v1beta/files') {
    return { status: 200, headers: { 'x-goog-upload-url': base + '/__gemini_upload/' + (++uploadSeq) }, body: {}, why: 'gemini-upload-start' };
  }
  if (req.method === 'POST' && path.indexOf('/__gemini_upload/') === 0) {
    const key = Object.keys(GEMINI_FILES).find((k) => raw.indexOf('mock-audio:' + k) !== -1);
    if (!key) return null;   // unmarkierte Datei -> 404 -> Fehlerweg (voice_unavailable)
    const name = GEMINI_FILES[key];
    return { status: 200, body: { file: { name, uri: base + '/v1beta/' + name, mimeType: 'audio/ogg', state: 'ACTIVE' } }, why: 'gemini-upload-finalize:' + key };
  }
  if (req.method === 'POST' && /:generateContent$/.test(path)) {
    const content = raw.indexOf('files/mock-speech') !== -1 ? { parts: [{ text: MOCK_TRANSCRIPT }], role: 'model' }
      : raw.indexOf('files/mock-silent') !== -1 ? { role: 'model' } : null;
    if (!content) return null;
    return { status: 200, body: { candidates: [{ content, finishReason: 'STOP', index: 0 }], modelVersion: 'gemini-mock' }, why: 'gemini-generate' };
  }
  return null;
}

// ---- Anthropic-Extraktoren (Request-Form: { messages, tools[].name }) ----------------------------
// Task-Text: alle text-Parts aus user-role-messages; content ist String ODER Array von Parts
// (tool_result-Parts werden uebersprungen). Folge-Turns: user-message mit tool_result -> kein Text.
function anthropicTaskText(messages) {
  const out = [];
  for (const m of messages) {
    if (!m || m.role !== 'user') continue;
    if (typeof m.content === 'string') { out.push(m.content); continue; }
    for (const p of (m.content || [])) { if (p && p.type === 'text' && typeof p.text === 'string') out.push(p.text); }
  }
  return out.join(' ');
}
function anthropicPriorTurns(messages) {
  let k = 0;
  for (const m of messages) {
    if (m && m.role === 'assistant' && Array.isArray(m.content) && m.content.some((p) => p && p.type === 'tool_use')) k++;
  }
  return k;
}
function anthropicOffered(body) {
  return (Array.isArray(body.tools) ? body.tools : []).map((t) => t && t.name).filter(Boolean);
}

function isJson(s) {
  if (typeof s !== 'string') return false;
  try { JSON.parse(s); return true; } catch (e) { return false; }
}

function pickScenario(scenarios, task) {
  const t = (task || '').toLowerCase();
  let best = null;
  for (const s of scenarios) {
    if (s && typeof s.match === 'string' && t.indexOf(s.match.toLowerCase()) !== -1) {
      if (!best || s.match.length > best.match.length) best = s;
    }
  }
  return best;
}

// ---- Cache-Haltepunkte (der LLM-Gateway setzt sie; der Mock zeichnet sie auf und spiegelt sie in usage) ----
function ttlOf(b) { return b && b.cache_control ? (b.cache_control.ttl || '5m') : null; }
function cacheMarkers(body) {
  const tools = Array.isArray(body.tools) ? body.tools : [];
  const sys = Array.isArray(body.system) ? body.system : [];
  let tool = null; let system = null;
  for (const t of tools) if (ttlOf(t)) tool = ttlOf(t);
  for (const s of sys) if (ttlOf(s)) system = ttlOf(s);
  return { top: body.cache_control ? (body.cache_control.ttl || '5m') : null, tool, system };
}
// Feste, plausible Zahlen: mit Haltepunkten Cache-Felder != 0 (der Gateway-Test prueft das Durchreichen/Messen).
function mockUsage(m) {
  if (!m.top && !m.tool && !m.system) return { input_tokens: 1, output_tokens: 1 };
  return { input_tokens: 5, cache_creation_input_tokens: 100, cache_read_input_tokens: 50, output_tokens: 1,
    cache_creation: { ephemeral_5m_input_tokens: 20, ephemeral_1h_input_tokens: 80 } };
}

// Schema-plausibler Platzhalter fuer direkte JSON-Schema-Aufrufe (Scorer, Vision, Monitor): Pflichtfelder mit
// Typ-Standardwerten — der Aufrufer bekommt parsebares JSON statt "done" und nimmt seinen Normalweg.
function fromSchema(s) {
  if (!s || typeof s !== 'object') return null;
  if (Array.isArray(s.enum) && s.enum.length) return s.enum[0];
  const t = Array.isArray(s.type) ? s.type.find((x) => x !== 'null') : s.type;
  if (t === 'object' || s.properties) {
    const o = {};
    for (const k of (Array.isArray(s.required) ? s.required : [])) o[k] = fromSchema((s.properties || {})[k]);
    return o;
  }
  if (t === 'array') return [];
  if (t === 'string') return '';
  if (t === 'number' || t === 'integer') return 0;
  if (t === 'boolean') return false;
  return null;
}

// ---- Response-Builder ---------------------------------------------------------------------------
function anthropicToolUse(call, k) {
  return { id: 'msg_' + k, type: 'message', role: 'assistant', model: 'claude-mock',
    content: [{ type: 'tool_use', id: 'toolu_' + k, name: call.tool, input: call.args || {} }],
    stop_reason: 'tool_use', stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } };
}
function anthropicText(text) {
  return { id: 'msg_final', type: 'message', role: 'assistant', model: 'claude-mock',
    content: [{ type: 'text', text: text || 'done' }], stop_reason: 'end_turn', stop_sequence: null,
    usage: { input_tokens: 1, output_tokens: 1 } };
}

// Echtes Anthropic-SSE (message_start / content_block_* / message_delta / message_stop) aus einem Payload —
// usage-Eingabefelder in message_start, output_tokens in message_delta (wie die echte API).
function sseFrames(p) {
  const out = [];
  const ev = (type, data) => out.push('event: ' + type + '\ndata: ' + JSON.stringify(Object.assign({ type }, data)) + '\n\n');
  const u = p.usage || {};
  const startUsage = Object.assign({}, u, { output_tokens: 1 });
  ev('message_start', { message: Object.assign({}, p, { content: [], stop_reason: null, usage: startUsage }) });
  ev('ping', {});
  (p.content || []).forEach((b, i) => {
    if (b.type === 'tool_use') {
      ev('content_block_start', { index: i, content_block: { type: 'tool_use', id: b.id, name: b.name, input: {} } });
      ev('content_block_delta', { index: i, delta: { type: 'input_json_delta', partial_json: JSON.stringify(b.input || {}) } });
    } else {
      ev('content_block_start', { index: i, content_block: { type: 'text', text: '' } });
      ev('content_block_delta', { index: i, delta: { type: 'text_delta', text: b.text || '' } });
    }
    ev('content_block_stop', { index: i });
  });
  ev('message_delta', { delta: { stop_reason: p.stop_reason, stop_sequence: null }, usage: { output_tokens: u.output_tokens || 1 } });
  ev('message_stop', {});
  return out.join('');
}

// Entscheidungslogik: offered/task/k extrahieren, dann das Szenario-Mapping, dann der Payload.
function decide(body) {
  const scenarios = loadScenarios();
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const offered = anthropicOffered(body);
  const task = anthropicTaskText(messages);
  const k = anthropicPriorTurns(messages);
  const scenario = pickScenario(scenarios, task);
  // delay_ms (optional): Antwort erst nach dieser Zeit -> ein "langsames" LLM fuer die "Bot denkt nach"-Schleife
  // (mock_route_test [thinking-keepalive]); gilt fuer jeden Turn des Szenarios.
  const delay = (scenario && Number(scenario.delay_ms)) || 0;
  if (!scenario || !Array.isArray(scenario.calls)) {
    // scripted = reines Antwort-Szenario ohne calls, dessen `final` JSON ist (z. B. die Vision-Antwort eines
    // Dokument-Tools): die gewollte Antwort, die der Schema-Platzhalter NICHT ueberschreiben darf. Freitext-finals
    // (Chat-Szenarien) bleiben fuer Schema-Calls beim Platzhalter.
    return { payload: anthropicText(scenario && scenario.final), why: 'no-scenario-or-no-calls', offered, task,
      scripted: isJson(scenario && scenario.final), delay };
  }
  // Nur die Calls, deren Tool im Request ANGEBOTEN wird (Namespace-Filter Orchestrator vs Agent).
  const eligible = scenario.calls.filter((c) => offered.indexOf(c.tool) !== -1);
  if (k < eligible.length) {
    return { payload: anthropicToolUse(eligible[k], k), why: 'tool-call:' + eligible[k].tool + ' turn=' + k, offered, task, delay };
  }
  // Woertliches Weiterreichen (Orchestrator-Relay): nach einem Spezialisten-Aufruf antwortet der Router nur mit dem
  // Signal FRAME/NOFRAME (Prompt-Regel 6) — der Workflow haengt die Spezialisten-Antwort selbst an. Der Router ist der
  // Request, der Call_*-Tools anbietet; final_router (optional) ersetzt dort das Spezialisten-final, Default NOFRAME.
  const isRouter = offered.some((t) => /^Call_/.test(t));
  if (isRouter && eligible.length > 0) {
    return { payload: anthropicText(scenario.final_router || 'NOFRAME'), why: 'router-signal-after-' + eligible.length + '-calls', offered, task, delay };
  }
  return { payload: anthropicText(scenario.final), why: 'final-after-' + eligible.length + '-calls', offered, task, delay };
}

function logLine(entry) {
  try { fs.appendFileSync(LOG_FILE, JSON.stringify(Object.assign({ t: new Date().toISOString() }, entry)) + '\n'); }
  catch (e) { /* Logging-Fehler nie den Response kippen */ }
}

const server = http.createServer((req, res) => {
  if (req.url === '/__health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok'); return; }
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    if (!isAnthropic(req.url)) {
      const g = geminiRoute(req, Buffer.concat(chunks).toString('latin1'));
      if (g) {
        logLine({ url: req.url, dialect: 'gemini', decision: g.why });
        res.writeHead(g.status, Object.assign({ 'Content-Type': 'application/json' }, g.headers || {}));
        res.end(JSON.stringify(g.body));
        return;
      }
      // Kein bedienter Pfad (z. B. Gemini-Transkription einer unmarkierten Datei) -> 404, aufgezeichnet.
      logLine({ url: req.url, dialect: 'other', decision: 'not-found-404' });
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { code: 404, message: 'mock-llm: nur /v1/messages (Anthropic) und markierte Gemini-Transkription werden bedient' } }));
      return;
    }
    const raw = Buffer.concat(chunks).toString('utf8');
    let body = {};
    try { body = JSON.parse(raw); } catch (e) { /* leer lassen */ }
    const markers = cacheMarkers(body || {});
    // Test-Ausloeser (llm_gateway_test.ps1): Anthropic lehnt die Haltepunkte ab -> der Gateway muss EINMAL ohne
    // Einfuegen wiederholen. Ohne Marker (die Wiederholung) normal weiter.
    if (raw.indexOf('__mock_400_cache_control__') !== -1 && (markers.top || markers.tool || markers.system)) {
      logLine({ url: req.url, dialect: 'anthropic', markers, decision: 'forced-400-cache_control' });
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'mock: cache_control rejected' } }));
      return;
    }
    let out;
    try { out = decide(body); }
    catch (e) { out = { payload: anthropicText('mock-error'), why: 'exception:' + (e && e.message), offered: [], task: '' }; }
    // Direkte JSON-Schema-Aufrufe (output_config.format) ohne gescriptete Antwort bekommen statt Freitext einen
    // schema-plausiblen Platzhalter (vorher auch MIT Szenario -> tc49/tc51 lasen nie ihre Szenario-Werte).
    const fmt = body && body.output_config && body.output_config.format;
    if (fmt && fmt.schema && out.payload.stop_reason === 'end_turn' && !out.scripted) {
      out.payload = anthropicText(JSON.stringify(fromSchema(fmt.schema)));
      out.why += '+schema-placeholder';
    }
    out.payload.usage = Object.assign(mockUsage(markers), { output_tokens: 1 });
    // Aufzeichnung (eine JSON-Zeile je Call; der Harness liest sie via `docker exec cat`).
    // system_tail: die letzten Zeichen des System-Prompts (dort stehen die wechselnden Runtime-Flags, z. B.
    // "persona: butler") -> real_ingress_test prueft gratis, dass ein Flag das Modell erreicht.
    const sysText = !body ? '' : (typeof body.system === 'string' ? body.system
      : (Array.isArray(body.system) ? body.system.map((s) => (s && s.text) || '').join('\n') : ''));
    logLine({ url: req.url, dialect: 'anthropic', offered: out.offered, task: out.task, decision: out.why, markers,
      system_tail: sysText.slice(-300),
      tool_choice: (body && body.tool_choice) || null,      // llm_gateway_test (j): ein Werkzeug je Antwort
      max_tokens: body ? body.max_tokens : null });          // llm_gateway_test (k): Keep-Alive = max_tokens 0
    // Streaming (body.stream) -> echtes Anthropic-SSE; sonst JSON. Recherche-verifiziert: der Node ruft
    // non-streaming (JSON) -> der JSON-Pfad ist der Live-Pfad; SSE deckt den Gateway-Test ab.
    const send = () => {
      if (body && body.stream === true) {
        res.writeHead(200, { 'Content-Type': 'text/event-stream' });
        res.end(sseFrames(out.payload));
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(out.payload));
      }
    };
    // Keep-Alive des Gateways (max_tokens 0) nie verzoegern.
    if (out.delay > 0 && !(body && body.max_tokens === 0)) setTimeout(send, out.delay); else send();
  });
});

server.listen(PORT, '127.0.0.1', () => {
  logLine({ method: '__start', port: PORT, scenarios: SCENARIOS_FILE });
  process.stdout.write('mock-llm (anthropic) listening on 127.0.0.1:' + PORT + ' (scenarios: ' + SCENARIOS_FILE + ')\n');
});
