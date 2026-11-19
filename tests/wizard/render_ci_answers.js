// render_ci_answers.js — die Antwort-Datei für den kalten Docker-Lauf der CI, erzeugt mit dem Code des Einrichtungs-Assistenten
// (provisioning/wizard/flow.js: steps/answerLines/renderAnswers) und den Fragen der echten CLI-Quelle (bridge.sh questions),
// nicht von Hand nachgebaut. Läuft im master-Image (dort liegen flow.js und bridge.sh in der Form, die ein Nutzer bekommt):
//   docker cp tests/wizard/render_ci_answers.js <master>:/tmp/ && docker exec <master> node /tmp/render_ci_answers.js --reach tunnel|fritzbox --backup <eltern-ordner> > answers.env
// --packages none|all wählt die Module (Standard all). --print packages gibt stattdessen das Argument für `provision.sh --packages` aus (flow.packagesArg).
// Optionen: --wizard-dir <ordner> (Standard /opt/lifeagents/provisioning/wizard), --questions-file <json> (statt bridge.sh).
// --profile dev (Test-Unterbau scripts/dev/bootstrap_test_stack.ps1; Standard release = die Datei wie oben, byte-gleich): ohne
// erfundene Zugänge; --extra-stdin liest SCHLÜSSEL=Wert-Zeilen von stdin (die TEST_*-Werte aus .env
// und die Test-Schalter, beide aus scripts/lib/test_install_env.ps1), die einen Schlüssel an seiner Stelle ersetzen oder ans Ende kommen. Über stdin, damit
// kein Geheimnis in einer Befehlszeile steht (docker exec, Prozessliste). Diese Schlüssel kennt flow.allowedKeys nicht (keine
// Frage des Assistenten); welche der Installer sperrt, entscheidet sein Leser (release_inputs.sh _answers_load_wizard).
// Nur erfundene Werte (öffentliches Repo). Eine Pflichtfrage ohne erfundenen Wert bricht ab: eine neue Frage zwingt dazu, hier
// einen Wert zu ergänzen, statt dass der Lauf sie still leer lässt.
'use strict';
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');

// Erfundene Werte je Schlüssel (keine echten Zugänge; die Mock-Server im Lauf nehmen jedes Token).
const INVENTED = {
  OWNER_FIRST_NAME: 'Ci',
  OWNER_LAST_NAME: 'Runner',
  OWNER_BIRTH_DATE: '1990-01-01',
  OWNER_LANGUAGE: 'de',
};
const SECRETS = {
  TELEGRAM_BOT_TOKEN: '1000001:CIinventedTokenForMockTelegram0000',
  ANTHROPIC_API_KEY: 'sk-ant-api03-ci-invented-key-00000000000000000000',
};

// withExtra(flow, txt, extraText) -> txt mit ersetzten bzw. angehängten Schlüsseln; Fehler nennen Zeile und Schlüssel, nie den Wert.
function withExtra(flow, txt, extraText) {
  const m = flow.parseAnswers(txt);
  const seen = new Set();
  const lines = extraText.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  lines.forEach((l, i) => {
    const eq = l.indexOf('=');
    const k = eq > 0 ? l.slice(0, eq) : '';
    if (!/^[A-Z][A-Z0-9_]{0,63}$/.test(k)) throw new Error(`extra line ${i + 1}: expected KEY=value`);
    if (seen.has(k)) throw new Error(`extra line ${i + 1}: duplicate key ${k}`);
    seen.add(k);
    const pr = flow.valueProblem(l.slice(eq + 1));
    if (pr) throw new Error(`extra line ${i + 1}: bad value for ${k} (${pr})`);
    m.set(k, l.slice(eq + 1));
  });
  let out = '# lifeagents-answers v1\n';
  for (const [k, v] of m) out += `${k}=${v}\n`;
  return out;
}

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

function render({ flow, Q, reach, backup, what, packages = 'all', profile = 'release', extra = '' }) {
  if (!['tunnel', 'fritzbox'].includes(reach)) throw new Error('--reach tunnel|fritzbox');
  if (!backup) throw new Error('--backup <eltern-ordner>');
  if (!['release', 'dev'].includes(profile)) throw new Error('--profile release|dev');
  if (extra && profile !== 'dev') throw new Error('--extra-stdin only with --profile dev');
  const A = {
    __tg_have: 'both', __voice: 'no', __backup_choice: 'other', __backup_dir: backup,
    __packages: packages === 'none' ? [] : Q.packages.map((p) => p.id), __reach: reach,
  };
  if (reach === 'fritzbox') { A.__dslite = 'no'; A.__dslite_auto = 'yes'; A.__ports = 'free'; A.__fb_guide = 'seen'; }
  for (const id of flow.steps(Q, A)) {
    if (!/^[hcs]:/.test(id)) continue;
    const k = flow.envOf(Q, id);
    const q = flow.question(Q, id);
    if (!q || Object.prototype.hasOwnProperty.call(A, k)) continue;
    // Geheimnisse: release aus der Tabelle der erfundenen Werte (die Attrappen nehmen jedes Token); dev läuft ohne Attrappen
    // gegen echte Dienste, dort bleibt der Zugang leer, bis --extra-stdin den .env-Wert bringt.
    if (Object.prototype.hasOwnProperty.call(SECRETS, k)) { if (profile === 'dev') A[k] = ''; continue; }
    if (Object.prototype.hasOwnProperty.call(INVENTED, k)) A[k] = INVENTED[k];
    else if (k === 'OWNER_PERSONA') A[k] = (Q.personas && Q.personas[0] && Q.personas[0].code) || '';
    else if (id.startsWith('c:')) A[k] = '';                           // optionale Zugänge der Pakete bleiben leer
    else if (id.startsWith('s:')) continue;                            // Einstellungen: Vorgabe des Pakets
    else if (id === 'h:DOMAIN') continue;                              // FritzBox: die Adresse setzt der Lauf später selbst
    else if (q.required) throw new Error(`Pflichtfrage ohne erfundenen Wert: ${k} (in render_ci_answers.js ergänzen)`);
    else A[k] = '';
  }
  if (what === 'packages') return flow.packagesArg(Q, A);
  const txt = flow.renderAnswers(Q, flow.answerLines(Q, A, profile === 'dev' ? {} : SECRETS));
  if (profile !== 'dev') return txt;
  return withExtra(flow, txt, extra);
}

if (require.main === module) {
  const wiz = arg('wizard-dir', '/opt/lifeagents/provisioning/wizard');
  const flow = require(path.join(wiz, 'flow.js'));
  const qf = arg('questions-file', '');
  const Q = JSON.parse(qf ? fs.readFileSync(qf, 'utf8') : execFileSync('bash', [path.join(wiz, 'bridge.sh'), 'questions'], { encoding: 'utf8' }).trim().split('\n').pop());
  const extra = process.argv.includes('--extra-stdin') ? fs.readFileSync(0, 'utf8') : '';
  process.stdout.write(render({ flow, Q, reach: arg('reach', ''), backup: arg('backup', ''), what: arg('print', 'answers'),
    packages: arg('packages', 'all'), profile: arg('profile', 'release'), extra }));
}
module.exports = { render };
