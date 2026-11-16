// render_ci_answers.js — die Antwort-Datei für den kalten Docker-Lauf der CI, erzeugt mit dem Code des Einrichtungs-Assistenten
// (provisioning/wizard/flow.js: steps/answerLines/renderAnswers) und den Fragen der echten CLI-Quelle (bridge.sh questions),
// nicht von Hand nachgebaut. Läuft im master-Image (dort liegen flow.js und bridge.sh in der Form, die ein Nutzer bekommt):
//   docker cp tests/wizard/render_ci_answers.js <master>:/tmp/ && docker exec <master> node /tmp/render_ci_answers.js --reach tunnel|fritzbox --backup <eltern-ordner> > answers.env
// --packages none|all wählt die Module (Standard all). --print packages gibt stattdessen das Argument für `provision.sh --packages` aus (flow.packagesArg).
// Optionen: --wizard-dir <ordner> (Standard /opt/lifeagents/provisioning/wizard), --questions-file <json> (statt bridge.sh).
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

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}

function render({ flow, Q, reach, backup, what, packages = 'all' }) {
  if (!['tunnel', 'fritzbox'].includes(reach)) throw new Error('--reach tunnel|fritzbox');
  if (!backup) throw new Error('--backup <eltern-ordner>');
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
    if (Object.prototype.hasOwnProperty.call(SECRETS, k)) continue;   // geht über die Geheimnis-Tabelle
    if (Object.prototype.hasOwnProperty.call(INVENTED, k)) A[k] = INVENTED[k];
    else if (k === 'OWNER_PERSONA') A[k] = (Q.personas && Q.personas[0] && Q.personas[0].code) || '';
    else if (id.startsWith('c:')) A[k] = '';                           // optionale Zugänge der Pakete bleiben leer
    else if (id.startsWith('s:')) continue;                            // Einstellungen: Vorgabe des Pakets
    else if (id === 'h:DOMAIN') continue;                              // FritzBox: die Adresse setzt der Lauf später selbst
    else if (q.required) throw new Error(`Pflichtfrage ohne erfundenen Wert: ${k} (in render_ci_answers.js ergänzen)`);
    else A[k] = '';
  }
  if (what === 'packages') return flow.packagesArg(Q, A);
  return flow.renderAnswers(Q, flow.answerLines(Q, A, SECRETS));
}

if (require.main === module) {
  const wiz = arg('wizard-dir', '/opt/lifeagents/provisioning/wizard');
  const flow = require(path.join(wiz, 'flow.js'));
  const qf = arg('questions-file', '');
  const Q = JSON.parse(qf ? fs.readFileSync(qf, 'utf8') : execFileSync('bash', [path.join(wiz, 'bridge.sh'), 'questions'], { encoding: 'utf8' }).trim().split('\n').pop());
  process.stdout.write(render({ flow, Q, reach: arg('reach', ''), backup: arg('backup', ''), what: arg('print', 'answers'), packages: arg('packages', 'all') }));
}
module.exports = { render };
