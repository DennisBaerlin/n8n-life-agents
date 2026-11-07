// Sicherheits-Fälle des Wizard-Servers (Plan *Wizard-Sicherheit*): Host/Origin, Einmal-Wert, Sitzung, CSRF, Kopfzeilen,
// Eingaben mit Sonderzeichen, Geheimnisse nie im Klartext auf der Platte, Steuerkanal, Ende nach „Fertig“.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { WIZ, startWizard, req, ctl, login, state, post, answer } = require('./helpers');

let w;
test.before(async () => { w = await startWizard(); });
test.after(async () => { if (w) await w.stop(); });

test('falscher Host wird abgewiesen (auch DNS-Rebinding)', async () => {
  for (const host of ['evil.example', `evil.example:${w.port}`, `127.0.0.1:${w.port + 1}`, `localhost:${w.port}`, '127.0.0.1', `127.0.0.1.nip.io:${w.port}`]) {
    for (const p of ['/', '/start?t=x', '/api/state', '/app.js']) {
      const r = await req(w, 'GET', p, { headers: { Host: host } });
      assert.equal(r.status, 421, `${host} ${p}`);
    }
  }
});

test('Kopfzeilen: CSP ohne Inline-Skript, kein Referrer, kein Caching, kein Einbetten', async () => {
  const r = await req(w, 'GET', '/app.js');
  assert.equal(r.status, 200);
  for (const [p, f] of [['/app.js', 'app.js'], ['/app.css', 'app.css']]) {
    assert.ok((p === '/app.js' ? r : await req(w, 'GET', p)).buf.equals(fs.readFileSync(path.join(WIZ, 'ui', f))), p + ' kommt als die Datei selbst');
  }
  assert.match(r.headers['content-security-policy'], /default-src 'none'/);
  assert.match(r.headers['content-security-policy'], /script-src 'self'(;|$)/);
  assert.doesNotMatch(r.headers['content-security-policy'], /unsafe-inline|unsafe-eval/);
  assert.match(r.headers['content-security-policy'], /frame-ancestors 'none'/);
  assert.equal(r.headers['referrer-policy'], 'no-referrer');
  assert.equal(r.headers['x-content-type-options'], 'nosniff');
  assert.equal(r.headers['x-frame-options'], 'DENY');
  assert.equal(r.headers['cache-control'], 'no-store');
});

test('ohne Sitzung: Startseite und API gesperrt', async () => {
  assert.equal((await req(w, 'GET', '/')).status, 403);
  assert.equal((await req(w, 'GET', '/api/state')).status, 401);
  assert.equal((await req(w, 'GET', '/api/report')).status, 401);
  assert.equal((await req(w, 'POST', '/api/answer', { body: {}, headers: { Origin: w.origin, 'Content-Type': 'application/json' } })).status, 401);
});

test('Einmal-Wert: falsch, wiederverwendet, ersetzt; Cookie-Attribute', async () => {
  assert.equal((await req(w, 'GET', '/start?t=' + 'A'.repeat(43))).status, 403);
  const a = new URL((await ctl(w, 'issue')).url);
  const b = new URL((await ctl(w, 'issue')).url);
  assert.equal((await req(w, 'GET', a.pathname + a.search)).status, 403, 'älterer Wert gilt nach neuem issue nicht mehr');
  const ok = await req(w, 'GET', b.pathname + b.search);
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.location, '/');
  const c = ok.headers['set-cookie'][0];
  assert.match(c, /HttpOnly/); assert.match(c, /SameSite=Strict/); assert.match(c, /Path=\//);
  assert.equal((await req(w, 'GET', b.pathname + b.search)).status, 403, 'Wert nur einmal');
  assert.equal((await req(w, 'GET', b.pathname + b.search, { headers: { 'Sec-Fetch-Site': 'cross-site' } })).status, 403);
});

test('Startseite: Projekt-Zeichen eingesetzt, Bild-Bausteine nur als eigene Datei (CSP)', async () => {
  await login(w);
  const r = await req(w, 'GET', '/', { headers: { Cookie: w.cookie } });
  assert.equal(r.status, 200);
  assert.ok(r.body.includes('M13 2.5 L22 10 V19.5'), 'Haus mit Sprechblase');
  assert.ok(!r.body.includes('<!--mark-->'));
  assert.ok(!r.body.includes('-->'), 'kein Rest des Datei-Kommentars in der Seite');
  assert.ok(!/<script>/.test(r.body), 'kein Inline-Skript');
  assert.ok([200, 404].includes((await req(w, 'GET', '/art.js')).status), 'Bilder (art/) kommen von di9; fehlen sie, 404 statt Absturz');
  // Erklär-Bilder: nur Dateien aus ui/explain/ mit festem Namensaufbau, als SVG.
  const svg = await req(w, 'GET', '/explain/telegram.de.svg');
  assert.equal(svg.status, 200);
  assert.match(svg.headers['content-type'], /^image\/svg\+xml/);
  assert.ok(svg.body.includes('<svg'));
  for (const p of ['/explain/fehlt.de.svg', '/explain/..%2Fserver.js', '/explain/telegram.de.svg.bak', '/explain/Telegram.de.svg']) {
    assert.equal((await req(w, 'GET', p)).status, 404, p);
  }
});

test('neue Anmeldung beendet die alte Sitzung', async () => {
  await login(w);
  const old = w.cookie;
  await login(w);
  assert.equal((await req(w, 'GET', '/api/state', { headers: { Cookie: old } })).status, 401);
  assert.equal((await state(w)).status, 200);
});

test('ctl.js (Aufruf der App per docker exec): url, status, unbekannter Befehl', () => {
  const { execFileSync, spawnSync } = require('child_process');
  const env = Object.assign({}, process.env, { WIZARD_RUN_DIR: path.join(w.dir, 'run') });
  const ctlJs = path.join(require('./helpers').WIZ, 'ctl.js');
  const u = JSON.parse(execFileSync(process.execPath, [ctlJs, 'url'], { env }).toString());
  assert.match(u.url, new RegExp(`^http://127\\.0\\.0\\.1:${w.port}/start\\?t=[A-Za-z0-9_-]{43}$`));
  assert.equal(JSON.parse(execFileSync(process.execPath, [ctlJs, 'status'], { env }).toString()).phase, 'questions');
  for (const bad of ['constructor', 'prune', '']) assert.equal(spawnSync(process.execPath, [ctlJs, bad], { env }).status, 64, bad);
});

test('Docker-Betrieb: Adresse aus LA_WIZARD_PORT (veröffentlicht am Rand), eigener Port gilt dann nicht als Host', async () => {
  const c = await startWizard({ env: { LIFEAGENTS_RUNTIME: 'compose', LA_WIZARD_PORT: '5999', WIZARD_PUBLIC_ORIGIN: '', WIZARD_BIND: '' } });
  try {
    const { url } = await ctl(c, 'issue');
    assert.match(url, /^http:\/\/127\.0\.0\.1:5999\/start\?t=/);
    assert.equal((await req(c, 'GET', '/app.js')).status, 421, 'interner Port ist nicht die veröffentlichte Adresse');
    assert.equal((await req(c, 'GET', '/app.js', { headers: { Host: '127.0.0.1:5999' } })).status, 200);
  } finally { await c.stop(); }
});

test('POST: Origin, CSRF, Content-Type und Sec-Fetch-Site sind Pflicht', async () => {
  await login(w);
  const body = { id: 'x', value: 'y' };
  const H = { Cookie: w.cookie, 'Content-Type': 'application/json', 'X-CSRF-Token': w.csrf };
  const cases = [
    [{ ...H }, 403, 'ohne Origin'],
    [{ ...H, Origin: 'http://evil.example' }, 403, 'fremder Origin'],
    [{ ...H, Origin: 'null' }, 403, 'Origin null'],
    [{ ...H, Origin: w.origin, 'X-CSRF-Token': '' }, 403, 'ohne CSRF'],
    [{ ...H, Origin: w.origin, 'X-CSRF-Token': w.csrf.slice(0, -1) + 'x' }, 403, 'falscher CSRF'],
    [{ ...H, Origin: w.origin, 'Content-Type': 'text/plain' }, 415, 'Formular-Typ'],
    [{ ...H, Origin: w.origin, 'Content-Type': 'application/x-www-form-urlencoded' }, 415, 'Formular-Typ 2'],
    [{ ...H, Origin: w.origin, 'Sec-Fetch-Site': 'cross-site' }, 403, 'cross-site'],
  ];
  for (const [headers, code, why] of cases) {
    const r = await req(w, 'POST', '/api/answer', { body, headers });
    assert.equal(r.status, code, why);
  }
  const big = await req(w, 'POST', '/api/answer', { raw: JSON.stringify({ id: 'x', value: 'y'.repeat(20000) }), headers: { ...H, Origin: w.origin } }).catch(() => ({ status: 400 }));
  assert.equal(big.status, 400, 'zu großer Body');
});

test('Eingaben: Zeilenumbruch und Steuerzeichen abgelehnt, Sonderzeichen wörtlich gespeichert', async () => {
  await login(w);
  assert.equal((await answer(w, 'h:OWNER_LANGUAGE', '', { skip: true })).status, 422, 'Sprache hat eine Vorauswahl, kein Überspringen');
  await answer(w, 'h:OWNER_LANGUAGE', 'de');
  for (const bad of ['Erika\nOWNER_LAST_NAME=x', 'Erika\r', 'Er\u0007ika', 'Er\u0000ika']) {
    const r = await answer(w, 'h:OWNER_FIRST_NAME', bad);
    assert.equal(r.status, 422, JSON.stringify(bad));
    assert.match(r.json.error, /Zeile|ungültig|passt nicht/);
  }
  const special = "O'Neil $(touch /tmp/wizard-pwned) `id` ; | & \\";
  const r = await answer(w, 'h:OWNER_FIRST_NAME', special);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.page.id, 'h:OWNER_LAST_NAME');
  assert.ok(!fs.existsSync('/tmp/wizard-pwned'), 'nichts ausgeführt');
  const prog = JSON.parse(fs.readFileSync(path.join(w.dir, 'state', 'progress.json'), 'utf8'));
  assert.equal(prog.A.OWNER_FIRST_NAME, special);
  // Zurück: der Wert steht unverändert wieder im Feld.
  await post(w, '/api/back', {});
  assert.equal((await state(w)).json.page.value, special);
});

test('Doppelklick: zwei gleichzeitige Antworten laufen nacheinander, die zweite trifft keine offene Seite mehr', async () => {
  await login(w);
  const id = (await state(w)).json.page.id;
  assert.equal(id, 'h:OWNER_FIRST_NAME');
  const [a, b] = await Promise.all([post(w, '/api/answer', { id, value: 'Erika' }), post(w, '/api/answer', { id, value: 'Lisa' })]);
  assert.deepEqual([a.status, b.status].sort(), [200, 422]);
  const prog = JSON.parse(fs.readFileSync(path.join(w.dir, 'state', 'progress.json'), 'utf8'));
  assert.equal(prog.A.OWNER_FIRST_NAME, a.status === 200 ? 'Erika' : 'Lisa');
  assert.equal((await state(w)).json.page.id, 'h:OWNER_LAST_NAME');
});

test('Geheimnisse liegen nie im Klartext auf der Platte; Dateirechte 0600', async () => {
  await login(w);
  let s = (await state(w)).json.page;
  const vals = { 'h:OWNER_FIRST_NAME': 'Erika', 'h:OWNER_LAST_NAME': 'Muster', 'h:OWNER_BIRTH_DATE': '1980-01-01', 'h:OWNER_PERSONA': 'neutral', tg_why: null };
  while (s.id in vals) { await answer(w, s.id, vals[s.id]); s = (await state(w)).json.page; }
  const secret = '123456789:ABC-beispiel-GEHEIM-zz';
  const r = await answer(w, 'h:TELEGRAM_BOT_TOKEN', secret);
  assert.equal(r.status, 200);
  const raw = fs.readFileSync(path.join(w.dir, 'state', 'progress.json'), 'utf8');
  assert.ok(!raw.includes('GEHEIM'), 'Token nicht im Klartext im Fortschritt');
  assert.equal(fs.statSync(path.join(w.dir, 'state', 'progress.json')).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(w.dir, 'etc', 'wizard.key')).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.join(w.dir, 'run', 'ctl.sock')).mode & 0o777, 0o600);
  // Das Geheimnis kommt auch nie zurück an die Oberfläche.
  await post(w, '/api/back', {});
  const back = await state(w);
  assert.equal(back.json.page.id, 'h:TELEGRAM_BOT_TOKEN');
  assert.ok(!back.body.includes('GEHEIM'));
  assert.equal(back.json.page.hasSecret, true);
  // Leeres Feld = behalten.
  const keep = await answer(w, 'h:TELEGRAM_BOT_TOKEN', '');
  assert.equal(keep.status, 200);
  assert.equal(keep.json.page.id, 'h:ANTHROPIC_API_KEY');
});

test('Fehlerbericht nur aus festen Feldern, ohne Namen und Schlüssel', async () => {
  await login(w);
  const r = await req(w, 'GET', '/api/report', { headers: { Cookie: w.cookie } });
  assert.equal(r.status, 200);
  const t = r.json.text;
  assert.match(t, /^lifeagents-wizard-report v1\n/);
  assert.ok(!/Erika|Muster|O'Neil|GEHEIM|ABC-beispiel/.test(t), t);
  for (const line of t.split('\n').slice(1)) assert.match(line, /^(wizard|phase|step|packages|reach|install_status|install_stage|install_reason|install_exit|tunnel|pairing|time): [A-Za-z0-9_.:,?-]*$/);
});

test('„Fertig“ über den Steuerkanal: Fortschritt und Schlüssel weg, Prozess endet', async () => {
  const r = await ctl(w, 'finish');
  assert.equal(r.ok, true);
  const code = await w.exited;
  assert.equal(code, 0);
  assert.ok(!fs.existsSync(path.join(w.dir, 'state', 'progress.json')));
  assert.ok(!fs.existsSync(path.join(w.dir, 'etc', 'wizard.key')));
  // Neustart des master danach: der Wizard endet sofort, kein neuer Fragebogen, kein neuer Schlüssel.
  const again = require('child_process').spawnSync(process.execPath, [path.join(require('./helpers').WIZ, 'server.js')], { env: w.env, timeout: 20000 });
  assert.equal(again.status, 0);
  assert.match(again.stdout.toString(), /"wizard_done"/);
  assert.ok(!fs.existsSync(path.join(w.dir, 'etc', 'wizard.key')));
  assert.ok(!fs.existsSync(path.join(w.dir, 'run', 'ctl.sock')));
  w = null;
});
