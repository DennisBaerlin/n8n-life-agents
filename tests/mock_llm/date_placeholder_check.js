// Prueft die JS-Aufloesung der Datums-Platzhalter in server.js gegen tests/util/date_placeholder_vectors.json.
// Aufruf: node tests/mock_llm/date_placeholder_check.js   (aus dem Repo-Root; Exit-Code = Anzahl Fehler; Selbsttest-Treiber:
// scripts/dev/date_placeholder_test.ps1, der dieselben Werte gegen die PowerShell-Seite prueft).
'use strict';
const fs = require('fs');
const path = require('path');
const { datePlaceholderValue, resolveDatePlaceholders } = require('./server.js');

const v = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'util', 'date_placeholder_vectors.json'), 'utf8'));
let failed = 0;
function check(ok, name) { console.log((ok ? '  [PASS] ' : '  [FAIL] ') + name); if (!ok) failed++; }
function day(s) { const p = s.split('-').map(Number); return new Date(Date.UTC(p[0], p[1] - 1, p[2])); }

for (const x of v.vectors) check(datePlaceholderValue(x.expr, day(x.today)) === x.expect, 'js ' + x.today + ' {{date:' + x.expr + '}} = ' + x.expect);
for (const x of v.text) check(resolveDatePlaceholders(x.in, day(x.today)) === x.expect, 'js Text: ' + x.in);
for (const bad of v.invalid) {
  let threw = false;
  try { resolveDatePlaceholders(bad, day('2026-11-15')); } catch (e) { threw = true; }
  check(threw, 'js wirft bei ' + bad);
}
const deep = resolveDatePlaceholders({ match: 'am {{date:0d}}', args: { d: ['{{date:+1d}}'], n: 3 } }, day('2026-11-15'));
check(deep.match === 'am 2026-11-15' && deep.args.d[0] === '2026-11-16' && deep.args.n === 3, 'js loest verschachtelte Szenario-Objekte auf');
process.exit(failed);
