// preview_dump.js — sammelt die Seiten des Wizards für die Vorschau-Bilder (scripts/dev/build_ui_review.ps1 -Surface wizard):
// fährt den echten Server mit den Attrappen aus fixtures/ durch alle Schritte und schreibt je Seite das View-Modell, wie es
// ui/app.js bekommt, als JSON nach stdout. Nur erfundene Werte. Kein Test (kein *.test.js), läuft im selben Container.
'use strict';
const fs = require('fs');
const http = require('http');
const path = require('path');
const { startWizard, login, state, post, answer, waitFor, lanIp } = require('./helpers');

const out = [];
async function shot(w, name, extra) {
  const p = (await state(w)).json.page;
  out.push(Object.assign({ name, page: p }, extra || {}));
  return p;
}
async function step(w, id, value, opt) {
  await shot(w, id.replace(/[^A-Za-z0-9_.-]/g, '_'));
  const r = await answer(w, id, value, opt);
  if (r.status !== 200) throw new Error(`${id}: ${JSON.stringify(r.json)}`);
}

(async () => {
  const pl = http.createServer((req, res) => {
    if ((req.headers.authorization || '') === 'Token beispieltoken0123') res.writeHead(200, { 'X-Version': '3.4.2' }); else res.writeHead(401);
    res.end('{}');
  });
  await new Promise((r) => pl.listen(0, '0.0.0.0', r));
  const plUrl = `http://${lanIp()}:${pl.address().port}`;
  const w = await startWizard({ hints: { LA_HOST_IP: '192.0.2.10', LA_USER_LANG: 'de-DE', LA_USER_FULLNAME: 'Erika Mustermann',
    LA_MYFRITZ_ZONE: 'deine-domain.myfritz.net', LA_HOST_NAME_CANDIDATES: 'mac-mini' }, env: { WIZARD_FAKE_DNS: '' } });
  try {
    await login(w);
    // Sprach-Seite: Antippen stellt die Einrichtung sofort um (Auswahl bleibt in Eigenschreibweise).
    await shot(w, 'h_OWNER_LANGUAGE');
    for (const l of ['en', 'ko', 'de']) {
      await post(w, '/api/lang', { lang: l });
      if (l !== 'de') await shot(w, `h_OWNER_LANGUAGE-${l}`);
    }
    await answer(w, 'h:OWNER_LANGUAGE', 'de');
    await step(w, 'h:OWNER_FIRST_NAME', 'Erika');
    await step(w, 'h:OWNER_LAST_NAME', 'Muster');
    await shot(w, 'h_OWNER_BIRTH_DATE-fehler', { error: (await answer(w, 'h:OWNER_BIRTH_DATE', '2999-01-01')).json.error, value: '2999-01-01' });
    await step(w, 'h:OWNER_BIRTH_DATE', '1980-01-01');
    await step(w, 'h:OWNER_PERSONA', 'neutral');
    fs.writeFileSync(path.join(w.fake, 'tg_conflict'), 'beispiel.example');
    await step(w, 'h:TELEGRAM_BOT_TOKEN', '123456789:ABC-beispiel');
    await shot(w, 'tg_busy');
    await answer(w, 'tg_busy', 'take');
    await step(w, 'h:ANTHROPIC_API_KEY', 'sk-ant-beispiel');
    await step(w, 'voice', 'yes');
    await step(w, 'h:GOOGLE_API_KEY', 'AIza-beispiel');
    fs.writeFileSync(path.join(w.fake, 'paperless_ports'), JSON.stringify([{ ip: '0.0.0.0', port: 8010 }]));
    await step(w, 'packages', ['career', 'estate', 'finance', 'paperless']);
    await step(w, 'c:career:ADZUNA_APP_ID', 'beispiel-id');
    await step(w, 'c:career:ADZUNA_APP_KEY', 'beispiel-key');
    await step(w, 'c:career:JSEARCH_API_KEY', '', { skip: true });
    await step(w, 's:estate:general.bundesland', 'bayern');
    await waitFor(async () => !(await state(w)).json.page.poll);   // Paperless-Suche fertig (hier: Container auf diesem Rechner)
    await step(w, 's:paperless:general.paperless_url', plUrl);
    await step(w, 'c:paperless:PAPERLESS_API_TOKEN', 'beispieltoken0123');
    await step(w, 'reach', 'fritzbox');
    await step(w, 'fb_dslite', 'no');
    await step(w, 'fb_guide', null);
    await waitFor(async () => !(await state(w)).json.page.poll);   // MyFRITZ: Kennung fest, Gerätename fehlt
    await step(w, 'h:DOMAIN', 'meinrechner');
    await step(w, 'review', null);
    await shot(w, 'confirm');
    fs.writeFileSync(path.join(w.fake, 'hold_stage'), 'workflows');
    await answer(w, 'confirm', null);
    await waitFor(async () => ((await state(w)).json.page.items || []).some((i) => i.state === 'run' && i.text.startsWith('Bot')));
    await shot(w, 'install');
    fs.writeFileSync(path.join(w.fake, 'fail_stage'), 'workflows');
    fs.rmSync(path.join(w.fake, 'hold_stage'));
    await waitFor(async () => (await state(w)).json.page.failed);
    await shot(w, 'install-fehler');
    fs.rmSync(path.join(w.fake, 'fail_stage'));
    await post(w, '/api/action', { name: 'retry' });
    await answer(w, 'confirm', null);
    await waitFor(async () => (await state(w)).json.page.id === 'connect');
    const pg = await waitFor(async () => { const p = (await state(w)).json.page; return p.qr ? p : null; });
    out.push({ name: 'connect', page: pg });
    // Selbsttest: Telegram meldet einen Zustellfehler -> Hinweis mit nächstem Schritt für die FritzBox.
    fs.writeFileSync(path.join(w.fake, 'reach'), JSON.stringify({ mode: 'fritzbox', state: 'ready', webhook: 'ours', webhook_error: 'Connection timed out' }));
    const pe = await waitFor(async () => { const p = (await state(w)).json.page; return p.note ? p : null; }, 30000);
    out.push({ name: 'connect-zustellfehler', page: pe });
    fs.writeFileSync(path.join(w.fake, 'paired'), '');
    await waitFor(async () => (await state(w)).json.page.id === 'handoff');
    await shot(w, 'handoff');
  } catch (e) {
    process.stderr.write('letzte Seite: ' + JSON.stringify((await state(w)).json.page).slice(0, 900) + '\n');
    throw e;
  } finally {
    pl.close();
    await w.stop();
  }
  // MyFRITZ: Gerätename löst auf -> Adresse vorausgefüllt.
  const d = await startWizard({ hints: { LA_MYFRITZ_ZONE: 'deine-domain.myfritz.net', LA_HOST_NAME_CANDIDATES: 'mac-mini' },
    env: { WIZARD_FAKE_DNS: 'mac-mini.deine-domain.myfritz.net' } });
  try {
    await login(d);
    for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'], ['h:OWNER_BIRTH_DATE', '1980-01-01'],
      ['h:OWNER_PERSONA', 'neutral'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'], ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', []],
      ['reach', 'fritzbox'], ['fb_dslite', 'no'], ['fb_guide', null]]) await answer(d, id, v);
    await waitFor(async () => !(await state(d)).json.page.poll);
    await shot(d, 'h_DOMAIN-gefunden');
  } finally { await d.stop(); }
  // Tunnel-Anmeldung und belegte Ports als eigene Läufe (anderer Weg).
  const t = await startWizard();
  try {
    await login(t);
    for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'], ['h:OWNER_BIRTH_DATE', '1980-01-01'],
      ['h:OWNER_PERSONA', 'neutral'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'], ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', []]]) await answer(t, id, v);
    fs.writeFileSync(path.join(t.fake, 'ports'), 'busy');
    await answer(t, 'reach', 'fritzbox');
    await answer(t, 'fb_dslite', 'no');
    await shot(t, 'fb_ports_busy');
    await answer(t, 'fb_ports_busy', null);
    await shot(t, 'review-tunnel');
    await answer(t, 'review', null);
    fs.writeFileSync(path.join(t.fake, 'reach'), 'needs_login');
    await answer(t, 'confirm', null);
    const p = await waitFor(async () => { const x = (await state(t)).json.page; return x.link ? x : null; });
    out.push({ name: 'connect-tailscale', page: p });
  } finally { await t.stop(); }
  // Paperless im Heimnetz: Suche läuft, mehrere gefunden (Auswahl), keiner gefunden. Attrappen auf den echten Suchports.
  const LOGIN = '<html><head><meta name="author" content="Paperless-ngx project and contributors"></head></html>';
  const mock = (port) => new Promise((r) => { const s = http.createServer((q, res) => { res.writeHead(200); res.end(LOGIN); }); s.listen(port, '0.0.0.0', () => r(s)); });
  const toPaperless = async (x) => {
    await login(x);
    for (const [id, v] of [['h:OWNER_LANGUAGE', 'de'], ['h:OWNER_FIRST_NAME', 'Erika'], ['h:OWNER_LAST_NAME', 'Muster'], ['h:OWNER_BIRTH_DATE', '1980-01-01'],
      ['h:OWNER_PERSONA', 'neutral'], ['h:TELEGRAM_BOT_TOKEN', '1:beispiel'], ['h:ANTHROPIC_API_KEY', 'sk-ant-beispiel'], ['voice', 'no'], ['packages', ['paperless']]]) await answer(x, id, v);
  };
  const m1 = await mock(8000); const m2 = await mock(8010);
  const s1 = await startWizard({ hints: { LA_HOST_IP: lanIp() }, env: { WIZARD_SCAN_TIMEOUT_MS: '200' } });
  try {
    await toPaperless(s1);
    await waitFor(async () => !(await state(s1)).json.page.poll, 60000);
    await shot(s1, 'paperless-auswahl');
  } finally { await s1.stop(); m1.close(); m2.close(); }
  const s2 = await startWizard({ hints: { LA_HOST_IP: lanIp() } });
  try {
    await toPaperless(s2);
    await shot(s2, 'paperless-suche');
    await waitFor(async () => !(await state(s2)).json.page.poll, 120000);
    await shot(s2, 'paperless-keiner');
  } finally { await s2.stop(); }
  // Varianten (<seite>-<zusatz>) direkt hinter ihre Seite, damit die Liste der Vorschau z. B. MyFRITZ „nicht gefunden“ und
  // „gefunden“ nebeneinander zeigt.
  const baseOf = (o) => out.find((b) => b !== o && o.name.startsWith(b.name + '-'));
  const order = out.filter((o) => !baseOf(o));
  for (const v of out.filter((o) => baseOf(o))) {
    const b = baseOf(v).name;
    let at = -1;
    order.forEach((x, i) => { if (x.name === b || x.name.startsWith(b + '-')) at = i; });
    order.splice(at + 1, 0, v);
  }
  process.stdout.write(JSON.stringify({ pages: order }) + '\n');
})().catch((e) => { process.stderr.write(String(e && e.stack) + '\n'); process.exit(1); });
