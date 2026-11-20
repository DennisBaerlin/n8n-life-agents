// Die Antwort-Datei der CI (render_ci_answers.js) kommt aus flow.js und den echten Fragen (bridge.sh questions); der ECHTE Leser
// des Installers (install_answers_load) muss sie annehmen, und sie muss die Teile tragen, die der kalte Docker-Lauf braucht:
// Sicherungs-Ordner, Weg, Pflichtfragen, alle Pakete. Braucht nur bash + jq (wie reader.test.js).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawnSync } = require('child_process');
const { REPO, WIZ } = require('./helpers');
const flow = require(path.join(WIZ, 'flow.js'));
const { render } = require('./render_ci_answers.js');

const q = spawnSync('bash', [path.join(WIZ, 'bridge.sh'), 'questions'], { encoding: 'utf8', env: Object.assign({}, process.env, { OWNER_LANGUAGE: 'de' }) });
assert.equal(q.status, 0, q.stderr);
const Q = JSON.parse(q.stdout);

function installerReads(txt, keys) {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'ci-answers-')), 'answers.env');
  fs.writeFileSync(file, txt, { mode: 0o600 });
  const script = [
    'set -euo pipefail',
    '. "$1/provisioning/lib/common.sh"; . "$1/provisioning/lib/release_inputs.sh"',
    'die() { printf "DIE: %s\\n" "$*" >&2; exit 1; }',
    'install_answers_load "$2"',
    'shift 2; for k in "$@"; do printf "%s=%s\\n" "$k" "${!k-<unset>}"; done',
  ].join('\n');
  return spawnSync('bash', ['-c', script, 'x', REPO, file, ...keys], { encoding: 'utf8', env: Object.assign({}, process.env, { GUM_DISABLE: '1' }) });
}

for (const reach of ['tunnel', 'fritzbox']) {
  test(`CI-Antwort-Datei (${reach}): echter Leser nimmt sie an, Sicherungs-Ordner und Weg stehen drin`, () => {
    const txt = render({ flow, Q, reach, backup: '/daten/ci-sicherung' });
    const m = flow.parseAnswers(txt);
    assert.equal(m.get('BACKUP_PARENT_DIR'), '/daten/ci-sicherung');
    assert.equal(m.get('REACH_MODE'), reach);
    for (const h of Q.host.filter((x) => x.required)) assert.ok(m.has(h.key), 'Pflichtfrage fehlt: ' + h.key);
    const r = installerReads(txt, ['BACKUP_PARENT_DIR', 'REACH_MODE', 'OWNER_FIRST_NAME', 'TELEGRAM_BOT_TOKEN']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /^BACKUP_PARENT_DIR=\/daten\/ci-sicherung$/m);
    assert.match(r.stdout, new RegExp(`^REACH_MODE=${reach}$`, 'm'));
  });
}

test('CI-Antwort-Datei: --print packages = alle Pakete mit Fragen, wie der Assistent sie übergibt', () => {
  const arg = render({ flow, Q, reach: 'tunnel', backup: '/x', what: 'packages' });
  assert.equal(arg, Q.packages.map((p) => p.id).join(','));
});

// Profil dev (Test-Unterbau, scripts/dev/bootstrap_test_stack.ps1): dieselbe Datei; Zusatz-Zeilen (stdin: TEST_*-Werte aus .env und
// die Test-Schalter aus scripts/lib/test_install_env.ps1) ersetzen einen Schlüssel an seiner Stelle oder kommen dazu.
test('CI-Antwort-Datei --profile dev: Zusatz-Zeilen ersetzen und ergänzen, echter Leser nimmt sie an, eigene Schalter keine', () => {
  // Die Schalter kommen nur ueber --extra-stdin (scripts/lib/test_install_env.ps1); ohne sie liefe dev still ohne Harness-Header.
  assert.throws(() => render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'dev' }), /--extra-stdin/);
  const release = render({ flow, Q, reach: 'tunnel', backup: '/x' });
  const txt = render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'dev',
    extra: 'TELEGRAM_BOT_TOKEN=2000002:inventedDevToken\nTEST_HARNESS_HEADER=X-Test-Auth\nLIFEAGENTS_DEPLOY_FULL=1\nTEST_HARNESS_SECRET=invented-harness\n' });
  const m = flow.parseAnswers(txt);
  assert.equal(m.get('TEST_HARNESS_HEADER'), 'X-Test-Auth');
  assert.equal(m.get('LIFEAGENTS_DEPLOY_FULL'), '1');
  assert.equal(m.get('TELEGRAM_BOT_TOKEN'), '2000002:inventedDevToken');
  assert.equal(m.get('TEST_HARNESS_SECRET'), 'invented-harness');
  // Ersetzt an Ort und Stelle: die Reihenfolge der Release-Zeilen bleibt, neue Schlüssel kommen ans Ende.
  const relKeys = [...flow.parseAnswers(release).keys()];
  assert.deepEqual([...m.keys()].slice(0, relKeys.length), relKeys);
  const r = installerReads(txt, ['TEST_HARNESS_HEADER', 'TELEGRAM_BOT_TOKEN', 'LIFEAGENTS_DEPLOY_FULL']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^TELEGRAM_BOT_TOKEN=2000002:inventedDevToken$/m);
  assert.match(r.stdout, /^LIFEAGENTS_DEPLOY_FULL=1$/m);
});

test('CI-Antwort-Datei: ohne --profile bleibt sie byte-gleich (genericity liest sie), Zusatz-Zeilen nur mit dev', () => {
  assert.equal(render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'release' }), render({ flow, Q, reach: 'tunnel', backup: '/x' }));
  assert.throws(() => render({ flow, Q, reach: 'tunnel', backup: '/x', extra: 'A=1\n' }), /--profile dev/);
  assert.throws(() => render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'qa' }), /--profile/);
});

test('CI-Antwort-Datei --profile dev: kaputte Zusatz-Zeilen brechen ab und nennen nie den Wert', () => {
  const bad = ['kleinschreibung=1', 'OHNE_GLEICH', 'A=wert mit cr\r', 'A=1\nA=2', 'B= führendes-leerzeichen'];
  for (const extra of bad) {
    assert.throws(() => render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'dev', extra }), (e) => {
      assert.doesNotMatch(e.message, /wert mit cr|führendes/);
      return true;
    }, JSON.stringify(extra));
  }
});

// Profil dev läuft ohne Attrappen gegen echte Dienste: die erfundenen CI-Schlüssel dürfen dort nie stehen. Ohne .env-Wert
// bleibt der Schlüssel leer (der Installer überspringt den Zugang wie im klassischen Unterbau), mit Wert gilt der Wert.
test('CI-Antwort-Datei --profile dev: keine erfundenen Zugänge, nur leer oder der Wert aus .env', () => {
  const m = flow.parseAnswers(render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'dev', extra: 'TEST_HARNESS_HEADER=X-Test-Auth\n' }));
  assert.equal(m.get('TELEGRAM_BOT_TOKEN'), '');
  assert.equal(m.get('ANTHROPIC_API_KEY'), '');
  const r = flow.parseAnswers(render({ flow, Q, reach: 'tunnel', backup: '/x', profile: 'dev', extra: 'ANTHROPIC_API_KEY=sk-ant-invented-dev\n' }));
  assert.equal(r.get('ANTHROPIC_API_KEY'), 'sk-ant-invented-dev');
  assert.equal(r.get('TELEGRAM_BOT_TOKEN'), '');
});
