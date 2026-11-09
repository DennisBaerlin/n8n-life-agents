// Prueft prepareChatApproval der echten n8n-Datei gegen ein ersetztes Telegram (nur apiRequest ist Attrappe).
// Aufruf: node hitl_chat_approval_cases.js <pfad zu Telegram/hitl/setup.js>
// Ausgabe: je Fall PASS/FAIL <id>; Exit = Anzahl FAIL. Laeuft ohne n8n-Prozess und ohne Netz.
'use strict';
const Module = require('module');
const path = require('path');

// realpath: im Docker-Abbild ist der npm-Pfad ein Symlink, Module._load meldet den echten pnpm-Pfad.
const setupPath = require('fs').realpathSync(path.resolve(process.argv[2]));
const req = Module.createRequire(setupPath);
const { NodeOperationError } = req('n8n-workflow');
const { buildResumeUrlSuffix } = req('n8n-core');

// Antwort-Drehbuch je Telegram-Methode: Eintrag = Error (wirft) oder Ergebnis-Objekt; der letzte Eintrag gilt weiter.
let script = {};
let calls = [];
const apiRequest = async function (_verb, method, body) {
  calls.push({ method, body });
  const list = script[method];
  if (!list) throw new Error(`unerwarteter Aufruf ${method}`);
  const step = list[Math.min(calls.filter((c) => c.method === method).length - 1, list.length - 1)];
  if (step instanceof Error) throw step;
  return step;
};
const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === '../GenericFunctions' && parent && parent.filename === setupPath) return { apiRequest };
  return origLoad.call(this, request, parent, isMain);
};
const { prepareChatApproval } = require(setupPath);

// Wartezeiten mitschreiben statt abwarten (erst nach dem Laden: n8n-core nutzt beim Import eigene Timer).
let delays = [];
const realSetTimeout = global.setTimeout;
global.setTimeout = (fn, ms, ...rest) => { if (ms > 0) delays.push(ms); return realSetTimeout(fn, 0, ...rest); };

const EXEC = '4711';
const NODE = { id: 'node-1', name: 'Owner approval', type: 'n8n-nodes-base.telegram', typeVersion: 1.2, position: [0, 0], parameters: {} };
function ctx({ chatApproval = true, responseType = 'approval', base = 'https://bot.example.com/webhook-waiting' } = {}) {
  const params = { chatApproval, responseType };
  return {
    getNodeParameter: (n, _i, d) => (n in params ? params[n] : d),
    getSignedResumeUrl: () => `${base}${buildResumeUrlSuffix(EXEC, NODE.id)}?signature=x`,
    getExecutionId: () => EXEC,
    getNode: () => NODE,
    getCredentials: async () => ({ accessToken: '123:abc' }),
    logger: { warn() {} },
  };
}
const NET = () => new Error('The connection to the server was closed unexpectedly');
const NO_HOOK = { result: { url: '', allowed_updates: [] } };
const TRIGGER = { result: { url: 'https://bot.example.com/webhook/abc/webhook', allowed_updates: [] } };
const FOREIGN = { result: { url: 'https://other.example.org/hook', allowed_updates: [] } };
const OK = { result: true };

const cases = [
  { id: 'aus_kein_aufruf', ctx: { chatApproval: false }, script: {}, want: false, calls: 0 },
  { id: 'kein_approval_typ', ctx: { responseType: 'freeText' }, script: {}, want: false, calls: 0 },
  { id: 'ohne_fehler_ein_versuch', script: { getWebhookInfo: [NO_HOOK], setWebhook: [OK] }, want: true, calls: 2, delays: [] },
  { id: 'info_einmal_fehl', script: { getWebhookInfo: [NET(), NO_HOOK], setWebhook: [OK] }, want: true, calls: 3, delays: [400] },
  { id: 'info_zweimal_fehl', script: { getWebhookInfo: [NET(), NET(), NO_HOOK], setWebhook: [OK] }, want: true, calls: 4, delays: [400, 1200] },
  { id: 'info_endgueltig_stopp', script: { getWebhookInfo: [NET()], setWebhook: [OK] }, throws: true, calls: 3, delays: [400, 1200], noSet: true },
  { id: 'set_einmal_fehl', script: { getWebhookInfo: [NO_HOOK], setWebhook: [NET(), OK] }, want: true, calls: 3, delays: [400] },
  { id: 'set_endgueltig_stopp', script: { getWebhookInfo: [NO_HOOK], setWebhook: [NET()] }, throws: true, calls: 4, delays: [400, 1200] },
  { id: 'trigger_besitzt_webhook', script: { getWebhookInfo: [TRIGGER] }, want: true, calls: 1, delays: [] },
  { id: 'fremder_webhook_stopp', script: { getWebhookInfo: [FOREIGN] }, throws: true, calls: 1, unchangedMsg: true },
  { id: 'http_stopp', ctx: { base: 'http://bot.example.com/webhook-waiting' }, script: {}, throws: true, calls: 0 },
  { id: 'localhost_stopp', ctx: { base: 'https://localhost/webhook-waiting' }, script: {}, throws: true, calls: 0 },
];

(async () => {
  let failed = 0;
  for (const c of cases) {
    script = c.script; calls = []; delays = [];
    let got, err, problem = '';
    try { got = await prepareChatApproval(ctx(c.ctx)); } catch (e) { err = e; }
    if (c.throws) {
      if (!(err instanceof NodeOperationError)) problem = `erwartet NodeOperationError, bekam ${err ? err.constructor.name + ': ' + err.message : 'Rueckgabe ' + got}`;
      else if (!c.unchangedMsg && !/nothing was saved/i.test(err.message)) problem = `Meldung ohne Hinweis: ${err.message}`;
    } else if (err) problem = `unerwarteter Fehler: ${err.message}`;
    else if (got !== c.want) problem = `Rueckgabe ${got}, erwartet ${c.want}`;
    if (!problem && calls.length !== c.calls) problem = `${calls.length} Telegram-Aufrufe, erwartet ${c.calls}`;
    if (!problem && c.delays && delays.join() !== c.delays.join()) problem = `Wartezeiten [${delays}], erwartet [${c.delays}]`;
    if (!problem && c.noSet && calls.some((x) => x.method === 'setWebhook')) problem = 'setWebhook trotz gescheiterter Abfrage';
    if (problem) failed++;
    console.log(problem ? `FAIL ${c.id}: ${problem}` : `PASS ${c.id}`);
  }
  process.exit(failed);
})();
