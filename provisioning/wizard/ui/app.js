// Wizard-Oberfläche: zeigt die Seite, die der Server vorgibt (server.js view()), und schickt die Antwort zurück.
// Keine eigene Ablauf-Logik und keine Prüfregeln hier — beides liegt im Server (flow.js, bridge.sh).
// Sicherheit: kein innerHTML mit Server-Text (nur textContent), Ausnahme der QR-Code (vom Server aus eigenem Code erzeugt);
// POST nur mit CSRF-Kopf; keine Inline-Skripte (CSP script-src 'self').
'use strict';
(function () {
  const PREVIEW = window.WIZARD_PREVIEW || null;
  const main = document.getElementById('m');
  let csrf = '';
  let page = null;
  let pollT = null;
  let busy = false;
  let renderedId = null;

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
    if (r.page) { page = r.page; render(); }
  }

  async function load() {
    clearTimeout(pollT);
    const r = await api('GET', '/api/state');
    if (r.fatal) return fatal();
    if (r.offline || !r.page) { pollT = setTimeout(load, 3000); return; }
    apply(r);
    if (PREVIEW) {   // Vorschau-Bilder: Eingabe und Fehlermeldung eines festgehaltenen Zustands
      const i = document.getElementById('in');
      if (i && PREVIEW.value) i.value = PREVIEW.value;
      if (PREVIEW.error) setErr(PREVIEW.error);
    }
  }

  function fatal() {
    clearTimeout(pollT);
    main.replaceChildren(h('h1', { text: 'Bitte öffne die Einrichtung über die App' }),
      h('p', { class: 'lead', text: 'Die Sitzung ist abgelaufen. Schließe das Fenster und öffne die App lifeagents neu. Deine Antworten sind gespeichert.' }));
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
    if (r.offline) { if (btn) btn.disabled = false; setErr('Keine Verbindung zum Wizard. Versuch es gleich noch einmal.'); return; }
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
    if (p.kind === 'choice' && !currentValue()) return setErr('Wähle eine Antwort aus.');
    return post('/api/answer', { id: p.id, value: currentValue() });
  }

  function render() {
    clearTimeout(pollT);
    const p = page;
    // Neu zeichnen derselben Seite (Abfrage während einer Suche): schon Getipptes bleibt stehen.
    const prevIn = document.getElementById('in');
    const keep = prevIn && renderedId === p.id && prevIn.value ? prevIn.value : null;
    renderedId = p.id;
    let art = null;   // Bild dieser Seite (di9, ui/art/art.js), s. u.
    const kids = [
      h('h1', { id: 'title', text: p.title })];
    const help = p.kind === 'connect' && p.qr ? [] : helpNodes(p.help);
    if (help[0] && help[0].tagName === 'P') help[0].className = 'lead';
    kids.push(...help);
    if (p.note && p.note.busy) kids.push(h('ul', { class: 'steps' }, h('li', { class: 'run' }, h('i', { 'aria-hidden': 'true' }), p.note.text)));
    else if (p.note) kids.push(h('div', { class: 'note ' + (p.note.kind || ''), text: p.note.text }));

    if (['text', 'date', 'secret'].includes(p.kind)) {
      const type = p.kind === 'secret' ? 'password' : p.kind === 'date' ? 'date' : 'text';
      kids.push(h('label', { class: 'sr', for: 'in', text: p.title }),
        h('input', { id: 'in', type, value: p.value || '', placeholder: p.hasSecret ? 'Schon eingetragen. Leer lassen, um es zu behalten.' : (p.placeholder || null),
          autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'aria-describedby': 'er',
          on: { keydown: (e) => { if (e.key === 'Enter') { e.preventDefault(); next(); } } } }));
      // Vorschläge (z. B. mehrere gefundene Paperless-Adressen): Antippen trägt die Adresse ins Feld ein.
      if ((p.suggestions || []).length) {
        kids.push(h('div', { class: 'suggest', role: 'group', 'aria-label': 'Gefundene Adressen' }, p.suggestions.map((s) => h('button', {
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
        });
        wrap.appendChild(b);
      }
      kids.push(wrap);
    }
    if (p.kind === 'review') {
      kids.push(h('dl', null, (p.rows || []).map((r) => h('div', { class: 'rv' }, h('dt', { text: r.label }), h('dd', { text: String(r.value).replace(/\.(?=\S)/g, '.​') }),
        h('button', { type: 'button', 'aria-label': `${r.label} ändern`, on: { click: () => post('/api/goto', { id: r.goto }) } }, 'Ändern')))));
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
    if (p.kind === 'handoff' && p.done) kids.push(h('ul', { class: 'steps' }, h('li', { class: 'run' }, h('i', { 'aria-hidden': 'true' }), 'Einen Moment …')));

    kids.push(h('div', { class: 'err', id: 'er', role: 'alert' }), h('div', { id: 'ck' }));
    // Einbaustelle für Bilder und Animationen (di9, ui/art/): art.js entscheidet nach page.id, null = kein Bild.
    // Platz und Verhalten im schmalen Fenster regelt art.css; die CSP gilt auch dort (kein style=, kein Inline-Skript).
    art = window.WizardArt && typeof window.WizardArt.mount === 'function' ? window.WizardArt.mount(p) : null;
    if (art && art.el) kids.push(art.el);
    if (p.kind === 'install' && p.failed) {
      kids.push(h('p', null, h('button', { type: 'button', id: 'rp', on: { click: showReport } }, 'Bericht für die Hilfe anzeigen')), h('div', { id: 'rpt' }));
    }
    kids.push(h('div', { class: 'spacer' }));
    const actions = h('div', { class: 'actions' });
    actions.appendChild(p.canBack ? h('button', { type: 'button', class: 'link', id: 'bk', on: { click: () => post('/api/back', {}) } }, 'Zurück') : h('span'));
    const right = h('div', { class: 'right' });
    if (p.optional && p.kind !== 'multi') right.appendChild(h('button', { type: 'button', class: 'link', id: 'sk', on: { click: () => post('/api/answer', { id: p.id, value: '', skip: true }) } }, 'Überspringen'));
    if (p.kind === 'install' && p.failed) right.appendChild(h('button', { type: 'button', class: 'primary', id: 'nx', on: { click: () => post('/api/action', { name: 'retry' }) } }, 'Noch einmal versuchen'));
    else if (p.next) right.appendChild(h('button', { type: 'button', class: 'primary', id: 'nx', on: { click: next } }, p.next));
    actions.appendChild(right);
    kids.push(actions);
    main.replaceChildren(...kids);
    const f = document.getElementById('in');
    if (f && keep !== null) f.value = keep;
    if (f) f.focus();
    if (p.poll && !PREVIEW) pollT = setTimeout(load, 1500);
  }

  async function showReport() {
    const r = await api('GET', '/api/report');
    if (r.fatal) return fatal();
    const box = document.getElementById('rpt');
    if (!box || !r.text) return;
    box.replaceChildren(h('p', { class: 'small', text: 'Darin stehen keine Namen und keine Schlüssel, nur der Stand der Einrichtung.' }), h('pre', { class: 'report', text: r.text }));
    try { await navigator.clipboard.writeText(r.text); box.prepend(h('div', { class: 'check', text: '✓ In die Zwischenablage kopiert' })); } catch (_) { /* nur anzeigen */ }
  }

  load();
})();
