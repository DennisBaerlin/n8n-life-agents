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
const MSG = {
  empty: 'Hier fehlt noch etwas.',
  invalid: 'Das passt nicht (ungültig oder Tippfehler). Bitte prüfe die Eingabe.',
  line: 'Bitte nur eine Zeile eingeben, ohne Zeilenumbruch.',
  choose: 'Wähle eine Antwort aus.',
  offline: 'Konnte gerade nicht online prüfen. Die Angabe ist übernommen und wird bei der Einrichtung noch einmal geprüft.',
};
// Optionale CLI-Fragen, die der Wizard trotzdem nicht überspringen lässt (Grund an der Stelle in pageFor).
const NO_SKIP = ['DOMAIN', 'GOOGLE_API_KEY', 'OWNER_LANGUAGE', 'OWNER_PERSONA'];
const PAPERLESS_MSG = {
  localhost: '„localhost“ meint für den Assistenten ihn selbst, nicht deinen Rechner. Nimm die Adresse des Rechners im Netzwerk, zum Beispiel http://192.168.1.50:8000.',
  invalid: 'Das sieht nicht nach einer Adresse aus. Sie beginnt mit http:// oder https://.',
  unreachable: 'Unter dieser Adresse antwortet nichts. Prüfe, ob Paperless läuft und ob du die Adresse so auch im Browser öffnest.',
  not_paperless: 'Unter dieser Adresse antwortet kein Paperless. Prüfe die Adresse und den Port.',
  token_rejected: 'Paperless lehnt diesen Zugang ab. Kopiere den Token noch einmal aus deinem Profil in Paperless.',
  too_old: 'Dein Paperless ist zu alt. Nötig ist Paperless-NGX 3.0 oder neuer.',
};

function optionsFor(id) {
  switch (id) {
    case 'voice': return [
      { value: 'no', label: 'Nein, ich schreibe lieber', desc: 'Du kannst das später nachholen.' },
      { value: 'yes', label: 'Ja, ich trage einen Schlüssel ein', desc: 'Dauert etwa 5 Minuten.' }];
    case 'tg_busy': return [
      { value: 'new', label: 'Einen neuen Bot anlegen', tag: 'empfohlen', desc: 'Dauert zwei Minuten, der andere Dienst läuft einfach weiter.' },
      { value: 'take', label: 'Diesen Bot übernehmen', desc: 'Nur, wenn du sicher bist, dass der andere Dienst nicht mehr gebraucht wird.' }];
    case 'reach': return [
      { value: 'tunnel', label: 'Über einen sicheren Tunnel', tag: 'empfohlen', desc: 'Geht mit jedem Anschluss. Du brauchst ein kostenloses Konto bei Tailscale; die Anmeldung kommt nach der Installation.' },
      { value: 'fritzbox', label: 'Über meine FritzBox', desc: 'Einige Schritte im Router, kein fremdes Konto. Dein Anschluss braucht eine eigene IPv4-Adresse.' }];
    case 'fb_dslite': return [
      { value: 'no', label: 'Nein, dort steht kein DS-Lite', desc: 'Weiter mit der FritzBox.' },
      { value: 'yes', label: 'Ja, dort steht DS-Lite', desc: 'Telegram erreicht dich über die FritzBox dann nicht. Wir nehmen den Tunnel.' }];
    case 'packages': return Q.packages.map((p) => ({ value: p.id, label: p.name, desc: p.summary }));
    default: return null;
  }
}

function pageFor(id) {
  const base = { id, phase: flow.phaseOf(id), phases: flow.PHASES };
  const q = flow.question(Q, id);
  if (q) {
    const key = q.key;
    const v = P.A[key];
    const page = Object.assign(base, {
      kind: q.kind, title: q.label, help: flow.helpBlocks(q.help), optional: !q.required,
      value: q.secret ? '' : (typeof v === 'string' ? v : ''), hasSecret: q.secret && v === null,
      options: q.choices, next: 'Weiter',
    });
    if (key === 'DOMAIN') {
      page.title = 'Füge die MyFRITZ!-Adresse deines Rechners ein';
      page.help = [{ p: 'Sie steht in der Freigabe im Feld „MyFRITZ!-Adresse“, zum Beispiel meinrechner.deine-domain.myfritz.net. Warte danach etwa eine Minute, bis sie eingetragen ist.' }];
      page.optional = false;
    }
    if (key === 'OWNER_LANGUAGE' && !v) page.value = 'de';
    if (q.setting === 'general.paperless_url' && v === undefined) Object.assign(page, paperlessSearchView());
    if (key === 'OWNER_PERSONA' && !v) page.value = 'neutral';
    // Google: „Nein“ auf der Seite davor ist das Überspringen; Sprache und Charakter haben eine Vorauswahl.
    if (NO_SKIP.includes(key)) page.optional = false;
    if (q.kind === 'date') page.placeholder = 'JJJJ-MM-TT';
    return page;
  }
  switch (id) {
    case 'tg_busy': return Object.assign(base, { kind: 'choice', title: 'Dieser Bot läuft schon woanders',
      help: [{ p: 'Er schickt seine Nachrichten gerade an einen anderen Dienst. Übernehmen wir ihn, bekommt dieser Dienst nichts mehr.' }],
      note: P.A.__tg_conflict && P.A.__tg_conflict !== 'polling' ? { kind: 'warn', text: `Bisherige Adresse: ${P.A.__tg_conflict}` } : null,
      options: optionsFor(id), value: P.A.__tg_choice || 'new', next: 'Weiter' });
    case 'voice': return Object.assign(base, { kind: 'choice', title: 'Möchtest du dem Bot auch Sprachnachrichten schicken?',
      help: [{ p: 'Dafür brauchst du zusätzlich einen Schlüssel von Google im bezahlten Tarif. Nur dann nutzt Google deine Aufnahmen nicht zum Training. Ohne Schlüssel läuft alles andere normal.' }],
      options: optionsFor(id), value: P.A.__voice || '', next: 'Weiter' });
    case 'packages': return Object.assign(base, { kind: 'multi', title: 'Was soll dein Assistent können?',
      help: [{ p: 'Das Grundsystem mit Haushalt, Erinnerungen und Hilfe ist immer dabei. Den Rest kannst du jetzt wählen oder später dazunehmen.' }],
      options: optionsFor(id), value: P.A.__packages || [], next: 'Weiter' });
    case 'reach': return Object.assign(base, { kind: 'choice', title: 'Wie soll Telegram deinen Rechner erreichen?',
      help: [{ p: 'Telegram muss deine Nachrichten bei dir abliefern können, auch wenn du unterwegs bist.' }],
      options: optionsFor(id), value: P.A.__reach || 'tunnel', next: 'Weiter' });
    case 'fb_dslite': return Object.assign(base, { kind: 'choice', title: 'Steht in deiner FritzBox „DS-Lite“?',
      help: [{ p: 'Öffne im Browser fritz.box und gehe zu Internet → Online-Monitor. Schaue, ob dort das Wort „DS-Lite“ steht. Dann kann Telegram deinen Rechner über die FritzBox nicht erreichen.' }],
      link: { href: GUIDE_URL, label: 'Ausführliche Anleitung mit Bildern öffnen' },
      options: optionsFor(id), value: P.A.__dslite || '', next: 'Weiter' });
    case 'fb_ports_busy': return Object.assign(base, { kind: 'info', title: 'Der FritzBox-Weg ist auf diesem Rechner schon belegt',
      help: [{ p: 'Ein anderes Programm auf diesem Rechner nutzt schon den Weg, den die FritzBox bräuchte. Wir ändern daran nichts, sonst fällt es aus.' }, { p: 'Nimm den Tunnel, der stört nichts.' }],
      next: 'Den Tunnel nehmen' });
    case 'fb_guide': return Object.assign(base, { kind: 'info', title: 'Richte die FritzBox ein',
      help: [{ p: 'In der FritzBox stellst du ein, dass Nachrichten aus dem Internet bei diesem Rechner ankommen. Das sind einige Schritte, die Anleitung zeigt jeden mit Bild.' }],
      note: { kind: 'warn', text: 'Meldet die FritzBox „Freigabe existiert bereits“, nutzt schon etwas anderes diesen Weg. Lösche nichts, sonst fällt es aus. Geh dann zurück und nimm den Tunnel.' },
      link: { href: GUIDE_URL, label: 'Anleitung für die FritzBox öffnen' }, next: 'Ich habe die Freigaben angelegt' });
    case 'review': return Object.assign(base, { kind: 'review', title: 'Stimmt alles so?', rows: reviewRows(), next: 'Alles richtig, weiter' });
    case 'confirm': return Object.assign(base, { kind: 'confirm', title: 'Das wird auf deinem Rechner geändert',
      help: [{ p: 'Bis hierher hat die Einrichtung nichts verändert. Du kannst jetzt noch abbrechen.' }],
      groups: confirmGroups(), next: 'Einverstanden, Installation starten' });
    case 'install': return Object.assign(base, installView());
    case 'connect': return Object.assign(base, connectView());
    case 'handoff': return Object.assign(base, { kind: 'handoff', title: 'Dein Bot ist eingerichtet',
      help: [{ p: P.notes.welcome_sent ? 'Er hat dir in Telegram geschrieben. Tippe dort auf „Haushalt einrichten“.' : 'Schreib ihm in Telegram einfach /start, er zeigt dir den nächsten Schritt.' },
        { p: 'Zum Schluss fragen wir dich noch, ob dieser Rechner wach bleiben soll, damit dein Bot jederzeit antwortet.' }],
      next: P.phase === 'handoff' ? null : 'Weiter', action: 'handoff', done: P.phase === 'handoff' });
    default: return Object.assign(base, { kind: 'info', title: '…' });
  }
}

// Paperless-Adresse finden (Owner-Runden 2026-11-06), nur auf deren Seite und nur, wenn das Modul Dokumente gewählt ist:
//   1) dieser Rechner: Paperless-Container mit veröffentlichtem Port (bridge.sh paperless-ports) + LA_HOST_IP der App;
//   2) sonst das eigene Heimnetz (scan.js: /24, typische Ports, Anmeldeseite als Erkennung).
//   Ein Treffer = vorausgefüllt, mehrere = Auswahl, keiner = leeres Feld. Die Live-Prüfung beim Weiter bleibt wie bisher.
let paperlessSearching = null;
function startPaperlessSearch() {
  if (paperlessSearching || (P.notes.paperless_search && P.notes.paperless_search.state === 'done')) return;
  P.notes.paperless_search = { state: 'running', found: [] };
  paperlessSearching = (async () => {
    const hostIp = process.env.LA_HOST_IP;
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
  if (s.state === 'running') return { poll: true, note: { kind: '', text: 'Suche im Heimnetz nach Paperless …', busy: true } };
  if (s.found.length === 1) {
    return { value: s.found[0], note: { kind: '', text: s.local ? 'Auf diesem Rechner läuft Paperless. Die Adresse ist schon eingetragen, prüf sie kurz.'
      : 'Im Heimnetz gefunden. Die Adresse ist schon eingetragen, prüf sie kurz.' } };
  }
  if (s.found.length > 1) return { suggestions: s.found, note: { kind: '', text: 'Im Heimnetz läuft Paperless mehrmals. Tipp die richtige Adresse an.' } };
  return { note: { kind: '', text: 'Im Heimnetz wurde kein Paperless gefunden. Trag die Adresse selbst ein.' } };
}

function labelOf(id, value) {
  const q = flow.question(Q, id);
  if (q && q.choices) { const c = q.choices.find((x) => x.value === value); return c ? c.label : value; }
  return value;
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
      if (q.secret) shown = v === null ? 'eingetragen' : 'übersprungen';
      else if (q.kind === 'date' && /^\d{4}-\d{2}-\d{2}$/.test(v || '')) shown = v.split('-').reverse().join('.');
      else shown = v ? labelOf(id, v) : 'übersprungen';
      if (q.key === 'GOOGLE_API_KEY') continue;   // steht schon in der Zeile „Sprachnachrichten“
      const pk = q.pkg ? flow.pkgDef(Q, q.pkg).name + ': ' : '';
      rows.push({ label: q.key === 'DOMAIN' ? 'MyFRITZ!-Adresse' : pk + q.label, value: shown, goto: id });
    } else if (id === 'voice') rows.push({ label: 'Sprachnachrichten', value: P.A.__voice === 'yes' ? 'ja, Google-Schlüssel eingetragen' : 'nein', goto: id });
    else if (id === 'packages') {
      const n = (P.A.__packages || []).map((p) => (flow.pkgDef(Q, p) || {}).name).filter(Boolean);
      rows.push({ label: 'Funktionen', value: n.length ? 'Grundsystem, ' + n.join(', ') : 'nur Grundsystem', goto: id });
    } else if (id === 'reach') rows.push({ label: 'Erreichbarkeit', value: flow.reachMode(P.A) === 'fritzbox' ? 'FritzBox' : 'Tunnel', goto: id });
  }
  return rows;
}
function confirmGroups() {
  const mode = flow.reachMode(P.A);
  return [
    { title: 'Neu dazu kommt', items: [
      'Dein Assistent bekommt einen eigenen, abgetrennten Bereich auf diesem Rechner',
      mode === 'fritzbox' ? 'Die Verbindung über die zwei Freigaben, die du in der FritzBox angelegt hast' : 'Ein Tunnel über dein Tailscale-Konto, nur für die Adressen von Telegram',
      'Dein Telegram-Bot wird auf diesen Rechner eingestellt'] },
    { title: 'Das bleibt, wie es ist', items: ['Deine anderen Programme, auch alles, was schon in Docker läuft', 'Deine Dateien und der Schutz deiner Festplatte', 'Die Energie-Einstellungen, bis du zum Schluss zustimmst'] },
  ];
}

// Fortschritt der Installation: die Schritt-Codes aus provision.sh (ui_step <text> <stage>) in sechs Gruppen.
const STAGE_GROUPS = [
  ['Rechner prüfen', ['preflight']],
  ['Programme einrichten', ['base', 'n8n', 'gateway']],
  ['Datenbank einrichten', ['backup', 'postgres', 'schema']],
  ['Zugänge einrichten', ['access']],
  ['Bot und Funktionen einspielen', ['workflows', 'packages', 'cli']],
  ['Alles einmal prüfen', ['final']],
];
function installView() {
  const ins = P.install || {};
  const g = STAGE_GROUPS.findIndex(([, st]) => st.includes(ins.stage));
  const at = P.phase === 'installing' || P.phase === 'failed' ? Math.max(0, g) : STAGE_GROUPS.length;
  const failed = P.phase === 'failed';
  return { kind: 'install', title: failed ? 'Die Einrichtung ist hängen geblieben' : 'Dein Assistent wird eingerichtet',
    help: failed ? [] : [{ p: 'Das dauert ein paar Minuten. Du kannst das Fenster offen lassen und etwas anderes tun.' }],
    items: STAGE_GROUPS.map(([t], i) => ({ text: t, state: i < at ? 'ok' : i === at ? (failed ? 'bad' : 'run') : '' })),
    failed, note: failed ? { kind: 'bad', text: `Beim Schritt „${STAGE_GROUPS[Math.max(0, g)][0]}“ hat etwas nicht geklappt. Deine Antworten sind gespeichert. Versuch es noch einmal; klappt es wieder nicht, schick den Bericht an die Person, die dir hilft.` } : null,
    poll: P.phase === 'installing' };
}

// Verbinden: beim Tunnel erst die Anmeldung bei Tailscale (Paket 3 meldet den Zustand), dann das Pairing per QR-Code.
function connectView() {
  const c = P.notes.connect || {};
  const v = { kind: 'connect', title: 'Verbinde dich mit deinem Bot', poll: true };
  if (c.tunnel && c.tunnel.state !== 'ready' && c.tunnel.state !== 'unavailable') {
    const login = c.tunnel.state === 'needs_login';
    return Object.assign(v, { title: login ? 'Melde dich bei Tailscale an' : 'Erlaube deinem Rechner den Empfang',
      help: [{ p: login ? 'Es öffnet sich eine neue Seite. Du kannst dich dort mit deinem Google-, Apple- oder Microsoft-Konto anmelden.' : 'Bestätige auf der nächsten Seite einmal, dass Nachrichten von außen bei diesem Rechner ankommen dürfen. Nur die Adressen für Telegram sind offen, alles andere bleibt zu.' }],
      link: c.tunnel.url ? { href: c.tunnel.url, label: login ? 'Tailscale-Anmeldung öffnen' : 'Freigabe-Seite öffnen', primary: true } : null,
      wait: c.tunnel.url ? 'Warte auf deine Bestätigung …' : 'Der Tunnel startet …' });
  }
  if (c.problem) {
    return Object.assign(v, { help: [{ p: 'Telegram erreicht deinen Rechner noch nicht.' }], note: { kind: 'warn', text: c.problem },
      poll: false, action: 'connect_retry', next: 'Noch einmal prüfen' });
  }
  if (c.expired) return Object.assign(v, { help: [{ p: 'Der Code ist abgelaufen.' }], poll: false, action: 'pair_new', next: 'Neuen Code anzeigen' });
  if (PAIR) {
    return Object.assign(v, { qr: PAIR.qr, link: { href: PAIR.link, label: 'Link öffnen, wenn du Telegram auf diesem Rechner hast' },
      help: [{ p: 'Scanne den Code mit dem Handy. Telegram öffnet deinen Bot.' }, { p: 'Tippe dort auf „Starten“.' },
        { p: 'Der Code gilt 10 Minuten und zeigt nur dir, dass du der Besitzer bist.' }],
      wait: c.connected ? 'Verbunden. Der Bot wird auf dich eingestellt …' : 'Warte auf deine Nachricht an den Bot …' });
  }
  return Object.assign(v, { help: [{ p: 'Einen Moment, der Code wird vorbereitet.' }], wait: 'Bereite die Verbindung vor …' });
}

function view() {
  const id = cursor();
  const page = pageFor(id);
  const s = list();
  const i = s.indexOf(id);
  page.canBack = P.phase === 'questions' && i > 0 && !['install', 'connect', 'handoff'].includes(id);
  return page;
}

// --- Antworten ------------------------------------------------------------------------------------------------
async function answer(id, raw, skip) {
  if (P.phase !== 'questions' || id !== cursor()) return { error: 'Diese Seite ist gerade nicht offen. Lade die Seite neu.' };
  const q = flow.question(Q, id);
  if (q) {
    if (typeof raw !== 'string' || /[\r\n]/.test(raw)) return { error: MSG.line };
    const value = raw.trim();
    if (flow.valueProblem(value) === 'control') return { error: MSG.line };
    if (flow.valueProblem(value) === 'length') return { error: MSG.invalid };
    // Schon eingetragenes Geheimnis + leeres Feld = behalten (die Seite zeigt Geheimnisse nie wieder an).
    if (value === '' && !skip && q.secret && P.A[q.key] === null) { P.cursor = firstOpen(); save(); return { ok: true }; }
    if (value === '' && (q.required || NO_SKIP.includes(q.key))) return { error: q.choices ? MSG.choose : MSG.empty };
    if (value !== '' && skip) return { error: MSG.invalid };
    let check = null;
    let note = null;
    let v = value;
    if (v !== '') {
      const r = await bridge(['validate', q.validateRef], { input: v, timeoutMs: 30000 });
      if (!r) return { error: 'Die Prüfung hat nicht geantwortet. Versuch es gleich noch einmal.' };
      if (r.rc === 1) return { error: r.problem ? r.problem + '.' : MSG.invalid };
      if (r.rc === 2) note = MSG.offline;
      if (typeof r.value === 'string' && r.value !== '') v = r.value;
      // Paperless (Plan *Die Module wie in der CLI*): Adresse, Version und Zugang live prüfen.
      if (q.pkg === 'paperless') {
        const url = q.setting === 'general.paperless_url' ? v : (P.A.CONFIG_GENERAL_PAPERLESS_URL || '');
        const token = q.cred ? v : (SECRETS.PAPERLESS_API_TOKEN || '');   // neue Adresse: vorhandenen Zugang gleich mitprüfen
        if (url) {
          const pc = await bridge(['paperless-check'], { input: `${url}\n${token}\n`, timeoutMs: 20000 });
          if (pc && !pc.ok) return { error: PAPERLESS_MSG[pc.reason] || MSG.invalid };
          if (pc && pc.ok) check = pc.version ? `Paperless ${pc.version} gefunden${token ? ', Zugang funktioniert' : ''}` : 'Paperless antwortet';
        }
      }
    }
    setAnswer(q, v);
    if (q.key === 'TELEGRAM_BOT_TOKEN') {
      delete P.A.__tg_conflict; delete P.A.__tg_choice; delete P.notes.bot;
      if (v) {
        const t = await bridge(['tg-check'], { env: { TELEGRAM_BOT_TOKEN: v }, timeoutMs: 30000 });
        if (t && t.ok) {
          if (/^[A-Za-z0-9_]{1,64}$/.test(t.bot || '')) { check = `Gefunden: dein Bot @${t.bot}`; P.notes.bot = t.bot; }
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
      if (!['new', 'take'].includes(raw)) return { error: MSG.choose };
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
      if (!['yes', 'no'].includes(raw)) return { error: MSG.choose };
      P.A.__voice = raw;
      if (raw === 'no') { delete P.S.GOOGLE_API_KEY; delete SECRETS.GOOGLE_API_KEY; P.A.GOOGLE_API_KEY = ''; }
      else if (P.A.GOOGLE_API_KEY === '') delete P.A.GOOGLE_API_KEY;
      break;
    case 'packages': {
      if (!Array.isArray(raw) || raw.some((p) => typeof p !== 'string' || !flow.pkgDef(Q, p))) return { error: MSG.choose };
      P.A.__packages = Q.packages.map((p) => p.id).filter((p) => raw.includes(p));
      break;
    }
    case 'reach':
      if (!['tunnel', 'fritzbox'].includes(raw)) return { error: MSG.choose };
      P.A.__reach = raw;
      delete P.A.__ports;   // bei jeder Wahl neu messen: ein inzwischen beendetes Programm gibt den Weg wieder frei
      if (raw === 'fritzbox') {
        // Prüfliste Nr. 13: Ports 80/443 belegt? Die Messung gehört Paket 1/3 (reach_ports_json); unbekannt = weiter.
        const r = await bridge(['reach-ports'], { timeoutMs: 20000 });
        if (r && r.state === 'busy') P.A.__ports = 'busy';
      }
      break;
    case 'fb_dslite':
      if (!['yes', 'no'].includes(raw)) return { error: MSG.choose };
      P.A.__dslite = raw;
      break;
    case 'fb_guide': P.A.__fb_guide = true; break;
    case 'fb_ports_busy': P.A.__reach = 'tunnel'; break;
    case 'review': P.cursor = 'confirm'; save(); return { ok: true };
    case 'confirm': return startInstall();
    default: return { error: 'Diese Seite kennt keine Antwort.' };
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
  if (P.phase !== 'questions' || !['review', 'confirm'].includes(cursor())) return { error: 'Ändern geht nur in der Übersicht.' };
  if (!list().includes(id) || ['review', 'confirm', 'install', 'connect', 'handoff'].includes(id)) return { error: 'Unbekannte Angabe.' };
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
  if (open) { P.cursor = open; save(); return { error: 'Eine Angabe fehlt noch.' }; }
  let txt;
  try { txt = flow.renderAnswers(Q, flow.answerLines(Q, P.A, SECRETS)); } catch (_) { return { error: 'Eine Angabe passt nicht. Geh zurück zur Übersicht und prüfe sie.' }; }
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
const TS_URL = /^https:\/\/login\.tailscale\.com\/[A-Za-z0-9/_?=&.-]{1,200}$/;
async function connectTick(force) {
  if (P.phase !== 'pairing' || connectBusy) return;
  if (!force && Date.now() - lastConnect < Math.max(POLL_MS, 2500)) return;
  connectBusy = true;
  lastConnect = Date.now();
  const c = P.notes.connect || (P.notes.connect = {});
  try {
    if (flow.reachMode(P.A) === 'tunnel' && !(c.tunnel && c.tunnel.state === 'ready')) {
      const r = await bridge(['reach-status'], { timeoutMs: 20000 });
      const state = r && ['needs_login', 'needs_funnel', 'starting', 'ready', 'unavailable'].includes(r.state) ? r.state : 'unavailable';
      c.tunnel = { state, url: r && TS_URL.test(r.url || '') ? r.url : '' };
      if (state !== 'ready' && state !== 'unavailable') { save(); return; }
    }
    if (!PAIR && !c.connected && !c.problem && !c.expired) {
      const reach = await laCli('reach');
      if (reach && reach.ok === false) { c.problem = String(reach.problem || 'Telegram erreicht deinen Rechner noch nicht.').slice(0, 400); save(); return; }
      const a = await laCli('arm');
      if (a && a.ok && a.connected) { c.connected = true; }
      else if (a && a.ok && /^https:\/\/t\.me\/[A-Za-z0-9_]{1,64}\?start=[A-Za-z0-9_-]{1,64}$/.test(a.link || '')) {
        PAIR = { link: a.link, qr: qr.toSvg(qr.encode(a.link)), armed: Date.now() };
      } else { c.problem = 'Der Code für die Verbindung ließ sich nicht erzeugen. Versuch es gleich noch einmal.'; save(); return; }
    }
    if (PAIR && !c.connected) {
      if (Date.now() - PAIR.armed > TOKEN_TTL_MS) { c.expired = true; PAIR = null; save(); return; }
      const st = await laCli('status');
      if (st && st.ok && st.connected) c.connected = true;
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
    case 'connect_retry': delete c.problem; await connectTick(true); return { ok: true };
    case 'pair_new': delete c.expired; await connectTick(true); return { ok: true };
    case 'handoff':
      if (P.phase !== 'connected') return { error: 'Noch nicht verbunden.' };
      P.phase = 'handoff'; save(); return { ok: true };
    case 'retry': retry(); return { ok: true };
    default: return { error: 'Unbekannte Aktion.' };
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
      if (!Q) return send(res, 503, { error: 'Der Wizard konnte die Fragen nicht laden.' });
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
  if (!['/api/answer', '/api/back', '/api/goto', '/api/action'].includes(url.pathname)) return deny(res, 404);
  const r = await serial(async () => {
    switch (url.pathname) {
      case '/api/answer': return answer(String(body.id || ''), body.value, body.skip === true);
      case '/api/back': back(); return { ok: true };
      case '/api/goto': return gotoStep(String(body.id || ''));
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

function page403() {
  return '<!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>Einrichtung</title><link rel="stylesheet" href="/app.css"></head>'
    + '<body><main class="solo"><h1>Bitte öffne die Einrichtung über die App</h1><p class="lead">Dieser Link gilt nur einmal. Schließe das Fenster und öffne die App lifeagents neu.</p></main></body></html>';
}

// --- Steuerkanal (nur root im master: `node ctl.js issue|status|finish`) ------------------------------------------
let httpServer = null;
let ctlServer = null;
function finishAll() {
  rmQuiet(PROGRESS); rmQuiet(KEY_FILE); rmQuiet(ANSWERS); rmQuiet(RESULT); rmQuiet(LOG_FILE);
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
      else if (cmd === 'status') s.end(JSON.stringify(Object.assign({ phase: P.phase, step: Q ? cursor() : '' }, P.notes.bot ? { bot: P.notes.bot } : {})) + '\n');
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
