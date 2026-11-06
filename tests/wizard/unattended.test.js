// Unbeaufsichtigter Lauf (--unattended, Antwort-Datei des Wizards): Paket-Zugänge und Paket-Einstellungen aus der
// Prozess-Umgebung kommen an — dieselben Funktionen wie die CLI (pkg_lifecycle.sh), ohne Datenbank.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { REPO } = require('./helpers');

function bashLib(script, env) {
  const P = path.join(REPO, 'provisioning');
  const pre = `set -euo pipefail; export REPO_ROOT='${REPO}'; UNATTENDED=1; PROFILE=release
    . '${P}/lib/common.sh'; . '${P}/lib/pkg_lifecycle.sh'; . '${P}/lib/release_inputs.sh'
`;
  return execFileSync('bash', ['-c', pre + script], { env: Object.assign({}, process.env, env), stdio: ['ignore', 'pipe', 'ignore'] }).toString();
}

test('Paket-Zugänge aus der Umgebung landen in <pkg>.env (nie leer, nie Seen-Zeile, nichts überschrieben)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'la-env-'));
  const envf = path.join(dir, 'career.env');
  fs.writeFileSync(envf, 'JSEARCH_API_KEY=schon-da\n');
  bashLib(`LIFEAGENTS_DIR='${dir}'; _pkg_secrets_wizard career "$(lifeagents_env_file career)" 0`,
    { ADZUNA_APP_ID: 'beispiel-id', ADZUNA_APP_KEY: "k'ey $(id) `x`", JSEARCH_API_KEY: '' });
  const t = fs.readFileSync(envf, 'utf8');
  assert.match(t, /^ADZUNA_APP_ID=beispiel-id$/m);
  assert.ok(t.includes("ADZUNA_APP_KEY=k'ey $(id) `x`\n"), 'wörtlich');
  assert.match(t, /^JSEARCH_API_KEY=schon-da$/m, 'leerer Env-Wert überschreibt nichts');
  assert.ok((fs.statSync(envf).mode & 0o007) === 0, 'nicht für alle lesbar');
});

test('Paket-Einstellungen CONFIG_<CAT>_<KEY>: Auswahl/validator wie die Frage, ungültig nie gepuffert', () => {
  const out = (env) => bashLib('_pkg_settings_from_env estate; _pkg_settings_from_env paperless; printf "%s" "$PKG_SETTINGS_ANSWERS"', env);
  assert.equal(out({ CONFIG_GENERAL_BUNDESLAND: 'bayern', CONFIG_GENERAL_PAPERLESS_URL: 'http://192.0.2.10:8000' }),
    'estate\tgeneral\tbundesland\tbayern\npaperless\tgeneral\tpaperless_url\thttp://192.0.2.10:8000\n');
  assert.equal(out({ CONFIG_GENERAL_BUNDESLAND: 'atlantis', CONFIG_GENERAL_PAPERLESS_URL: 'ftp://x' }), '', 'ungültig = nichts');
  assert.equal(out({ CONFIG_GENERAL_BUNDESLAND: 'bay\tern' }), '', 'Steuerzeichen = nichts');
  assert.equal(out({}), '', 'ohne Angabe = nichts');
  // Der unbeaufsichtigte Zweig des CLI-Wizards nimmt denselben Weg.
  assert.equal(bashLib('_pkg_settings_wizard estate; printf "%s" "$PKG_SETTINGS_ANSWERS"', { CONFIG_GENERAL_BUNDESLAND: 'berlin' }),
    'estate\tgeneral\tbundesland\tberlin\n');
});
