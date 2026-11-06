// wizard/ctl.js — Steuerkanal des Wizards für die Start-App (Paket 6), aufgerufen per `docker exec <master> node ctl.js …`.
//   issue | url        -> {"url":"http://127.0.0.1:<port>/start?t=…"}: neuer Einmal-Wert (10 Min, ersetzt jeden älteren)
//   status            -> {"phase":"questions|installing|failed|pairing|connected|handoff","step":"<seite>"}
//   finish | power-done -> {"ok":true}: Wizard löscht Fortschritt + Schlüssel und beendet sich (nach Dauerbetrieb/Fertig der App)
// Der Kanal ist ein Unix-Socket (0600 root) unter WIZARD_RUN_DIR — n8n im selben Netz-Namensraum erreicht ihn nicht.
'use strict';
const net = require('net');
const path = require('path');

// url und power-done = die Namen, mit denen die Start-App (Paket 6) ruft.
const ALIAS = { url: 'issue', 'power-done': 'finish' };
const cmd = ALIAS[process.argv[2]] || process.argv[2] || '';
if (!['issue', 'status', 'finish'].includes(cmd)) {
  process.stderr.write('Aufruf: node ctl.js url|status|power-done\n');
  process.exit(64);
}
const sock = path.join(process.env.WIZARD_RUN_DIR || '/run/lifeagents-wizard', 'ctl.sock');
let out = '';
const c = net.createConnection(sock, () => c.write(cmd + '\n'));
c.setTimeout(10000, () => { process.stderr.write('Wizard antwortet nicht.\n'); process.exit(1); });
c.on('data', (d) => { out += d; });
c.on('end', () => { process.stdout.write(out); process.exit(out.includes('"error"') ? 1 : 0); });
c.on('error', () => { process.stderr.write('Wizard läuft nicht.\n'); process.exit(1); });
