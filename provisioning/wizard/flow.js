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

// Phasen der Seitenleiste. Start, Vorbereiten, Dauerbetrieb und Fertig zeigt die App selbst (Paket 6/7); der Wizard
// zeigt sie mit, damit die Leiste über beide Fenster gleich bleibt.
const PHASES = ['Start', 'Vorbereiten', 'Über dich', 'Telegram', 'KI-Schlüssel', 'Funktionen', 'Erreichbarkeit',
  'Prüfen', 'Installieren', 'Verbinden', 'Dauerbetrieb', 'Fertig'];
const PH = Object.fromEntries(PHASES.map((p, i) => [p, i]));

// Host-Fragen in der Reihenfolge der CLI (_INSTALL_ENV_KEYS) mit ihrer Phase. TELEGRAM vor ANTHROPIC wie dort.
const HOST_PHASE = {
  OWNER_LANGUAGE: PH['Über dich'], OWNER_FIRST_NAME: PH['Über dich'], OWNER_LAST_NAME: PH['Über dich'],
  OWNER_BIRTH_DATE: PH['Über dich'], OWNER_PERSONA: PH['Über dich'], TELEGRAM_BOT_TOKEN: PH.Telegram,
  ANTHROPIC_API_KEY: PH['KI-Schlüssel'], GOOGLE_API_KEY: PH['KI-Schlüssel'],
};
// Eigene Reihenfolge in „Über dich“: Sprache zuerst (Entwurf), Charakter zuletzt.
const ABOUT_ORDER = ['OWNER_LANGUAGE', 'OWNER_FIRST_NAME', 'OWNER_LAST_NAME', 'OWNER_BIRTH_DATE', 'OWNER_PERSONA'];

function hostDef(Q, key) { return Q.host.find((h) => h.key === key) || null; }
function pkgDef(Q, id) { return Q.packages.find((p) => p.id === id) || null; }

// steps(Q, A) -> die Liste der Seiten-ids, die für diese Antworten gelten (ändert sich mit den Antworten).
function steps(Q, A) {
  const s = [];
  for (const k of ABOUT_ORDER) if (hostDef(Q, k)) s.push('h:' + k);
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
    s.push('fb_dslite');
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

// phaseOf(id) -> Index in PHASES.
function phaseOf(id) {
  if (id.startsWith('h:')) { const k = id.slice(2); return k === 'DOMAIN' ? PH.Erreichbarkeit : HOST_PHASE[k]; }
  if (id.startsWith('s:') || id.startsWith('c:') || id === 'packages') return PH.Funktionen;
  return ({ tg_busy: PH.Telegram, voice: PH['KI-Schlüssel'], reach: PH.Erreichbarkeit, fb_dslite: PH.Erreichbarkeit,
    fb_ports_busy: PH.Erreichbarkeit, fb_guide: PH.Erreichbarkeit, review: PH['Prüfen'], confirm: PH['Prüfen'],
    install: PH.Installieren, connect: PH.Verbinden, handoff: PH.Dauerbetrieb })[id] ?? PH['Über dich'];
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
  const k = new Set(['REACH_MODE', 'PACKAGES_SELECTED', 'DOMAIN']);
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
  add('PACKAGES_SELECTED', (A.__packages || []).filter((p) => pkgDef(Q, p)).join(','));
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
    txt += `${k}=${v}\n`;
  }
  return txt;
}

// parseAnswers(text) -> Map: der Leser des Vertrags (ohne Ausführen). Dient den Tests und der Attrappe als Referenz für
//   den Leser in Paket 1 (dort in bash).
function parseAnswers(text) {
  const lines = text.split('\n');
  if (lines[lines.length - 1] === '') lines.pop();
  if (lines[0] !== '# lifeagents-answers v1') throw new Error('answers: header');
  const m = new Map();
  lines.slice(1).forEach((l, i) => {
    const eq = l.indexOf('=');
    if (eq < 1) throw new Error('answers: line ' + (i + 2));
    const k = l.slice(0, eq);
    const v = l.slice(eq + 1);
    if (!KEY_RE.test(k) || m.has(k) || CTRL_RE.test(v)) throw new Error('answers: line ' + (i + 2));
    m.set(k, v);
  });
  return m;
}

module.exports = { PHASES, PH, steps, reachMode, answered, envOf, question, phaseOf, helpBlocks, valueProblem,
  allowedKeys, answerLines, renderAnswers, parseAnswers, hostDef, pkgDef };
