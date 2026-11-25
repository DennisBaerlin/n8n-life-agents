// wizard_klick.cjs -- klickt den Einrichtungs-Fragebogen (provisioning/wizard) im echten Browser durch, mit erfundenen Werten, so
// wie ein Nutzer am Laptop: Seite ueber den Einmal-Link, je Seite lesen, eintippen oder waehlen, "Weiter" druecken, ueber die
// Installation bis zur Seite "Verbinden". Auf dem Weg prueft er die Eigenschaften des Fragebogens (Fall a-f, Kopf von checkTunnelPage).
// Aufruf (Playwright aus tests/install/package-lock.json: npm ci --prefix tests/install):
//   KLICK_URL=<einmal-link> [KLICK_OUT=<ordner>] [KLICK_SHOT=0] [KLICK_FINISH_VIA=fritzbox|tunnel] node tests/install/wizard_klick.cjs
// Exit 0 = alle Seiten bedient und die Seite "Verbinden" (nach der Installation) erreicht; Exit 1 = Seite oder Wert unbekannt oder
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
  'h:ANTHROPIC_API_KEY': process.env.KLICK_ANTHROPIC_KEY || 'test-fake-ci-anthropic-key-0000000000',
  backup_dir_custom: process.env.KLICK_BACKUP_DIR || '/srv/lifeagents-backup',
};
// Auswahl-Seiten: gewuenschter Wert; fehlt der Eintrag, nimmt der Klicker die vorgewaehlte Antwort (sonst die erste).
// reach: erst der Tunnel (Seite "tunnel" mit Anmeldung bei Tailscale, Faelle c-e), danach je KLICK_FINISH_VIA der Weg zum Ende.
const CHOOSE = {
  'h:OWNER_LANGUAGE': 'de', 'h:OWNER_PERSONA': 'neutral', tg_why: 'both', voice: 'no', backup_dir: 'other', fb_dslite: 'no',
};
// Ohne Tailscale-Konto geht der Tunnel-Weg nach der Anmeldeseite nicht weiter (die Installation laeuft erst danach). Der Lauf
// wechselt dort ueber "Zurueck" und die Uebersicht auf die FritzBox-Adresse (fritzbox) und installiert so; mit einem
// Test-Tailnet-Schluessel in den Antworten (tunnel) wartet er stattdessen, bis die Anmeldung durch ist.
const FINISH_VIA = process.env.KLICK_FINISH_VIA || 'fritzbox';
FILL['h:DOMAIN'] = 'ci-runner.example.org';
// Module: alle; die optionale Paperless-Adresse wird uebersprungen (Fall a prueft, was danach kommt).

const log = (m) => process.stdout.write(`[klick] ${m}\n`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let shot = 0;
let tunnelDetour = 'todo';   // todo -> done, wenn die Tunnel-Seite geprueft und der Weg gewechselt ist
let layoutChecked = false;
const seenIds = [];

function check(cond, msg) { if (!cond) throw new Error(`Pruefung verletzt: ${msg}`); log(`  ok: ${msg}`); }

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

// Fall f: bei 1280 px Breite steht das Logo buendig mit der Schritt-Leiste (Abstand der linken Kanten <= 2 px).
async function checkLayout(page) {
  const d = await page.evaluate(() => {
    const w = document.querySelector('.wordmark'); const i = document.querySelector('.la-rail-step > i');
    return w && i ? Math.abs(w.getBoundingClientRect().left - i.getBoundingClientRect().left) : null;
  });
  check(d !== null && d <= 2, `Logo buendig mit der Schritt-Leiste (Abstand ${d === null ? '?' : d.toFixed(1)} px)`);
}

// Faelle c-e auf der Tailscale-Seite (Seite "tunnel", vor der Installation); Merkmale ueber Seiten-id, Rail-Schritt und Elemente,
// nicht ueber Wortlaute (die Texte aendern sich).
//   c: Seite kommt VOR der Installation, die Leiste steht auf "install", bis hierhin lief keine Installation
//   d: Knopf zur Tailscale-Anmeldung oeffnet ein neues Fenster, die Fragebogen-Adresse bleibt; QR-Code bei 1280 px sichtbar, bei 600 px nicht
//   e: "Zurueck" fuehrt zur Uebersicht
async function checkTunnelPage(page, s) {
  const p = s.page;
  check(!seenIds.includes('install'), 'Tailscale-Seite kommt vor der Installation');
  check(p.step && p.step.current === 'install', 'Schritt-Leiste steht auf der Installation');
  // Tailscale starten braucht beim ersten Mal das Abbild; "gestoert" bietet "Erneut pruefen" (#nx).
  const link = page.locator('a[target="_blank"][href^="https://login.tailscale.com/"]').first();
  const end = Date.now() + 8 * 60 * 1000;
  while (!(await link.count())) {
    if (Date.now() > end) throw new Error('Tailscale-Seite ohne Anmelde-Link (8 Min)');
    const x = await state(page);
    if (x.page && x.page.id !== 'tunnel') throw new Error(`Tailscale-Seite wechselte ohne Anmeldung zu ${x.page.id}`);
    if (x.page && x.page.action && (await page.locator('#nx').count())) { await page.locator('#nx').click().catch(() => {}); }
    await sleep(2000);
  }
  await snap(page, 'tunnel');
  const before = page.url();
  await page.setViewportSize({ width: 1280, height: 900 });
  check(await page.locator('.pair.qr-desk .qr svg').first().isVisible(), 'QR-Code bei 1280 px sichtbar');
  await page.setViewportSize({ width: 600, height: 900 });
  check(!(await page.locator('.pair.qr-desk .qr').first().isVisible()), 'QR-Code bei 600 px nicht sichtbar');
  await page.setViewportSize({ width: 1280, height: 900 });
  const [pop] = await Promise.all([page.waitForEvent('popup', { timeout: 15000 }), link.click()]);
  check(!!pop, 'Anmeldung oeffnet ein neues Fenster');
  await pop.close().catch(() => {});
  check(page.url() === before, 'Adresse des Fragebogens bleibt gleich');
  if (FINISH_VIA === 'tunnel') return 'wait';
  await page.locator('#bk').click();
  const x = await waitUntil(page, (st) => st.page && st.page.id === 'review', 30000);
  check(!!x, 'Zurueck fuehrt zur Uebersicht');
  return 'switch';
}
async function waitUntil(page, fn, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const st = await state(page); if (fn(st)) return st; await sleep(500); }
  return null;
}

async function handle(page, s) {
  const p = s.page;
  const id = p.id;
  if (seenIds[seenIds.length - 1] !== id) seenIds.push(id);
  if (!layoutChecked && !p.poll && p.title) { layoutChecked = true; await page.setViewportSize({ width: 1280, height: 900 }); await checkLayout(page); }
  if (p.poll && p.kind !== 'connect' && p.kind !== 'install') { await sleep(1000); return; }
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
    const want = id === 'reach' ? (FINISH_VIA === 'tunnel' || tunnelDetour === 'todo' ? 'tunnel' : 'fritzbox') : CHOOSE[id];
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
      const b = page.locator(`[data-m="${v}"]`);
      if ((await b.getAttribute('aria-pressed')) !== 'true') await b.click();
    }
    log(`Module: ${opts.join(', ')}`);
    await snap(page, id);
    return press(page, id);
  }
  if (['text', 'date', 'secret'].includes(p.kind)) {
    const inp = page.locator('#in');
    const have = await inp.inputValue();
    if (FILL[id] !== undefined) {
      await inp.fill(FILL[id]);
    } else if (!have) {
      if (p.optional) {
        await snap(page, id);
        await page.locator('#sk').click();
        if (!(await waitChange(page, id, 45000))) throw new Error(`Seite ${id}: Ueberspringen ohne neue Seite`);
        if (id.startsWith('s:paperless:')) {
          // Fall a: ohne Paperless-Adresse fragt der Fragebogen nicht nach dem Zugangstoken (der waere ohne Adresse nutzlos).
          const nx = await state(page);
          check(!!nx.page && !String(nx.page.id).startsWith('c:paperless:'), 'nach uebersprungener Paperless-Adresse kein Zugangstoken-Frage');
        }
        return;
      }
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
  if (p.kind === 'connect' && id === 'tunnel') {
    // Anmeldung bei Tailscale VOR der Installation (Faelle c-e). Ohne Konto geht es hier nicht weiter: der Lauf wechselt ueber
    // "Zurueck" zur Uebersicht und waehlt dort die FritzBox-Adresse (KLICK_FINISH_VIA=fritzbox) oder wartet auf die
    // Anmeldung per Test-Tailnet-Schluessel (tunnel).
    const r = tunnelDetour === 'todo' ? await checkTunnelPage(page, s) : 'wait';
    tunnelDetour = 'done';
    if (r === 'switch') return;
    if (!(await waitChange(page, 'tunnel', 10 * 60 * 1000))) throw new Error('Tailscale-Anmeldung: keine neue Seite nach 10 Min');
    return;
  }
  if (p.kind === 'connect') {
    // Seite "Verbinden" nach der Installation: ab hier kommt das Koppeln mit Telegram (naechster Schritt des Laufs, nicht des Klickers).
    await snap(page, id);
    log('Verbinden erreicht (Installation fertig)');
    const e = new Error('__done__');
    e.done = true;
    throw e;
  }
  if (p.kind === 'review') {
    // Fall b: keine eigene Bestaetigungsseite mehr; beim Tunnel-Weg steht ein Hinweis auf die Anmeldung auf der Uebersicht.
    check(!seenIds.includes('confirm'), 'keine Seite "Das wird auf deinem Rechner geaendert"');
    const viaTunnel = !!p.note;
    if (tunnelDetour === 'todo') check(viaTunnel, 'Uebersicht (Tunnel) nennt die Anmeldung als naechsten Schritt');
    else if (!viaTunnel) check(true, 'Uebersicht (FritzBox) ohne Tunnel-Hinweis');
    await snap(page, id);
    if (viaTunnel && tunnelDetour === 'done' && FINISH_VIA !== 'tunnel') {
      // Zurueck von der Tailscale-Seite: Weg aendern (Zeile "Erreichbarkeit" -> Seite reach), dort die FritzBox-Adresse waehlen.
      const at = p.rows.findIndex((r) => r.goto === 'reach');
      if (at < 0) throw new Error('Uebersicht ohne Zeile zum Aendern des Wegs');
      await page.locator('.rv button').nth(at).click();
      if (!(await waitUntil(page, (st) => st.page && st.page.id === 'reach', 30000))) throw new Error('Uebersicht: "Aendern" fuehrte nicht zur Wahl des Wegs');
      return;
    }
    if (!viaTunnel) return press(page, id);
    // Tunnel: "Weiter" fuehrt zur Tailscale-Seite, nicht zur Installation.
    await page.locator('#nx').click();
    if (!(await waitUntil(page, (st) => st.page && st.page.id === 'tunnel', 45000))) throw new Error('Uebersicht (Tunnel): nach "Weiter" kam nicht die Tailscale-Seite');
    return;
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
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, locale: 'de-DE' });
  const page = await ctx.newPage();
  const seen = [];
  let rc = 1;
  try {
    await page.goto(URL_, { waitUntil: 'domcontentloaded' });
    for (const deadline = Date.now() + 60 * 60 * 1000; Date.now() < deadline;) {
      const s = await state(page);
      if (s.offline || !s.page) { await sleep(1000); continue; }
      if (seen[seen.length - 1] !== s.page.id) { seen.push(s.page.id); log(`Seite ${seen.length}: ${s.page.id} (${s.page.kind})`); }
      await handle(page, s);
    }
    throw new Error('Zeitgrenze (60 Min) im Klickweg');
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
