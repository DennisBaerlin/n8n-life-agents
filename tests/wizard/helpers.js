// Gemeinsame Helfer der Wizard-Tests (node --test, nur Node-Core). Startet provisioning/wizard/server.js als eigenen
// Prozess mit Wegwerf-Verzeichnissen und den Attrappen aus fixtures/, und spricht ihn über echtes HTTP an.
'use strict';
const http = require('http');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
const WIZ = path.join(REPO, 'provisioning', 'wizard');

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
}

// Attrappen ausführbar in ein Wegwerf-Verzeichnis kopieren (der Repo-Baum ist im Test-Container schreibgeschützt).
function fixtures(dir) {
  const out = {};
  for (const f of ['fake_bridge.sh', 'fake_provision.sh', 'fake_lifeagents.sh', 'fake_reach.sh']) {
    const dst = path.join(dir, f);
    fs.copyFileSync(path.join(__dirname, 'fixtures', f), dst);
    fs.chmodSync(dst, 0o755);
    out[f] = dst;
  }
  return out;
}

async function startWizard(opts = {}) {
  const dir = opts.dir || fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-'));
  const fake = path.join(dir, 'fake');
  fs.mkdirSync(fake, { recursive: true });
  const fx = fixtures(dir);
  const port = opts.port || await freePort();
  const env = Object.assign({}, process.env, {
    WIZARD_PORT: String(port), WIZARD_BIND: '127.0.0.1', WIZARD_PUBLIC_ORIGIN: `http://127.0.0.1:${port}`,
    WIZARD_STATE_DIR: path.join(dir, 'state'), WIZARD_RUN_DIR: path.join(dir, 'run'), WIZARD_KEY_FILE: path.join(dir, 'etc', 'wizard.key'),
    WIZARD_BRIDGE: fx['fake_bridge.sh'], WIZARD_FAKE_REAL_BRIDGE: path.join(WIZ, 'bridge.sh'), WIZARD_FAKE_DIR: fake,
    LA_PROVISION: fx['fake_provision.sh'], LA_CLI: fx['fake_lifeagents.sh'], LA_REACH: fx['fake_reach.sh'], WIZARD_POLL_MS: '50',
    WIZARD_GUIDE_URL: 'https://beispiel.example/anleitung/',
  }, opts.env || {});
  // Vorschläge der Start-App: wie im master als flüchtige Datei hints.env (Objekt -> KEY=wert-Zeilen, Text roh).
  if (opts.hints !== undefined) {
    fs.mkdirSync(path.join(dir, 'run'), { recursive: true, mode: 0o700 });
    const t = typeof opts.hints === 'string' ? opts.hints : Object.entries(opts.hints).map(([k, v]) => `${k}=${v}\n`).join('');
    fs.writeFileSync(path.join(dir, 'run', 'hints.env'), t, { mode: 0o600 });
  }
  const proc = spawn(process.execPath, [path.join(WIZ, 'server.js')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let errOut = '';
  proc.stderr.on('data', (d) => { errOut += d; });
  await new Promise((resolve, reject) => {
    let out = '';
    const t = setTimeout(() => reject(new Error('wizard not ready: ' + errOut)), 60000);
    proc.stdout.on('data', (d) => { out += d; if (out.includes('wizard_ready')) { clearTimeout(t); resolve(); } });
    proc.on('exit', (c) => { clearTimeout(t); reject(new Error('wizard exited ' + c + ': ' + errOut)); });
  });
  // Der Wizard-Prozess hält den Test-Lauf nie offen: Sind alle Tests einer Datei per Namensfilter übersprungen, läuft
  // test.after nicht, und ein offener Kind-Prozess samt Pipes ließe node --test ewig warten (Fund 2026-11-06).
  proc.stdout.destroy();
  proc.stderr.destroy();
  proc.unref();
  process.once('exit', () => { try { proc.kill('SIGKILL'); } catch (_) { /* schon weg */ } });
  const w = { dir, fake, port, proc, env, origin: `http://127.0.0.1:${port}`, cookie: '', csrf: '' };
  w.exited = new Promise((resolve) => proc.on('exit', (c) => resolve(c)));
  // Beim Warten aufs Ende den Prozess wieder festhalten, sonst endet node vorher still (nichts anderes hält die Schleife).
  w.stop = async () => { if (proc.exitCode === null) { proc.ref(); proc.kill('SIGTERM'); await w.exited; } };
  return w;
}

// req(w, method, path, {headers, body, raw}) -> {status, headers, body (Text), json}
function req(w, method, p, o = {}) {
  return new Promise((resolve, reject) => {
    const headers = Object.assign({ Host: `127.0.0.1:${w.port}` }, o.headers || {});
    let body = null;
    if (o.raw !== undefined) body = Buffer.from(o.raw);
    else if (o.body !== undefined) body = Buffer.from(JSON.stringify(o.body));
    if (body) headers['Content-Length'] = body.length;
    const r = http.request({ host: '127.0.0.1', port: w.port, method, path: p, headers }, (res) => {
      const parts = [];
      res.on('data', (d) => parts.push(d));
      res.on('end', () => {
        const buf = Buffer.concat(parts);
        const text = buf.toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch (_) { /* kein JSON */ }
        resolve({ status: res.statusCode, headers: res.headers, body: text, buf, json });
      });
    });
    r.on('error', reject);
    if (body) r.write(body);
    r.end();
  });
}

function ctl(w, cmd) {
  return new Promise((resolve, reject) => {
    let out = '';
    const c = net.createConnection(path.join(w.dir, 'run', 'ctl.sock'), () => c.write(cmd + '\n'));
    c.on('data', (d) => { out += d; });
    c.on('end', () => { try { resolve(JSON.parse(out)); } catch (e) { reject(e); } });
    c.on('error', reject);
  });
}

async function login(w) {
  const { url } = await ctl(w, 'issue');
  const u = new URL(url);
  const r = await req(w, 'GET', u.pathname + u.search);
  if (r.status !== 303) throw new Error('login failed ' + r.status);
  w.cookie = /la_wizard=[^;]+/.exec(r.headers['set-cookie'][0])[0];
  const s = await state(w);
  return s;
}
async function state(w) {
  const r = await req(w, 'GET', '/api/state', { headers: { Cookie: w.cookie } });
  if (r.json && r.json.csrf) w.csrf = r.json.csrf;
  return r;
}
function post(w, p, body, extra = {}) {
  return req(w, 'POST', p, { body, headers: Object.assign({ Cookie: w.cookie, Origin: w.origin, 'Content-Type': 'application/json', 'X-CSRF-Token': w.csrf }, extra) })
    .then((r) => { if (r.json && r.json.csrf) w.csrf = r.json.csrf; return r; });
}
// answer(w, value, opts) -> beantwortet die gerade offene Seite; prüft, dass die Seite die erwartete ist.
async function answer(w, expectId, value, extra = {}) {
  const s = await state(w);
  if (s.json.page.id !== expectId) throw new Error(`expected page ${expectId}, got ${s.json.page.id}`);
  return post(w, '/api/answer', Object.assign({ id: expectId, value }, extra));
}
async function waitFor(fn, ms = 20000) {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timeout');
    await new Promise((r) => setTimeout(r, 60));
  }
}
function lanIp() {
  for (const list of Object.values(os.networkInterfaces())) for (const a of list) if (a.family === 'IPv4' && !a.internal) return a.address;
  return null;
}

module.exports = { REPO, WIZ, startWizard, req, ctl, login, state, post, answer, waitFor, lanIp, freePort };
