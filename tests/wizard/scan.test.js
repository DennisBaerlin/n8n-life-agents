// Paperless im eigenen Heimnetz finden (provisioning/wizard/scan.js + Seite im Wizard): Attrappen-Server mit der
// Paperless-Anmeldeseite auf den echten Suchports dieses Test-Containers; ein anderer Dienst auf einem Suchport zählt nicht.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { WIZ, startWizard, login, state, answer, waitFor, lanIp } = require('./helpers');
const scan = require(path.join(WIZ, 'scan.js'));

const LOGIN = '<!DOCTYPE html><html><head><meta name="author" content="Paperless-ngx project and contributors"><title>Anmelden</title></head><body></body></html>';
function server(port, paperless) {
  return new Promise((resolve) => {
    const s = http.createServer((req, res) => {
      if (paperless && req.url === '/accounts/login/') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(LOGIN); }
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<html><head><title>Anderer Dienst</title></head></html>');
    });
    s.listen(port, '0.0.0.0', () => resolve(s));
  });
}
const close = (...s) => Promise.all(s.map((x) => new Promise((r) => x.close(r))));

test('scanPaperless: erkennt nur die Paperless-Anmeldeseite, eigener Rechner zuerst, ohne Adresse keine Suche', async () => {
  const ip = lanIp();
  const a = await server(8010, true);
  const b = await server(8000, false);
  try {
    assert.deepEqual(await scan.scanPaperless({ hostIp: ip, timeoutMs: 150 }), [`http://${ip}:8010`]);
  } finally { await close(a, b); }
  const c = await server(8000, true);
  const d = await server(8010, true);
  try {
    assert.deepEqual(await scan.scanPaperless({ hostIp: ip, timeoutMs: 150 }), [`http://${ip}:8000`, `http://${ip}:8010`]);
  } finally { await close(c, d); }
  for (const bad of ['', '127.0.0.1', '169.254.1.2', 'x.y', '192.0.2.1; rm -rf /']) assert.deepEqual(await scan.scanPaperless({ hostIp: bad }), []);
  assert.deepEqual(scan.PORTS, [8000, 8010, 80, 443]);
});

async function toPaperlessPage(w) {
  await login(w);
  for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'],
    ['h:OWNER_BIRTH_DATE', '1980-01-01'], ['h:OWNER_PERSONA', 'neutral'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'],
    ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', ['paperless']]]) {
    const r = await answer(w, id, v);
    if (r.status !== 200) throw new Error(id + ' ' + JSON.stringify(r.json));
  }
  return waitFor(async () => { const p = (await state(w)).json.page; return p.id === 's:paperless:general.paperless_url' && !p.poll ? p : null; }, 30000);
}

test('Wizard-Seite: Suche im Heimnetz, mehrere Treffer = Auswahl, keiner = leeres Feld', async () => {
  const ip = lanIp();
  const env = { WIZARD_SCAN_TIMEOUT_MS: '150' };
  const hints = { LA_HOST_IP: ip };
  const a = await server(8000, true);
  const b = await server(8010, true);
  let w = await startWizard({ env, hints });
  try {
    await login(w);
    const p = await toPaperlessPage(w);
    assert.deepEqual(p.suggestions, [`http://${ip}:8000`, `http://${ip}:8010`]);
    assert.equal(p.value, '', 'bei mehreren nichts vorausgefüllt');
    assert.match(p.note.text, /mehrmals/);
  } finally { await w.stop(); await close(a, b); }
  w = await startWizard({ env, hints });
  try {
    const p = await toPaperlessPage(w);
    assert.equal(p.value, '');
    assert.ok(!p.suggestions);
    assert.match(p.note.text, /kein Paperless gefunden/);
  } finally { await w.stop(); }
  // Ohne Modul Dokumente wird nie gesucht: die Seite gibt es dann nicht, also auch keinen Suchlauf.
  w = await startWizard({ env, hints });
  try {
    await login(w);
    const prog = path.join(w.dir, 'state', 'progress.json');
    await answer(w, 'h:OWNER_LANGUAGE', 'de');
    assert.ok(!fs.readFileSync(prog, 'utf8').includes('paperless_search'));
  } finally { await w.stop(); }
});
