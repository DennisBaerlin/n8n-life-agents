// Brücke zur CLI-Quelle (provisioning/wizard/bridge.sh): der Fragen-Auszug folgt release_inputs.sh und den Manifesten,
// die Prüfregeln sind die der CLI, die Paperless-Prüfung erkennt Version und Zugang. Ruft die echte bridge.sh.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { execFileSync } = require('child_process');
const { REPO, WIZ, lanIp } = require('./helpers');

const BRIDGE = path.join(WIZ, 'bridge.sh');
// Kein Aufruf darf eine echte FritzBox oder den Echo-Dienst erreichen (der Container hat Netz, siehe durchlauf.test.js),
// und keiner liest den Zwischenspeicher eines früheren Aufrufs: reach-status prüft vor der Wahl dieselbe IPv4 wie dslite.
const NO_BOX = { REACH_UPNP_URL: 'http://127.0.0.1:9/', REACH_IPV4_ECHO: 'http://127.0.0.1:9/', REACH_HINTS_FILE: '/nonexistent/hints.env',
  REACH_RUN_DIR: fs.mkdtempSync(path.join(require('os').tmpdir(), 'reach-')) };
const run = (args, input = '', env = {}) => JSON.parse(execFileSync('bash', [BRIDGE, ...args], { input, env: Object.assign({}, process.env, NO_BOX, env) }).toString().trim());
const sh = (script) => execFileSync('bash', ['-c', script], { env: Object.assign({}, process.env, { P: path.join(REPO, 'provisioning') }) }).toString().trim();

test('Fragen-Auszug = Host-Fragen der CLI (ohne n8n-Anmeldung und Proxy-Ort) + alle gebündelten Pakete', () => {
  const q = run(['questions']);
  const cli = sh('. "$P/lib/common.sh"; . "$P/lib/release_inputs.sh"; printf %s "$_INSTALL_ENV_KEYS"').split(' ');
  assert.deepEqual(q.host.map((h) => h.key), cli.filter((k) => !['REACH_MODE', 'N8N_OWNER_EMAIL', 'N8N_OWNER_PASSWORD', 'TRUSTED_PROXIES'].includes(k)));
  const req = sh('. "$P/lib/common.sh"; . "$P/lib/release_inputs.sh"; printf %s "$_REQUIRED_HOST_KEYS"').split(' ');
  for (const h of q.host) assert.equal(h.required, req.includes(h.key), h.key);
  const pk = fs.readdirSync(path.join(REPO, 'packages')).filter((p) => p !== 'core' && fs.existsSync(path.join(REPO, 'packages', p, 'manifest.json')));
  assert.deepEqual(q.packages.map((p) => p.id).sort(), pk.sort());
  for (const p of q.packages) {
    const m = JSON.parse(fs.readFileSync(path.join(REPO, 'packages', p.id, 'manifest.json'), 'utf8'));
    assert.ok(p.name && p.summary, p.id + ': Name + Kurzbeschreibung aus dem Textkatalog');
    const envKeys = Object.entries(m.credentials || {}).filter(([k]) => k !== '_comment').flatMap(([, c]) => Object.keys(c.env));
    assert.deepEqual(p.credentials.flatMap((c) => c.keys.map((k) => k.env)), envKeys, p.id);
    for (const s of p.settings) assert.match(s.env, /^CONFIG_[A-Z0-9_]+$/);
    const cfg = Object.entries(m.config || {}).filter(([c]) => c !== '_comment')
      .flatMap(([c, v]) => Object.entries(v).filter(([, e]) => e && typeof e === 'object' && e.prompt).map(([k]) => c + '.' + k));
    assert.deepEqual(p.settings.map((s) => s.id), cfg, p.id + ': Einstellungen mit prompt');
  }
  assert.ok(q.languages.some((l) => l.code === 'de') && q.personas.some((p) => p.code === 'neutral'));
  assert.ok(q.host.find((h) => h.key === 'TELEGRAM_BOT_TOKEN').live && q.host.find((h) => h.key === 'TELEGRAM_BOT_TOKEN').secret);
});

test('Prüfregeln der CLI über die Brücke (lokal, ohne Netz)', () => {
  const v = (ref, val) => run(['validate', ref], val);
  assert.equal(v('host:OWNER_BIRTH_DATE', '1985-04-23').rc, 0);
  for (const bad of ['1985-02-30', '2999-01-01', '23.04.1985', '1985-4-23']) assert.equal(v('host:OWNER_BIRTH_DATE', bad).rc, 1, bad);
  assert.equal(v('host:OWNER_FIRST_NAME', '   ').rc, 1);
  assert.equal(v('host:OWNER_FIRST_NAME', "O'Neil $(id) `x`").value, "O'Neil $(id) `x`");
  assert.equal(v('host:DOMAIN', 'https://MeinRechner.Deine-Domain.myfritz.net/').value, 'meinrechner.deine-domain.myfritz.net');
  assert.match(v('host:DOMAIN', 'deine-domain.myfritz.net').problem, /FritzBox selbst/);
  assert.match(v('host:DOMAIN', 'bot.example.org:8443').problem, /Port 8443/);
  assert.equal(v('host:N8N_OWNER_PASSWORD', 'Geheim123').rc, 1, 'nicht gefragte Schlüssel gibt es für den Wizard nicht');
  assert.equal(v('host:PATH', '/x').rc, 1);
  assert.equal(v('cfg:estate:general.bundesland', 'bayern').rc, 0);
  assert.equal(v('cfg:estate:general.bundesland', 'Bayern').rc, 1);
  assert.equal(v('cfg:paperless:general.paperless_url', 'ftp://x').rc, 1);
  assert.equal(v('cfg:../core:x.y', 'a').rc, 1);
  assert.equal(v('cred:career:ADZUNA_APP_ID', 'abc').rc, 0);
  assert.equal(v('cred:career:UNBEKANNT', 'abc').rc, 1);
});

test('Paperless-Prüfung: Version, Zugang, localhost, nicht erreichbar', async () => {
  const ip = lanIp();
  const srv = http.createServer((req, res) => {
    const a = req.headers.authorization || '';
    if (req.url !== '/api/') { res.writeHead(404); return res.end(); }
    if (a === 'Token alt') { res.writeHead(200, { 'X-Version': '2.17.1' }); return res.end('{}'); }
    if (a === 'Token keinpaperless') { res.writeHead(200); return res.end('{}'); }
    if (a === 'Token gut') { res.writeHead(200, { 'X-Version': '3.0.0' }); return res.end('{}'); }
    res.writeHead(401); return res.end('{}');
  });
  await new Promise((r) => srv.listen(0, '0.0.0.0', r));
  const url = `http://${ip}:${srv.address().port}`;
  const pc = (u, t) => new Promise((resolve) => {
    const p = require('child_process').spawn('bash', [BRIDGE, 'paperless-check']);
    let o = ''; p.stdout.on('data', (d) => { o += d; }); p.on('close', () => resolve(JSON.parse(o.trim())));
    p.stdin.end(`${u}\n${t}\n`);
  });
  try {
    assert.deepEqual(await pc(url, ''), { ok: true, reason: 'reachable' });
    assert.deepEqual(await pc(url, 'gut'), { ok: true, reason: 'ok', version: '3.0.0' });
    assert.deepEqual(await pc(url, 'alt'), { ok: false, reason: 'too_old', version: '2.17.1' });
    assert.deepEqual(await pc(url, 'falsch'), { ok: false, reason: 'token_rejected' });
    assert.deepEqual(await pc(url, 'keinpaperless'), { ok: false, reason: 'not_paperless' });
    for (const u of ['http://localhost:8000', 'http://LOCALHOST:8000', 'http://127.0.0.2', 'http://[::1]:8000', 'http://0.0.0.0:1', 'http://admin@localhost:8000', 'http://a:b@127.0.0.1/', 'http://127.1:8000', 'http://[::ffff:127.0.0.1]:8000'])  {
      assert.equal((await pc(u, '')).reason, 'localhost', u);
    }
    assert.equal((await pc('192.0.2.1:8000', '')).reason, 'invalid');
    assert.equal((await pc(`http://${ip}:1`, '')).reason, 'unreachable');
  } finally { srv.close(); }
});

// Der Test-Container hat weder Docker noch einen gewählten Weg: so sieht es auf einem frischen Rechner vor der Wahl aus.
test('Schnittstellen zu Paket 1/3: frischer Rechner ohne Weg = nicht verfügbar, ohne Docker unbekannt statt belegt', () => {
  const r = run(['reach-status']);
  assert.equal(r.state, 'unavailable');
  assert.equal(r.reason, 'no_mode');
  assert.deepEqual(run(['reach-ports']), { state: 'unknown' }, 'nicht messbar ist nicht belegt');
  assert.deepEqual(run(['reach-ports'], '', { LA_PROBE_IMAGE: '' }), { state: 'unknown' }, 'ohne Probe-Image nicht messbar');
  assert.deepEqual(run(['paperless-ports']), { ports: [] }, 'ohne Docker keine Suche');
  assert.equal(run(['dslite']).dslite, 'unknown', 'ohne FritzBox und MyFRITZ-Zone: von Hand fragen');
  assert.deepEqual(run(['tg-check'], '', { TELEGRAM_BOT_TOKEN: '' }), { ok: false, reason: 'unauthorized' });
});
