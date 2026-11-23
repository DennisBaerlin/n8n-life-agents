// wizard_klick.cjs -- klickt den Einrichtungs-Fragebogen (provisioning/wizard) im echten Browser durch, mit erfundenen Werten, so
// wie ein Nutzer am Laptop: Seite ueber den Einmal-Link, je Seite lesen, eintippen oder waehlen, "Weiter" druecken, ueber die
// Installation bis zur Seite "Verbinden". Aufruf (Playwright aus tests/install/package-lock.json: npm ci --prefix tests/install):
//   KLICK_URL=<einmal-link> [KLICK_OUT=<ordner>] [KLICK_SHOT=0] node tests/install/wizard_klick.cjs
// Exit 0 = alle Seiten bedient und die Seite "Verbinden" zeigt den Anmelde-Link des Tunnels; Exit 1 = Seite oder Wert unbekannt oder
// abgelehnt, Installation gescheitert (die Meldung nennt die Seite, nie einen Wert). Screenshots je Seite in KLICK_OUT.
// Den Seitenzustand liest der Klicker nur lesend ueber GET /api/state (dieselbe Abfrage wie die Seite selbst); alle Eingaben
// laufen durch Tastatur und Maus. Eine neue Frage ohne Eintrag in FILL/CHOOSE bricht ab (wie render_ci_answers.js), statt still
// einen Wert zu raten.
'use strict';
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const URL_ = process.env.KLICK_URL;
const OUT = process.env.KLICK_OUT || path.join(process.cwd(), 'klick-out');
const INSTALL_TIMEOUT_MS = 40 * 60 * 1000;
if (!URL_) { process.stderr.write('KLICK_URL fehlt\n'); process.exit(2); }
fs.mkdirSync(OUT, { recursive: true });

// Erfundene Werte (oeffentliches Repo). Token-Form wie bei Telegram (Zahl:Zeichen); der Bot ist die Attrappe im Lauf.
const FILL = {
  'h:OWNER_FIRST_NAME': 'Ci',
  'h:OWNER_LAST_NAME': 'Runner',
  'h:OWNER_BIRTH_DATE': '1990-01-01',
  // Mit den Secrets des Laufs (KLICK_TELEGRAM_TOKEN, KLICK_ANTHROPIC_KEY) die echten Werte, sonst die erfundenen; nie ausgeben.
  'h:TELEGRAM_BOT_TOKEN': process.env.KLICK_TELEGRAM_TOKEN || '1000001:CIinventedTokenForMockTelegram0000',
  'h:ANTHROPIC_API_KEY': process.env.KLICK_ANTHROPIC_KEY || 'sk-ant-api03-ci-invented-key-00000000000000000000',
  backup_dir_custom: process.env.KLICK_BACKUP_DIR || '/srv/lifeagents-backup',
};
// Auswahl-Seiten: gewuenschter Wert; fehlt der Eintrag, nimmt der Klicker die vorgewaehlte Antwort (sonst die erste).
const CHOOSE = {
  'h:OWNER_LANGUAGE': 'de', 'h:OWNER_PERSONA': 'neutral', tg_why: 'both', voice: 'no', reach: 'tunnel', backup_dir: 'other',
};
// Module: alle bis auf Paperless (dessen Adresse prueft der Fragebogen live gegen ein echtes Paperless im LAN).
const PACKAGES_SKIP = new Set(['paperless']);

const log = (m) => process.stdout.write(`[klick] ${m}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let shot = 0;
let connectWaits = 0;

async function state(page) {
  return page.evaluate(async () => {
    try { const r = await fetch('/api/state', { credentials: 'same-origin' }); return await r.json(); } catch (_) { return { offline: true }; }
  });
}
async function snap(page, id) {
  if (process.env.KLICK_SHOT === '0') return;   // mit echten Zugaengen zeigen Seiten echte Namen (Bot): keine Bilder in oeffentliche Artefakte
  shot += 1;
  const f = path.join(OUT, `${String(shot).padStart(2, '0')}-${id.replace(/[^A-Za-z0-9_.-]/g, '_')}.png`);
  await page.screenshot({ path: f, fullPage: true }).catch(() => {});
}
async function visibleError(page) { return (await page.locator('#er').textContent().catch(() => '')) || ''; }

// waitChange(page, id, ms) -> Seite wechselt (andere id) oder der Wizard ist weg; false bei Zeitablauf.
async function waitChange(page, id, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const s = await state(page);
    if (s.offline || !s.page || s.page.id !== id) return true;
    const er = await visibleError(page);
    if (er) throw new Error(`Seite ${id} meldet einen Fehler: ${er}`);
    await sleep(500);
  }
  return false;
}

async function press(page, id) {
  await page.locator('#nx').click();
  if (!(await waitChange(page, id, 45000))) throw new Error(`Seite ${id}: nach "Weiter" kam keine neue Seite`);
}

async function handle(page, s) {
  const p = s.page;
  const id = p.id;
  if (p.poll && p.kind !== 'connect') { await sleep(1000); return; }
  // Die Seite zeichnet nach einer Antwort erst nach einer kurzen Anzeige der Pruefmeldung (bis ~2 s) neu; wer vorher tippt,
  // tippt ins alte Feld. Darum erst handeln, wenn die Ueberschrift im Browser die der neuen Seite ist.
  // (waitForFunction scheitert an der CSP der Seite: kein eval.)
  if (p.title && p.kind !== 'connect') {
    const end = Date.now() + 15000;
    while ((await page.locator('#title').textContent().catch(() => '')) !== p.title) {
      if (Date.now() > end) throw new Error(`Seite ${id}: Ueberschrift im Browser stimmt nicht mit der Seite ueberein`);
      await sleep(200);
    }
  }

  if (p.kind === 'choice') {
    const want = CHOOSE[id];
    const opts = await page.locator('[data-c]').evaluateAll((els) => els.map((e) => ({ v: e.dataset.c, sel: e.classList.contains('sel') })));
    if (!opts.length) throw new Error(`Seite ${id}: keine Antworten`);
    let pick = want;
    if (pick === undefined) pick = (opts.find((o) => o.sel) || opts[0]).v;
    if (!opts.some((o) => o.v === pick)) throw new Error(`Seite ${id}: Antwort "${pick}" wird nicht angeboten`);
    await page.locator(`[data-c="${pick}"]`).click();
    await snap(page, id);
    return press(page, id);
  }
  if (p.kind === 'multi') {
    const opts = await page.locator('[data-m]').evaluateAll((els) => els.map((e) => e.dataset.m));
    for (const v of opts) {
      if (PACKAGES_SKIP.has(v)) continue;
      const b = page.locator(`[data-m="${v}"]`);
      if ((await b.getAttribute('aria-pressed')) !== 'true') await b.click();
    }
    log(`Module: ${opts.filter((v) => !PACKAGES_SKIP.has(v)).join(', ')}`);
    await snap(page, id);
    return press(page, id);
  }
  if (['text', 'date', 'secret'].includes(p.kind)) {
    const inp = page.locator('#in');
    const have = await inp.inputValue();
    if (FILL[id] !== undefined) {
      await inp.fill(FILL[id]);
    } else if (!have) {
      if (p.optional) { await snap(page, id); await page.locator('#sk').click(); if (!(await waitChange(page, id, 45000))) throw new Error(`Seite ${id}: Ueberspringen ohne neue Seite`); return; }
      throw new Error(`Pflichtfrage ohne erfundenen Wert: ${id} (in wizard_klick.cjs ergaenzen)`);
    }
    await snap(page, id);
    return press(page, id);
  }
  if (p.kind === 'install') {
    log('Installation laeuft (Seite "install") ...');
    const t0 = Date.now();
    let last = '';
    while (Date.now() - t0 < INSTALL_TIMEOUT_MS) {
      const x = await state(page);
      if (x.offline || !x.page || x.page.id !== 'install') { log(`Installation fertig nach ${Math.round((Date.now() - t0) / 1000)} s`); return; }
      if (x.page.failed) {
        const rep = await page.evaluate(async () => { const r = await fetch('/api/report', { credentials: 'same-origin' }); return (await r.json()).text; }).catch(() => '');
        await snap(page, 'install-failed');
        throw new Error(`Installation im Fragebogen fehlgeschlagen. Bericht des Fragebogens:\n${rep}`);
      }
      const prog = (x.page.items || []).filter((i) => i.state === 'ok').length + '/' + (x.page.items || []).length;
      if (prog !== last) { log(`  Schritte fertig: ${prog}`); last = prog; }
      await sleep(3000);
    }
    throw new Error('Installation: Zeitgrenze (40 Min)');
  }
  if (p.kind === 'connect') {
    // Letzte Seite des Klickwegs: mit dem Tunnel (Tailscale) steht hier der Anmelde-Link des echten Tailscale-Dienstes. Weiter geht es
    // nur mit einem Konto; das gibt es im Lauf nicht (Grenze, im Kopf von debian_vm.sh). Die Seite fragt den Stand selbst weiter ab.
    const href = await page.locator('a[href^="https://login.tailscale.com/"]').first().getAttribute('href', { timeout: 1500 }).catch(() => null);
    if (!href) { connectWaits += 1; if (connectWaits > 180) throw new Error('Verbinden-Seite ohne Tailscale-Anmelde-Link'); await sleep(1000); return; }
    await snap(page, id);
    log('Verbinden: Anmelde-Link des Tunnels steht (ohne Tailscale-Konto endet der Klickweg hier)');
    const e = new Error('__done__');
    e.done = true;
    throw e;
  }
  if (p.kind === 'handoff') {
    await snap(page, id);
    log('Letzte Seite erreicht (handoff)');
    const nx = page.locator('#nx');
    if (await nx.count()) await nx.click();
    await sleep(2000);
    const e = new Error('__done__');
    e.done = true;
    throw e;
  }
  // review, confirm, tg_phone, tg_pc, fb_*: nur lesen und "Weiter"
  if (p.next) { await snap(page, id); return press(page, id); }
  throw new Error(`Unbekannte Seite ${id} (kind ${p.kind})`);
}

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1000, height: 900 }, locale: 'de-DE' });
  const page = await ctx.newPage();
  const seen = [];
  let rc = 1;
  try {
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    for (let i = 0; i < 200; i += 1) {
      const s = await state(page);
      if (s.offline || !s.page) { await sleep(1000); continue; }
      if (seen[seen.length - 1] !== s.page.id) { seen.push(s.page.id); log(`Seite ${seen.length}: ${s.page.id} (${s.page.kind})`); }
      await handle(page, s);
    }
    throw new Error('Zu viele Seiten (Schleife?)');
  } catch (e) {
    if (e.done) { rc = 0; log(`FERTIG, ${seen.length} Seiten: ${seen.join(' > ')}`); } else {
      log(`FEHLER: ${e.message}`);
      await snap(page, 'fehler');
      fs.writeFileSync(path.join(OUT, 'fehler.txt'), `${e.stack || e.message}\nSeiten bis dahin: ${seen.join(' > ')}\n`);
    }
  }
  await browser.close();
  process.exit(rc);
})();
