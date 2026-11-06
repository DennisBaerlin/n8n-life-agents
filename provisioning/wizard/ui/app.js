// Wizard-Oberfläche: zeigt die Seite, die der Server vorgibt (server.js view()), und schickt die Antwort zurück.
// Keine eigene Ablauf-Logik und keine Prüfregeln hier — beides liegt im Server (flow.js, bridge.sh).
// Sicherheit: kein innerHTML mit Server-Text (nur textContent), Ausnahme der QR-Code (vom Server aus eigenem Code erzeugt);
// POST nur mit CSRF-Kopf; keine Inline-Skripte (CSP script-src 'self').
'use strict';
/* ui-copy:begin ui.steps.js (kopiert von scripts/build_ui_tokens.ps1 aus config/ui.steps.js, nicht von Hand aendern) */
// Schritt-Leiste der Einrichtung, gemeinsam für Start-App und Fragebogen im selben Fenster: Jede Seite zeichnet sie selbst,
// mit derselben Reihenfolge und demselben Aussehen (config/ui.steps.css). Kopie per scripts/build_ui_tokens.ps1 als Block in
// die Datei jeder Oberfläche (so liegt sie auch im Release-Paket des Fragebogens), kein Nachladen zur Laufzeit.
// Die App zeichnet prepare, docker, power und done; der Fragebogen questions (mit Unterschritten), install und connect.
// Texte stehen hier keine: Der Aufrufer gibt sie mit (Fragebogen aus dem Textkatalog, Schlüssel core.wizard.step.<id>).
// Nur textContent, kein HTML, keine Abhängigkeit.
const UiSteps = {
  steps: [
    { id: 'prepare' },
    { id: 'docker' },
    { id: 'questions', sub: [{ id: 'about' }, { id: 'access' }, { id: 'modules' }, { id: 'reach' }, { id: 'check' }] },
    { id: 'install' },
    { id: 'connect' },
    { id: 'power' },
    { id: 'done' },
  ],

  /**
   * Leiste in `el` zeichnen. current = id aus steps, sub = id eines Unterschritts (nur bei questions) oder leer.
   * text = { step: (id) => Beschriftung, short: (n, total, name) => „Schritt 3 von 7 · Fragen“, aria: Name der Leiste }.
   * Davor = erledigt, danach = offen; Unterschritte stehen nur beim aktuellen Schritt (sonst wird es zu lang).
   * Unter 600 px Breite zeigt das CSS statt der Liste die kurze Zeile.
   */
  render(el, current, sub, text) {
    const mk = (tag, cls, txt) => {
      const e = document.createElement(tag);
      if (cls) e.className = cls;
      if (txt != null) e.textContent = txt;
      return e;
    };
    const at = this.steps.findIndex((s) => s.id === current);
    const last = this.steps.length - 1;
    const list = mk('ol', 'la-rail-list');
    this.steps.forEach((s, i) => {
      // Der letzte Schritt („Fertig“) ist erreicht = erledigt, daher dort das Häkchen statt des offenen Kreises.
      const state = i < at || (i === at && i === last) ? 'done' : i === at ? 'now' : 'todo';
      const li = mk('li', 'la-rail-step ' + state);
      if (i === at) li.setAttribute('aria-current', 'step');
      li.append(mk('i', null, state === 'done' ? '✓' : ''), mk('span', null, text.step(s.id)));
      if (state === 'now' && s.sub) {
        const subAt = s.sub.findIndex((x) => x.id === sub);
        const ul = mk('ul', 'la-rail-sub');
        s.sub.forEach((x, k) => {
          const sli = mk('li', k < subAt ? 'done' : k === subAt ? 'now' : 'todo', text.step(x.id));
          if (k === subAt) sli.setAttribute('aria-current', 'step');
          ul.append(sli);
        });
        li.append(ul);
      }
      list.append(li);
    });
    const short = mk('p', 'la-rail-short', at < 0 ? '' : text.short(at + 1, this.steps.length, text.step(this.steps[at].id)));
    el.setAttribute('aria-label', text.aria);
    el.replaceChildren(list, short);
  },
};
/* ui-copy:end */
/* ui-copy:begin ui.nudge.js (kopiert von scripts/build_ui_tokens.ps1 aus config/ui.nudge.js, nicht von Hand aendern) */
// Lese-Hinweis am Hauptknopf (Owner-Wunsch: erst lesen lassen, dann dezent auf „Weiter“ zeigen; Werte von der Leitung),
// gemeinsam für Fragebogen, Start-App und die Knöpfe in den Bildern. Kopie per scripts/build_ui_tokens.ps1 als Block in die
// Datei jeder Oberfläche (Get-UiCopies), Aussehen in config/ui.nudge.css. Keine Abhängigkeit, kein Inline-Stil (CSP).
//   UiNudge.start(getButton, isReady) beim Wechsel auf eine neue Seite; getButton() liefert den Hauptknopf (darf wechseln),
//   isReady() sagt, ob die Seite gerade gültig ist (keine Fehlermeldung, Pflichtfeld gefüllt, keine laufende Prüfung).
// Regeln: 12 s ohne Eingabe (keydown, input, pointerdown, scroll, wheel setzen die Uhr zurück) -> genau 2 Pulse von je 1,5 s,
// danach still; erneut erst nach weiteren 12 s Ruhe, höchstens 2-mal je Seite. Nicht bereit = kein Puls, es zählt nicht.
// Ohne Bewegung (prefers-reduced-motion) zeigt das CSS nur eine farbige Hervorhebung.
const UiNudge = {
  IDLE_MS: 12000,
  PULSE_MS: 3000,
  MAX: 2,
  CLS: 'la-nudge',
  _t: null,
  _n: 0,
  _get: null,
  _ready: null,
  _bound: false,

  start(getButton, isReady) {
    this.stop();
    this._get = getButton;
    this._ready = isReady || null;
    this._n = 0;
    if (!this._bound) {
      this._bound = true;
      for (const ev of ['keydown', 'input', 'pointerdown', 'scroll', 'wheel']) {
        document.addEventListener(ev, () => this._poke(), { capture: true, passive: true });
      }
    }
    this._arm();
  },
  stop() {
    clearTimeout(this._t);
    const b = this._get && this._get();
    if (b) b.classList.remove(this.CLS);
  },
  _arm() {
    clearTimeout(this._t);
    if (this._n >= this.MAX) return;
    this._t = setTimeout(() => this._fire(), this.IDLE_MS);
  },
  _fire() {
    const b = this._get && this._get();
    if (!b || b.disabled || (this._ready && !this._ready())) { this._arm(); return; }
    this._n += 1;
    b.classList.add(this.CLS);
    this._t = setTimeout(() => { b.classList.remove(this.CLS); this._arm(); }, this.PULSE_MS);
  },
  _poke() {
    if (!this._get) return;
    const b = this._get();
    if (b) b.classList.remove(this.CLS);
    this._arm();
  },
};
/* ui-copy:end */
(function () {
  const PREVIEW = window.WIZARD_PREVIEW || null;
  const main = document.getElementById('m');
  let csrf = '';
  let page = null;
  let pollT = null;
  let busy = false;
  let renderedId = null;
  // Texte der Knöpfe und festen Hinweise in der Sprache der Seite (server.js uiTexts); vor der ersten Seite Deutsch.
  let T = { next: 'Weiter', back: 'Zurück', skip: 'Überspringen', retry: 'Noch einmal versuchen', change: 'Ändern', change_label: '{label} ändern',
    secret_kept: 'Schon eingetragen. Leer lassen, um es zu behalten.', found_addresses: 'Gefundene Adressen', one_moment: 'Einen Moment …',
    report_show: 'Bericht für die Hilfe anzeigen', report_note: 'Darin stehen keine Namen und keine Schlüssel, nur der Stand der Einrichtung.',
    report_copied: 'In die Zwischenablage kopiert', offline: 'Keine Verbindung zur Einrichtung. Versuch es gleich noch einmal.',
    open_via_app: 'Bitte öffne die Einrichtung über die App', choose: 'Wähle eine Antwort aus.',
    session_expired: 'Die Sitzung ist abgelaufen. Schließe das Fenster und öffne die App lifeagents neu. Deine Antworten sind gespeichert.' };

  function h(tag, attrs) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === 'text') e.textContent = v;
      else if (k === 'on') for (const [ev, fn] of Object.entries(v)) e.addEventListener(ev, fn);
      else e.setAttribute(k, v === true ? '' : v);
    }
    for (let i = 2; i < arguments.length; i++) {
      const c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      if (Array.isArray(c)) c.forEach((x) => x && e.appendChild(typeof x === 'string' ? document.createTextNode(x) : x));
      else e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return e;
  }

  async function api(method, path, body) {
    if (PREVIEW) return PREVIEW.api(method, path, body);
    const opt = { method, credentials: 'same-origin', headers: {} };
    if (method === 'POST') {
      opt.headers['Content-Type'] = 'application/json';
      opt.headers['X-CSRF-Token'] = csrf;
      opt.body = JSON.stringify(body || {});
    }
    let r;
    try { r = await fetch(path, opt); } catch (_) { return { offline: true }; }
    let j = {};
    try { j = await r.json(); } catch (_) { /* leer */ }
    if (r.status === 401 || r.status === 403) return { fatal: true };
    return Object.assign({ status: r.status }, j);
  }

  function apply(r) {
    if (r.csrf) csrf = r.csrf;
    if (r.page) {
      page = r.page;
      if (page.t) T = page.t;
      if (page.lang) document.documentElement.lang = page.lang;
      if (T.doc_title) document.title = T.doc_title;
      rail(page);
      render();
    }
  }

  async function load() {
    clearTimeout(pollT);
    const r = await api('GET', '/api/state');
    if (r.fatal) return fatal();
    if (r.offline || !r.page) { pollT = setTimeout(load, 3000); return; }
    apply(r);
    if (PREVIEW) {   // Vorschau-Bilder: Eingabe und Fehlermeldung eines festgehaltenen Zustands
      const i = document.getElementById('in');
      if (i && PREVIEW.value) { i.value = PREVIEW.value; if (page.live) liveSoon(page.id, 0); }
      if (PREVIEW.error) setErr(PREVIEW.error);
    }
  }

  // ready — ist die Seite gerade gültig für den Hinweis am Weiter-Knopf? Kein Puls bei Fehlermeldung, laufender Prüfung
  //   oder Suche, leerem Pflichtfeld, fehlender Auswahl oder einer Adresse, die nicht auf diesen Anschluss zeigt.
  function ready() {
    const p = page;
    if (!p || busy || p.poll) return false;
    const er = document.getElementById('er');
    if (er && er.textContent) return false;
    if (p.kind === 'choice' && !currentValue()) return false;
    if (['text', 'date', 'secret'].includes(p.kind) && !p.optional && !p.hasSecret) {
      const i = document.getElementById('in');
      if (!i || !i.value.trim()) return false;
    }
    const lv = document.getElementById('live');
    return !(lv && / warn/.test(lv.className));
  }

  // Live-Prüfung einer Eingabe (POST /api/check, ändert nichts am Stand): kurz nach dem letzten Tastendruck.
  let liveT = null;
  function liveSoon(id, ms) {
    clearTimeout(liveT);
    liveT = setTimeout(async () => {
      const i = document.getElementById('in');
      const box = document.getElementById('live');
      if (!i || !box) return;
      if (!i.value.trim()) { box.textContent = ''; box.className = 'live'; return; }
      const r = await api('POST', '/api/check', { id, value: i.value });
      if (r.csrf) csrf = r.csrf;
      if (!r.live || document.getElementById('live') !== box) return;
      box.textContent = r.live.text;
      // Darstellung wie die übrigen Rückmeldungen: gefunden = Häkchen-Zeile, falsche Adresse = Warnung, noch nicht = Hinweis.
      box.className = 'live ' + (({ ok: 'check', found: 'check', wrong_ip: 'note warn' })[r.live.state] || 'note');
    }, ms === undefined ? 700 : ms);
  }

  // Schritt-Leiste (gemeinsamer Block ui.steps.js oben, Texte aus dem Katalog in der Sprache der Seite).
  function rail(p) {
    const el = document.getElementById('rail');
    if (!el || !p.step || typeof UiSteps === 'undefined') return;
    const fill = (s, v) => s.replace(/\{(\w+)\}/g, (m, k) => (v[k] !== undefined ? String(v[k]) : m));
    UiSteps.render(el, p.step.current, p.step.sub, {
      step: (id) => (T.step && T.step[id]) || id,
      short: (n, total, name) => fill(T.step_short || '{n}/{total} · {name}', { n, total, name }),
      aria: T.step_aria || '' });
    el.hidden = false;
  }

  function fatal() {
    clearTimeout(pollT);
    main.replaceChildren(h('h1', { text: T.open_via_app }),
      h('p', { class: 'lead', text: T.session_expired }));
  }

  function helpNodes(blocks) {
    return (blocks || []).map((b) => (b.ol ? h('ol', null, b.ol.map((t) => h('li', { text: t }))) : h('p', { text: b.p })));
  }

  function setErr(t) { const e = document.getElementById('er'); if (e) e.textContent = t || ''; }

  async function post(path, body, okMsg) {
    if (busy) return;
    busy = true;
    const btn = document.getElementById('nx');
    if (btn) btn.disabled = true;
    setErr('');
    const r = await api('POST', path, body);
    busy = false;
    if (r.fatal) return fatal();
    if (r.offline) { if (btn) btn.disabled = false; setErr(T.offline); return; }
    if (r.error) { if (r.csrf) csrf = r.csrf; if (btn) btn.disabled = false; setErr(r.error); return; }
    const msg = r.check || r.note || okMsg;
    if (msg) {
      const ck = document.getElementById('ck');
      if (ck) ck.replaceChildren(h('div', { class: r.note ? 'note warn' : 'check' }, (r.note ? '' : '✓ ') + msg));
      setTimeout(() => apply(r), r.note ? 1800 : 900);
      return;
    }
    apply(r);
  }

  function currentValue() {
    const p = page;
    if (p.kind === 'choice') { const s = main.querySelector('[data-c].sel'); return s ? s.dataset.c : ''; }
    if (p.kind === 'multi') return Array.from(main.querySelectorAll('[data-m].sel')).map((b) => b.dataset.m);
    const i = document.getElementById('in');
    return i ? i.value : null;
  }

  function next() {
    const p = page;
    if (p.action) return post('/api/action', { name: p.action });
    if (p.kind === 'choice' && !currentValue()) return setErr(T.choose);
    return post('/api/answer', { id: p.id, value: currentValue() });
  }

  function render() {
    clearTimeout(pollT);
    const p = page;
    // Neu zeichnen derselben Seite (Abfrage während einer Suche): schon Getipptes bleibt stehen.
    const prevIn = document.getElementById('in');
    const keep = prevIn && renderedId === p.id && prevIn.value ? prevIn.value : null;
    const fresh = renderedId !== p.id;
    renderedId = p.id;
    // Bild dieser Seite (di9, ui/art/): art.js entscheidet nach page.id, null = kein Bild; side = neben die Auswahl.
    const art = window.WizardArt && typeof window.WizardArt.mount === 'function' ? window.WizardArt.mount(p) : null;
    const kids = [
      h('h1', { id: 'title', text: p.title })];
    const help = p.kind === 'connect' && p.qr ? [] : helpNodes(p.help);
    if (help[0] && help[0].tagName === 'P') help[0].className = 'lead';
    kids.push(...help);
    if (p.note && p.note.busy) kids.push(h('ul', { class: 'steps' }, h('li', { class: 'run' }, h('i', { 'aria-hidden': 'true' }), p.note.text)));
    else if (p.note) kids.push(h('div', { class: 'note ' + (p.note.kind || ''), text: p.note.text }));

    if (['text', 'date', 'secret'].includes(p.kind)) {
      const type = p.kind === 'secret' ? 'password' : p.kind === 'date' ? 'date' : 'text';
      const inp = h('input', { id: 'in', type, value: p.value || '', placeholder: p.hasSecret ? T.secret_kept : (p.placeholder || null),
        autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'aria-describedby': 'er',
        on: { keydown: (e) => { if (e.key === 'Enter') { e.preventDefault(); next(); } },
          input: () => { if (p.live) liveSoon(p.id); } } });
      // Fester Teil hinter dem Feld (z. B. .<kennung>.myfritz.net): nur der Gerätename vorne wird getippt.
      kids.push(h('label', { class: 'sr', for: 'in', text: p.title }),
        p.suffix ? h('div', { class: 'with-suffix' }, inp, h('span', { class: 'suffix', text: p.suffix })) : inp);
      // Live-Prüfung (MyFRITZ): Stand der Adresse direkt unter dem Feld, daneben „Erneut prüfen“ (die FritzBox braucht etwa
      // eine Minute) und der Name aus der FritzBox als kleiner Knopf zum Antippen (kompakt, passt ins App-Fenster 760 × 640).
      if (p.live) {
        const tap = (s) => h('button', { type: 'button', class: 'chip', on: { click: () => {
          const i = document.getElementById('in'); i.value = s; i.focus(); liveSoon(p.id, 0);
        } } }, s);
        kids.push(h('div', { class: 'live-row' },
          (p.suggestions || []).length ? h('span', { class: 'small' }, p.suggestLabel + ': ', ...p.suggestions.map(tap)) : null,
          h('button', { type: 'button', class: 'link', id: 'rc', on: { click: () => liveSoon(p.id, 0) } }, p.live.recheck)),
        h('div', { class: 'live', id: 'live', role: 'status' }));
      } else if ((p.suggestions || []).length) {
        // Vorschläge (z. B. mehrere gefundene Paperless-Adressen): Antippen trägt die Adresse ins Feld ein.
        kids.push(h('div', { class: 'suggest', role: 'group', 'aria-label': p.suggestLabel || T.found_addresses }, p.suggestions.map((s) => h('button', {
          type: 'button', class: 'choice', on: { click: (e) => {
            const i = document.getElementById('in'); i.value = s; i.focus();
            main.querySelectorAll('.suggest .choice').forEach((b) => b.classList.toggle('sel', b === e.currentTarget));
          } } }, h('b', { text: s })))));
      }
    }
    if (p.kind === 'choice' || p.kind === 'multi') {
      const multi = p.kind === 'multi';
      const wrap = h('div', { class: 'choices' + (multi ? ' multi' : '') + ((p.options || []).length > 6 ? ' long' : ''), role: multi ? 'group' : 'radiogroup', 'aria-labelledby': 'title' });
      for (const o of p.options || []) {
        const sel = multi ? (p.value || []).includes(o.value) : p.value === o.value;
        const b = h('button', { type: 'button', class: 'choice' + (sel ? ' sel' : ''), [multi ? 'data-m' : 'data-c']: o.value,
          role: multi ? null : 'radio', 'aria-checked': multi ? null : String(sel), 'aria-pressed': multi ? String(sel) : null },
        h('b', null, o.label, o.tag ? h('span', { class: 'tag', text: o.tag }) : null), o.desc ? h('small', { text: o.desc }) : null);
        b.addEventListener('click', () => {
          if (multi) { b.classList.toggle('sel'); b.setAttribute('aria-pressed', String(b.classList.contains('sel'))); return; }
          wrap.querySelectorAll('[data-c]').forEach((x) => { x.classList.toggle('sel', x === b); x.setAttribute('aria-checked', String(x === b)); });
          setErr('');
          if (art && art.select) art.select(o.value);   // Bild folgt der Auswahl (z. B. Charakter des Bots)
          // Sprach-Seite: die ganze Einrichtung wechselt sofort; die Auswahl selbst bleibt in Eigenschreibweise.
          if (p.langSwitch) post('/api/lang', { lang: o.value });
        });
        wrap.appendChild(b);
      }
      kids.push(art && art.side ? h('div', { class: 'with-art' }, wrap, art.el) : wrap);
    }
    if (p.kind === 'review') {
      kids.push(h('dl', null, (p.rows || []).map((r) => h('div', { class: 'rv' }, h('dt', { text: r.label }), h('dd', { text: String(r.value).replace(/\.(?=\S)/g, '.​') }),
        h('button', { type: 'button', 'aria-label': T.change_label.replace('{label}', r.label), on: { click: () => post('/api/goto', { id: r.goto }) } }, T.change)))));
    }
    if (p.kind === 'confirm') {
      for (const g of p.groups || []) kids.push(h('p', { class: 'group-title', text: g.title }), h('ul', null, g.items.map((t) => h('li', { text: t }))));
    }
    if (p.kind === 'install') {
      kids.push(h('ul', { class: 'steps' }, (p.items || []).map((it) => h('li', { class: it.state }, h('i', { 'aria-hidden': 'true', text: it.state === 'ok' ? '✓' : it.state === 'bad' ? '!' : '' }), it.text))));
    }
    if (p.kind === 'connect') {
      if (p.qr) {
        const box = h('div', { class: 'qr' });
        box.innerHTML = p.qr;   // eigener Code (qr.js), keine Nutzer- oder Fremddaten
        kids.push(h('div', { class: 'pair' }, box, h('div', null, helpNodes(p.help))));
      }
      if (p.link) kids.push(h('p', null, h('a', { class: p.link.primary ? 'button primary' : null, href: p.link.href, target: '_blank', rel: 'noopener noreferrer', text: p.link.label })));
      if (p.wait) kids.push(h('ul', { class: 'steps' }, h('li', { class: 'run' }, h('i', { 'aria-hidden': 'true' }), p.wait)));
    } else if (p.link) {
      kids.push(h('p', null, h('a', { href: p.link.href, target: '_blank', rel: 'noopener noreferrer', text: p.link.label })));
    }
    // Nach „Weiter“ holt die App (gleiches Fenster) ihre eigenen Seiten zurück, sobald sie phase=handoff sieht (alle 3 s).
    if (p.kind === 'handoff' && p.done) kids.push(h('ul', { class: 'steps' }, h('li', { class: 'run' }, h('i', { 'aria-hidden': 'true' }), T.one_moment)));

    kids.push(h('div', { class: 'err', id: 'er', role: 'alert' }), h('div', { id: 'ck' }));
    // Einbaustelle für Bilder und Animationen (di9, ui/art/): art.js entscheidet nach page.id, null = kein Bild.
    // Platz und Verhalten im schmalen Fenster regelt art.css; die CSP gilt auch dort (kein style=, kein Inline-Skript).
    if (art && art.el && !art.side) kids.push(art.el);
    if (p.kind === 'install' && p.failed) {
      kids.push(h('p', null, h('button', { type: 'button', id: 'rp', on: { click: showReport } }, T.report_show)), h('div', { id: 'rpt' }));
    }
    kids.push(h('div', { class: 'spacer' }));
    const actions = h('div', { class: 'actions' });
    actions.appendChild(p.canBack ? h('button', { type: 'button', class: 'link', id: 'bk', on: { click: () => post('/api/back', {}) } }, T.back) : h('span'));
    const right = h('div', { class: 'right' });
    if (p.optional && p.kind !== 'multi') right.appendChild(h('button', { type: 'button', class: 'link', id: 'sk', on: { click: () => post('/api/answer', { id: p.id, value: '', skip: true }) } }, T.skip));
    if (p.kind === 'install' && p.failed) right.appendChild(h('button', { type: 'button', class: 'primary', id: 'nx', on: { click: () => post('/api/action', { name: 'retry' }) } }, T.retry));
    else if (p.next) right.appendChild(h('button', { type: 'button', class: 'primary', id: 'nx', on: { click: next } }, p.next));
    actions.appendChild(right);
    kids.push(actions);
    main.replaceChildren(...kids);
    const f = document.getElementById('in');
    if (f && keep !== null) f.value = keep;
    if (f) f.focus();
    if (p.live && f && f.value) liveSoon(p.id, 0);
    if (p.poll && !PREVIEW) pollT = setTimeout(load, 1500);
    // Lese-Hinweis am Weiter-Knopf (gemeinsamer Block ui.nudge.js oben): je neue Seite von vorn.
    if (fresh && !PREVIEW && typeof UiNudge !== 'undefined') UiNudge.start(() => document.getElementById('nx'), ready);
  }

  async function showReport() {
    const r = await api('GET', '/api/report');
    if (r.fatal) return fatal();
    const box = document.getElementById('rpt');
    if (!box || !r.text) return;
    box.replaceChildren(h('p', { class: 'small', text: T.report_note }), h('pre', { class: 'report', text: r.text }));
    try { await navigator.clipboard.writeText(r.text); box.prepend(h('div', { class: 'check', text: '✓ ' + T.report_copied })); } catch (_) { /* nur anzeigen */ }
  }

  load();
})();
