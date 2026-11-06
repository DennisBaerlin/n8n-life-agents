// wizard/server.js — der Einrichtungs-Wizard im Docker-Betrieb (Plan „Docker-Installer für Freunde“, Paket 4).
//
// WAS: sammelt im Fenster der Start-App die Antworten, die die CLI im Terminal fragt, und fährt danach den vorhandenen
//   Installer `provision.sh --unattended`. Er ersetzt keine Installer-Logik: Fragen und Prüfregeln kommen über
//   bridge.sh aus derselben Quelle wie die CLI (release_inputs.sh, Manifeste), der Ablauf steht in flow.js.
// SCHUTZ (Plan *Wizard-Sicherheit*): Er läuft im `master`, im selben Netz-Namensraum wie n8n. Darum
//   - Einmal-Wert nur im Arbeitsspeicher, ausgestellt über einen Unix-Socket, den nur root im master erreicht
//     (`node ctl.js issue`, die App ruft das per `docker exec`); jeder neue Wert macht den alten ungültig;
//   - strenge Host- und Origin-Prüfung (gegen DNS-Rebinding und fremde Seiten), Sitzungs-Cookie HttpOnly +
//     SameSite=Strict, CSRF-Wert in einem eigenen Kopf, nur JSON-Anfragen, Sec-Fetch-Site muss same-origin sein;
//   - CSP ohne Inline-Skript, kein Referrer, kein Caching, kein Einbetten;
//   - Fortschritt im Volume, Geheimnisse dort nur AES-256-GCM-verschlüsselt (Schlüssel getrennt, 0600 root);
//   - die Antwort-Datei für den Installer entsteht erst nach der zweiten Bestätigung (Prüfliste Nr. 14), flüchtig unter
//     /run, und wird nach dem Lauf gelöscht; ihr Format (KEY=wert roh, Positivliste) liest Paket 1 ohne Ausführen;
//   - der Fehlerbericht entsteht nur aus festen Feldern (Positivliste), nie aus Log-Text;
//   - nach „Fertig“ (`ctl.js finish`) löscht er Fortschritt und Schlüssel und beendet sich.
// Bewusst dependency-frei (nur Node-Core) wie das LLM-Gateway: kein npm install, keine Lieferkette.
'use strict';
const http = require('http');
const net = require('net');
const crypto = require('crypto');
const dns = require('dns');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const flow = require('./flow');
const qr = require('./qr');
const scan = require('./scan');

const VERSION = '1';
const PORT = parseInt(process.env.WIZARD_PORT || '8091', 10);
// Docker-Betrieb (LIFEAGENTS_RUNTIME=compose): der Rand `edge` veröffentlicht nur 127.0.0.1:${LA_WIZARD_PORT} des Rechners
// und reicht an anchor:8091 weiter — darum im Pod auf 0.0.0.0 lauschen, Host/Origin = die veröffentlichte Adresse (Caddy
// reicht Host unverändert durch). Schutz bleibt Einmal-Wert + Host/Origin + CSRF (n8n im selben Namensraum sieht den Port).
const COMPOSE = process.env.LIFEAGENTS_RUNTIME === 'compose';
const BIND = process.env.WIZARD_BIND || (COMPOSE ? '0.0.0.0' : '127.0.0.1');
const DEFAULT_ORIGIN = /^\d{1,5}$/.test(process.env.LA_WIZARD_PORT || '') ? `http://127.0.0.1:${process.env.LA_WIZARD_PORT}`
  : `http://127.0.0.1:${PORT},http://localhost:${PORT}`;
const ORIGINS = (process.env.WIZARD_PUBLIC_ORIGIN || DEFAULT_ORIGIN)
  .split(',').map((s) => s.trim().replace(/\/+$/, '').toLowerCase()).filter(Boolean);
const HOSTS = new Set(ORIGINS.map((o) => new URL(o).host));
const STATE_DIR = process.env.WIZARD_STATE_DIR || '/var/lib/lifeagents-wizard';
const RUN_DIR = process.env.WIZARD_RUN_DIR || '/run/lifeagents-wizard';
const KEY_FILE = process.env.WIZARD_KEY_FILE || '/etc/lifeagents/wizard.key';
const BRIDGE = process.env.WIZARD_BRIDGE || path.join(__dirname, 'bridge.sh');
const PROVISION = process.env.LA_PROVISION || path.join(__dirname, '..', 'provision.sh');
const LA_CLI = process.env.LA_CLI || 'lifeagents';
// Ausführliche FritzBox-Anleitung für den Docker-Weg (docs/site fritzbox.md, Abschnitt start-app, Paket 8).
const GUIDE_URL = process.env.WIZARD_GUIDE_URL || 'https://dennisbaerlin.github.io/n8n-life-agents/docs/fritzbox/#start-app';
const POLL_MS = Math.max(50, parseInt(process.env.WIZARD_POLL_MS || '1000', 10));
const TOKEN_TTL_MS = 10 * 60 * 1000;
const UI_DIR = path.join(__dirname, 'ui');
const PROGRESS = path.join(STATE_DIR, 'progress.json');
const LOG_FILE = path.join(STATE_DIR, 'provision.log');
// Merker „Einrichtung abgeschlossen“ (ohne Inhalt): der master startet den Wizard bei jedem Hochfahren; steht der Merker,
// endet der Server sofort, statt einen neuen Fragebogen zu beginnen (P1, compose: init + Ruhe-Prozess danach).
const DONE = path.join(STATE_DIR, 'done');
const ANSWERS = path.join(RUN_DIR, 'answers.env');
const RESULT = path.join(RUN_DIR, 'result.env');
const HINTS_FILE = path.join(RUN_DIR, 'hints.env');   // Vorschläge der Start-App, flow.parseHints
const CTL_SOCK = path.join(RUN_DIR, 'ctl.sock');

// --- Hilfen ----------------------------------------------------------------------------------------------------
function atomicWrite(file, data) {
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(tmp, data, { mode: 0o600 });
  fs.renameSync(tmp, file);
}
function rmQuiet(f) { try { fs.rmSync(f, { force: true }); } catch (_) { /* egal */ } }
function sha256(s) { return crypto.createHash('sha256').update(s).digest(); }
function safeEq(a, b) {
  const x = Buffer.from(String(a)); const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}
function rnd(n = 32) { return crypto.randomBytes(n).toString('base64url'); }

// Umgebung für Kind-Prozesse: nur, was sie brauchen (der Wizard selbst hat keine Geheimnisse in seiner Env).
function childEnv(extra) {
  const keep = ['PATH', 'LANG', 'LC_ALL', 'HOME', 'REPO_ROOT', 'LIFEAGENTS_LIB', 'LIFEAGENTS_TELEGRAM_API', 'LIFEAGENTS_RUNTIME',
    'COMPOSE_PROJECT_NAME', 'COMPOSE_FILE', 'TZ'];
  const env = {};
  for (const k of keep) if (process.env[k] !== undefined) env[k] = process.env[k];
  for (const k of Object.keys(process.env)) if (k.startsWith('LA_') || k.startsWith('WIZARD_FAKE_')) env[k] = process.env[k];
  return Object.assign(env, { LANG: env.LANG || 'C.UTF-8', LC_ALL: env.LC_ALL || 'C.UTF-8' }, extra || {});
}

// run(cmd, args, {input, env, timeoutMs}) -> {code, out}: stdout als Text, stderr verworfen (kann Werte zitieren).
function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    let out = '';
    let done = false;
    const p = spawn(cmd, args, { env: childEnv(opts.env), stdio: ['pipe', 'pipe', 'ignore'] });
    const t = setTimeout(() => { if (!done) p.kill('SIGKILL'); }, opts.timeoutMs || 30000);
    p.stdout.on('data', (d) => { if (out.length < 1 << 20) out += d; });
    p.on('error', () => { done = true; clearTimeout(t); resolve({ code: 127, out: '' }); });
    p.on('close', (code) => { done = true; clearTimeout(t); resolve({ code: code ?? 1, out }); });
    p.stdin.end(opts.input || '');
  });
}
async function runJson(cmd, args, opts) {
  const r = await run(cmd, args, opts);
  const line = r.out.trim().split('\n').pop() || '';
  try { return JSON.parse(line); } catch (_) { return null; }
}
const bridge = (args, opts) => runJson('bash', [BRIDGE, ...args], opts);
const laCli = (verb) => runJson(LA_CLI, ['household', 'pair-owner', '--machine', verb], { timeoutMs: 240000 });

// --- Geheimnisse: AES-256-GCM, Schlüssel getrennt vom Fortschritt -----------------------------------------------
function loadKey() {
  try {
    const k = fs.readFileSync(KEY_FILE);
    if (k.length === 32) return k;
  } catch (_) { /* neu anlegen */ }
  const k = crypto.randomBytes(32);
  fs.mkdirSync(path.dirname(KEY_FILE), { recursive: true });
  atomicWrite(KEY_FILE, k);
  return k;
}
let KEY = null;
function seal(name, value) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', KEY, iv);
  c.setAAD(Buffer.from(name));
  const ct = Buffer.concat([c.update(value, 'utf8'), c.final()]);
  return { iv: iv.toString('base64'), tag: c.getAuthTag().toString('base64'), ct: ct.toString('base64') };
}
function unseal(name, box) {
  const d = crypto.createDecipheriv('aes-256-gcm', KEY, Buffer.from(box.iv, 'base64'));
  d.setAAD(Buffer.from(name));
  d.setAuthTag(Buffer.from(box.tag, 'base64'));
  return Buffer.concat([d.update(Buffer.from(box.ct, 'base64')), d.final()]).toString('utf8');
}

// --- Zustand ---------------------------------------------------------------------------------------------------
// P = Fortschritt (gespeichert): cursor, A (Antworten, Geheimnisse dort nur als null = „eingetragen“), S (versiegelte
// Geheimnisse), phase, install, notes. SECRETS = entschlüsselt, nur im Speicher.
let Q = null;
let P = null;
const SECRETS = {};
function freshProgress() { return { v: 1, cursor: null, A: {}, S: {}, phase: 'questions', install: null, notes: {} }; }
function loadProgress() {
  try {
    const p = JSON.parse(fs.readFileSync(PROGRESS, 'utf8'));
    if (p && p.v === 1 && p.A && p.S) {
      for (const [k, box] of Object.entries(p.S)) {
        try { SECRETS[k] = unseal(k, box); } catch (_) { delete p.S[k]; delete p.A[k]; }
      }
      if (p.phase === 'installing') p.phase = 'failed';   // Lauf wurde unterbrochen (Neustart des Containers)
      return p;
    }
  } catch (_) { /* neu */ }
  return freshProgress();
}
function save() {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  atomicWrite(PROGRESS, JSON.stringify(P));
}
function setAnswer(q, value) {
  if (q.secret && value !== '') {
    SECRETS[q.key] = value;
    P.S[q.key] = seal(q.key, value);
    P.A[q.key] = null;
  } else {
    delete SECRETS[q.key]; delete P.S[q.key];
    P.A[q.key] = value;
  }
}

function list() { return flow.steps(Q, P.A); }
// Erste offene Frage-Seite vor der Übersicht, sonst die Übersicht.
function firstOpen() {
  const s = list();
  for (const id of s) {
    if (id === 'review') return 'review';
    if (!flow.answered(Q, P.A, id)) return id;
  }
  return 'review';
}
function cursor() {
  const s = list();
  if (P.phase === 'installing' || P.phase === 'failed') return 'install';
  if (P.phase === 'pairing') return 'connect';
  if (P.phase === 'handoff' || P.phase === 'connected') return 'handoff';
  if (!P.cursor || !s.includes(P.cursor) || ['install', 'connect', 'handoff'].includes(P.cursor)) P.cursor = firstOpen();
  return P.cursor;
}

// --- Seiten (View-Modell für ui/app.js) ------------------------------------------------------------------------
// --- Sprache der Einrichtung (Owner 2026-11-06: Antippen auf der Sprach-Seite stellt sofort alles um) --------------
// Texte aus dem Textkatalog der Pakete (packages/<pkg>/locales/<lang>.json, locale_lint prüft Vollständigkeit und
// Platzhalter): <pkg>.wizard.* (eigene Texte für das Fenster der App, „Rechner“ statt „Server“, ohne Terminal-Befehle),
// <pkg>.package.name/summary, core.persona.name.*. Fehlt ein Key, gilt Deutsch, dann der CLI-Text der Frage.
const PKG_DIR = process.env.WIZARD_PKG_DIR || path.join(__dirname, '..', '..', 'packages');
const CAT = {};
function loadCatalog() {
  let pkgs = [];
  try { pkgs = fs.readdirSync(PKG_DIR); } catch (_) { return; }
  for (const p of pkgs) {
    let files = [];
    try { files = fs.readdirSync(path.join(PKG_DIR, p, 'locales')); } catch (_) { continue; }
    for (const f of files) {
      const m = /^([a-z]{2,8})\.json$/.exec(f);
      if (!m) continue;
      let o = null;
      try { o = JSON.parse(fs.readFileSync(path.join(PKG_DIR, p, 'locales', f), 'utf8')); } catch (_) { continue; }
      const t = CAT[m[1]] || (CAT[m[1]] = {});
      for (const [k, v] of Object.entries(o || {})) {
        if (typeof v === 'string' && (k.includes('.wizard.') || /\.package\.(name|summary)$/.test(k) || /^core\.persona\.(name\.[a-z_]+|frame\.[a-z_]+\.1)$/.test(k))) t[k] = v;
      }
    }
  }
}
// uiLang — Sprache der Seiten: gewählt (P.ui_lang), sonst Vorschlag vom Rechner, sonst Deutsch.
function uiLang() {
  const langs = (Q && Q.languages) || [];
  if (P && P.ui_lang && langs.some((l) => l.code === P.ui_lang)) return P.ui_lang;
  return flow.userLanguage(hints().LA_USER_LANG, langs) || 'de';
}
function has(key) { return !!((CAT[uiLang()] || {})[key] || (CAT.de || {})[key]); }
function T(key, vars) {
  const l = uiLang();
  const s = (CAT[l] && CAT[l][key]) || (CAT.de && CAT.de[key]) || key;
  return vars ? s.replace(/\{([a-z_]+)\}/g, (m, k) => (vars[k] !== undefined ? String(vars[k]) : m)) : s;
}
// Texte der Fragen: Host-Fragen core.wizard.q.<key>, Paket-Einstellungen <pkg>.wizard.cfg_<cat>_<key>, Zugänge <pkg>.wizard.<env>.
function qKey(q) {
  if (!q.pkg) return `core.wizard.q.${q.key.toLowerCase()}`;
  return q.setting ? `${q.pkg}.wizard.cfg_${q.setting.replace(/\./g, '_')}` : `${q.pkg}.wizard.${q.key.toLowerCase()}`;
}
function qTitle(q) { const k = qKey(q) + '.title'; return has(k) ? T(k) : q.label; }
function qLabel(q) { const k = qKey(q) + '.label'; return has(k) ? T(k) : qTitle(q); }
function qHelp(q) {
  const k = qKey(q) + '.help';
  if (has(k)) return flow.helpBlocks(T(k));
  return has(qKey(q) + '.title') ? [] : flow.helpBlocks(q.help);
}
function pkgName(p) { return has(`${p.id}.package.name`) ? T(`${p.id}.package.name`) : p.name; }
function pkgSummary(p) { return has(`${p.id}.package.summary`) ? T(`${p.id}.package.summary`) : p.summary; }
// Auswahl einer Frage in der Sprache der Seite: Sprachen bleiben in Eigenschreibweise (Deutsch / English / 한국어), damit
//   man nach einem Verklicken zurückfindet; Charaktere aus core.persona.name.<code>. Für das Handy-Bild (di9, Owner-Wunsch)
//   je Charakter sein Zeichen (erstes Wort des Namens) und eine echte Sprechweise aus dem Katalog: frame = {sprache: Satz}
//   aus core.persona.frame.<code>.1, nur wo es den Satz in genau dieser Sprache gibt (Standard hat keinen).
function choicesOf(q) {
  if (!q.choices) return null;
  if (q.key === 'OWNER_PERSONA') {
    return q.choices.map((c) => {
      const name = has(`core.persona.name.${c.value}`) ? T(`core.persona.name.${c.value}`) : c.label;
      const de = (CAT.de || {})[`core.persona.name.${c.value}`] || '';
      const frame = {};
      for (const l of Object.keys(CAT)) { const s = CAT[l][`core.persona.frame.${c.value}.1`]; if (s) frame[l] = s; }
      const tok = de.split(' ')[0] || '';
      return { value: c.value, label: name, emoji: /\p{L}/u.test(tok) ? '' : tok, frame };
    });
  }
  return q.choices;
}
function setLang(code) {
  if (P.phase !== 'questions' || !((Q && Q.languages) || []).some((l) => l.code === code)) return { error: T('core.wizard.msg.choose') };
  P.ui_lang = code;
  save();
  return { ok: true };
}
// Texte der Knöpfe und festen Hinweise in ui/app.js (kommen mit jeder Seite, auch in die Vorschau-Bilder).
function uiTexts() {
  const o = {};
  for (const k of ['next', 'back', 'skip', 'retry', 'change', 'change_label', 'secret_kept', 'found_addresses', 'one_moment', 'report_show',
    'report_note', 'report_copied', 'offline', 'open_via_app', 'session_expired', 'doc_title']) o[k] = T(`core.wizard.ui.${k}`);
  o.choose = T('core.wizard.msg.choose');
  // Schritt-Leiste (gemeinsamer Block ui.steps.js): Beschriftung je id, Kurzform für schmale Fenster, Name für Vorleser.
  o.step = {};
  for (const id of ['prepare', 'docker', 'questions', 'about', 'access', 'modules', 'reach', 'check', 'install', 'connect', 'power', 'done']) {
    o.step[id] = T(`core.wizard.step.${id}`);
  }
  o.step_short = T('core.wizard.step.short');
  o.step_aria = T('core.wizard.step.aria');
  return o;
}

// Optionale CLI-Fragen, die der Wizard trotzdem nicht überspringen lässt (Grund an der Stelle in pageFor).
const NO_SKIP = ['DOMAIN', 'GOOGLE_API_KEY', 'OWNER_LANGUAGE', 'OWNER_PERSONA'];
const PAPERLESS_REASONS = ['localhost', 'invalid', 'unreachable', 'not_paperless', 'token_rejected', 'too_old'];

function optionsFor(id) {
  const o = (value, key, tag) => ({ value, label: T(`core.wizard.opt.${key}`), desc: T(`core.wizard.opt.${key}_desc`),
    tag: tag ? T('core.wizard.ui.recommended') : null });
  switch (id) {
    case 'voice': return [o('no', 'voice_no'), o('yes', 'voice_yes')];
    case 'tg_busy': return [o('new', 'tg_new', true), o('take', 'tg_take')];
    case 'reach': return [o('tunnel', 'reach_tunnel', true), o('fritzbox', 'reach_fritzbox')];
    case 'fb_dslite': return [o('no', 'dslite_no'), o('yes', 'dslite_yes')];
    case 'packages': return Q.packages.map((p) => ({ value: p.id, label: pkgName(p), desc: pkgSummary(p) }));
    default: return null;
  }
}

function pageFor(id) {
  const base = { id, step: flow.stepOf(id) };
  const q = flow.question(Q, id);
  if (q) {
    const key = q.key;
    const v = P.A[key];
    const next = T('core.wizard.ui.next');
    const page = Object.assign(base, {
      kind: q.kind, title: qTitle(q), help: qHelp(q), optional: !q.required,
      value: q.secret ? '' : (typeof v === 'string' ? v : ''), hasSecret: q.secret && v === null,
      options: choicesOf(q), next,
    });
    if (key === 'DOMAIN') {
      page.optional = false;
      Object.assign(page, domainView(v));
    }
    // Vorschläge vom Rechner (hints.env der App), nur solange nichts beantwortet ist, sichtbar als Vorschlag gekennzeichnet.
    const fromAccount = { kind: '', text: T('core.wizard.msg.from_account') };
    if (key === 'OWNER_LANGUAGE') {
      const hinted = flow.userLanguage(hints().LA_USER_LANG, Q.languages);
      page.value = v || P.ui_lang || hinted || 'de';
      page.langSwitch = true;   // ui/app.js: Antippen stellt die Seiten sofort um (/api/lang)
      if (!v && !P.ui_lang && hinted) page.note = fromAccount;
    }
    for (const [k, part] of [['OWNER_FIRST_NAME', 'first'], ['OWNER_LAST_NAME', 'last']]) {
      if (key !== k || v !== undefined) continue;
      page.value = flow.userName(hints().LA_USER_FULLNAME)[part];
      if (page.value) page.note = fromAccount;
    }
    if (q.setting === 'general.paperless_url' && v === undefined) Object.assign(page, paperlessSearchView());
    if (key === 'OWNER_PERSONA' && !v) page.value = 'neutral';
    // Google: „Nein“ auf der Seite davor ist das Überspringen; Sprache und Charakter haben eine Vorauswahl.
    if (NO_SKIP.includes(key)) page.optional = false;
    if (q.kind === 'date') page.placeholder = T('core.wizard.ui.date_placeholder');
    return page;
  }
  const next = T('core.wizard.ui.next');
  const P1 = (k) => [{ p: T(k) }];
  switch (id) {
    case 'tg_busy': return Object.assign(base, { kind: 'choice', title: T('core.wizard.page.tg_busy_title'), help: P1('core.wizard.page.tg_busy_help'),
      note: P.A.__tg_conflict && P.A.__tg_conflict !== 'polling' ? { kind: 'warn', text: T('core.wizard.page.tg_busy_previous', { host: P.A.__tg_conflict }) } : null,
      options: optionsFor(id), value: P.A.__tg_choice || 'new', next });
    case 'voice': return Object.assign(base, { kind: 'choice', title: T('core.wizard.page.voice_title'), help: P1('core.wizard.page.voice_help'),
      options: optionsFor(id), value: P.A.__voice || '', next });
    case 'packages': return Object.assign(base, { kind: 'multi', title: T('core.wizard.page.packages_title'), help: P1('core.wizard.page.packages_help'),
      options: optionsFor(id), value: P.A.__packages || [], next });
    case 'reach': return Object.assign(base, { kind: 'choice', title: T('core.wizard.page.reach_title'), help: P1('core.wizard.page.reach_help'),
      options: optionsFor(id), value: P.A.__reach || 'tunnel', next });
    case 'fb_dslite': return Object.assign(base, { kind: 'choice', title: T('core.wizard.page.dslite_title'), help: P1('core.wizard.page.dslite_help'),
      link: { href: GUIDE_URL, label: T('core.wizard.page.guide_pictures') },
      options: optionsFor(id), value: P.A.__dslite || '', next });
    case 'fb_ports_busy': return Object.assign(base, { kind: 'info', title: T('core.wizard.page.ports_busy_title'),
      help: [{ p: T('core.wizard.page.ports_busy_help') }, { p: T('core.wizard.page.ports_busy_help2') }],
      next: T('core.wizard.page.ports_busy_next') });
    case 'fb_guide': return Object.assign(base, { kind: 'info', title: T('core.wizard.page.fb_guide_title'), help: P1('core.wizard.page.fb_guide_help'),
      note: { kind: 'warn', text: T('core.wizard.page.fb_guide_note') },
      link: { href: GUIDE_URL, label: T('core.wizard.page.fb_guide_link') }, next: T('core.wizard.page.fb_guide_next') });
    case 'review': return Object.assign(base, { kind: 'review', title: T('core.wizard.page.review_title'), rows: reviewRows(),
      next: T('core.wizard.page.review_next') });
    case 'confirm': return Object.assign(base, { kind: 'confirm', title: T('core.wizard.page.confirm_title'), help: P1('core.wizard.page.confirm_help'),
      groups: confirmGroups(), next: T('core.wizard.page.confirm_next') });
    case 'install': return Object.assign(base, installView());
    case 'connect': return Object.assign(base, connectView());
    case 'handoff': return Object.assign(base, { kind: 'handoff', title: T('core.wizard.page.handoff_title'), note: keyExpiryNote(),
      help: [{ p: T(P.notes.welcome_sent ? 'core.wizard.page.handoff_welcome' : 'core.wizard.page.handoff_start') },
        { p: T('core.wizard.page.handoff_awake') }],
      next: P.phase === 'handoff' ? null : next, action: 'handoff', done: P.phase === 'handoff' });
    default: return Object.assign(base, { kind: 'info', title: '…' });
  }
}

// Paperless-Adresse finden (Owner-Runden 2026-11-06), nur auf deren Seite und nur, wenn das Modul Dokumente gewählt ist:
//   1) dieser Rechner: Paperless-Container mit veröffentlichtem Port (bridge.sh paperless-ports) + LA_HOST_IP aus hints.env;
//   2) sonst das eigene Heimnetz (scan.js: /24, typische Ports, Anmeldeseite als Erkennung).
//   Ein Treffer = vorausgefüllt, mehrere = Auswahl, keiner = leeres Feld. Die Live-Prüfung beim Weiter bleibt wie bisher.
let paperlessSearching = null;
function startPaperlessSearch() {
  if (paperlessSearching || (P.notes.paperless_search && P.notes.paperless_search.state === 'done')) return;
  P.notes.paperless_search = { state: 'running', found: [] };
  paperlessSearching = (async () => {
    const hostIp = hints().LA_HOST_IP;
    let found = [];
    const r = await bridge(['paperless-ports'], { timeoutMs: 20000 });
    const local = flow.paperlessGuess(r && r.ports, hostIp);
    if (local) found = [local];
    else found = await scan.scanPaperless({ hostIp, timeoutMs: parseInt(process.env.WIZARD_SCAN_TIMEOUT_MS || '400', 10) });
    P.notes.paperless_search = { state: 'done', found: found.slice(0, 8), local: !!local };
    save();
  })().catch(() => { P.notes.paperless_search = { state: 'done', found: [] }; }).finally(() => { paperlessSearching = null; });
}
function paperlessSearchView() {
  startPaperlessSearch();
  const s = P.notes.paperless_search || { state: 'running', found: [] };
  if (s.state === 'running') return { poll: true, note: { kind: '', text: T('core.wizard.paperless.searching'), busy: true } };
  if (s.found.length === 1) {
    return { value: s.found[0], note: { kind: '', text: s.local ? T('core.wizard.paperless.found_local')
      : T('core.wizard.paperless.found_lan') } };
  }
  if (s.found.length > 1) return { suggestions: s.found, note: { kind: '', text: T('core.wizard.paperless.found_many') } };
  return { note: { kind: '', text: T('core.wizard.paperless.found_none') } };
}

// MyFRITZ-Adresse: s. domainView unten.
// hints — Vorschläge der Start-App, bei jedem Gebrauch frisch gelesen (die App schreibt die Datei vor jedem `ctl.js url` neu).
//   Fehlt sie oder bricht sie eine Regel: keine Vorschläge. Werte nie loggen, nie in den Fehlerbericht.
//   Kurz zwischengespeichert (1 s): eine Seite fragt die Sprache dutzendfach ab.
let hintsCache = { at: 0, v: {} };
function hints() {
  if (Date.now() - hintsCache.at < 1000) return hintsCache.v;
  let v = {};
  try { v = flow.parseHints(fs.readFileSync(HINTS_FILE, 'utf8')); } catch (_) { /* keine Vorschläge */ }
  hintsCache = { at: Date.now(), v };
  return v;
}
function myfritzZone() { return flow.myfritzZone(hints().LA_MYFRITZ_ZONE); }
let domainSearching = null;
// dnsLookup — öffentliche Auflösung (nicht der Resolver des Heimnetzes, der eine MyFRITZ-Adresse auf die Box selbst biegen
//   kann): WIZARD_DNS_SERVERS, sonst zwei öffentliche Resolver. Fehler = keine Adresse.
const DNS_SERVERS = (process.env.WIZARD_DNS_SERVERS || '1.1.1.1,9.9.9.9').split(',').filter(Boolean);
function dnsLookup(name) {
  // Nur Tests: WIZARD_FAKE_DNS = „name=ipv4,name=ipv4“ (deterministisch, ohne Netz).
  if (process.env.WIZARD_FAKE_DNS !== undefined) {
    return Promise.resolve(process.env.WIZARD_FAKE_DNS.split(',').map((e) => e.split('=')).filter(([n, ip]) => n === name && ip).map(([, ip]) => ip));
  }
  const r = new dns.Resolver({ timeout: 1500, tries: 1 });
  try { r.setServers(DNS_SERVERS); } catch (_) { /* Standard-Resolver */ }
  return r.resolve4(name).catch(() => []);
}
// publicIp — öffentliche IPv4 des Anschlusses von Paket 3 (bridge public-ip); leer = unbekannt, dann wird nichts vorgeschlagen.
async function publicIp() {
  const r = await bridge(['public-ip'], { timeoutMs: 20000 });
  return r && typeof r.ip === 'string' ? r.ip : '';
}
// MyFRITZ-Adresse (Seite h:DOMAIN, flow.domainCheck): vorgeschlagen wird nur eine GEPRÜFTE volle Adresse (löst öffentlich auf
//   und zeigt auf diesen Anschluss), mit Hinweis. Sonst steht .<zone> fest hinter dem Feld, der Name der FritzBox ist ein
//   anklickbarer Vorschlag (nicht eingetragen) und die Seite prüft beim Tippen live (POST /api/check). Ohne Zone wie bisher.
function domainView(v) {
  const zone = myfritzZone();
  if (!zone) return {};
  const h = hints();
  const cands = flow.myfritzCandidates(h.LA_HOST_NAME_FRITZ, h.LA_HOST_NAME_CANDIDATES);
  if (!P.notes.domain_guess && !domainSearching) {
    P.notes.domain_guess = { state: 'running' };
    domainSearching = publicIp()
      .then((ip) => flow.myfritzGuess(zone, cands, dnsLookup, ip))
      .then((name) => { P.notes.domain_guess = { state: 'done', name }; save(); })
      .catch(() => { P.notes.domain_guess = { state: 'done', name: '' }; })
      .finally(() => { domainSearching = null; });
  }
  const s = P.notes.domain_guess || { state: 'running' };
  if (s.state === 'running') return { poll: true, note: { kind: '', text: T('core.wizard.domain.searching'), busy: true } };
  if (s.name) return { value: v || s.name, note: { kind: '', text: T('core.wizard.domain.verified') } };
  const prefix = v && v.endsWith('.' + zone) ? v.slice(0, -zone.length - 1) : (v || '');
  return { value: prefix, suffix: '.' + zone, placeholder: 'meinrechner', suggestions: cands.slice(0, 1),
    suggestLabel: T('core.wizard.domain.suggest_label'), live: { recheck: T('core.wizard.domain.recheck') },
    note: { kind: '', text: T('core.wizard.domain.suffix') } };
}
// liveCheck — Prüfung beim Tippen (nur MyFRITZ mit Zone): ändert nichts am Stand, meldet nur, ob die Adresse schon stimmt.
async function liveCheck(id, raw) {
  const zone = id === 'h:DOMAIN' ? myfritzZone() : '';
  const name = String(raw || '').trim().toLowerCase();
  if (!zone || P.phase !== 'questions' || !/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(name)) return { ok: true, live: null };
  const state = await flow.domainCheck(`${name}.${zone}`, dnsLookup, await publicIp());
  return { ok: true, live: { state, text: T(`core.wizard.domain.live_${state}`) } };
}

function labelOf(id, value) {
  const q = flow.question(Q, id);
  const ch = q && choicesOf(q);
  if (ch) { const c = ch.find((x) => x.value === value); return c ? c.label : value; }
  return value;
}
// Datum wie in der gewählten Sprache (Muster aus languages.list im Core-Manifest).
function showDate(iso) {
  const [y, m, d] = iso.split('-');
  return ({ en: `${d}/${m}/${y}`, ko: `${y}. ${m}. ${d}.` })[uiLang()] || `${d}.${m}.${y}`;
}
function reviewRows() {
  const rows = [];
  const s = list();
  for (const id of s) {
    if (id === 'review') break;
    const q = flow.question(Q, id);
    if (q) {
      const v = P.A[q.key];
      let shown;
      if (q.secret) shown = T(v === null ? 'core.wizard.review.entered' : 'core.wizard.review.skipped');
      else if (q.kind === 'date' && /^\d{4}-\d{2}-\d{2}$/.test(v || '')) shown = showDate(v);
      else shown = v ? labelOf(id, v) : T('core.wizard.review.skipped');
      if (q.key === 'GOOGLE_API_KEY') continue;   // steht schon in der Zeile „Sprachnachrichten“
      const pk = q.pkg ? pkgName(flow.pkgDef(Q, q.pkg)) + ': ' : '';
      rows.push({ label: pk + qLabel(q), value: shown, goto: id });
    } else if (id === 'voice') {
      rows.push({ label: T('core.wizard.review.voice'), value: T(P.A.__voice === 'yes' ? 'core.wizard.review.voice_yes' : 'core.wizard.review.voice_no'), goto: id });
    } else if (id === 'packages') {
      const n = (P.A.__packages || []).map((p) => flow.pkgDef(Q, p)).filter(Boolean).map(pkgName);
      rows.push({ label: T('core.wizard.review.packages'), value: n.length ? T('core.wizard.review.base_plus', { list: n.join(', ') }) : T('core.wizard.review.base_only'), goto: id });
    } else if (id === 'reach') {
      rows.push({ label: T('core.wizard.review.reach'), value: T(flow.reachMode(P.A) === 'fritzbox' ? 'core.wizard.review.reach_fritzbox' : 'core.wizard.review.reach_tunnel'), goto: id });
    }
  }
  return rows;
}
function confirmGroups() {
  const mode = flow.reachMode(P.A);
  return [
    { title: T('core.wizard.confirm.new_title'), items: [T('core.wizard.confirm.new_area'),
      T(mode === 'fritzbox' ? 'core.wizard.confirm.new_fritzbox' : 'core.wizard.confirm.new_tunnel'), T('core.wizard.confirm.new_bot')] },
    { title: T('core.wizard.confirm.keep_title'), items: [T('core.wizard.confirm.keep_programs'), T('core.wizard.confirm.keep_files'),
      T('core.wizard.confirm.keep_energy')] },
  ];
}

// Fortschritt der Installation: die Schritt-Codes aus provision.sh (ui_step <text> <stage>) in sechs Gruppen.
const STAGE_GROUPS = [
  ['check', ['preflight']],
  ['programs', ['base', 'n8n', 'gateway']],
  ['database', ['backup', 'postgres', 'schema']],
  ['access', ['access']],
  ['bot', ['workflows', 'packages', 'cli']],
  ['final', ['final']],
];
function installView() {
  const ins = P.install || {};
  const g = STAGE_GROUPS.findIndex(([, st]) => st.includes(ins.stage));
  const at = P.phase === 'installing' || P.phase === 'failed' ? Math.max(0, g) : STAGE_GROUPS.length;
  const failed = P.phase === 'failed';
  const stage = (k) => T(`core.wizard.stage.${k}`);
  return { kind: 'install', title: T(failed ? 'core.wizard.install.failed_title' : 'core.wizard.install.title'),
    help: failed ? [] : [{ p: T('core.wizard.install.help') }],
    items: STAGE_GROUPS.map(([k], i) => ({ text: stage(k), state: i < at ? 'ok' : i === at ? (failed ? 'bad' : 'run') : '' })),
    failed, note: failed ? { kind: 'bad', text: T('core.wizard.install.failed_note', { step: stage(STAGE_GROUPS[Math.max(0, g)][0]) }) } : null,
    poll: P.phase === 'installing' };
}

// Verbinden: beim Tunnel erst die Anmeldung bei Tailscale (Paket 3 meldet den Zustand), dann das Pairing per QR-Code.
// Texte je Zustand des Tunnels (Paket 3, Katalog core.wizard.reach.*). Knöpfe zeigen nur Adressen von login.tailscale.com (TS_URL).
const REACH_TEXT = {
  starting: { title: 'starting_title', help: 'starting_help', wait: 'starting_wait' },
  needs_login: { title: 'needs_login_title', help: 'needs_login_help', link: 'login_link', wait: 'login_wait' },
  needs_machine_auth: { title: 'needs_machine_auth_title', help: 'needs_machine_auth_help', link: 'needs_machine_auth_link', wait: 'needs_machine_auth_wait' },
  needs_funnel: { title: 'needs_funnel_title', help: 'needs_funnel_help', link: 'needs_funnel_link', wait: 'needs_funnel_wait' },
  key_expired: { title: 'key_expired_title', help: 'key_expired_help', link: 'login_link', wait: 'login_wait' },
  ports_busy: { title: 'ports_busy_title', help: 'ports_busy_help', note: 'ports_busy_note', retry: true },
};
// keyExpiryNote — Tunnel: Tailscale meldet Geräte nach einer Frist ab (Standard 180 Tage), dann schweigt der Bot. Unter 30
//   Tagen (Paket 3: key_days_left) ein Hinweis, wie man den Ablauf abschaltet.
function keyExpiryNote() {
  const t = P.notes.connect && P.notes.connect.tunnel;
  if (!t || t.days === null || t.days === undefined || t.days >= 30 || flow.reachMode(P.A) !== 'tunnel') return null;
  return { kind: 'warn', text: T('core.wizard.connect.key_expiry', { days: t.days }) };
}
// webhookNote — Zustellfehler verständlich erklären, mit dem nächsten Schritt je Weg, statt still zu warten.
function webhookNote(c) {
  const w = c.webhook;
  if (!w) return null;
  if (w.state === 'foreign') return { kind: 'warn', text: T('core.wizard.webhook.foreign') };
  if (!w.error) return null;
  return { kind: 'warn', text: T(flow.reachMode(P.A) === 'fritzbox' ? 'core.wizard.webhook.fritzbox' : 'core.wizard.webhook.tunnel') };
}
function connectView() {
  const c = P.notes.connect || {};
  const C = (k) => T(`core.wizard.connect.${k}`);
  const v = { kind: 'connect', title: C('title'), poll: true };
  if (c.activating || (c.tunnel && c.tunnel.state === 'pending_activation')) {
    return Object.assign(v, { help: [{ p: C('activating') }], wait: C('activating_wait') });
  }
  const R = c.tunnel && REACH_TEXT[c.tunnel.state];
  if (R) {
    const t = (k) => (R[k] ? T(`core.wizard.reach.${R[k]}`) : null);
    // Geräte-Freigabe: Paket 3 liefert keinen Link, die Geräteliste im Konto hat eine feste Adresse.
    const href = c.tunnel.url || (c.tunnel.state === 'needs_machine_auth' ? 'https://login.tailscale.com/admin/machines' : '');
    return Object.assign(v, { title: t('title'), help: [{ p: t('help') }], note: R.note ? { kind: 'warn', text: t('note') } : null,
      link: href ? { href, label: t('link'), primary: true } : null,
      wait: R.wait ? (href || !R.link ? t('wait') : T('core.wizard.reach.starting_wait')) : null,
      poll: !R.retry, action: R.retry ? 'connect_retry' : null, next: R.retry ? C('check_again') : null });
  }
  if (c.problem) {
    return Object.assign(v, { help: [{ p: C('not_reaching') }], note: { kind: 'warn', text: problemText(c.problem) },
      poll: false, action: 'connect_retry', next: C('check_again') });
  }
  if (c.expired) return Object.assign(v, { help: [{ p: C('expired') }], poll: false, action: 'pair_new', next: C('new_code') });
  if (PAIR) {
    return Object.assign(v, { qr: PAIR.qr, link: { href: PAIR.link, label: C('open_link') },
      help: [{ p: C('scan') }, { p: C('tap_start') }, { p: C('code_valid') }],
      note: webhookNote(c),
      wait: C(c.connected ? 'connected_wait' : 'waiting') });
  }
  return Object.assign(v, { help: [{ p: C('preparing') }], wait: C('preparing_wait') });
}
// problemText — Grund beim Verbinden: eigene Codes aus dem Katalog; ein Text der CLI (deutsch) nur auf Deutsch, sonst allgemein.
function problemText(p) {
  if (p === 'code_failed' || p === 'activation_failed') return T(`core.wizard.connect.${p}`);
  return uiLang() === 'de' ? p : T('core.wizard.connect.not_reaching');
}

function view() {
  const id = cursor();
  const page = pageFor(id);
  const s = list();
  const i = s.indexOf(id);
  page.canBack = P.phase === 'questions' && i > 0 && !['install', 'connect', 'handoff'].includes(id);
  page.lang = uiLang();
  page.t = uiTexts();
  return page;
}

// --- Antworten ------------------------------------------------------------------------------------------------
async function answer(id, raw, skip) {
  if (P.phase !== 'questions' || id !== cursor()) return { error: T('core.wizard.msg.not_open') };
  const q = flow.question(Q, id);
  if (q) {
    if (typeof raw !== 'string' || /[\r\n]/.test(raw)) return { error: T('core.wizard.msg.line') };
    const value = raw.trim();
    if (flow.valueProblem(value) === 'control') return { error: T('core.wizard.msg.line') };
    if (flow.valueProblem(value) === 'length') return { error: T('core.wizard.msg.invalid') };
    // Schon eingetragenes Geheimnis + leeres Feld = behalten (die Seite zeigt Geheimnisse nie wieder an).
    if (value === '' && !skip && q.secret && P.A[q.key] === null) { P.cursor = firstOpen(); save(); return { ok: true }; }
    if (value === '' && (q.required || NO_SKIP.includes(q.key))) return { error: T(q.choices ? 'core.wizard.msg.choose' : 'core.wizard.msg.empty') };
    if (value !== '' && skip) return { error: T('core.wizard.msg.invalid') };
    let check = null;
    let note = null;
    let v = value;
    // MyFRITZ mit fester Zone: eingegeben wird nur der Gerätename vorne (domainView), die Zone hängt der Server an.
    const zone = q.key === 'DOMAIN' ? myfritzZone() : '';
    if (zone && /^[A-Za-z0-9-]{1,63}$/.test(v)) v = `${v}.${zone}`;
    if (v !== '') {
      const r = await bridge(['validate', q.validateRef], { input: v, timeoutMs: 30000 });
      if (!r) return { error: T('core.wizard.msg.no_reply') };
      // Grund der CLI-Prüfung (deutsch) nur auf Deutsch, sonst der allgemeine Satz.
      if (r.rc === 1) return { error: r.problem && uiLang() === 'de' ? r.problem + '.' : T('core.wizard.msg.invalid') };
      if (r.rc === 2) note = T('core.wizard.msg.offline');
      if (typeof r.value === 'string' && r.value !== '') v = r.value;
      // Paperless (Plan *Die Module wie in der CLI*): Adresse, Version und Zugang live prüfen.
      if (q.pkg === 'paperless') {
        const url = q.setting === 'general.paperless_url' ? v : (P.A.CONFIG_GENERAL_PAPERLESS_URL || '');
        const token = q.cred ? v : (SECRETS.PAPERLESS_API_TOKEN || '');   // neue Adresse: vorhandenen Zugang gleich mitprüfen
        if (url) {
          const pc = await bridge(['paperless-check'], { input: `${url}\n${token}\n`, timeoutMs: 20000 });
          if (pc && !pc.ok) return { error: T(PAPERLESS_REASONS.includes(pc.reason) ? `core.wizard.paperless.${pc.reason}` : 'core.wizard.msg.invalid') };
          if (pc && pc.ok) check = pc.version ? T(token ? 'core.wizard.check.paperless_access' : 'core.wizard.check.paperless', { version: pc.version }) : T('core.wizard.check.paperless_answers');
        }
      }
    }
    setAnswer(q, v);
    if (q.key === 'OWNER_LANGUAGE') P.ui_lang = v;   // die Einrichtung spricht ab hier die gewählte Sprache
    if (q.key === 'TELEGRAM_BOT_TOKEN') {
      delete P.A.__tg_conflict; delete P.A.__tg_choice; delete P.notes.bot;
      if (v) {
        const t = await bridge(['tg-check'], { env: { TELEGRAM_BOT_TOKEN: v }, timeoutMs: 30000 });
        if (t && t.ok) {
          if (/^[A-Za-z0-9_]{1,64}$/.test(t.bot || '')) { check = T('core.wizard.check.bot', { bot: t.bot }); P.notes.bot = t.bot; }
          if (t.webhook_host) P.A.__tg_conflict = String(t.webhook_host).slice(0, 253);
          else if (t.polling_conflict) P.A.__tg_conflict = 'polling';
        }
      }
    }
    P.cursor = firstOpen();
    save();
    return { ok: true, check, note };
  }
  switch (id) {
    case 'tg_busy':
      if (!['new', 'take'].includes(raw)) return { error: T('core.wizard.msg.choose') };
      if (raw === 'new') {
        delete P.A.__tg_conflict; delete P.A.__tg_choice; delete P.notes.bot;
        delete P.A.TELEGRAM_BOT_TOKEN; delete P.S.TELEGRAM_BOT_TOKEN; delete SECRETS.TELEGRAM_BOT_TOKEN;
        P.cursor = 'h:TELEGRAM_BOT_TOKEN';
        save();
        return { ok: true };
      }
      P.A.__tg_choice = 'take';
      break;
    case 'voice':
      if (!['yes', 'no'].includes(raw)) return { error: T('core.wizard.msg.choose') };
      P.A.__voice = raw;
      if (raw === 'no') { delete P.S.GOOGLE_API_KEY; delete SECRETS.GOOGLE_API_KEY; P.A.GOOGLE_API_KEY = ''; }
      else if (P.A.GOOGLE_API_KEY === '') delete P.A.GOOGLE_API_KEY;
      break;
    case 'packages': {
      if (!Array.isArray(raw) || raw.some((p) => typeof p !== 'string' || !flow.pkgDef(Q, p))) return { error: T('core.wizard.msg.choose') };
      P.A.__packages = Q.packages.map((p) => p.id).filter((p) => raw.includes(p));
      break;
    }
    case 'reach':
      if (!['tunnel', 'fritzbox'].includes(raw)) return { error: T('core.wizard.msg.choose') };
      P.A.__reach = raw;
      delete P.A.__ports;   // bei jeder Wahl neu messen: ein inzwischen beendetes Programm gibt den Weg wieder frei
      if (raw === 'fritzbox') {
        // Prüfliste Nr. 13: Ports 80/443 belegt? Gemessen über die Brücke (rt_host_port_free); unbekannt = weiter.
        const r = await bridge(['reach-ports'], { timeoutMs: 20000 });
        if (r && r.state === 'busy') P.A.__ports = 'busy';
      }
      break;
    case 'fb_dslite':
      if (!['yes', 'no'].includes(raw)) return { error: T('core.wizard.msg.choose') };
      P.A.__dslite = raw;
      break;
    case 'fb_guide': P.A.__fb_guide = true; break;
    case 'fb_ports_busy': P.A.__reach = 'tunnel'; break;
    case 'review': P.cursor = 'confirm'; save(); return { ok: true };
    case 'confirm': return startInstall();
    default: return { error: T('core.wizard.msg.unknown_page') };
  }
  P.cursor = firstOpen();
  save();
  return { ok: true };
}

function back() {
  if (P.phase !== 'questions') return;
  const s = list();
  const i = s.indexOf(cursor());
  if (i > 0) { P.cursor = s[i - 1]; save(); }
}
function gotoStep(id) {
  if (P.phase !== 'questions' || !['review', 'confirm'].includes(cursor())) return { error: T('core.wizard.msg.change_in_review') };
  if (!list().includes(id) || ['review', 'confirm', 'install', 'connect', 'handoff'].includes(id)) return { error: T('core.wizard.msg.unknown_item') };
  P.cursor = id;
  save();
  return { ok: true };
}

// --- Installation ---------------------------------------------------------------------------------------------
let child = null;
function readResult() {
  const out = {};
  try {
    for (const l of fs.readFileSync(RESULT, 'utf8').split('\n')) {
      const m = /^([a-z_]+)=(.*)$/.exec(l);
      if (m) out[m[1]] = m[2];
    }
  } catch (_) { /* noch nichts */ }
  return out;
}
function startInstall() {
  if (child) return { ok: true };
  const open = list().find((id) => id !== 'review' && list().indexOf(id) < list().indexOf('review') && !flow.answered(Q, P.A, id));
  if (open) { P.cursor = open; save(); return { error: T('core.wizard.msg.missing') }; }
  let txt;
  try { txt = flow.renderAnswers(Q, flow.answerLines(Q, P.A, SECRETS)); } catch (_) { return { error: T('core.wizard.msg.bad_answer') }; }
  fs.mkdirSync(RUN_DIR, { recursive: true, mode: 0o700 });
  rmQuiet(RESULT);
  atomicWrite(ANSWERS, txt);
  fs.mkdirSync(STATE_DIR, { recursive: true });
  const log = fs.openSync(LOG_FILE, 'a', 0o600);
  P.phase = 'installing';
  P.install = { stage: '', status: 'running', started: new Date().toISOString() };
  save();
  child = spawn('bash', [PROVISION, '--profile', 'release', '--unattended', ANSWERS, '--packages', flow.packagesArg(Q, P.A)],
    { env: Object.assign({}, process.env, { LIFEAGENTS_RESULT_FILE: RESULT }), stdio: ['ignore', log, log] });
  fs.closeSync(log);
  const tick = setInterval(() => {
    const r = readResult();
    if (r.stage && P.install && r.stage !== P.install.stage) { P.install.stage = r.stage.slice(0, 40); save(); }
  }, POLL_MS);
  const finish = (code) => {
    clearInterval(tick);
    child = null;
    rmQuiet(ANSWERS);
    const r = readResult();
    const status = r.status || (code === 0 ? 'ok' : 'failed');
    P.install = Object.assign(P.install || {}, { stage: (r.stage || P.install.stage || '').slice(0, 40), status, exit: code,
      reason: /^[a-z0-9_]{1,40}$/.test(r.reason_code || '') ? r.reason_code : '' });
    if (code === 0 && (status === 'ok' || status === 'partial')) { P.phase = 'pairing'; P.notes.connect = {}; }
    else P.phase = 'failed';
    save();
  };
  child.on('error', () => finish(127));
  child.on('close', (code) => finish(code ?? 1));
  return { ok: true };
}
function retry() {
  if (P.phase !== 'failed') return;
  P.phase = 'questions';
  P.cursor = 'confirm';
  save();
}

// --- Verbinden (Tunnel-Zustand + Pairing über `lifeagents household pair-owner --machine`) -----------------------
let connectBusy = false;
// Pairing-Link mit Einmal-Code + QR nur im Arbeitsspeicher, nie im Fortschritt (der Code verbindet ein Telegram-Konto als
// Owner). Nach einem Neustart wird einfach ein neuer Code erzeugt.
let PAIR = null;
let lastConnect = 0;
const TS_URL = /^https:\/\/login\.tailscale\.com\/[A-Za-z0-9/_?=&.%:-]{1,300}$/;
const REACH_STATES = ['unavailable', 'starting', 'needs_login', 'needs_machine_auth', 'needs_funnel', 'key_expired', 'ports_busy',
  'pending_activation', 'ready'];
const REACH = process.env.LA_REACH || path.join(__dirname, '..', 'compose', 'reach_ctl.sh');
// startActivation — nach der Tunnel-Anmeldung den Installer einmal nachfahren (Paket 3: reach_ctl.sh activate holt die
//   Tunnel-Adresse, n8n setzt den Telegram-Webhook neu). Fortschritt wie bei der Installation über die Ergebnis-Datei.
function startActivation(c) {
  c.activating = true;
  fs.mkdirSync(RUN_DIR, { recursive: true, mode: 0o700 });
  const log = fs.openSync(LOG_FILE, 'a', 0o600);
  const p = spawn('bash', [REACH, 'activate'], { env: Object.assign({}, process.env, { LIFEAGENTS_RESULT_FILE: RESULT }), stdio: ['ignore', log, log] });
  fs.closeSync(log);
  const done = (code) => {
    c.activating = false;
    if (code === 0) c.activated = true;
    else c.problem = 'activation_failed';   // Code, Text beim Anzeigen (problemText)
    delete c.tunnel;   // neu abfragen
    save();
  };
  p.on('error', () => done(127));
  p.on('close', (code) => done(code ?? 1));
}
async function connectTick(force) {
  if (P.phase !== 'pairing' || connectBusy) return;
  if (!force && Date.now() - lastConnect < Math.max(POLL_MS, 2500)) return;
  connectBusy = true;
  lastConnect = Date.now();
  const c = P.notes.connect || (P.notes.connect = {});
  try {
    // Zustand des Wegs zu Telegram (Paket 3, reach_status_json): Tunnel-Anmeldung/-Freigabe, belegte Ports, Aktivierung.
    if (!(c.tunnel && c.tunnel.state === 'ready') && !c.activating) {
      const r = await bridge(['reach-status'], { timeoutMs: 20000 });
      const state = r && REACH_STATES.includes(r.state) ? r.state : 'unavailable';
      c.tunnel = { state, url: r && TS_URL.test(r.url || '') ? r.url : '',
        days: r && Number.isInteger(r.key_days_left) ? r.key_days_left : null };
      // Tunnel steht, Telegram zeigt noch nicht darauf: einmal den Installer nachfahren lassen (reach_ctl.sh activate).
      if (state === 'pending_activation' && !c.activated) { startActivation(c); save(); return; }
      if (state !== 'ready' && state !== 'unavailable') { save(); return; }
    }
    if (c.activating) return;
    if (!PAIR && !c.connected && !c.problem && !c.expired) {
      const reach = await laCli('reach');
      if (reach && reach.ok === false) { c.problem = String(reach.problem || T('core.wizard.connect.not_reaching')).slice(0, 400); save(); return; }
      const a = await laCli('arm');
      if (a && a.ok && a.connected) { c.connected = true; }
      else if (a && a.ok && /^https:\/\/t\.me\/[A-Za-z0-9_]{1,64}\?start=[A-Za-z0-9_-]{1,64}$/.test(a.link || '')) {
        PAIR = { link: a.link, qr: qr.toSvg(qr.encode(a.link)), armed: Date.now() };
      } else { c.problem = 'code_failed'; save(); return; }
    }
    if (PAIR && !c.connected) {
      if (Date.now() - PAIR.armed > TOKEN_TTL_MS) { c.expired = true; PAIR = null; save(); return; }
      const st = await laCli('status');
      if (st && st.ok && st.connected) c.connected = true;
      // Selbsttest (Leitung, Format Paket 3): kommt Telegram bei diesem Rechner an? Alle 10 s den Webhook-Zustand lesen.
      if (!c.connected && (!c.webhookAt || Date.now() - c.webhookAt > 10000)) {
        c.webhookAt = Date.now();
        const r = await bridge(['reach-status'], { timeoutMs: 20000 });
        if (r) c.webhook = { state: ['ours', 'none', 'foreign', 'unknown'].includes(r.webhook) ? r.webhook : 'unknown',
          error: flow.webhookFailing(r, Date.now() / 1000) };
      }
    }
    if (c.connected && !c.finalized) {
      const f = await laCli('finalize');
      c.finalized = true;
      P.notes.welcome_sent = !!(f && f.ok && f.welcome_sent);
      PAIR = null;
      P.phase = 'connected';
      P.cursor = 'handoff';
    }
    save();
  } finally { connectBusy = false; }
}
async function action(name) {
  const c = P.notes.connect || {};
  switch (name) {
    case 'connect_retry': delete c.problem; delete c.tunnel; await connectTick(true); return { ok: true };
    case 'pair_new': delete c.expired; await connectTick(true); return { ok: true };
    case 'handoff':
      if (P.phase !== 'connected') return { error: T('core.wizard.msg.not_connected') };
      P.phase = 'handoff'; save(); return { ok: true };
    case 'retry': retry(); return { ok: true };
    default: return { error: T('core.wizard.msg.unknown_action') };
  }
}

// --- Fehlerbericht (nur feste Felder, Positivliste) ---------------------------------------------------------------
const SAFE = /^[A-Za-z0-9_.:,-]{0,80}$/;
function report() {
  const ins = P.install || {};
  const c = P.notes.connect || {};
  const f = {
    wizard: VERSION, phase: P.phase, step: cursor(), packages: (P.A.__packages || []).join(','), reach: flow.reachMode(P.A),
    install_status: ins.status || '', install_stage: ins.stage || '', install_reason: ins.reason || '',
    install_exit: ins.exit === undefined ? '' : String(ins.exit), tunnel: (c.tunnel && c.tunnel.state) || '',
    pairing: c.connected ? 'connected' : PAIR ? 'waiting' : c.problem ? 'unreachable' : c.expired ? 'expired' : '',
    time: new Date().toISOString(),
  };
  return ['lifeagents-wizard-report v1', ...Object.entries(f).map(([k, v]) => `${k}: ${SAFE.test(String(v)) ? v : '?'}`)].join('\n');
}

// --- HTTP: Schutz ---------------------------------------------------------------------------------------------
const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'";
function headers(extra) {
  return Object.assign({
    'Content-Security-Policy': CSP, 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY', 'Cache-Control': 'no-store', 'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin', 'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  }, extra || {});
}
function send(res, code, body, type, extra) {
  const b = Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
  res.writeHead(code, headers(Object.assign({ 'Content-Type': type || 'application/json; charset=utf-8', 'Content-Length': b.length }, extra)));
  res.end(b);
}
const deny = (res, code) => send(res, code, { error: 'forbidden' });

// Ein Einmal-Wert (nur der Hash im Speicher) + eine Sitzung. Jeder neue Wert/jede neue Sitzung ersetzt die alte.
let pending = null;   // {hash, exp}
let session = null;   // {sid, csrf}
let failedStarts = [];
function issueToken() {
  const t = rnd(32);
  pending = { hash: sha256(t), exp: Date.now() + TOKEN_TTL_MS };
  return `${ORIGINS[0]}/start?t=${t}`;
}
function cookieSid(req) {
  const m = /(?:^|;\s*)la_wizard=([A-Za-z0-9_-]{20,})/.exec(req.headers.cookie || '');
  return m ? m[1] : null;
}
function hasSession(req) { const s = cookieSid(req); return !!(session && s && safeEq(s, session.sid)); }

// Bilder und Animationen liefert di9 als ui/art/art.css + ui/art/art.js (Zuordnung Seite -> Bild nur dort, nach page.id).
const STATIC = { '/app.js': ['app.js', 'text/javascript; charset=utf-8'], '/art.js': ['art/art.js', 'text/javascript; charset=utf-8'], '/art.css': ['art/art.css', 'text/css; charset=utf-8'],
  '/app.css': ['app.css', 'text/css; charset=utf-8'] };
// Startseite mit dem Projekt-Zeichen (ui/mark.html, eine Datei, gegen die Quelle der Site prüfbar) an jeder Stelle <!--mark-->.
function indexHtml() {
  const mark = fs.readFileSync(path.join(UI_DIR, 'mark.html'), 'utf8').replace(/<!--[\s\S]*?-->\s*/, '').trim();
  return fs.readFileSync(path.join(UI_DIR, 'index.html'), 'utf8').split('<!--mark-->').join(mark);
}

function readBody(req) {
  return new Promise((resolve) => {
    let n = 0; const parts = [];
    req.on('data', (d) => { n += d.length; if (n > 16384) { req.destroy(); resolve(null); } else parts.push(d); });
    req.on('end', () => { try { resolve(JSON.parse(Buffer.concat(parts).toString('utf8') || '{}')); } catch (_) { resolve(null); } });
    req.on('error', () => resolve(null));
  });
}

async function handle(req, res) {
  const host = String(req.headers.host || '').toLowerCase();
  if (!HOSTS.has(host)) return deny(res, 421);
  const url = new URL(req.url, 'http://x');
  const sfs = req.headers['sec-fetch-site'];
  if (req.method === 'GET' && url.pathname === '/start') {
    if (sfs && sfs !== 'none' && sfs !== 'same-origin') return deny(res, 403);
    failedStarts = failedStarts.filter((t) => Date.now() - t < 60000);
    if (failedStarts.length >= 10) return deny(res, 429);
    const t = url.searchParams.get('t') || '';
    if (!pending || Date.now() > pending.exp || !/^[A-Za-z0-9_-]{43}$/.test(t) || !crypto.timingSafeEqual(sha256(t), pending.hash)) {
      failedStarts.push(Date.now());
      return send(res, 403, page403(), 'text/html; charset=utf-8');
    }
    pending = null;
    session = { sid: rnd(32), csrf: rnd(32) };
    return send(res, 303, '', 'text/plain', { Location: '/', 'Set-Cookie': `la_wizard=${session.sid}; HttpOnly; SameSite=Strict; Path=/` });
  }
  if (req.method === 'GET' && STATIC[url.pathname]) {
    const [f, type] = STATIC[url.pathname];
    let body;
    try { body = fs.readFileSync(path.join(UI_DIR, f)); } catch (_) { return deny(res, 404); }   // z. B. noch keine Bilder (art/)
    return send(res, 200, body, type);
  }
  if (req.method === 'GET' && url.pathname === '/') {
    if (!hasSession(req)) return send(res, 403, page403(), 'text/html; charset=utf-8');
    return send(res, 200, indexHtml(), 'text/html; charset=utf-8');
  }
  if (!url.pathname.startsWith('/api/')) return deny(res, 404);
  if (!hasSession(req)) return deny(res, 401);
  if (sfs && sfs !== 'same-origin') return deny(res, 403);
  if (req.method === 'GET') {
    if (url.pathname === '/api/state') {
      if (!Q) await loadQuestions();
      if (!Q) return send(res, 503, { error: T('core.wizard.msg.no_questions') });
      connectTick(false).catch(() => {});   // im Hintergrund: finalize dauert Minuten, die Seite zeigt bis dahin „Warte …“
      return send(res, 200, { csrf: session.csrf, page: view() });
    }
    if (url.pathname === '/api/report') return send(res, 200, { text: report() });
    return deny(res, 404);
  }
  if (req.method !== 'POST') return deny(res, 405);
  const origin = String(req.headers.origin || '').toLowerCase();
  if (!ORIGINS.includes(origin)) return deny(res, 403);
  if (!/^application\/json(;|$)/.test(String(req.headers['content-type'] || ''))) return deny(res, 415);
  if (!safeEq(req.headers['x-csrf-token'] || '', session.csrf)) return deny(res, 403);
  const body = await readBody(req);
  if (!body || typeof body !== 'object') return send(res, 400, { error: 'bad request' });
  if (!['/api/answer', '/api/back', '/api/goto', '/api/action', '/api/lang', '/api/check'].includes(url.pathname)) return deny(res, 404);
  const r = await serial(async () => {
    switch (url.pathname) {
      case '/api/answer': return answer(String(body.id || ''), body.value, body.skip === true);
      case '/api/back': back(); return { ok: true };
      case '/api/goto': return gotoStep(String(body.id || ''));
      case '/api/lang': return setLang(String(body.lang || ''));
      case '/api/check': return liveCheck(String(body.id || ''), body.value);
      default: return action(String(body.name || ''));
    }
  });
  return send(res, r.error ? 422 : 200, Object.assign({}, r, { csrf: session.csrf, page: view() }));
}

// Änderungen strikt nacheinander: bei einem Doppelklick dürfen zwei Prüfungen den Stand nicht verschränkt überschreiben.
let chain = Promise.resolve();
function serial(fn) {
  const p = chain.then(fn, fn);
  chain = p.catch(() => {});
  return p;
}

function esc(s) { return String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`); }
function page403() {
  return `<!DOCTYPE html><html lang="${esc(uiLang())}"><head><meta charset="utf-8"><title>${esc(T('core.wizard.ui.doc_title'))}</title><link rel="stylesheet" href="/app.css"></head>`
    + `<body><main class="solo"><h1>${esc(T('core.wizard.ui.open_via_app'))}</h1><p class="lead">${esc(T('core.wizard.ui.link_once'))}</p></main></body></html>`;
}

// --- Steuerkanal (nur root im master: `node ctl.js issue|status|finish`) ------------------------------------------
let httpServer = null;
let ctlServer = null;
function finishAll() {
  rmQuiet(PROGRESS); rmQuiet(KEY_FILE); rmQuiet(ANSWERS); rmQuiet(RESULT); rmQuiet(LOG_FILE); rmQuiet(HINTS_FILE);
  try { fs.mkdirSync(STATE_DIR, { recursive: true }); atomicWrite(DONE, ''); } catch (_) { /* Volume weg: dann gibt es auch nichts fortzusetzen */ }
  for (const k of Object.keys(SECRETS)) delete SECRETS[k];
  session = null; pending = null;
  const bye = () => process.exit(0);
  if (httpServer) httpServer.close();
  if (ctlServer) ctlServer.close(() => { rmQuiet(CTL_SOCK); bye(); }); else bye();
  setTimeout(bye, 1000).unref();
}
function startCtl() {
  fs.mkdirSync(RUN_DIR, { recursive: true, mode: 0o700 });
  rmQuiet(CTL_SOCK);
  ctlServer = net.createServer((s) => {
    let buf = '';
    s.on('data', (d) => {
      buf += d;
      if (buf.length > 256) return s.destroy();
      if (!buf.includes('\n')) return;
      const cmd = buf.split('\n')[0].trim();
      if (cmd === 'issue') s.end(JSON.stringify({ url: issueToken() }) + '\n');
      // bot = Benutzername aus getMe (öffentlich, kein Geheimnis): die App braucht ihn für „Telegram öffnen“.
      else if (cmd === 'status') s.end(JSON.stringify(Object.assign({ phase: P.phase, step: Q ? cursor() : '', lang: uiLang() }, P.notes.bot ? { bot: P.notes.bot } : {})) + '\n');
      else if (cmd === 'finish') { s.end(JSON.stringify({ ok: true }) + '\n', finishAll); }
      else s.end(JSON.stringify({ error: 'unknown' }) + '\n');
    });
    s.on('error', () => {});
  });
  const old = process.umask(0o077);
  ctlServer.listen(CTL_SOCK, () => { process.umask(old); fs.chmodSync(CTL_SOCK, 0o600); });
}

// Fragen-Auszug laden; scheitert es (z. B. Baum noch nicht ganz da), versucht es die nächste Seitenabfrage erneut.
let questionsLoading = null;
function loadQuestions() {
  if (!questionsLoading) {
    questionsLoading = bridge(['questions'], { timeoutMs: 60000 }).then((q) => {
      if (q && q.v === 1 && Array.isArray(q.host) && Array.isArray(q.packages)) Q = q;
      if (Q && P.cursor === null) P.cursor = firstOpen();
    }).finally(() => { questionsLoading = null; });
  }
  return questionsLoading;
}

async function main() {
  if (fs.existsSync(DONE)) { process.stdout.write(JSON.stringify({ ev: 'wizard_done' }) + '\n'); process.exit(0); }
  KEY = loadKey();
  loadCatalog();
  P = loadProgress();
  await loadQuestions();
  startCtl();
  httpServer = http.createServer((req, res) => {
    handle(req, res).catch(() => { try { send(res, 500, { error: 'internal' }); } catch (_) { /* weg */ } });
  });
  httpServer.headersTimeout = 10000;
  httpServer.requestTimeout = 300000;
  httpServer.listen(PORT, BIND, () => process.stdout.write(JSON.stringify({ ev: 'wizard_ready', port: PORT, questions: !!Q }) + '\n'));
}

if (require.main === module) main();
module.exports = { report };
