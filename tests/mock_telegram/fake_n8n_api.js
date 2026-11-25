// fake_n8n_api.js — Attrappe der n8n-Public-API fuer relink_cases.sh (nur die drei Aufrufe, die `lifeagents telegram relink` braucht).
// real-path-test: none (der echte Weg braucht den echten Test-Bot, den eine andere Installation belegt haben kann; echter Lauf nur mit N8NTEST_REAL_TELEGRAM=1)
//
// GET  /api/v1/workflows            -> ein Orchestrator-Workflow (id wf-orch)
// POST /api/v1/workflows/<id>/unpublish -> 200; wie n8n: Webhook beim Telegram-Mock loesen (deleteWebhook-Wirkung)
// POST /api/v1/workflows/<id>/publish   -> 200; wie n8n: Webhook auf https://<WEBHOOK_HOST>/webhook/x/webhook setzen
// GET  /__mode?publish=ok|fail|noop   fail = HTTP 400 {message}, noop = 200 ohne setWebhook (Telegram lehnt still ab)
// GET  /__calls                      -> Zahl der POSTs (publish + unpublish)
'use strict';
const http = require('http');
const tgPort = process.env.MOCK_TG_PORT;
const host = process.env.WEBHOOK_HOST || 'home.example.test';
let mode = 'ok';
let calls = 0;
const tg = (qs) => new Promise((resolve) => {
  http.get(`http://127.0.0.1:${tgPort}/__webhook?${qs}`, (r) => { r.resume(); r.on('end', resolve); }).on('error', resolve);
});
http.createServer(async (req, res) => {
  const send = (code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(obj)); };
  const u = req.url;
  if (u === '/__health') return send(200, { ok: true });
  if (u.startsWith('/__mode?')) { mode = new URLSearchParams(u.split('?')[1]).get('publish') || 'ok'; return send(200, { mode }); }
  if (u === '/__calls') return send(200, { calls });
  if (u.startsWith('/api/v1/workflows?') && req.method === 'GET') return send(200, { data: [{ id: 'wf-orch', name: 'core.orchestrator', active: true }] });
  let m = u.match(/^\/api\/v1\/workflows\/([^/]+)\/(publish|unpublish)$/);
  if (m && req.method === 'POST') {
    calls++;
    if (m[2] === 'unpublish') { await tg('off=1'); return send(200, {}); }
    if (mode === 'fail') return send(400, { message: 'Telegram: bad webhook: IP address is not allowed' });
    if (mode === 'ok') await tg('url=' + encodeURIComponent(`https://${host}/webhook/x/webhook`));
    return send(200, {});
  }
  send(404, {});
}).listen(Number(process.env.FAKE_N8N_PORT), '127.0.0.1');
