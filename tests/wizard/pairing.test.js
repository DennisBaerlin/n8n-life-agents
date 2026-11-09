// Maschinenlesbarer Pairing-Einstieg (household_cli.sh owner_connect_machine, `lifeagents household pair-owner --machine`):
// eine JSON-Zeile je Aufruf, ohne Terminal, ohne Datenbank prüfbar für die Fälle ohne Voraussetzungen.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
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

// Abschluss: Erfolg heißt nachgeprüft, dass kein Telegram-Schritt mehr die Platzhalter-chat_id trägt.
const PAIRED = '_owner_chat_id_db() { echo 4711; }; _oc_send_welcome() { return 0; }';
const NOLOCK = 'update_lock_acquire() { return 0; }';
const wfPage = (nodes, extra) => JSON.stringify({ data: [Object.assign({ id: 'w1', active: true, nodes }, extra || {})] });
const tg = (chatId) => ({ name: 'Send', type: 'n8n-nodes-base.telegram', parameters: { chatId } });
const api = (p) => `n8n_api_curl() { cat <<'JSON'\n${p}\nJSON\n}`;
const GOOD = api(wfPage([tg('4711')]));

function logged(stubs, lock) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fin-'));
  const log = path.join(dir, 'f.log');
  const r = machine('finalize', { N8N_API_KEY: 'beispiel', N8N_URL: 'http://127.0.0.1:1', LA_FINALIZE_LOG: log }, `${PAIRED}; ${lock || NOLOCK}; ${stubs}`);
  return { r, log: fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '' };
}

test('finalize: echter Stand = ok, Protokoll geschrieben', () => {
  const { r, log } = logged(`_oc_finalize() { echo eingespielt; }; ${GOOD}`);
  assert.deepEqual(r, { ok: true, welcome_sent: true });
  assert.match(log, /eingespielt/);
});

test('finalize: Abbruch im Einspielen = finalize_failed, Grund steht im Protokoll', () => {
  const { r, log } = logged(`_oc_finalize() { echo 'n8n import:workflow fehlgeschlagen.'; exit 1; }; ${GOOD}`);
  assert.deepEqual(r, { ok: false, reason: 'finalize_failed' });
  assert.match(log, /import:workflow fehlgeschlagen/);
});

test('finalize: Scheinerfolg mit chatId 0 wird erkannt, auch nur in der aktiven Fassung', () => {
  assert.deepEqual(logged(`_oc_finalize() { :; }; ${api(wfPage([tg('0'), Object.assign(tg(0), { name: 'Zwei' })]))}`).r, { ok: false, reason: 'placeholders_left', placeholders: 2 });
  assert.deepEqual(logged(`_oc_finalize() { :; }; ${api(wfPage([tg('4711')], { activeVersion: { nodes: [tg('0')] } }))}`).r, { ok: false, reason: 'placeholders_left', placeholders: 1 });
});

test('finalize: Prüfung nicht möglich gilt nicht als Erfolg', () => {
  assert.deepEqual(logged('_oc_finalize() { :; }; n8n_api_curl() { return 22; }').r, { ok: false, reason: 'check_failed' });
});

test('finalize: Ausdrücke und andere Knoten zählen nicht als Platzhalter', () => {
  const nodes = [tg('={{ $json.chat_id }}'), { name: 'x', type: 'n8n-nodes-base.set', parameters: { value: '0' } }];
  assert.equal(logged(`_oc_finalize() { :; }; ${api(wfPage(nodes))}`).r.ok, true);
});

test('finalize: zweiter gleichzeitiger Lauf startet nicht', () => {
  const { r, log } = logged(`_oc_finalize() { echo LIEF; }; ${GOOD}`, 'update_lock_acquire() { return 1; }');
  assert.deepEqual(r, { ok: false, reason: 'busy' });
  assert.doesNotMatch(log, /LIEF/);
});

test('finalize: Protokoll enthält keine Token, Codes oder chat_ids', () => {
  const { log } = logged(`_oc_finalize() { echo 'bot123456789:AAbcdefghijklmnopqrstuvwxyz012345678 start=0123456789abcdef X-N8N-API-KEY: geheim123 chat 987654321 sk-ant-abc123def456'; }; ${GOOD}`);
  assert.doesNotMatch(log, /AAbcdefghij|0123456789abcdef|geheim123|987654321|sk-ant-abc/);
});
