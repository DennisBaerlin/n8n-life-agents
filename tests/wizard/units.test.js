// Einheiten-Tests ohne Server: Antwort-Datei (Vertrag mit Paket 1), Ablauf, Hilfetext, QR-Code.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const path = require('path');
const { WIZ } = require('./helpers');
const flow = require(path.join(WIZ, 'flow.js'));
const qr = require(path.join(WIZ, 'qr.js'));

// Kleiner erfundener Fragen-Auszug in der Form von bridge.sh questions.
const Q = {
  v: 1,
  host: ['OWNER_FIRST_NAME', 'OWNER_LAST_NAME', 'OWNER_BIRTH_DATE', 'OWNER_LANGUAGE', 'OWNER_PERSONA', 'TELEGRAM_BOT_TOKEN', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'DOMAIN']
    .map((k) => ({ key: k, label: k, help: '', secret: /TOKEN|KEY/.test(k), required: !/GOOGLE|DOMAIN|LANG|PERSONA/.test(k), live: false })),
  languages: [{ code: 'de', name: 'Deutsch' }], personas: [{ code: 'neutral', name: 'Standard' }],
  packages: [
    { id: 'career', name: 'Karriere', summary: '', settings: [], credentials: [{ id: 'adzuna', required: false, keys: [{ env: 'ADZUNA_APP_ID', label: 'ID' }, { env: 'ADZUNA_APP_KEY', label: 'Key', secret: true }] }] },
    { id: 'estate', name: 'Nachlass', summary: '', settings: [{ id: 'general.bundesland', env: 'CONFIG_GENERAL_BUNDESLAND', label: 'Land', choices: [{ value: 'bayern', label: 'Bayern' }] }], credentials: [] },
  ],
};

test('Antwort-Datei: Sonderzeichen bleiben wörtlich, Kopf und Reihenfolge stimmen', () => {
  const A = { OWNER_FIRST_NAME: "O'Neil $(touch /tmp/x) `id`", OWNER_LAST_NAME: 'Muster; rm -rf ~ \\ "q"', OWNER_BIRTH_DATE: '1980-01-01',
    OWNER_LANGUAGE: 'de', OWNER_PERSONA: 'neutral', TELEGRAM_BOT_TOKEN: null, ANTHROPIC_API_KEY: null, __voice: 'no', GOOGLE_API_KEY: '',
    __packages: ['estate'], CONFIG_GENERAL_BUNDESLAND: 'bayern', __reach: 'tunnel' };
  const S = { TELEGRAM_BOT_TOKEN: '123456:ABC-beispiel', ANTHROPIC_API_KEY: 'sk-ant-beispiel=mit=gleich' };
  const txt = flow.renderAnswers(Q, flow.answerLines(Q, A, S));
  assert.ok(txt.startsWith('# lifeagents-answers v1\n'));
  const m = flow.parseAnswers(txt);
  assert.equal(m.get('OWNER_FIRST_NAME'), "O'Neil $(touch /tmp/x) `id`");
  assert.equal(m.get('OWNER_LAST_NAME'), 'Muster; rm -rf ~ \\ "q"');
  assert.equal(m.get('ANTHROPIC_API_KEY'), 'sk-ant-beispiel=mit=gleich');
  assert.equal(m.get('GOOGLE_API_KEY'), '');
  assert.ok(!m.has('PACKAGES_SELECTED'), 'Module gehen als --packages an provision.sh, nicht in die Datei');
  assert.equal(flow.packagesArg(Q, A), 'estate');
  assert.equal(flow.packagesArg(Q, { __packages: [] }), 'none');
  assert.equal(flow.packagesArg(Q, { __packages: ['estate', 'unbekannt'] }), 'estate');
  assert.ok(txt.includes("\nOWNER_FIRST_NAME=O'Neil $(touch /tmp/x) `id`\n"), 'roh, ohne Quotes');
  assert.equal(m.get('REACH_MODE'), 'tunnel');
  assert.equal(m.get('DOMAIN'), '');
  assert.equal(m.get('CONFIG_GENERAL_BUNDESLAND'), 'bayern');
  assert.ok(!m.has('ADZUNA_APP_ID'), 'nicht gewähltes Paket schreibt nichts');
});

test('Antwort-Datei: Verstöße werfen, nie still reparieren', () => {
  for (const bad of ['a\nB=1', 'a\rb', 'x\u0000', 'x\u007f', ' lead', 'trail ', 'x'.repeat(4097)]) {
    assert.throws(() => flow.renderAnswers(Q, [['OWNER_FIRST_NAME', bad]]), /bad value/, JSON.stringify(bad.slice(0, 10)));
  }
  assert.throws(() => flow.renderAnswers(Q, [['PATH', '/x']]), /not allowed/);
  assert.throws(() => flow.renderAnswers(Q, [['owner_first_name', 'x']]), /not allowed/);
  assert.throws(() => flow.renderAnswers(Q, [['OWNER_FIRST_NAME', 'a'], ['OWNER_FIRST_NAME', 'b']]), /duplicate/);
  assert.equal(flow.valueProblem('ä€😀'.repeat(300)), null);
  assert.equal(flow.valueProblem('😀'.repeat(1025)), 'length');
});

test('Leser-Referenz (Regeln von install_answers_load): Kopf, Zeile ohne =, Leer-/Kommentarzeile, doppelt, Steuerzeichen', () => {
  assert.throws(() => flow.parseAnswers('KEY=1\n'), /header/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\nKEY\n'), /line 2/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\n\n'), /line 2/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\n# x\n'), /line 2/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\nKEY=1\nKEY=2\n'), /line 3/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\nKEY=a\rb\n'), /line 2/);
  assert.equal(flow.parseAnswers('# lifeagents-answers v1\nK=a=b\n').get('K'), 'a=b');
});

test('Antwort-Datei: Übernahme eines belegten Bots nur nach ausdrücklicher Wahl', () => {
  const take = flow.parseAnswers(flow.renderAnswers(Q, flow.answerLines(Q, { __tg_conflict: 'beispiel.example', __tg_choice: 'take' }, {})));
  assert.equal(take.get('TELEGRAM_WEBHOOK_TAKEOVER'), '1');
  const none = flow.parseAnswers(flow.renderAnswers(Q, flow.answerLines(Q, { __tg_conflict: 'beispiel.example' }, {})));
  assert.ok(!none.has('TELEGRAM_WEBHOOK_TAKEOVER'));
});

test('Ablauf: Telegram je nach Bestand (Handy nur ohne Konto, Rechner nur ohne Telegram dort)', () => {
  const tg = (have) => flow.steps(Q, { __tg_have: have }).filter((x) => x.startsWith('tg_') || x === 'h:TELEGRAM_BOT_TOKEN');
  assert.deepEqual(tg('none'), ['tg_why', 'tg_phone', 'tg_pc', 'h:TELEGRAM_BOT_TOKEN']);
  assert.deepEqual(tg('phone'), ['tg_why', 'tg_pc', 'h:TELEGRAM_BOT_TOKEN'], 'Konto da: Handy-Seite entfällt');
  assert.deepEqual(tg('both'), ['tg_why', 'h:TELEGRAM_BOT_TOKEN'], 'alles da: gleich zum Bot');
  assert.equal(flow.answered(Q, {}, 'tg_why'), false);
  assert.equal(flow.answered(Q, { __tg_have: 'phone' }, 'tg_why'), true);
  for (const id of ['tg_why', 'tg_phone', 'tg_pc']) assert.deepEqual(flow.stepOf(id), { current: 'questions', sub: 'access' }, id);
});

test('Ablauf: Folgefragen nur gewählter Module, „beide oder keine“, FritzBox-Weg', () => {
  const base = { __packages: ['career', 'estate'] };
  let s = flow.steps(Q, base);
  assert.ok(s.includes('c:career:ADZUNA_APP_ID') && s.includes('c:career:ADZUNA_APP_KEY') && s.includes('s:estate:general.bundesland'));
  s = flow.steps(Q, Object.assign({}, base, { ADZUNA_APP_ID: '' }));
  assert.ok(!s.includes('c:career:ADZUNA_APP_KEY'), 'leere App-ID lässt den Key entfallen');
  s = flow.steps(Q, { __packages: [] });
  assert.ok(!s.some((x) => x.startsWith('c:') || x.startsWith('s:')));
  assert.ok(flow.steps(Q, { __reach: 'fritzbox', __dslite: 'no' }).includes('h:DOMAIN'));
  assert.ok(!flow.steps(Q, { __reach: 'fritzbox', __dslite: 'yes' }).includes('h:DOMAIN'));
  assert.ok(!flow.steps(Q, { __reach: 'fritzbox', __dslite: 'no', __dslite_auto: 'no' }).includes('fb_dslite'), 'sicher erkannt: keine Seite');
  assert.ok(flow.steps(Q, { __reach: 'fritzbox', __dslite_auto: 'yes' }).includes('fb_dslite'), 'keine eigene IPv4: Bestätigung');
  assert.equal(flow.reachMode({ __reach: 'fritzbox', __dslite: 'yes' }), 'tunnel');
  assert.equal(flow.reachMode({ __reach: 'fritzbox', __dslite: 'no', __ports: 'busy' }), 'tunnel');
  assert.equal(flow.reachMode({ __reach: 'fritzbox', __dslite: 'no' }), 'fritzbox');
  assert.ok(flow.steps(Q, { __reach: 'fritzbox', __dslite: 'no', __ports: 'busy' }).includes('fb_ports_busy'));
});

test('Projekt-Zeichen: ui/mark.html ist dasselbe SVG wie die Quelle der Site', () => {
  const fs = require('fs');
  const svg = (f) => /<svg[\s\S]*<\/svg>/.exec(fs.readFileSync(f, 'utf8'))[0].replace(/\s+/g, ' ');
  assert.equal(svg(path.join(WIZ, 'ui', 'mark.html')), svg(path.join(WIZ, '..', '..', 'docs', 'site', 'layouts', 'partials', 'mark.html')));
});

test('Paperless-Adresse vorausfüllen: genau ein erreichbarer Treffer, sonst leer', () => {
  const g = flow.paperlessGuess;
  assert.equal(g([{ ip: '0.0.0.0', port: 8000 }], '192.0.2.10'), 'http://192.0.2.10:8000');
  assert.equal(g([{ ip: '192.0.2.10', port: 8010 }, { ip: '::', port: 8010 }], '192.0.2.10'), 'http://192.0.2.10:8010', 'derselbe Port doppelt = ein Treffer');
  assert.equal(g([{ ip: '0.0.0.0', port: 8000 }, { ip: '0.0.0.0', port: 8001 }], '192.0.2.10'), '', 'mehrdeutig = leer');
  assert.equal(g([{ ip: '127.0.0.1', port: 8000 }, { ip: '::1', port: 8001 }], '192.0.2.10'), '', 'nur lokal = aus dem Verbund nicht erreichbar');
  assert.equal(g([{ ip: '198.51.100.7', port: 8000 }], '192.0.2.10'), '', 'an eine fremde Adresse gebunden');
  assert.equal(g([], '192.0.2.10'), '');
  assert.equal(g(null, '192.0.2.10'), '');
  assert.equal(g([{ ip: '0.0.0.0', port: 8000 }], ''), '', 'ohne Heimnetz-Adresse der App = leer');
  assert.equal(g([{ ip: '0.0.0.0', port: 8000 }], '127.0.0.1'), '');
  assert.equal(g([{ ip: '0.0.0.0', port: 8000 }], '192.0.2.10; rm -rf /'), '', 'nur echte IPv4');
  assert.equal(g([{ ip: '0.0.0.0', port: 0 }, { ip: '0.0.0.0', port: 'x' }], '192.0.2.10'), '');
});

test('MyFRITZ-Adresse: Zone und Namen streng geprüft, vorgeschlagen nur, was auf diesen Anschluss zeigt', async () => {
  assert.equal(flow.myfritzZone('Deine-Domain.myfritz.net.'), 'deine-domain.myfritz.net');
  for (const bad of ['', 'myfritz.net', 'zwei.deine-domain.myfritz.net', 'deine-domain.myfritz.net.evil.example', 'mein rechner.deine-domain.myfritz.net']) assert.equal(flow.myfritzZone(bad), '', bad);
  // Name der FritzBox zuerst, dann die weiteren; Unbrauchbares fällt weg.
  assert.deepEqual(flow.myfritzCandidates('Kims-PC', 'Mac-Mini, kims-pc mac-mini ;rm -rf /, -x'), ['kims-pc', 'mac-mini']);
  const Z = 'deine-domain.myfritz.net'; const IP = '203.0.113.7';
  const dnsTab = { [`mac-mini.${Z}`]: ['198.51.100.9'], [`meinrechner.${Z}`]: [IP] };
  const seen = [];
  const lookup = async (n) => { seen.push(n); return dnsTab[n] || []; };
  assert.equal(await flow.domainCheck(`meinrechner.${Z}`, lookup, IP), 'ok');
  assert.equal(await flow.domainCheck(`mac-mini.${Z}`, lookup, IP), 'wrong_ip', 'zeigt woandershin');
  assert.equal(await flow.domainCheck(`neu.${Z}`, lookup, IP), 'pending', 'Freigabe fehlt oder wird gerade eingetragen');
  assert.equal(await flow.domainCheck(`meinrechner.${Z}`, lookup, ''), 'found', 'ohne bekannte IPv4 nur „gefunden“');
  assert.equal(await flow.domainCheck('x', async () => { throw new Error('x'); }, IP), 'pending');
  seen.length = 0;
  assert.equal(await flow.myfritzGuess(Z, ['mac-mini', 'meinrechner', 'x'], lookup, IP), `meinrechner.${Z}`, 'falsche IP wird übersprungen');
  assert.deepEqual(seen, [`mac-mini.${Z}`, `meinrechner.${Z}`], 'stoppt beim ersten geprüften Treffer');
  assert.equal(await flow.myfritzGuess(Z, ['meinrechner'], lookup, ''), '', 'ohne öffentliche IPv4 kein Vorschlag');
  assert.equal(await flow.myfritzGuess('', ['meinrechner'], lookup, IP), '', 'ohne Kennung kein Vorschlag');
});

test('Vorschläge vom Rechner: Sprache auf angebotene Codes, Name am letzten Leerzeichen', () => {
  const L = [{ code: 'de' }, { code: 'en' }];
  assert.equal(flow.userLanguage('de-DE', L), 'de');
  assert.equal(flow.userLanguage('en_US.UTF-8', L), 'en');
  assert.equal(flow.userLanguage('fr', L), '');
  assert.equal(flow.userLanguage('', L), '');
  assert.deepEqual(flow.userName('Lena Marie Beispiel'), { first: 'Lena Marie', last: 'Beispiel' });
  assert.deepEqual(flow.userName('  Kim  '), { first: 'Kim', last: '' });
  assert.deepEqual(flow.userName('Tom\nBeispiel'), { first: 'Tom', last: 'Beispiel' }, 'Zeilenumbruch wird Leerzeichen');
  assert.deepEqual(flow.userName('x\u0000y'), { first: '', last: '' });
  assert.deepEqual(flow.userName(''), { first: '', last: '' });
});

test('Hilfetext der CLI: Listen, Absätze, Terminal-Befehle entfallen', () => {
  const b = flow.helpBlocks('Erste Zeile\nzweite Zeile.\n  1. Eins\n  2. Zwei mit\n     Fortsetzung\nSpäter nachtragen: lifeagents reconfigure');
  assert.deepEqual(b, [{ p: 'Erste Zeile zweite Zeile.' }, { ol: ['Eins', 'Zwei mit Fortsetzung'] }]);
});

test('QR-Code: feste Fassung (gegen einen unabhängigen Decoder geprüft) und Grundmuster', () => {
  const link = 'https://t.me/beispiel_bot?start=0123456789abcdef';
  const q = qr.encode(link);
  assert.equal(q.size, 33);   // Version 4
  const finder = (x0, y0) => [0, 6].every((d) => q.modules[y0][x0 + d] && q.modules[y0 + d][x0] && q.modules[y0 + 6][x0 + d] && q.modules[y0 + d][x0 + 6]);
  assert.ok(finder(0, 0) && finder(q.size - 7, 0) && finder(0, q.size - 7));
  const hash = crypto.createHash('sha256').update(q.modules.map((r) => r.map((v) => (v ? 1 : 0)).join('')).join('\n')).digest('hex');
  assert.equal(hash, GOLDEN_QR);
  assert.match(qr.toSvg(q), /^<svg [^>]*viewBox="0 0 41 41"/);
  assert.throws(() => qr.encode('x'.repeat(300)), /too long/);
});
const GOLDEN_QR = 'fd6f2b9619bde53cb828f90e06585aca1c8dc80dfb838c90ebbc8960aa84aa23';   // jsQR 1.4.0 las diesen Code am 2026-11-06 als den Link

test('hints.env: streng gelesen, nie ausgeführt, eine verletzte Regel = keine Vorschläge', () => {
  const p = flow.parseHints;
  assert.deepEqual(p('LA_USER_LANG=de\nLA_USER_FULLNAME=Erika $(id) `x`\nLA_HOST_IP=\nANDERES=x\n'),
    { LA_USER_LANG: 'de', LA_USER_FULLNAME: 'Erika $(id) `x`' }, 'roh, leere und unbekannte Schlüssel zählen nicht');
  assert.deepEqual(p('LA_MYFRITZ_ZONE=deine-domain.myfritz.net\r\nLA_USER_LANG=en\r\n'), { LA_MYFRITZ_ZONE: 'deine-domain.myfritz.net', LA_USER_LANG: 'en' }, 'CRLF');
  for (const bad of ['LA_USER_LANG=de\nLA_USER_LANG=en\n', '# kommentar\nLA_USER_LANG=de\n', 'LA_USER_LANG=de\n\nLA_HOST_IP=192.0.2.10\n',
    'LA_USER_LANG=d\u0007e\n', 'export LA_USER_LANG=de\n', '=de\n', 'LA_USER_LANG=de\r\r\n', 'x'.repeat(9000), null]) {
    assert.deepEqual(p(bad), {}, JSON.stringify(bad));
  }
});

test('Zustellfehler: nur frisch und mit wartenden Nachrichten (Format Paket 3)', () => {
  const f = flow.webhookFailing; const now = 1800000000;
  assert.equal(f({ webhook_error: 'Connection timed out', webhook_error_at: now - 60, webhook_pending: 2 }, now), true);
  assert.equal(f({ webhook_error: 'Connection timed out' }, now), true, 'ohne Zeit und Zähler zählt der Text');
  assert.equal(f({ webhook_error: 'Connection timed out', webhook_error_at: now - 3600, webhook_pending: 2 }, now), false, 'alt');
  assert.equal(f({ webhook_error: 'Connection timed out', webhook_error_at: now - 60, webhook_pending: 0 }, now), false, 'nichts wartet');
  assert.equal(f({ webhook_error: '' }, now), false);
  assert.equal(f(null, now), false);
});

test('Texte der Einrichtung: jeder feste Katalog-Key im Code steht in allen Sprachen', () => {
  const fs = require('fs');
  const { REPO } = require('./helpers');
  const cat = {};
  for (const l of ['de', 'en', 'ko']) cat[l] = JSON.parse(fs.readFileSync(path.join(REPO, 'packages', 'core', 'locales', `${l}.json`), 'utf8'));
  const src = fs.readFileSync(path.join(WIZ, 'server.js'), 'utf8');
  const keys = new Set([...src.matchAll(/'(core\.wizard\.[a-z0-9_.]+)'/g)].map((m) => m[1]));
  // Zusammengesetzte Keys: Präfix + bekannte Endungen.
  for (const k of ['next', 'back', 'skip', 'retry', 'change', 'change_label', 'secret_kept', 'found_addresses', 'one_moment', 'report_show',
    'report_note', 'report_copied', 'offline', 'open_via_app', 'session_expired', 'doc_title']) keys.add(`core.wizard.ui.${k}`);
  for (const k of ['voice_no', 'voice_yes', 'tg_new', 'tg_take', 'reach_tunnel', 'reach_fritzbox', 'dslite_no', 'dslite_yes']) keys.add(`core.wizard.opt.${k}`);
  // Beschreibung je Antwort (optionsFor); das DS-Lite-„Nein“ hat bewusst keine.
  for (const k of ['voice_no', 'voice_yes', 'tg_new', 'tg_take', 'reach_tunnel', 'reach_fritzbox', 'dslite_yes']) keys.add(`core.wizard.opt.${k}_desc`);
  for (const k of ['check', 'programs', 'database', 'access', 'bot', 'final']) keys.add(`core.wizard.stage.${k}`);
  for (const k of ['localhost', 'invalid', 'unreachable', 'not_paperless', 'token_rejected', 'too_old']) keys.add(`core.wizard.paperless.${k}`);
  for (const k of ['title', 'activating', 'activating_wait', 'not_reaching', 'check_again', 'expired', 'new_code', 'open_link', 'scan', 'tap_start',
    'code_valid', 'connected_wait', 'waiting', 'preparing', 'preparing_wait', 'code_failed', 'activation_failed', 'key_expiry']) keys.add(`core.wizard.connect.${k}`);
  for (const m of src.matchAll(/(\w+): '([a-z_]+)'/g)) if (/_(title|help|link|wait|note)$/.test(m[2])) keys.add(`core.wizard.reach.${m[2]}`);
  for (const k of ['owner_language', 'owner_first_name', 'owner_last_name', 'owner_birth_date', 'owner_persona', 'telegram_bot_token', 'anthropic_api_key',
    'google_api_key', 'domain']) keys.add(`core.wizard.q.${k}.title`);
  // Bilder (ui/art/art.js): Schritt-Beschriftungen (key: '…') und Bild-Namen (<bild>_label) stehen in core.wizard.art.*.
  const art = fs.readFileSync(path.join(WIZ, 'ui', 'art', 'art.js'), 'utf8');
  for (const m of art.matchAll(/key: '([a-z0-9_]+)'/g)) keys.add(`core.wizard.art.${m[1]}`);
  for (const m of art.matchAll(/name: '([a-z]+-[a-z]+)'/g)) keys.add(`core.wizard.art.${m[1].replace('-', '_')}_label`);
  assert.ok(keys.has('core.wizard.art.ts_funnel_4') && keys.has('core.wizard.art.ts_login_label'), 'Bild-Keys gefunden');
  assert.ok(keys.size > 100, 'Keys gefunden');
  for (const k of keys) for (const l of ['de', 'en', 'ko']) assert.ok(typeof cat[l][k] === 'string' && cat[l][k], `${k} fehlt in ${l}.json`);
});
