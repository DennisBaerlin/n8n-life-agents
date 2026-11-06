// Durchlauf des Wizards gegen die Attrappen (fixtures/): alle Seiten über echtes HTTP, die Antwort-Datei so gelesen, wie der
// Leser in Paket 1 sie liest (fake_provision.sh), Fortschritt, Fehlschlag + neuer Versuch, Neustart mitten in den Fragen,
// Telegram-Bot schon belegt, Tunnel-Anmeldung, Pairing per QR-Code, Übergabe an die App.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { startWizard, ctl, login, state, post, answer, waitFor, lanIp } = require('./helpers');

// Erfundenes Paperless: /api/ antwortet mit X-Version, prüft den Token.
function paperlessMock() {
  return new Promise((resolve) => {
    const s = http.createServer((req, res) => {
      if (!req.url.startsWith('/api/')) { res.writeHead(404); return res.end(); }
      const auth = req.headers.authorization || '';
      if (!auth) { res.writeHead(401); return res.end('{}'); }
      if (auth !== 'Token beispieltoken0123') { res.writeHead(403); return res.end('{}'); }
      res.writeHead(200, { 'X-Version': '3.4.2', 'X-Api-Version': '9' });
      res.end('{}');
    });
    s.listen(0, '0.0.0.0', () => resolve(s));
  });
}

async function page(w) { return (await state(w)).json.page; }
async function expectOk(r) { assert.equal(r.status, 200, JSON.stringify(r.json && (r.json.error || r.json))); return r.json; }

test('Durchlauf FritzBox mit drei Modulen: Antwort-Datei, Installation, Pairing, Übergabe', async () => {
  const pl = await paperlessMock();
  const ip = lanIp();
  assert.ok(ip, 'Container braucht eine Netz-Adresse für die Paperless-Attrappe');
  const plUrl = `http://${ip}:${pl.address().port}`;
  const w = await startWizard({ env: { LA_HOST_IP: '192.0.2.10' } });
  try {
    await login(w);
    assert.equal((await page(w)).id, 'h:OWNER_LANGUAGE');
    assert.equal((await page(w)).value, 'de', 'Vorauswahl Deutsch wie in der CLI');
    await expectOk(await answer(w, 'h:OWNER_LANGUAGE', 'de'));
    await expectOk(await answer(w, 'h:OWNER_FIRST_NAME', "Lena $(id)"));
    await expectOk(await answer(w, 'h:OWNER_LAST_NAME', "O'Beispiel"));
    // Geburtsdatum mit den Regeln der CLI (_validate_birthdate): kein 30. Februar, nicht in der Zukunft.
    assert.equal((await answer(w, 'h:OWNER_BIRTH_DATE', '1985-02-30')).status, 422);
    assert.equal((await answer(w, 'h:OWNER_BIRTH_DATE', '2999-01-01')).status, 422);
    assert.equal((await answer(w, 'h:OWNER_BIRTH_DATE', '01.02.1985')).status, 422);
    await expectOk(await answer(w, 'h:OWNER_BIRTH_DATE', '1984-07-15'));
    assert.equal((await answer(w, 'h:OWNER_PERSONA', 'pirat')).status, 422, 'nur angebotene Charaktere');
    await expectOk(await answer(w, 'h:OWNER_PERSONA', 'butler'));
    assert.equal((await answer(w, 'h:TELEGRAM_BOT_TOKEN', '')).status, 422, 'Pflicht');
    assert.equal((await answer(w, 'h:TELEGRAM_BOT_TOKEN', 'bad-token')).status, 422);
    const tg = await expectOk(await answer(w, 'h:TELEGRAM_BOT_TOKEN', '123456789:ABC-beispiel-token'));
    assert.equal(tg.check, 'Gefunden: dein Bot @beispiel_bot');
    assert.equal(fs.readFileSync(path.join(w.fake, 'tg_token_seen'), 'utf8'), '123456789:ABC-beispiel-token', 'Token nur per Env an die Prüfung');
    const an = await expectOk(await answer(w, 'h:ANTHROPIC_API_KEY', 'sk-ant-offline-beispiel'));
    assert.match(an.note, /nicht online prüfen/, 'Dienst nicht erreichbar = übernommen mit Hinweis (wie _live_rc 2)');
    await expectOk(await answer(w, 'voice', 'yes'));
    await expectOk(await answer(w, 'h:GOOGLE_API_KEY', 'AIza-beispiel'));
    const pk = await page(w);
    assert.deepEqual(pk.options.map((o) => o.value), ['career', 'estate', 'finance', 'paperless'], 'Module aus der CLI-Quelle');
    assert.ok(pk.options.every((o) => o.label && o.desc), 'Name + package.summary');
    // Paperless läuft auf diesem Rechner (ein veröffentlichter Port, einer nur lokal): Adresse vorausgefüllt.
    fs.writeFileSync(path.join(w.fake, 'paperless_ports'), JSON.stringify([{ ip: '0.0.0.0', port: 8010 }, { ip: '127.0.0.1', port: 8011 }]));
    await expectOk(await answer(w, 'packages', ['paperless', 'career', 'estate']));
    // Folgefragen nur der gewählten Module, je Seite eine.
    await expectOk(await answer(w, 'c:career:ADZUNA_APP_ID', 'beispiel-id'));
    await expectOk(await answer(w, 'c:career:ADZUNA_APP_KEY', 'beispiel-key'));
    await expectOk(await answer(w, 'c:career:JSEARCH_API_KEY', '', { skip: true }));
    assert.equal((await answer(w, 's:estate:general.bundesland', 'atlantis')).status, 422);
    await expectOk(await answer(w, 's:estate:general.bundesland', 'thueringen'));
    const pre = await waitFor(async () => { const x = await page(w); return x.poll ? null : x; });
    assert.equal(pre.value, 'http://192.0.2.10:8010', 'vorausgefüllt aus dem Paperless-Container dieses Rechners');
    assert.match(pre.note.text, /Auf diesem Rechner läuft Paperless/);
    const loc = await answer(w, 's:paperless:general.paperless_url', 'http://localhost:8000');
    assert.equal(loc.status, 422);
    assert.match(loc.json.error, /localhost/);
    assert.equal((await answer(w, 's:paperless:general.paperless_url', 'http://127.0.0.1:8000')).status, 422);
    const pu = await expectOk(await answer(w, 's:paperless:general.paperless_url', plUrl + '/'));
    assert.equal(pu.check, 'Paperless antwortet');
    const bad = await answer(w, 'c:paperless:PAPERLESS_API_TOKEN', 'falsch');
    assert.equal(bad.status, 422);
    assert.match(bad.json.error, /lehnt diesen Zugang ab/);
    const ok = await expectOk(await answer(w, 'c:paperless:PAPERLESS_API_TOKEN', 'beispieltoken0123'));
    assert.equal(ok.check, 'Paperless 3.4.2 gefunden, Zugang funktioniert');
    const reach = await page(w);
    assert.equal(reach.options[0].value, 'tunnel');
    assert.equal(reach.options[0].tag, 'empfohlen');
    await expectOk(await answer(w, 'reach', 'fritzbox'));
    await expectOk(await answer(w, 'fb_dslite', 'no'));
    const guide = await page(w);
    assert.equal(guide.id, 'fb_guide');
    assert.equal(guide.link.href, 'https://beispiel.example/anleitung/');
    await expectOk(await answer(w, 'fb_guide', null));
    const box = await answer(w, 'h:DOMAIN', 'deine-domain.myfritz.net');
    assert.equal(box.status, 422);
    assert.match(box.json.error, /FritzBox selbst/);
    await expectOk(await answer(w, 'h:DOMAIN', 'https://MeinRechner.Deine-Domain.myfritz.net/'));

    // Übersicht: Ändern springt zur Seite und zurück zur Übersicht.
    let rv = await page(w);
    assert.equal(rv.id, 'review');
    const rows = Object.fromEntries(rv.rows.map((r) => [r.label, r.value]));
    assert.equal(rows['Telegram-Bot-Token'], 'eingetragen');
    assert.equal(rows['Dein Nachname'], "O'Beispiel");
    assert.equal(rows['Dein Geburtsdatum'], '15.07.1984', 'Datum wie eingegeben, nicht ISO');
    assert.equal(rows['MyFRITZ!-Adresse'], 'meinrechner.deine-domain.myfritz.net');
    assert.equal(rows['Sprachnachrichten'], 'ja, Google-Schlüssel eingetragen');
    assert.ok(!('Google-API-Schlüssel' in rows), 'eine Zeile je Fakt');
    assert.equal(rows['Funktionen'], 'Grundsystem, Karriere, Nachlass & Vorsorge, Dokumente');
    assert.equal(rows['Erreichbarkeit'], 'FritzBox');
    assert.ok(!JSON.stringify(rv).includes('beispiel-token'), 'kein Geheimnis in der Übersicht');
    await expectOk(await post(w, '/api/goto', { id: 'h:OWNER_LAST_NAME' }));
    await expectOk(await answer(w, 'h:OWNER_LAST_NAME', 'Beispiel-Neu'));
    rv = await page(w);
    assert.equal(rv.id, 'review');
    assert.equal((await post(w, '/api/goto', { id: 'install' })).status, 422);
    await expectOk(await answer(w, 'review', null));
    const cf = await page(w);
    assert.equal(cf.id, 'confirm');
    assert.equal(cf.next, 'Einverstanden, Installation starten');
    assert.ok(!fs.existsSync(path.join(w.dir, 'run', 'answers.env')), 'vor der zweiten Bestätigung keine Antwort-Datei');
    await expectOk(await answer(w, 'confirm', null));

    // Installation gegen die Attrappe; Antwort-Datei danach gelöscht.
    await waitFor(async () => (await page(w)).id === 'connect');
    assert.ok(!fs.existsSync(path.join(w.dir, 'run', 'answers.env')), 'Antwort-Datei nach dem Lauf gelöscht');
    const parsed = JSON.parse(fs.readFileSync(path.join(w.fake, 'parsed.json'), 'utf8'));
    assert.deepEqual(parsed, {
      OWNER_LANGUAGE: 'de', OWNER_FIRST_NAME: 'Lena $(id)', OWNER_LAST_NAME: 'Beispiel-Neu', OWNER_BIRTH_DATE: '1984-07-15',
      OWNER_PERSONA: 'butler', TELEGRAM_BOT_TOKEN: '123456789:ABC-beispiel-token', ANTHROPIC_API_KEY: 'sk-ant-offline-beispiel',
      GOOGLE_API_KEY: 'AIza-beispiel', ADZUNA_APP_ID: 'beispiel-id', ADZUNA_APP_KEY: 'beispiel-key', JSEARCH_API_KEY: '',
      CONFIG_GENERAL_BUNDESLAND: 'thueringen', CONFIG_GENERAL_PAPERLESS_URL: plUrl + '/', PAPERLESS_API_TOKEN: 'beispieltoken0123',
      DOMAIN: 'meinrechner.deine-domain.myfritz.net', REACH_MODE: 'fritzbox', __packages: 'career,estate,paperless',
    });

    // Verbinden: QR-Code, dann Telegram-/start (Attrappe), dann Übergabe.
    const cn = await waitFor(async () => { const p = await page(w); return p.qr ? p : null; });
    assert.match(cn.qr, /^<svg /);
    assert.equal(cn.link.href, 'https://t.me/beispiel_bot?start=0123456789abcdef');
    assert.ok(!fs.readFileSync(path.join(w.dir, 'state', 'progress.json'), 'utf8').includes('0123456789abcdef'), 'Pairing-Code nie auf der Platte');
    assert.equal(cn.canBack, false);
    assert.deepEqual(await ctl(w, 'status'), { phase: 'pairing', step: 'connect', bot: 'beispiel_bot' });
    fs.writeFileSync(path.join(w.fake, 'paired'), '');
    const ho = await waitFor(async () => { const p = await page(w); return p.id === 'handoff' ? p : null; });
    assert.match(ho.help[0].p, /Haushalt einrichten/);
    assert.deepEqual(fs.readFileSync(path.join(w.fake, 'pair_calls'), 'utf8').trim().split('\n'), ['arm', 'finalize']);
    await expectOk(await post(w, '/api/action', { name: 'handoff' }));
    assert.deepEqual(await ctl(w, 'status'), { phase: 'handoff', step: 'handoff', bot: 'beispiel_bot' }, 'Bot-Name für „Telegram öffnen“ der App');
    assert.equal((await ctl(w, 'finish')).ok, true);
    assert.equal(await w.exited, 0);
  } finally { pl.close(); await w.stop(); }
});

test('Durchlauf Tunnel: belegter Bot, Fehlschlag + neuer Versuch, Neustart, Tailscale-Anmeldung', async () => {
  const w = await startWizard();
  try {
    await login(w);
    for (const [id, v] of [['h:OWNER_LANGUAGE', 'en'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'],
      ['h:OWNER_BIRTH_DATE', '1970-12-31'], ['h:OWNER_PERSONA', 'neutral']]) await expectOk(await answer(w, id, v));
    // Prüfliste Nr. 10: der Bot hat schon eine fremde Webhook-Adresse.
    fs.writeFileSync(path.join(w.fake, 'tg_conflict'), 'beispiel.example');
    await expectOk(await answer(w, 'h:TELEGRAM_BOT_TOKEN', '111:alt-beispiel'));
    const busy = await page(w);
    assert.equal(busy.id, 'tg_busy');
    assert.equal(busy.note.text, 'Bisherige Adresse: beispiel.example');
    assert.equal(busy.options[0].value, 'new');
    await expectOk(await answer(w, 'tg_busy', 'new'));
    assert.equal((await page(w)).id, 'h:TELEGRAM_BOT_TOKEN', 'neuer Bot = Token neu eingeben');
    fs.rmSync(path.join(w.fake, 'tg_conflict'));
    await expectOk(await answer(w, 'h:TELEGRAM_BOT_TOKEN', '222:neu-beispiel'));
    assert.equal((await page(w)).id, 'h:ANTHROPIC_API_KEY');

    // Neustart mitten in den Fragen: nichts geht verloren, Geheimnisse kommen entschlüsselt zurück.
    await w.stop();
    const w2 = await startWizard({ dir: w.dir, port: w.port });
    Object.assign(w, w2);
    await login(w);
    assert.equal((await page(w)).id, 'h:ANTHROPIC_API_KEY');
    await expectOk(await answer(w, 'h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'));
    await expectOk(await answer(w, 'voice', 'no'));
    assert.equal((await page(w)).id, 'packages');
    await expectOk(await answer(w, 'packages', []));
    // Belegte Ports führen zum Tunnel; nach dem Freigeben misst eine neue Wahl erneut (nie ein alter Befund).
    fs.writeFileSync(path.join(w.fake, 'ports'), 'busy');
    await expectOk(await answer(w, 'reach', 'fritzbox'));
    await expectOk(await answer(w, 'fb_dslite', 'no'));
    assert.equal((await page(w)).id, 'fb_ports_busy');
    await post(w, '/api/back', {}); await post(w, '/api/back', {});
    fs.writeFileSync(path.join(w.fake, 'ports'), 'free');
    await expectOk(await answer(w, 'reach', 'fritzbox'));
    assert.equal((await page(w)).id, 'fb_guide', 'frei gemessen, DS-Lite-Antwort bleibt');
    await post(w, '/api/back', {});
    await expectOk(await answer(w, 'fb_dslite', 'yes'));   // DS-Lite führt zum Tunnel
    assert.equal((await page(w)).id, 'review');
    assert.equal((await page(w)).rows.find((r) => r.label === 'Erreichbarkeit').value, 'Tunnel');
    await expectOk(await answer(w, 'review', null));

    // Fehlschlag in einer Stufe: Antworten bleiben, „Noch einmal versuchen“ führt über die Bestätigung erneut.
    fs.writeFileSync(path.join(w.fake, 'fail_stage'), 'workflows');
    await expectOk(await answer(w, 'confirm', null));
    const failed = await waitFor(async () => { const p = await page(w); return p.failed ? p : null; });
    assert.deepEqual(failed.items.map((i) => i.state), ['ok', 'ok', 'ok', 'ok', 'bad', '']);
    const rep = (await (require('./helpers').req)(w, 'GET', '/api/report', { headers: { Cookie: w.cookie } })).json.text;
    assert.match(rep, /install_status: failed/); assert.match(rep, /install_stage: workflows/); assert.match(rep, /install_reason: fake_failure/);
    assert.ok(!/Erika|Muster|beispiel/.test(rep));
    fs.rmSync(path.join(w.fake, 'fail_stage'));
    await expectOk(await post(w, '/api/action', { name: 'retry' }));
    assert.equal((await page(w)).id, 'confirm');
    fs.writeFileSync(path.join(w.fake, 'reach'), 'needs_login');   // Tunnel wartet auf die Anmeldung
    await expectOk(await answer(w, 'confirm', null));
    await waitFor(async () => (await page(w)).id === 'connect');
    assert.equal(fs.readFileSync(path.join(w.fake, 'runs'), 'utf8').trim(), '2');
    const parsed = JSON.parse(fs.readFileSync(path.join(w.fake, 'parsed.json'), 'utf8'));
    assert.equal(parsed.TELEGRAM_BOT_TOKEN, '222:neu-beispiel');
    assert.equal(parsed.GOOGLE_API_KEY, '');
    assert.equal(parsed.REACH_MODE, 'tunnel');
    assert.equal(parsed.DOMAIN, '');
    assert.equal(parsed.__packages, 'none', 'keine Module = --packages none');
    assert.equal(parsed.OWNER_LANGUAGE, 'en');

    // Tunnel: Anmelde-Link als Knopf (nur login.tailscale.com), fremde Adressen nie.
    const lg = await waitFor(async () => { const p = await page(w); return p.link && p.link.href ? p : null; });
    assert.equal(lg.title, 'Melde dich bei Tailscale an');
    assert.equal(lg.link.href, 'https://login.tailscale.com/a/beispiel123');
    fs.writeFileSync(path.join(w.fake, 'reach'), 'needs_funnel');
    const fu = await waitFor(async () => { const p = await page(w); return p.title === 'Erlaube deinem Rechner den Empfang' ? p : null; });
    assert.equal(fu.link, null, 'fremde Adresse wird nie als Knopf gezeigt');
    fs.writeFileSync(path.join(w.fake, 'reach'), 'ready');
    await waitFor(async () => !!(await page(w)).qr);
  } finally { await w.stop(); }
});
