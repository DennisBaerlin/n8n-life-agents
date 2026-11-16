// Alles, was der Wizard in die Antwort-Datei schreiben kann, muss der ECHTE Leser des Installers (install_answers_load in
// release_inputs.sh) annehmen. Der Fragebogen kommt aus bridge.sh questions (echte Manifeste), die Antworten aus
// flow.answerLines/renderAnswers: ein neuer Wizard-Schluessel, den die Sperrliste des Lesers ablehnt, wird hier rot, ohne
// dass jemand eine zweite Liste pflegt. Braucht nur bash + jq (wie die uebrigen Wizard-Tests).
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { REPO, WIZ } = require('./helpers');
const flow = require(path.join(WIZ, 'flow.js'));

function questionnaire() {
  const r = spawnSync('bash', [path.join(WIZ, 'bridge.sh'), 'questions'], { encoding: 'utf8', env: Object.assign({}, process.env, { OWNER_LANGUAGE: 'de' }) });
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(r.stdout);
}

// Fuehrt den echten Leser auf der Datei aus und gibt je Schluessel den danach exportierten Wert zurueck.
function readWithInstaller(file, keys) {
  const script = [
    'set -euo pipefail',
    '. "$1/provisioning/lib/common.sh"; . "$1/provisioning/lib/release_inputs.sh"',
    'die() { printf "DIE: %s\\n" "$*" >&2; exit 1; }',
    'install_answers_load "$2"',
    'shift 2; for k in "$@"; do printf "%s=%s\\n" "$k" "${!k-<unset>}"; done',
  ].join('\n');
  const r = spawnSync('bash', ['-c', script, 'x', REPO, file, ...keys], { encoding: 'utf8', env: Object.assign({}, process.env, { GUM_DISABLE: '1' }) });
  return r;
}

const Q = questionnaire();
const ids = Q.packages.map((p) => p.id);
const fill = (extra) => {
  const A = Object.assign({ __voice: 'yes', __tg_conflict: 'beispiel.example', __tg_choice: 'take', __dslite: 'no', __dslite_auto: 'no', __ports: 'free' }, extra);
  const S = {};
  for (const k of flow.allowedKeys(Q)) {
    if (k === 'REACH_MODE' || k === 'DOMAIN' || k === 'TELEGRAM_WEBHOOK_TAKEOVER' || k === 'BACKUP_PARENT_DIR') continue;
    A[k] = k.endsWith('DOMAIN') ? 'beispiel.example' : 'beispiel1';
    S[k] = 'geheim1';
  }
  return { A, S };
};

const cases = [];
for (const reach of ['tunnel', 'fritzbox']) {
  for (const pk of [ids, []]) {
    for (const backup of [{ __backup_choice: 'other', __backup_dir: '/daten/sicherung' }, { __backup_choice: 'other', __backup_dir: 'D:\\Sicherungen' }, {}]) {
      cases.push({ name: `${reach}, ${pk.length ? 'alle Pakete' : 'ohne Pakete'}, ${backup.__backup_dir ? 'Sicherungsordner ' + backup.__backup_dir : 'ohne Sicherungsordner'}`, extra: Object.assign({ __reach: reach, __packages: pk }, backup) });
    }
  }
}

for (const c of cases) {
  test(`Leser nimmt jede Wizard-Antwort an: ${c.name}`, () => {
    const { A, S } = fill(c.extra);
    const lines = flow.answerLines(Q, A, S);
    const txt = flow.renderAnswers(Q, lines);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rd-'));
    try {
      const file = path.join(dir, 'answers.env');
      fs.writeFileSync(file, txt);
      const keys = lines.map(([k]) => k);
      const r = readWithInstaller(file, keys);
      assert.equal(r.status, 0, `Leser lehnt ab: ${r.stderr}`);
      const got = new Map(r.stdout.split('\n').filter(Boolean).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
      for (const [k, v] of lines) assert.equal(got.get(k), v, `${k} nicht uebernommen`);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
}

test('Der Sicherungs-Schluessel ist in der Matrix wirklich enthalten', () => {
  const { A, S } = fill({ __reach: 'tunnel', __packages: [], __backup_choice: 'other', __backup_dir: '/daten/sicherung' });
  assert.ok(flow.answerLines(Q, A, S).some(([k]) => k === 'BACKUP_PARENT_DIR'));
});

test('Die Ausnahme gilt nur fuer BACKUP_PARENT_DIR: andere *_DIR-Schluessel bleiben gesperrt', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rd-'));
  try {
    for (const k of ['SCRIPT_DIR', 'BACKUP_DIR', 'LIFEAGENTS_DIR']) {
      const file = path.join(dir, 'answers.env');
      fs.writeFileSync(file, `# lifeagents-answers v1\n${k}=/x\n`);
      assert.notEqual(readWithInstaller(file, [k]).status, 0, `${k} muss abgelehnt werden`);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
