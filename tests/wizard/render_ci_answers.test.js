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
