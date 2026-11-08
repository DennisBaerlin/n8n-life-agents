// flow.js — Ablauf des Wizards: welche Seite kommt wann, aus dem Fragen-Auszug der CLI (bridge.sh questions) und den
// bisherigen Antworten. Reine Funktionen ohne Ein-/Ausgabe, damit der Ablauf ohne Browser und ohne Server testbar ist.
//
// Reihenfolge wie die CLI (collect_release_inputs -> _ask_initial_packages -> collect_package_inputs), je Seite eine Frage
// (docs/reference/ui.md Regel 10). Bewusste Abweichungen, je mit Grund:
//   - Google-Schlüssel hinter einer Ja/Nein-Seite (Entwurf, vom Owner freigegeben): Laien sollen nicht vor einem leeren
//     Pflicht-Feld stehen, das optional ist.
//   - Je Paket zuerst die Einstellungen, dann die Zugänge (CLI: umgekehrt): die Live-Prüfung des Paperless-Zugangs
//     braucht die Adresse.
//   - DOMAIN nur beim FritzBox-Weg, mit eigener Erklärung: der CLI-Hilfetext beschreibt den eigenen Reverse Proxy.
'use strict';

// Schritt-Leiste über App und Wizard (Owner-Wunsch, mit Paket 6/7 vereinbart): Reihenfolge und ids nur im gemeinsamen
// Block ui.steps.js (Kopie aus config/, scripts/build_ui_tokens.ps1), Beschriftungen im Katalog core.wizard.step.<id>.
// Der Wizard zeichnet „questions“ mit Unterschritten, „install“ und „connect“; die App den Rest.
const HOST_SUB = {
  OWNER_LANGUAGE: 'about', OWNER_FIRST_NAME: 'about', OWNER_LAST_NAME: 'about', OWNER_BIRTH_DATE: 'about', OWNER_PERSONA: 'about',
  TELEGRAM_BOT_TOKEN: 'access', ANTHROPIC_API_KEY: 'access', GOOGLE_API_KEY: 'access', DOMAIN: 'reach',
};
// Eigene Reihenfolge in „Über dich“: Sprache zuerst (Entwurf), Charakter zuletzt.
const ABOUT_ORDER = ['OWNER_LANGUAGE', 'OWNER_FIRST_NAME', 'OWNER_LAST_NAME', 'OWNER_BIRTH_DATE', 'OWNER_PERSONA'];

function hostDef(Q, key) { return Q.host.find((h) => h.key === key) || null; }
function pkgDef(Q, id) { return Q.packages.find((p) => p.id === id) || null; }

// steps(Q, A) -> die Liste der Seiten-ids, die für diese Antworten gelten (ändert sich mit den Antworten).
function steps(Q, A) {
  const s = [];
  for (const k of ABOUT_ORDER) if (hostDef(Q, k)) s.push('h:' + k);
  // „Warum Telegram?“ (Owner): erst der Nutzen; dann je nach Bestand Handy (neues Konto nur dort), Rechner verbinden, zuletzt der Schlüssel.
  s.push('tg_why');
  if (A.__tg_have === 'none') s.push('tg_phone');
  if (A.__tg_have !== 'both') s.push('tg_pc');
  s.push('h:TELEGRAM_BOT_TOKEN');
  if (A.__tg_conflict && !A.__tg_choice) s.push('tg_busy');
  s.push('h:ANTHROPIC_API_KEY', 'voice');
  if (A.__voice === 'yes') s.push('h:GOOGLE_API_KEY');
  s.push('packages');
  const sel = Array.isArray(A.__packages) ? A.__packages : [];
  for (const p of Q.packages) {
    if (!sel.includes(p.id)) continue;
    for (const st of p.settings) s.push(`s:${p.id}:${st.id}`);
    for (const c of p.credentials) {
      c.keys.forEach((k, i) => {
        // „Beide oder keine“ wie _pkg_secrets_wizard: bleibt beim optionalen Zugang der erste Wert leer, entfällt der Rest.
        if (i > 0 && !c.required && c.keys.length > 1 && A[c.keys[0].env] === '') return;
        s.push(`c:${p.id}:${k.env}`);
      });
    }
  }
  s.push('reach');
  if (A.__reach === 'fritzbox') {
    // Sicher erkannt „eigene IPv4“ (__dslite_auto, Paket 3 reach_dslite): keine Seite; „keine eigene“ bleibt als Bestätigung.
    if (A.__dslite_auto !== 'no') s.push('fb_dslite');
    if (A.__dslite === 'no') {
      if (A.__ports === 'busy') s.push('fb_ports_busy');
      else s.push('fb_guide', 'h:DOMAIN');
    }
  }
  s.push('review', 'confirm', 'install', 'connect', 'handoff');
  return s;
}

// reachMode(A) -> 'tunnel' | 'fritzbox' (DS-Lite oder belegte Ports führen zum Tunnel, nie zum Löschen).
function reachMode(A) {
  return A.__reach === 'fritzbox' && A.__dslite === 'no' && A.__ports !== 'busy' ? 'fritzbox' : 'tunnel';
}

// answered(Q, A, id) -> ist die Seite beantwortet? (Fortsetzen nach einem Abbruch springt zur ersten offenen Seite.)
function answered(Q, A, id) {
  if (id.startsWith('h:') || id.startsWith('c:') || id.startsWith('s:')) return Object.prototype.hasOwnProperty.call(A, envOf(Q, id));
  switch (id) {
    case 'tg_why': return !!A.__tg_have;
    case 'tg_phone': return !!A.__tg_phone;
    case 'tg_pc': return !!A.__tg_pc;
    case 'tg_busy': return !!A.__tg_choice;
    case 'voice': return !!A.__voice;
    case 'packages': return Array.isArray(A.__packages);
    case 'reach': return !!A.__reach;
    case 'fb_dslite': return !!A.__dslite;
    case 'fb_guide': return !!A.__fb_guide;
    default: return false;
  }
}

// envOf(Q, id) -> der Schlüssel in der Antwort-Datei für eine Frage-Seite.
function envOf(Q, id) {
  const [kind, a, b] = id.split(':');
  if (kind === 'h') return a;
  if (kind === 'c') return b;
  if (kind === 's') { const p = pkgDef(Q, a); const st = p && p.settings.find((x) => x.id === b); return st ? st.env : null; }
  return null;
}

// question(Q, id) -> Definition einer Frage-Seite: {key, kind, label, help, secret, required, live, validateRef, choices, pkg}.
function question(Q, id) {
  const [kind, a, b] = id.split(':');
  if (kind === 'h') {
    const h = hostDef(Q, a);
    if (!h) return null;
    let k = h.secret ? 'secret' : 'text';
    let choices = null;
    if (a === 'OWNER_BIRTH_DATE') k = 'date';
    if (a === 'OWNER_LANGUAGE') { k = 'choice'; choices = Q.languages.map((l) => ({ value: l.code, label: l.name })); }
    if (a === 'OWNER_PERSONA') { k = 'choice'; choices = Q.personas.map((p) => ({ value: p.code, label: p.name })); }
    return { key: a, kind: k, label: h.label, help: h.help, secret: h.secret, required: h.required, live: h.live,
      validateRef: 'host:' + a, choices, pkg: null };
  }
  const p = pkgDef(Q, a);
  if (!p) return null;
  if (kind === 's') {
    const st = p.settings.find((x) => x.id === b);
    if (!st) return null;
    const choices = st.choices.length ? st.choices.map((c) => ({ value: c.value, label: c.label })) : null;
    return { key: st.env, kind: choices ? 'choice' : 'text', label: st.label, help: st.help, secret: false,
      required: false, live: false, validateRef: `cfg:${p.id}:${st.id}`, choices, pkg: p.id, setting: st.id };
  }
  if (kind === 'c') {
    for (const c of p.credentials) {
      const k = c.keys.find((x) => x.env === b);
      if (k) return { key: k.env, kind: k.secret ? 'secret' : 'text', label: k.label, help: k.help, secret: !!k.secret,
        required: false, live: false, validateRef: `cred:${p.id}:${k.env}`, choices: null, pkg: p.id, cred: c.id };
    }
  }
  return null;
}

// stepOf(id) -> {current, sub}: Platz einer Seite in der Schritt-Leiste.
function stepOf(id) {
  if (id === 'install' || id === 'connect') return { current: id, sub: null };
  if (id === 'handoff') return { current: 'connect', sub: null };   // letzte Seite des Wizards, danach übernimmt die App
  let sub = 'about';
  if (id.startsWith('h:')) sub = HOST_SUB[id.slice(2)] || 'about';
  else if (id.startsWith('s:') || id.startsWith('c:') || id === 'packages') sub = 'modules';
  else sub = ({ tg_why: 'access', tg_phone: 'access', tg_pc: 'access', tg_busy: 'access', voice: 'access', reach: 'reach', fb_dslite: 'reach', fb_ports_busy: 'reach', fb_guide: 'reach',
    review: 'check', confirm: 'check' })[id] || 'about';
  return { current: 'questions', sub };
}

// helpBlocks(text) -> [{p:"…"} | {ol:["…"]}]: die CLI-Hilfe (feste Zeilenbreite, „  1.“-Listen) als Absätze und Liste.
//   Zeilen mit einem Terminal-Befehl („lifeagents …“) entfallen, sie gelten nur für die CLI.
function helpBlocks(text) {
  const out = [];
  let para = null;
  let list = null;
  for (const raw of String(text || '').split('\n')) {
    const line = raw.trim();
    if (!line || /\blifeagents\s/.test(line)) { para = null; list = null; continue; }
    const m = /^(\d+)\.\s+(.*)$/.exec(line);
    if (m) {
      para = null;
      if (!list) { list = { ol: [] }; out.push(list); }
      list.ol.push(m[2]);
    } else if (list && /^\s{4,}/.test(raw)) {
      list.ol[list.ol.length - 1] += ' ' + line;   // eingerückte Fortsetzung eines Listenpunkts
    } else {
      list = null;
      if (!para) { para = { p: line }; out.push(para); } else para.p += ' ' + line;
    }
  }
  return out;
}

// Prüfregeln der Antwort-Datei (Vertrag mit dem Leser in Paket 1, Notiz di4-wizard-antwort-format.md).
const KEY_RE = /^[A-Z][A-Z0-9_]{0,63}$/;
// eslint-disable-next-line no-control-regex
const CTRL_RE = /[\u0000-\u001f\u007f]/;
const MAX_VALUE_BYTES = 4096;

// valueProblem(v) -> null oder der Grund, warum ein Wert nie in die Antwort-Datei darf.
function valueProblem(v) {
  if (typeof v !== 'string') return 'type';
  if (CTRL_RE.test(v)) return 'control';
  if (v !== v.trim()) return 'whitespace';
  if (Buffer.byteLength(v, 'utf8') > MAX_VALUE_BYTES) return 'length';
  return null;
}

// allowedKeys(Q) -> Positivliste aller Schlüssel, die der Wizard schreiben darf.
function allowedKeys(Q) {
  const k = new Set(['REACH_MODE', 'DOMAIN', 'TELEGRAM_WEBHOOK_TAKEOVER']);
  for (const h of Q.host) k.add(h.key);
  for (const p of Q.packages) {
    for (const st of p.settings) k.add(st.env);
    for (const c of p.credentials) for (const x of c.keys) k.add(x.env);
  }
  return k;
}

// answerLines(Q, A, secrets) -> [[KEY, wert], …] für die Antwort-Datei, nur Fragen der geltenden Seiten.
function answerLines(Q, A, secrets) {
  const out = [];
  const seen = new Set();
  const add = (k, v) => {
    if (seen.has(k)) return;
    seen.add(k);
    out.push([k, v]);
  };
  for (const id of steps(Q, A)) {
    const k = envOf(Q, id);
    if (!k) continue;
    const q = question(Q, id);
    if (q && q.secret) { if (Object.prototype.hasOwnProperty.call(secrets, k)) add(k, secrets[k]); else if (A[k] === '') add(k, ''); }
    else if (Object.prototype.hasOwnProperty.call(A, k)) add(k, A[k]);
  }
  if (A.__voice === 'no') add('GOOGLE_API_KEY', '');
  if (reachMode(A) !== 'fritzbox') add('DOMAIN', '');
  add('REACH_MODE', reachMode(A));
  // Prüfliste Nr. 10: der Nutzer hat einen schon anderswo verbundenen Bot ausdrücklich übernommen (sonst bricht der
  // Installer die unbeaufsichtigte Erstinstallation ab, telegram_webhook_preflight in Paket 1).
  if (A.__tg_conflict && A.__tg_choice === 'take') add('TELEGRAM_WEBHOOK_TAKEOVER', '1');
  return out;
}

// renderAnswers(Q, lines) -> der Datei-Inhalt; wirft bei jedem Verstoß gegen den Vertrag (nie still „reparieren“).
function renderAnswers(Q, lines) {
  const allowed = allowedKeys(Q);
  const seen = new Set();
  let txt = '# lifeagents-answers v1\n';
  for (const [k, v] of lines) {
    if (!KEY_RE.test(k) || !allowed.has(k)) throw new Error('answers: key not allowed: ' + k);
    if (seen.has(k)) throw new Error('answers: duplicate key: ' + k);
    seen.add(k);
    const pr = valueProblem(v);
    if (pr) throw new Error(`answers: bad value for ${k} (${pr})`);
    // Roh wie core.env: alles nach dem ersten = ist der Wert. Der Leser des Installers (install_answers_load) erkennt
    // diese Form an der Kopfzeile und setzt die Werte per printf -v, nie per source/eval.
    txt += `${k}=${v}\n`;
  }
  return txt;
}

// parseAnswers(text) -> Map: Referenz-Leser des Vertrags (ohne Ausführen), dieselben Regeln wie install_answers_load
//   (Kopfzeile, KEY=wert roh, keine Leer-/Kommentarzeile, kein doppelter Schlüssel, keine Steuerzeichen). Für Tests und Attrappe.
function parseAnswers(text) {
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  if (lines[0] !== '# lifeagents-answers v1') throw new Error('answers: header');
  const m = new Map();
  lines.slice(1).forEach((l, i) => {
    const eq = l.indexOf('=');
    const k = eq > 0 ? l.slice(0, eq) : '';
    const v = l.slice(eq + 1);
    if (!KEY_RE.test(k) || m.has(k) || CTRL_RE.test(v)) throw new Error('answers: line ' + (i + 2));
    m.set(k, v);
  });
  return m;
}

// paperlessGuess(ports, lanIp) -> vorausgefüllte Paperless-Adresse oder '' (Owner-Runde 2026-11-06: „wenn was gefunden
//   wird, sonst leer lassen“). Nur DIESER Rechner: ports = veröffentlichte Ports von Containern mit Paperless-Image
//   ([{ip, port}], aus runtime.sh), lanIp = Heimnetz-Adresse des Rechners (LA_HOST_IP aus hints.env der App). Ein Port nur an
//   127.0.0.1/::1 ist aus dem Verbund nicht erreichbar und zählt nicht. Genau ein Treffer -> http://<lanIp>:<port>; keiner
//   oder mehrere (mehrdeutig) -> ''. Bestätigt wird wie bei einer Eingabe per Live-Check.
const IPV4_RE = /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/;
function paperlessGuess(ports, lanIp) {
  if (!IPV4_RE.test(String(lanIp || '')) || /^(127\.|0\.)/.test(lanIp)) return '';
  const ok = new Set();
  for (const p of Array.isArray(ports) ? ports : []) {
    const ip = String((p && p.ip) || '');
    const port = Number(p && p.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) continue;
    if (!['', '0.0.0.0', '::', lanIp].includes(ip)) continue;   // 127.0.0.1, ::1 oder eine fremde Adresse: nicht von hier erreichbar
    ok.add(port);
  }
  return ok.size === 1 ? `http://${lanIp}:${[...ok][0]}` : '';
}

// MyFRITZ-Adresse (Owner-Wunsch über die Leitung, 2. Runde: „testen, bevor das vorgeschlagen wird“, Namen lassen sich in
//   der FritzBox umbenennen): die App liest die Kennung der FritzBox aus deren Zertifikat (LA_MYFRITZ_ZONE =
//   <kennung>.myfritz.net), den Namen, den die FritzBox selbst für den Rechner führt (LA_HOST_NAME_FRITZ), und weitere
//   mögliche Gerätenamen (LA_HOST_NAME_CANDIDATES). myfritzZone/myfritzCandidates prüfen streng, der FritzBox-Name zuerst.
//   domainCheck bewertet eine Adresse: öffentlich aufgelöst (lookup = async name -> [IPv4]) UND auf die öffentliche IPv4 des
//   Anschlusses (Paket 3) zeigend = 'ok'; aufgelöst ohne bekannte IPv4 = 'found'; aufgelöst, aber woandershin = 'wrong_ip';
//   nicht aufgelöst = 'pending' (Freigabe fehlt noch oder die FritzBox trägt sie gerade ein). myfritzGuess schlägt nur
//   eine Adresse mit 'ok' vor, sonst nichts.
const ZONE_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.myfritz\.net$/;
const LABEL_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;
function myfritzZone(z) { const v = String(z || '').trim().toLowerCase().replace(/\.$/, ''); return ZONE_RE.test(v) ? v : ''; }
function myfritzCandidates(fritzName, others) {
  const out = [];
  for (const c of `${fritzName || ''},${others || ''}`.toLowerCase().split(/[\s,]+/)) if (LABEL_RE.test(c) && !out.includes(c)) out.push(c);
  return out.slice(0, 8);
}
async function domainCheck(name, lookup, publicIp) {
  let addrs = [];
  try { addrs = await lookup(name); } catch (_) { addrs = []; }
  if (!Array.isArray(addrs) || !addrs.length) return 'pending';
  if (!IPV4_RE.test(String(publicIp || ''))) return 'found';
  return addrs.includes(publicIp) ? 'ok' : 'wrong_ip';
}
async function myfritzGuess(zone, candidates, lookup, publicIp) {
  if (!zone || !IPV4_RE.test(String(publicIp || ''))) return '';
  for (const c of candidates) {
    const name = `${c}.${zone}`;
    if (await domainCheck(name, lookup, publicIp) === 'ok') return name;
  }
  return '';
}

// Vorschläge vom Rechner (nur Vorschlag, änderbar): Sprache aus LA_USER_LANG („de“, „en-US“, „de_DE.UTF-8“) auf eine der
//   angebotenen Sprachen, Name aus LA_USER_FULLNAME am letzten Leerzeichen geteilt. Unbrauchbares = kein Vorschlag.
function userLanguage(lang, languages) {
  const code = String(lang || '').trim().toLowerCase().split(/[-_.@]/)[0];
  return (languages || []).some((l) => l.code === code) ? code : '';
}
function userName(full) {
  const v = String(full || '').trim().replace(/\s+/g, ' ');
  if (!v || valueProblem(v) || v.length > 120) return { first: '', last: '' };
  const i = v.lastIndexOf(' ');
  return i > 0 ? { first: v.slice(0, i), last: v.slice(i + 1) } : { first: v, last: '' };
}

// parseHints(text) -> {KEY: wert}: Vorschläge der Start-App aus /run/lifeagents-wizard/hints.env (flüchtig, 0600; Entscheid
//   der Leitung: keine Umgebungsvariablen, die stünden dauerhaft in `docker inspect`). Gelesen, nie ausgeführt, nach den
//   Regeln der Antwort-Datei ohne Kopfzeile: KEY=wert roh, kein doppelter Schlüssel, keine Steuerzeichen (ein CR am
//   Zeilenende wird geduldet). Eine verletzte Regel = gar kein Vorschlag; unbekannte Schlüssel und leere Werte zählen nicht.
const HINT_KEYS = ['LA_HOST_IP', 'LA_MYFRITZ_ZONE', 'LA_HOST_NAME_FRITZ', 'LA_HOST_NAME_CANDIDATES', 'LA_USER_FULLNAME', 'LA_USER_LANG'];
function parseHints(text) {
  if (typeof text !== 'string' || text.length > 8192) return {};
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  const out = {}; const seen = new Set();
  for (const raw of lines) {
    const l = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    const eq = l.indexOf('=');
    const k = eq > 0 ? l.slice(0, eq) : '';
    const v = l.slice(eq + 1);
    if (!KEY_RE.test(k) || seen.has(k) || CTRL_RE.test(v)) return {};
    seen.add(k);
    if (HINT_KEYS.includes(k) && v !== '') out[k] = v;
  }
  return out;
}

// webhookFailing(r, nowSec) -> true, wenn Telegram laut reach_status_json (Paket 3) gerade nicht bei diesem Rechner ankommt:
//   Fehlertext von getWebhookInfo, frisch (webhook_error_at jünger als 15 Min) und Nachrichten warten (webhook_pending > 0).
//   Fehlt Zeit oder Zähler, zählt der Fehlertext allein (lieber ein Hinweis zu viel als still warten).
function webhookFailing(r, nowSec) {
  if (!r || typeof r.webhook_error !== 'string' || r.webhook_error === '') return false;
  if (Number.isInteger(r.webhook_error_at) && nowSec - r.webhook_error_at > 900) return false;
  if (Number.isInteger(r.webhook_pending) && r.webhook_pending <= 0) return false;
  return true;
}

// packagesArg(Q, A) -> Wert für `provision.sh --packages` (der bestehende Weg der CLI): Komma-Liste oder none.
function packagesArg(Q, A) {
  const p = (A.__packages || []).filter((x) => pkgDef(Q, x));
  return p.length ? p.join(',') : 'none';
}

module.exports = { steps, reachMode, answered, envOf, question, stepOf, helpBlocks, valueProblem,
  allowedKeys, answerLines, renderAnswers, parseAnswers, packagesArg, paperlessGuess, myfritzZone, myfritzCandidates, domainCheck, myfritzGuess,
  userLanguage, userName, parseHints, webhookFailing, hostDef, pkgDef };
