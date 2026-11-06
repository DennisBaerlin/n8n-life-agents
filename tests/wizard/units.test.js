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
  assert.equal(m.get('PACKAGES_SELECTED'), 'estate');
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

test('Leser-Referenz: falscher Kopf, Zeile ohne =, doppelter Schlüssel', () => {
  assert.throws(() => flow.parseAnswers('KEY=1\n'), /header/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\nKEY\n'), /line 2/);
  assert.throws(() => flow.parseAnswers('# lifeagents-answers v1\nKEY=1\nKEY=2\n'), /line 3/);
  assert.equal(flow.parseAnswers('# lifeagents-answers v1\nK=a=b\n').get('K'), 'a=b');
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
  assert.equal(flow.reachMode({ __reach: 'fritzbox', __dslite: 'yes' }), 'tunnel');
  assert.equal(flow.reachMode({ __reach: 'fritzbox', __dslite: 'no', __ports: 'busy' }), 'tunnel');
  assert.equal(flow.reachMode({ __reach: 'fritzbox', __dslite: 'no' }), 'fritzbox');
  assert.ok(flow.steps(Q, { __reach: 'fritzbox', __dslite: 'no', __ports: 'busy' }).includes('fb_ports_busy'));
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
