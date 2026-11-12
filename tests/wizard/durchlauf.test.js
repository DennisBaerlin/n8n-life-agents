// Durchlauf des Wizards gegen die Attrappen (fixtures/): alle Seiten über echtes HTTP, die Antwort-Datei so gelesen, wie der
// Leser in Paket 1 sie liest (fake_provision.sh), Fortschritt, Fehlschlag + neuer Versuch, Neustart mitten in den Fragen,
// Telegram-Bot schon belegt, Tunnel-Anmeldung, Pairing per QR-Code, Übergabe an die App.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { REPO, WIZ, startWizard, req, ctl, login, state, post, answer, waitFor, lanIp } = require('./helpers');
const qr = require(path.join(WIZ, 'qr.js'));

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
// backupPage(w) -> „Wohin sichern?“ mit einem eigenen Ordner beantworten (Pflichtseite vor der Zusammenfassung).
async function backupPage(w) {
  await expectOk(await answer(w, 'backup_dir', 'other'));
  await expectOk(await answer(w, 'backup_dir_custom', '/daten/sicherung'));
}

test('Durchlauf FritzBox mit drei Modulen: Antwort-Datei, Installation, Pairing, Übergabe', async () => {
  const pl = await paperlessMock();
  const ip = lanIp();
  assert.ok(ip, 'Container braucht eine Netz-Adresse für die Paperless-Attrappe');
  const plUrl = `http://${ip}:${pl.address().port}`;
  const w = await startWizard({ hints: { LA_HOST_IP: '192.0.2.10', LA_USER_LANG: 'en-US', LA_USER_FULLNAME: 'Lena Marie Beispiel',
    LA_MYFRITZ_ZONE: 'deine-domain.myfritz.net', LA_HOST_NAME_CANDIDATES: 'mac-mini,meinrechner' }, env: { WIZARD_FAKE_DNS: '' } });
  try {
    await login(w);
    assert.equal((await page(w)).id, 'h:OWNER_LANGUAGE');
    assert.equal((await page(w)).value, 'en', 'Sprache vom Rechner vorgeschlagen (hints.env)');
    await expectOk(await answer(w, 'h:OWNER_LANGUAGE', 'de'));
    assert.equal((await page(w)).value, 'Lena Marie', 'Vorname vom Rechner vorgeschlagen (hints.env)');
    await expectOk(await answer(w, 'h:OWNER_FIRST_NAME', "Lena $(id)"));
    await expectOk(await answer(w, 'h:OWNER_LAST_NAME', "O'Beispiel"));
    // Geburtsdatum mit den Regeln der CLI (_validate_birthdate): kein 30. Februar, nicht in der Zukunft.
    assert.equal((await answer(w, 'h:OWNER_BIRTH_DATE', '1985-02-30')).status, 422);
    assert.equal((await answer(w, 'h:OWNER_BIRTH_DATE', '2999-01-01')).status, 422);
    assert.equal((await answer(w, 'h:OWNER_BIRTH_DATE', '01.02.1985')).status, 422);
    await expectOk(await answer(w, 'h:OWNER_BIRTH_DATE', '1984-07-15'));
    // Handy-Bild der Charakter-Seite: echte Sprechweise aus dem Katalog, je Sprache; Standard ohne Rahmensatz. Sticker je
    // Charakter = byte-gleich die Datei, die der Bot in Telegram schickt (keine Kopie im Wizard, die veralten könnte).
    const pe = await page(w);
    const butler = pe.options.find((o) => o.value === 'butler');
    assert.ok(butler.frame.de.startsWith('🎩') && butler.frame.en && butler.frame.ko, 'Sprechweise in allen Sprachen');
    assert.deepEqual(pe.options.find((o) => o.value === 'neutral').frame, {});
    assert.equal(pe.t.art.next, 'Nächster Schritt ›', 'Bildtexte (ui/art) aus dem Katalog core.wizard.art.*');
    for (const o of pe.options) {
      assert.equal(o.sticker, `/sticker/${o.value}.webp`, o.value + ': Sticker angeboten');
      const r = await req(w, 'GET', o.sticker);
      assert.equal(r.status, 200, o.sticker);
      assert.equal(r.headers['content-type'], 'image/webp');
      assert.ok(r.buf.equals(fs.readFileSync(path.join(REPO, 'packages', 'core', 'build', 'stickers', `${o.value}_hallo.webp`))), o.value + ': Sticker byte-gleich mit dem des Bots');
    }
    for (const p of ['/sticker/pirat.webp', '/sticker/..%2Fstickers.webp', '/sticker/Butler.webp']) assert.equal((await req(w, 'GET', p)).status, 404, p);
    assert.equal((await answer(w, 'h:OWNER_PERSONA', 'pirat')).status, 422, 'nur angebotene Charaktere');
    await expectOk(await answer(w, 'h:OWNER_PERSONA', 'butler'));
    // Telegram einrichten: erst der Nutzen, dann je nach Bestand Handy (QR-Code lokal erzeugt, Konto nur dort anlegbar), Rechner
    // (Download je System, Telegram Web als Ausweg), dann der Bot. Links nur zu offiziellen Telegram-Adressen, Texte aus dem Katalog.
    const why = await page(w);
    assert.equal(why.id, 'tg_why', '„Warum Telegram?“ vor dem Token');
    assert.equal(why.explain.src, '/explain/telegram.de.svg', 'Erklär-Bild in der Sprache der Seiten');
    assert.ok(why.explain.alt.length > 20, 'Alt-Text aus dem Katalog');
    assert.ok(why.explain.top && !why.getApp, 'das Bild steht über der Frage, das Holen der App auf eigenen Seiten');
    assert.match(why.intro, /Messenger.*WhatsApp/, 'ganz oben: chatten wie im Messenger');
    assert.equal(why.kind, 'choice', 'dieselbe Seite fragt, was schon da ist');
    assert.deepEqual(why.options.map((o) => o.value), ['none', 'phone', 'both']);
    assert.ok(why.options.every((o) => o.label && o.desc), 'Antworten aus dem Katalog');
    assert.equal((await answer(w, 'tg_why', 'bogus')).status, 422, 'nur angebotene Antworten');
    assert.equal((await answer(w, 'tg_why', null)).status, 422, 'eine Antwort ist Pflicht');
    await expectOk(await answer(w, 'tg_why', 'none'));
    const ph = await page(w);
    assert.equal(ph.id, 'tg_phone', 'ohne Telegram: erst das Handy');
    assert.equal(ph.phoneQr.svg, qr.toSvg(qr.encode('https://telegram.org/dl')), 'QR-Code = Telegram-Link, der je Handy in den passenden Store führt');
    assert.ok(ph.phoneQr.text && ph.help.length === 2 && ph.next);
    await expectOk(await answer(w, 'tg_phone', null));
    const pc = await page(w);
    assert.equal(pc.id, 'tg_pc', 'danach der Rechner');
    assert.deepEqual(pc.open.links.map((l) => [l.os, new URL(l.href).origin]), [['mac', 'https://macos.telegram.org'], ['windows', 'https://desktop.telegram.org']]);
    assert.equal(pc.open.web.href, 'https://web.telegram.org/k/', 'Ausweg ohne Installation: Telegram Web');
    assert.ok(pc.help[1].ol.length === 3 && pc.next);
    await expectOk(await answer(w, 'tg_pc', null));
    const tok = await page(w);
    assert.equal(tok.id, 'h:TELEGRAM_BOT_TOKEN');
    assert.equal(tok.open.href, 'https://t.me/BotFather', 'Knopf „BotFather öffnen“: t.me öffnet die App, ohne App bietet t.me selbst Telegram Web an');
    assert.equal(tok.open.web.href, 'https://web.telegram.org/k/#@BotFather', 'Ausweg: BotFather direkt im Browser');
    assert.ok(tok.open.label && tok.open.web.label);
    assert.ok(!JSON.stringify(tok.help).includes('Suche'), 'die Anleitung schickt nicht mehr in die Telegram-Suche');
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
    assert.equal(reach.explain.side, true, 'hochkant neben den Antworten');
    assert.deepEqual(Object.keys(reach.explain.variants), ['tunnel', 'fritzbox']);
    assert.equal(reach.explain.variants.fritzbox.src, '/explain/reach-fritzbox.de.svg');
    await expectOk(await answer(w, 'reach', 'fritzbox'));
    assert.equal((await page(w)).art, 'dslite', 'Erkennung unsicher: Handfrage mit Bild des Wegs');
    await expectOk(await answer(w, 'fb_dslite', 'no'));
    const guide = await page(w);
    assert.equal(guide.id, 'fb_guide');
    assert.equal(guide.link.href, 'https://beispiel.example/anleitung/');
    await expectOk(await answer(w, 'fb_guide', null));
    // Kennung der FritzBox von der App, kein Gerätename löst auf: .<zone> steht fest, nur der Name vorne fehlt.
    const dom = await waitFor(async () => { const x = await page(w); return x.poll ? null : x; });
    assert.equal(dom.suffix, '.deine-domain.myfritz.net');
    assert.match(dom.help[0].p, /Namen vorne/, 'ein Satz statt des langen Hilfetexts, Platz fürs Bild');
    assert.ok(!dom.note);
    const box = await answer(w, 'h:DOMAIN', 'deine-domain.myfritz.net');
    assert.equal(box.status, 422);
    assert.match(box.json.error, /FritzBox selbst/);
    await expectOk(await answer(w, 'h:DOMAIN', 'meinrechner'));
    // Wohin sichern? Ohne Vorschläge der App nur „Anderer Ordner“; die Prüfung läuft über die Brücke, mit Fragebogen-Sprache.
    const bk = await page(w);
    assert.equal(bk.id, 'backup_dir');
    assert.deepEqual(bk.options.map((o) => o.value), ['other']);
    await expectOk(await answer(w, 'backup_dir', 'other'));
    fs.writeFileSync(path.join(w.fake, 'backup_problem'), 'missing');
    assert.match((await answer(w, 'backup_dir_custom', '/daten/fehlt')).json.error, /gibt es auf dem Rechner nicht/);
    fs.rmSync(path.join(w.fake, 'backup_problem'));
    await expectOk(await answer(w, 'backup_dir_custom', '  /daten/sicherung  '));
    assert.match(fs.readFileSync(path.join(w.fake, 'backup_dir_calls'), 'utf8'), /^\/daten\/sicherung\|de$/m);

    // Übersicht: Ändern springt zur Seite und zurück zur Übersicht.
    let rv = await page(w);
    assert.equal(rv.id, 'review');
    const rows = Object.fromEntries(rv.rows.map((r) => [r.label, r.value]));
    assert.equal(rows['Telegram-Bot'], 'eingetragen');
    assert.equal(rows['Nachname'], "O'Beispiel");
    assert.equal(rows['Geburtsdatum'], '15.07.1984', 'Datum wie eingegeben, nicht ISO');
    assert.equal(rows['MyFRITZ!-Adresse'], 'meinrechner.deine-domain.myfritz.net');
    assert.equal(rows['Sprachnachrichten'], 'ja, Google-Schlüssel eingetragen');
    assert.ok(!('Google-Schlüssel' in rows), 'eine Zeile je Fakt');
    assert.equal(rows['Funktionen'], 'Grundsystem, Karriere, Nachlass & Vorsorge, Dokumente');
    assert.equal(rows['Erreichbarkeit'], 'FritzBox');
    assert.equal(rows['Sicherungen'], '/daten/sicherung/Life Agents Sicherungen');
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
      DOMAIN: 'meinrechner.deine-domain.myfritz.net', REACH_MODE: 'fritzbox', BACKUP_PARENT_DIR: '/daten/sicherung',
      __packages: 'career,estate,paperless',
    });

    // Verbinden: QR-Code, dann Telegram-/start (Attrappe), dann Übergabe.
    const cn = await waitFor(async () => { const p = await page(w); return p.qr ? p : null; });
    assert.match(cn.qr, /^<svg /);
    assert.equal(cn.link.href, 'https://t.me/beispiel_bot?start=0123456789abcdef');
    assert.ok(!fs.readFileSync(path.join(w.dir, 'state', 'progress.json'), 'utf8').includes('0123456789abcdef'), 'Pairing-Code nie auf der Platte');
    assert.equal(cn.canBack, false);
    assert.deepEqual(await ctl(w, 'status'), { phase: 'pairing', step: 'connect', lang: 'de', bot: 'beispiel_bot' }, 'lang: Sprache der Einrichtung für die Seiten der App');
    fs.writeFileSync(path.join(w.fake, 'paired'), '');
    const ho = await waitFor(async () => { const p = await page(w); return p.id === 'handoff' ? p : null; });
    assert.match(ho.help[0].p, /Haushalt einrichten/);
    assert.deepEqual(fs.readFileSync(path.join(w.fake, 'pair_calls'), 'utf8').trim().split('\n'), ['arm', 'finalize']);
    await expectOk(await post(w, '/api/action', { name: 'handoff' }));
    assert.deepEqual(await ctl(w, 'status'), { phase: 'handoff', step: 'handoff', lang: 'de', bot: 'beispiel_bot' }, 'Bot-Name für „Telegram öffnen“ der App');
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
    // Bot-Sprache Englisch, Seiten der Einrichtung zurück auf Deutsch (die Texte unten sind deutsch geprüft).
    assert.equal((await page(w)).lang, 'en', 'die Antwort stellt die Einrichtung mit um');
    await expectOk(await post(w, '/api/lang', { lang: 'de' }));
    // Prüfliste Nr. 10: der Bot hat schon eine fremde Webhook-Adresse.
    fs.writeFileSync(path.join(w.fake, 'tg_conflict'), 'beispiel.example');
    await expectOk(await answer(w, 'tg_why', 'both'));
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
    await backupPage(w);
    assert.equal((await page(w)).id, 'review');
    assert.equal((await page(w)).rows.find((r) => r.label === 'Erreichbarkeit').value, 'Tunnel (Anmeldung bei Tailscale nach der Installation)');
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
    assert.equal(lg.art, 'ts_login', 'Bild zum Zustand (ui/art/art.js)');
    assert.deepEqual(lg.ts, { host: 'brave-otter' }, 'nur der gewürfelte Tailscale-Name fürs Bild');
    fs.writeFileSync(path.join(w.fake, 'reach'), 'needs_funnel');
    const fu = await waitFor(async () => { const p = await page(w); return p.title === 'Erlaube deinem Rechner den Empfang' ? p : null; });
    assert.equal(fu.link, null, 'fremde Adresse wird nie als Knopf gezeigt');
    assert.equal(fu.art, 'ts_funnel');
    // Paket-3-Zustände (reach_status_json): Geräte-Freigabe ohne Link -> feste Geräteliste; Funnel-Seite von Tailscale.
    fs.writeFileSync(path.join(w.fake, 'reach'), JSON.stringify({ mode: 'tunnel', state: 'needs_machine_auth', url: '' }));
    const ma = await waitFor(async () => { const p = await page(w); return p.title === 'Gib diesen Rechner in Tailscale frei' ? p : null; });
    assert.equal(ma.link.href, 'https://login.tailscale.com/admin/machines');
    assert.equal(ma.art, 'ts_machine');
    assert.equal(ma.ts, null, 'ohne geprüften Namen kein Wert im Bild');
    fs.writeFileSync(path.join(w.fake, 'reach'), JSON.stringify({ mode: 'tunnel', state: 'needs_funnel', url: 'https://login.tailscale.com/f/funnel?node=nBeispiel%3A1', ts_hostname: 'Kims-MacBook.local' }));
    const fn = await waitFor(async () => { const p = await page(w); return p.link && p.link.href.includes('/f/funnel') ? p : null; });
    assert.equal(fn.link.label, 'Freigabe-Seite öffnen');
    assert.equal(fn.ts, null, 'ein Wert, der kein gewürfelter Name sein kann, kommt nie ins Bild');
    // Tunnel steht, Telegram zeigt noch nicht darauf: der Wizard fährt einmal reach_ctl.sh activate, danach Pairing.
    fs.writeFileSync(path.join(w.fake, 'reach'), JSON.stringify({ mode: 'tunnel', state: 'pending_activation', url: '' }));
    await waitFor(async () => !!(await page(w)).qr);
    assert.deepEqual(fs.readFileSync(path.join(w.fake, 'reach_calls'), 'utf8').trim().split('\n'), ['activate'], 'genau einmal aktiviert');
    // Selbsttest beim Warten: Telegram meldet einen Zustellfehler -> Erklärung mit nächstem Schritt (Tunnel: Funnel).
    fs.writeFileSync(path.join(w.fake, 'reach'), JSON.stringify({ mode: 'tunnel', state: 'ready', webhook: 'ours', webhook_error: 'Connection timed out', key_days_left: 12 }));
    const err = await waitFor(async () => { const x = await page(w); return x.qr && x.note ? x : null; }, 30000);
    assert.match(err.note.text, /Funnel/);
    fs.writeFileSync(path.join(w.fake, 'paired'), '');
    const ho = await waitFor(async () => { const p = await page(w); return p.id === 'handoff' ? p : null; });
    assert.match(ho.note.text, /in 12 Tagen ab/, 'Hinweis zum Ablauf der Tailscale-Anmeldung');
  } finally { await w.stop(); }
});

// MyFRITZ (Owner, 2. und 3. Runde): nur eine GEPRÜFTE Adresse wird eingetragen oder vorgeschlagen; sonst feste Endung, Bild
// zum Nachsehen in der FritzBox und Live-Prüfung beim Tippen. Attrappen: WIZARD_FAKE_DNS „name=ipv4,…“, public_ip = öffentliche IPv4 (Paket 3).
const Z = 'deine-domain.myfritz.net';
const PUB = '203.0.113.7';
async function toDomain(hints, dnsSpec, ip) {
  const w = await startWizard({ hints, env: { WIZARD_FAKE_DNS: dnsSpec } });
  if (ip !== undefined) fs.writeFileSync(path.join(w.fake, 'public_ip'), ip);
  await login(w);
  for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'],
    ['h:OWNER_BIRTH_DATE', '1980-01-01'], ['h:OWNER_PERSONA', 'neutral'], ['tg_why', 'both'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'],
    ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', []], ['reach', 'fritzbox'], ['fb_dslite', 'no'],
    ['fb_guide', null]]) await expectOk(await answer(w, id, v));
  const dom = await waitFor(async () => { const x = await page(w); return x.id === 'h:DOMAIN' && !x.poll ? x : null; });
  return { w, dom };
}
const live = async (w, value) => (await post(w, '/api/check', { id: 'h:DOMAIN', value })).json.live;

// DS-Lite (Paket 3 reach_dslite, Attrappe: Datei dslite = yes|no|unknown): sicher erkannt ersetzt die Handfrage.
test('DS-Lite automatisch: „keine eigene IPv4“ = Bestätigung, „eigene“ = keine Seite, unsicher = Handfrage mit Bild', async () => {
  const w = await startWizard({ hints: {} });
  try {
    await login(w);
    for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'],
      ['h:OWNER_BIRTH_DATE', '1980-01-01'], ['h:OWNER_PERSONA', 'neutral'], ['tg_why', 'both'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'],
      ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', []]]) await expectOk(await answer(w, id, v));
    fs.writeFileSync(path.join(w.fake, 'dslite'), 'yes');
    await expectOk(await answer(w, 'reach', 'fritzbox'));
    const yes = await page(w);
    assert.equal(yes.id, 'fb_dslite');
    assert.equal(yes.kind, 'info', 'keine Frage, nur die Bestätigung');
    assert.match(yes.title, /^Geprüft/);
    assert.ok(!yes.art, 'Bild nur bei der Handfrage');
    await expectOk(await answer(w, 'fb_dslite', null));
    await backupPage(w);
    const rv = await page(w);
    assert.equal(rv.id, 'review');
    assert.match(rv.rows.find((r) => r.label === 'Erreichbarkeit').value, /^Tunnel/);

    fs.writeFileSync(path.join(w.fake, 'dslite'), 'no');
    await expectOk(await post(w, '/api/goto', { id: 'reach' }));
    assert.match((await expectOk(await answer(w, 'reach', 'fritzbox'))).check, /eigene IPv4-Adresse/);
    assert.equal((await page(w)).id, 'fb_guide', 'eigene IPv4 erkannt: keine DS-Lite-Seite');
    await post(w, '/api/back', {});
    assert.equal((await page(w)).id, 'reach', 'auch nicht beim Zurückgehen');

    // Jetzt unsicher: die früher erkannte Antwort gilt nicht mehr, es wird von Hand gefragt (kompakt, mit Bild).
    fs.writeFileSync(path.join(w.fake, 'dslite'), 'unknown');
    const r = await expectOk(await answer(w, 'reach', 'fritzbox'));
    assert.ok(!r.check);
    const q = await page(w);
    assert.equal(q.id, 'fb_dslite');
    assert.equal(q.kind, 'choice');
    assert.equal(q.art, 'dslite');
    assert.equal(q.row, true, 'zwei Antworten nebeneinander');
    assert.deepEqual(q.options.map((o) => [o.value, !!o.desc]), [['no', false], ['yes', true]]);
    assert.equal(q.value, '', 'keine Vorauswahl aus der früheren Erkennung');
  } finally { await w.stop(); }
});

test('MyFRITZ: Name der FritzBox zeigt auf diesen Anschluss -> geprüft eingetragen', async () => {
  // hints.env roh mit CRLF (Windows-Schreiber): ein CR am Zeilenende wird geduldet.
  const { w, dom } = await toDomain(`LA_MYFRITZ_ZONE=${Z}\r\nLA_HOST_NAME_FRITZ=Kims-PC\r\nLA_HOST_NAME_CANDIDATES=mac-mini\r\n`,
    `kims-pc.${Z}=${PUB}`, PUB);
  try {
    assert.equal(dom.value, `kims-pc.${Z}`);
    assert.ok(!dom.suffix && !dom.live);
    assert.match(dom.note.text, /Geprüft/);
    await expectOk(await answer(w, 'h:DOMAIN', dom.value));
    assert.equal((await page(w)).id, 'backup_dir', 'danach: Wohin sichern?');
  } finally { await w.stop(); }
});

test('MyFRITZ: falsche IP, umbenannt oder Freigabe fehlt -> nichts eingetragen, kein Vorschlag, Bild, Live-Prüfung', async () => {
  // falsche IP: der FritzBox-Name löst auf, zeigt aber woandershin; „meinrechner“ = in der FritzBox umbenannt, noch nicht da.
  const { w, dom } = await toDomain({ LA_MYFRITZ_ZONE: Z, LA_HOST_NAME_FRITZ: 'kims-pc', LA_HOST_NAME_CANDIDATES: 'mac-mini' },
    `kims-pc.${Z}=198.51.100.9`, PUB);
  try {
    assert.equal(dom.value, '', 'nichts eingetragen');
    assert.equal(dom.suffix, `.${Z}`);
    assert.ok(!dom.suggestions, 'ein ungeprüfter Name wird nie vorgeschlagen');
    assert.equal(dom.art, 'myfritz_name', 'stattdessen das Bild zum Nachsehen in der FritzBox');
    assert.equal(dom.fbHost, 'kims-pc', 'Name aus der Geräteliste der FritzBox, nur fürs Bild');
    assert.ok(dom.live && dom.live.recheck);
    const wrong = await live(w, 'kims-pc');
    assert.equal(wrong.state, 'wrong_ip');
    assert.match(wrong.text, /gehört nicht zu deinem Anschluss/);
    assert.equal((await live(w, 'meinrechner')).state, 'pending');
    assert.match((await live(w, 'meinrechner')).text, /gerade erst angelegt.*etwa eine Minute.*Sonst stimmt der Name nicht/);
    assert.equal((await live(w, 'nicht gültig!')), null, 'nur gültige Gerätenamen');
    assert.equal((await page(w)).id, 'h:DOMAIN', 'Prüfen ändert nichts am Stand');
  } finally { await w.stop(); }
});

test('MyFRITZ: öffentliche IPv4 unbekannt -> kein Vorschlag; Live-Prüfung meldet nur „gefunden“', async () => {
  const { w, dom } = await toDomain({ LA_MYFRITZ_ZONE: Z, LA_HOST_NAME_FRITZ: 'kims-pc' }, `kims-pc.${Z}=${PUB}`, '');
  try {
    assert.equal(dom.value, '');
    assert.equal((await live(w, 'kims-pc')).state, 'found');
  } finally { await w.stop(); }
});

test('MyFRITZ: ohne Kennung der FritzBox wie bisher die ganze Adresse eintippen', async () => {
  const { w, dom } = await toDomain({ LA_HOST_NAME_FRITZ: 'kims-pc' }, `kims-pc.${Z}=${PUB}`, PUB);
  try {
    assert.ok(!dom.suffix && !dom.live && !dom.suggestions);
    assert.equal(await live(w, 'kims-pc'), null);
  } finally { await w.stop(); }
});

test('Sprache: Antippen stellt die Einrichtung sofort um, die Auswahl bleibt in Eigenschreibweise', async () => {
  const w = await startWizard({ hints: { LA_USER_LANG: 'de-DE', LA_USER_FULLNAME: 'Erika Beispiel' } });
  try {
    await login(w);
    let p = await page(w);
    assert.equal(p.id, 'h:OWNER_LANGUAGE');
    assert.equal(p.title, 'Sprache');
    assert.equal(p.lang, 'de');
    assert.ok(p.langSwitch);
    assert.match(p.note.text, /Benutzerkonto/, 'Vorschlag vom Rechner sichtbar gekennzeichnet');
    const names = p.options.map((o) => o.label);
    let r = await post(w, '/api/lang', { lang: 'en' });
    assert.equal(r.status, 200);
    p = r.json.page;
    assert.equal(p.title, 'Language');
    assert.equal(p.lang, 'en');
    assert.equal(p.value, 'en', 'Auswahl bleibt markiert');
    assert.equal(p.t.next, 'Next');
    assert.deepEqual(p.options.map((o) => o.label), names, 'Sprachen in Eigenschreibweise');
    r = await post(w, '/api/lang', { lang: 'ko' });
    assert.equal(r.json.page.title, '언어');
    assert.equal((await post(w, '/api/lang', { lang: 'xx' })).status, 422, 'nur angebotene Sprachen');
    await expectOk(await answer(w, 'h:OWNER_LANGUAGE', 'en'));
    p = await page(w);
    assert.equal(p.title, 'Your first name');
    assert.equal(p.value, 'Erika');
    assert.match(p.note.text, /user account/);
    // Bildtexte (t.art) ausgenommen: sie nennen die FritzBox-Beschriftung „HTTP-Server“ wörtlich
    assert.ok(!JSON.stringify(Object.assign({}, p, { t: Object.assign({}, p.t, { art: null }) })).includes('Server'), 'App-Weg: Rechner/computer, nie Server');
    assert.equal((await answer(w, 'h:OWNER_FIRST_NAME', '')).json.error, 'Something is still missing here.');
  } finally { await w.stop(); }
});

// Live-Fund: Direkt nach dem Einrichten antwortet die Adresse oft noch nicht (Zertifikat, DNS). Nur dann wartet die Seite
// sichtbar; was Zeit nicht heilt, meldet sie sofort.
async function toConnect(env, signal) {
  const w = await startWizard({ hints: {}, env });
  await login(w);
  fs.writeFileSync(path.join(w.fake, signal), '');
  for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'],
    ['h:OWNER_BIRTH_DATE', '1980-01-01'], ['h:OWNER_PERSONA', 'neutral'], ['tg_why', 'both'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'],
    ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', []], ['reach', 'tunnel'], ['backup_dir', 'other'],
    ['backup_dir_custom', '/daten/sicherung'], ['review', null], ['confirm', null]]) await expectOk(await answer(w, id, v));
  await waitFor(async () => (await page(w)).id === 'connect');
  return w;
}

test('Verbinden: Adresse noch nicht da = sichtbar warten mit Restzeit, dann geht es von allein weiter', async () => {
  const w = await toConnect({}, 'reach_wait');
  try {
    const p = await waitFor(async () => { const x = await page(w); return /Minuten/.test(JSON.stringify(x.help || '')) ? x : null; });
    assert.match(p.wait, /höchstens 5 Min/, 'Standard-Frist 5 Minuten');
    assert.equal(p.action || null, null, 'kein „Noch einmal prüfen“ während des Wartens');
    assert.equal(p.note || null, null, 'keine Warnung während des Wartens');
    fs.rmSync(path.join(w.fake, 'reach_wait'));
    await waitFor(async () => (await page(w)).qr);
  } finally { await w.stop(); }
});

test('Verbinden: nach Ablauf der Frist erscheint das Problem mit „Noch einmal prüfen“', async () => {
  const w = await toConnect({ WIZARD_REACH_GRACE_MS: '0' }, 'reach_wait');
  try {
    const p = await waitFor(async () => { const x = await page(w); return x.action === 'connect_retry' ? x : null; });
    assert.equal(p.note.kind, 'warn');
  } finally { await w.stop(); }
});

test('Verbinden: ein Fehler, den Warten nicht heilt, erscheint sofort', async () => {
  const w = await toConnect({ WIZARD_REACH_GRACE_MS: '600000' }, 'unreachable');
  try {
    const p = await waitFor(async () => { const x = await page(w); return x.action === 'connect_retry' ? x : null; });
    assert.equal(p.note.kind, 'warn');
  } finally { await w.stop(); }
});

// Abschluss nach dem Pairing: Erst eine bestätigte Antwort der CLI (Workflows tragen die echte chat_id) schließt die Seite ab.
const FIN = { WIZARD_FINALIZE_RETRY_MS: '20' };
const finCalls = (w) => { try { return fs.readFileSync(path.join(w.fake, 'pair_calls'), 'utf8').split('\n').filter((l) => l === 'finalize').length; } catch (_) { return 0; } };
const failedPage = (w) => waitFor(async () => { const x = await page(w); return x.action === 'finalize_retry' ? x : null; });
const pairNow = (w) => fs.writeFileSync(path.join(w.fake, 'paired'), '');
const plan = (w, text) => fs.writeFileSync(path.join(w.fake, 'finalize_plan'), text);

for (const [name, line] of [['ok:false', '{"ok":false,"reason":"finalize_failed"}'], ['keine Antwort', 'empty'],
  ['Platzhalter übrig', '{"ok":false,"reason":"placeholders_left","placeholders":35}']]) {
  test(`Abschluss: ${name} schließt nicht ab, wiederholt von selbst, dann Knopf „Erneut versuchen“`, async () => {
    const w = await toConnect(FIN, 'paired_later');
    try {
      plan(w, `${line}\n${line}\n${line}\n`);
      pairNow(w);
      const p = await failedPage(w);
      assert.equal(finCalls(w), 3, 'drei Versuche von selbst');
      assert.equal(p.id, 'connect', 'bleibt auf „Verbinden“');
      assert.equal(p.note.kind, 'warn');
      assert.match(p.next, /Erneut versuchen/);
      assert.equal(p.poll, false);
      assert.equal(p.qr || null, null, 'kein alter Code mehr');
      assert.equal(p.report, true, 'Bericht anbietbar');
      assert.equal((await ctl(w, 'status')).phase, 'pairing', 'nicht connected');
      assert.equal((await post(w, '/api/action', { name: 'handoff' })).status, 422, 'Weiter ist gesperrt');
      await expectOk(await post(w, '/api/action', { name: p.action }));   // Plan leer = der nächste Versuch gelingt
      await waitFor(async () => (await page(w)).id === 'handoff');
      assert.equal(finCalls(w), 4);
      assert.equal((await ctl(w, 'status')).phase, 'connected');
    } finally { await w.stop(); }
  });
}

test('Abschluss: ein Fehlversuch heilt von selbst, ohne Meldung', async () => {
  const w = await toConnect(FIN, 'paired_later');
  try {
    plan(w, '{"ok":false,"reason":"finalize_failed"}\n');
    pairNow(w);
    await waitFor(async () => (await page(w)).id === 'handoff');
    assert.equal(finCalls(w), 2);
  } finally { await w.stop(); }
});

test('Abschluss: „läuft schon“ zählt nicht als Fehlversuch', async () => {
  const w = await toConnect(FIN, 'paired_later');
  try {
    plan(w, '{"ok":false,"reason":"busy"}\n'.repeat(5));
    pairNow(w);
    await waitFor(async () => (await page(w)).id === 'handoff');
    assert.equal(finCalls(w), 6);
  } finally { await w.stop(); }
});

test('Abschluss: viele Seitenabrufe und Knopfdrücke starten keinen zweiten Lauf', async () => {
  const w = await toConnect(FIN, 'paired_later');
  try {
    fs.writeFileSync(path.join(w.fake, 'finalize_sleep'), '1');
    pairNow(w);
    await waitFor(async () => finCalls(w) === 1);
    for (let i = 0; i < 15; i++) {
      await state(w);
      await post(w, '/api/action', { name: 'finalize_retry' });
      await new Promise((r) => setTimeout(r, 30));
    }
    assert.equal(finCalls(w), 1, 'während des Laufs kein zweiter');
    fs.rmSync(path.join(w.fake, 'finalize_sleep'));
    await waitFor(async () => (await page(w)).id === 'handoff');
    assert.equal(finCalls(w), 1);
  } finally { await w.stop(); }
});

test('Abschluss: Knopf antwortet sofort, auch wenn der neue Versuch dauert', async () => {
  const w = await toConnect(FIN, 'paired_later');
  try {
    plan(w, '{"ok":false,"reason":"finalize_failed"}\n'.repeat(3));
    pairNow(w);
    await failedPage(w);
    fs.writeFileSync(path.join(w.fake, 'finalize_sleep'), '2');
    const t0 = Date.now();
    const r = await post(w, '/api/action', { name: 'finalize_retry' });
    assert.ok(Date.now() - t0 < 1000, 'Antwort wartet nicht auf den Lauf');
    assert.equal(r.json.page.action || null, null, 'kein Knopf während des Laufs');
    assert.ok(r.json.page.wait, 'Warte-Hinweis');
  } finally { await w.stop(); }
});

test('Abschluss: ein hängender Lauf endet samt Kindprozessen und zählt als Fehlversuch', async () => {
  const w = await toConnect(Object.assign({ WIZARD_FINALIZE_TIMEOUT_MS: '400' }, FIN), 'paired_later');
  try {
    fs.writeFileSync(path.join(w.fake, 'finalize_hang'), '');
    pairNow(w);
    const pid = await waitFor(() => { try { return parseInt(fs.readFileSync(path.join(w.fake, 'grandchild'), 'utf8'), 10) || null; } catch (_) { return null; } });
    // Im Test-Container räumt kein init Waisen ab: beendet heißt weg oder Zombie.
    await waitFor(() => { try { return /^\d+ \(.*\) Z/.test(fs.readFileSync(`/proc/${pid}/stat`, 'utf8')); } catch (_) { return true; } }, 5000);
    await failedPage(w);
    assert.equal(finCalls(w), 3);
  } finally { await w.stop(); }
});

test('Abschluss: Fehlerbericht zeigt Grund und Protokoll, aber keine Geheimnisse', async () => {
  const w = await toConnect(FIN, 'paired_later');
  try {
    plan(w, '{"ok":false,"reason":"placeholders_left","placeholders":35}\n'.repeat(3));
    pairNow(w);
    await failedPage(w);
    fs.appendFileSync(path.join(w.dir, 'state', 'finalize.log'),
      'curl https://api.telegram.org/bot123456789:AAbcdefghijklmnopqrstuvwxyz012345678/getMe start=0123456789abcdef chat 987654321\n');
    const t = (await req(w, 'GET', '/api/report', { headers: { Cookie: w.cookie } })).json.text;
    assert.match(t, /finalize_reason: placeholders_left/);
    assert.match(t, /finalize_attempts: 3/);
    assert.match(t, /Beispiel-Zeile aus dem Einspielen/);
    assert.doesNotMatch(t, /AAbcdefghij|0123456789abcdef|987654321/);
  } finally { await w.stop(); }
});

test('Sicherungsordner ändern (--backup-dir): nur die Ordner-Seiten, Ergebnis, Fertig beendet, nichts im Volume', async () => {
  const w = await startWizard({ args: ['--backup-dir'], hints: { LA_BACKUP_CANDIDATES: 'icloud|/Users/erika/iCloud;documents|/Users/erika/Documents', LA_USER_LANG: 'de' } });
  try {
    await login(w);
    let p = await page(w);
    assert.equal(p.id, 'backup_dir');
    assert.match(p.title, /Sicherungsordner ändern/);
    assert.deepEqual(p.options.map((o) => o.value), ['icloud', 'documents', 'other']);
    assert.equal(p.value, 'icloud', 'Cloud vorausgewählt');
    assert.ok(p.options[0].tag && !p.options[1].tag, 'nur die Cloud empfohlen');
    assert.equal((await ctl(w, 'status')).phase, 'backup_dir');
    fs.writeFileSync(path.join(w.fake, 'backup_fail'), '');
    await expectOk(await answer(w, 'backup_dir', 'icloud'));
    p = await page(w);
    assert.equal(p.id, 'backup_result');
    assert.match(p.title, /nicht geklappt/);
    fs.rmSync(path.join(w.fake, 'backup_fail'));
    await expectOk(await answer(w, 'backup_result', null));   // „Noch einmal“
    assert.equal((await page(w)).id, 'backup_dir');
    await expectOk(await answer(w, 'backup_dir', 'icloud'));
    p = await page(w);
    assert.equal(p.id, 'backup_result');
    assert.match(p.help[0].p, /Life Agents Sicherungen/);
    assert.equal((await ctl(w, 'status')).phase, 'backup_done');
    assert.match(fs.readFileSync(path.join(w.fake, 'backup_calls'), 'utf8'), /backup host-dir \/Users\/erika\/iCloud --create\nbackup export\n$/);
    await expectOk(await answer(w, 'backup_result', null));   // „Fertig“
    w.proc.ref();
    assert.equal(await w.exited, 0, 'endet nach Fertig');
    assert.ok(!fs.existsSync(path.join(w.dir, 'state', 'progress.json')), 'kein Fortschritt im Volume');
  } finally { await w.stop(); }
});

test('Sicherungsordner ändern: Zurück vom Ergebnis + neuer Ordner legt neu an; Fertig löscht hints.env; zweiter Start lässt den ersten', async () => {
  const w = await startWizard({ args: ['--backup-dir'], hints: { LA_BACKUP_CANDIDATES: 'icloud|/Users/erika/iCloud;documents|/Users/erika/Documents' } });
  try {
    await login(w);
    await expectOk(await answer(w, 'backup_dir', 'icloud'));
    assert.equal((await page(w)).id, 'backup_result');
    // Menüpunkt ein zweites Mal: die neue Instanz endet, die laufende behält Steuerkanal und Sitzung.
    await assert.rejects(startWizard({ dir: w.dir, args: ['--backup-dir'] }), /wizard exited 0/);
    assert.equal((await ctl(w, 'status')).phase, 'backup_done');
    await post(w, '/api/back', {});
    await expectOk(await answer(w, 'backup_dir', 'documents'));
    const p = await page(w);
    assert.equal(p.id, 'backup_result');
    assert.match(fs.readFileSync(path.join(w.fake, 'backup_calls'), 'utf8'), /backup host-dir \/Users\/erika\/Documents --create\nbackup export\n$/,
      'der neue Ordner wird wirklich angelegt, nicht nur angezeigt');
    await expectOk(await answer(w, 'backup_result', null));
    w.proc.ref();
    assert.equal(await w.exited, 0);
    assert.ok(!fs.existsSync(path.join(w.dir, 'run', 'hints.env')), 'Vorschläge (privat) nach Fertig weg');
  } finally { await w.stop(); }
});

test('Wohin sichern: erst Vorschlag, dann „Anderer Ordner“ zeigt die Textseite (kein alter Pfad als Antwort)', async () => {
  const w = await startWizard({ args: ['--backup-dir'], hints: { LA_BACKUP_CANDIDATES: 'icloud|/Users/erika/iCloud' } });
  try {
    await login(w);
    fs.writeFileSync(path.join(w.fake, 'backup_fail'), '');   // Ergebnis „nicht geklappt“ -> Noch einmal, Wahl bleibt offen
    await expectOk(await answer(w, 'backup_dir', 'icloud'));
    await post(w, '/api/back', {});
    await expectOk(await answer(w, 'backup_dir', 'other'));
    const p = await page(w);
    assert.equal(p.id, 'backup_dir_custom');
    assert.equal(p.value, '', 'kein Vorschlags-Pfad im Feld');
  } finally { await w.stop(); }
});

test('Sicherungsordner ändern: läuft auch nach fertiger Einrichtung, endet nach Leerlauf', async () => {
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'wiz-'));
  fs.mkdirSync(path.join(dir, 'state'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'state', 'done'), '');
  const w = await startWizard({ dir, args: ['--backup-dir'], hints: {}, env: { WIZARD_BACKUP_IDLE_MS: '1500' } });
  try {
    await login(w);
    assert.equal((await page(w)).id, 'backup_dir');
    w.proc.ref();
    assert.equal(await w.exited, 0, 'Leerlauf beendet ihn');
  } finally { await w.stop(); }
});
