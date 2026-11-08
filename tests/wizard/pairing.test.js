// Maschinenlesbarer Pairing-Einstieg (household_cli.sh owner_connect_machine, `lifeagents household pair-owner --machine`):
// eine JSON-Zeile je Aufruf, ohne Terminal, ohne Datenbank prüfbar für die Fälle ohne Voraussetzungen.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { execFileSync } = require('child_process');
const { REPO } = require('./helpers');

const LIBS = ['common', 'release_inputs', 'apply_schema', 'seed_data', 'inject_credentials', 'deploy_workflows', 'pkg_teardown',
  'pkg_lifecycle', 'bootstrap_owner', 'firewall', 'owner_connect', 'household_cli'];
function machine(verb, env, stubs) {
  const P = path.join(REPO, 'provisioning', 'lib');
  const src = LIBS.map((l) => `. '${P}/${l}.sh'`).join('; ');
  const out = execFileSync('bash', ['-c', `set -euo pipefail; export REPO_ROOT='${REPO}'; UNATTENDED=1; ${src}; ${stubs ? stubs + '; ' : ''}owner_connect_machine '${verb}'`],
    { env: Object.assign({}, process.env, { TELEGRAM_BOT_TOKEN: '', DOMAIN: '', N8N_API_KEY: '' }, env || {}), stdio: ['ignore', 'pipe', 'ignore'] }).toString();
  const lines = out.trim().split('\n');
  assert.equal(lines.length, 1, 'genau eine Zeile: ' + out);
  return JSON.parse(lines[0]);
}

test('pair-owner --machine: eine JSON-Zeile je Verb, ohne Voraussetzungen kein Code', () => {
  assert.deepEqual(machine('status'), { ok: true, connected: false });
  assert.deepEqual(machine('arm'), { ok: false, reason: 'no_token' }, 'ohne Bot kein Code');
  assert.equal(machine('reach').ok, false);
  assert.match(machine('reach').problem, /fehlt noch eine Angabe/);
  assert.deepEqual(machine('finalize'), { ok: false, reason: 'not_connected' });
  assert.deepEqual(machine('unbekannt'), { ok: false, reason: 'usage' });
});

// Nur was Zeit heilt, trägt wait:true; der Wizard wartet dann statt zu melden.
test('reach: Adresse antwortet noch nicht = wait:true, Proxy-Fehler ohne wait', () => {
  const env = { TELEGRAM_BOT_TOKEN: '1:beispiel', DOMAIN: 'beispiel.example', N8N_API_KEY: 'beispiel' };
  const soft = machine('reach', env, `https_code() { echo 000; }`);
  assert.equal(soft.ok, false); assert.equal(soft.wait, true); assert.match(soft.problem, /beispiel\.example antwortet nicht/);
  const hard = machine('reach', env, `https_code() { case "$1" in */webhook/*) echo 502;; *) echo 200;; esac; }`);
  assert.equal(hard.ok, false); assert.equal(hard.wait, undefined); assert.match(hard.problem, /Reverse Proxy/);
});
