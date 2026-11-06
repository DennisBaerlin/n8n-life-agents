// Wizard-Bilder: Illustrationen und geführte Animationen neben den Fragen (Schnittstelle zu app.js: WizardArt.mount(page)).
// - Welche Seite welches Bild bekommt, steht nur hier (ART unten); app.js hängt das Ergebnis vor den Abstand über den Knöpfen.
// - Fremde Oberflächen (FritzBox, Telegram, …) nur als eigene, vereinfachte Schema-Zeichnung: keine Screenshots, keine Logos,
//   keine Markenfarben. Menü- und Knopfnamen stehen wörtlich (Quelle FritzBox: docs/site/content/docs/fritzbox.md).
// - Sicherheit/CSP: SVG nur aus festen Texten dieser Datei (nie Server- oder Nutzertext in innerHTML), kein style-Attribut im
//   Markup; Lage und Zoom setzt der Takt über element.style (CSSOM, von style-src 'self' nicht betroffen).
// - Farben nur über Klassen in art.css (var(--token)); hell/dunkel kommt allein aus den Tokens.
// - Bewegung: Takt stoppt, sobald das Bild nicht mehr im Dokument hängt. prefers-reduced-motion → stehendes Bild des
//   wichtigsten Schritts. Vorschau-Aufnahmen: window.WIZARD_PREVIEW.artStep = n hält Schritt n fest.
// Nur erfundene Werte (Rechnername, Bot-Name).
'use strict';
(function () {
  const PREVIEW = window.WIZARD_PREVIEW || null;
  const reduced = () => !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

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
      (Array.isArray(c) ? c : [c]).forEach((x) => x && e.appendChild(typeof x === 'string' ? document.createTextNode(x) : x));
    }
    return e;
  }
  function fromMarkup(markup) {   // nur feste Texte aus dieser Datei
    const t = document.createElement('template');
    t.innerHTML = markup.trim();
    return t.content.firstElementChild;
  }

  // Zeichen des Projekts (Haus mit Sprechblase und Häkchen). Geometrie wie docs/site/layouts/partials/mark.html.
  const MARK = '<svg viewBox="0 0 26 26" aria-hidden="true" class="mark"><path class="mark-body" d="M13 2.5 L22 10 V19.5 H11.5 L7 23.5 V19.5 H4 V10 Z"/>'
    + '<path class="mark-check" d="M8.6 12.8 L11.7 15.8 L17.4 10"/></svg>';

  // ---------- Geführte Animation (Mauszeiger, Klick, Zoom, Leuchtrahmen), Schritte als Schleife ----------
  // steps[i] = { cap, start: Zustand beim Beginn, acts: [{ to:[x,y], click, set, ring, cam }], hold }
  // Zustand: set = data-*-Attribute am <svg> (art.css entscheidet, was sichtbar ist), cam = {x,y,s} (Zoom auf Punkt x,y),
  // ring = [x,y,b,h] Leuchtrahmen oder null. Koordinaten im viewBox-Raum der Zeichnung.
  function guided(o) {
    const fig = h('figure', { class: 'art art-guide', 'data-art': o.name });
    const stage = fromMarkup(o.svg);
    const cam = stage.querySelector('.cam');
    const ring = stage.querySelector('.ring');
    const cursor = stage.querySelector('.cursor');
    const ripple = stage.querySelector('.ripple');
    const [, , W, H] = stage.getAttribute('viewBox').split(' ').map(Number);
    const num = h('span', { class: 'art-num' });
    const txt = h('span', { class: 'art-txt' });
    const dots = o.steps.map((s, i) => h('button', { type: 'button', class: 'art-dot', 'aria-label': `Schritt ${i + 1}: ${s.cap}`,
      on: { click: () => { pause(true); jump(i, true); } } }));
    const toggle = h('button', { type: 'button', class: 'art-play', on: { click: () => pause(!paused) } });
    fig.append(h('div', { class: 'art-stage' }, stage),
      h('figcaption', { class: 'art-cap' }, h('p', { class: 'art-line' }, num, txt), h('div', { class: 'art-ctl' }, dots, toggle)),
      h('ol', { class: 'sr' }, o.steps.map((s) => h('li', { text: s.cap }))));

    let i = 0, paused = false, timers = [], seen = false, born = Date.now();
    const clear = () => { timers.forEach(clearTimeout); timers = []; };
    function later(ms, fn) {
      timers.push(setTimeout(() => {
        if (fig.isConnected) seen = true;
        else if (seen || Date.now() - born > 5000) { clear(); return; }   // Seite gewechselt: Takt beenden
        fn();
      }, ms));
    }
    function setCam(c) {
      const s = c ? c.s : 1;
      const tx = c ? W / 2 - c.x * s : 0, ty = c ? H / 2 - c.y * s : 0;
      cam.style.transform = `translate(${tx}px, ${ty}px) scale(${s})`;
    }
    function setRing(r) {
      ring.classList.toggle('on', !!r);
      if (r) { ring.setAttribute('x', r[0]); ring.setAttribute('y', r[1]); ring.setAttribute('width', r[2]); ring.setAttribute('height', r[3]); }
    }
    function setCursor(p) { cursor.style.transform = `translate(${p[0]}px, ${p[1]}px)`; }
    function applyState(st) {
      for (const [k, v] of Object.entries(st.set || {})) stage.setAttribute('data-' + k, v);
      if ('cam' in st) setCam(st.cam);
      if ('ring' in st) setRing(st.ring);
    }
    // Zustand zu Beginn von Schritt n (alles davor aufaddiert), damit Springen und Festhalten stimmen
    function stateAt(n) {
      const st = { set: Object.assign({}, o.initial), cam: null, ring: null, cursor: o.cursor };
      const add = (x) => {
        Object.assign(st.set, x.set || {});
        if ('cam' in x) st.cam = x.cam;
        if ('ring' in x) st.ring = x.ring;
      };
      for (let k = 0; k <= n && k < o.steps.length; k++) {
        const s = o.steps[k];
        st.ring = null;
        add(s.start || {});
        if (k < n) for (const a of s.acts || []) { add(a); if (a.to) st.cursor = a.to; }
      }
      return st;
    }
    function caption(n) {
      num.textContent = `${n + 1}/${o.steps.length}`;
      txt.textContent = o.steps[n].cap;
      dots.forEach((d, k) => d.classList.toggle('on', k === n));
    }
    function instant(fn) {   // ohne Übergänge springen
      fig.classList.add('instant');
      fn();
      void stage.getBoundingClientRect();
      fig.classList.remove('instant');
    }
    function jump(n, still) {   // Schritt n zeigen; still = Endbild des Schritts ohne Bewegung
      clear();
      i = n;
      caption(n);
      instant(() => {
        const st = stateAt(n);
        applyState(st);
        setCursor(st.cursor);
        if (still) {
          for (const a of o.steps[n].acts || []) { applyState(a); if (a.to) setCursor(a.to); }
        }
      });
      if (!still) run(n);
    }
    function run(n) {
      const s = o.steps[n];
      let t = 500;
      for (const a of s.acts || []) {
        if (a.to) { later(t, () => setCursor(a.to)); t += 950; }
        if (a.click) {
          later(t, () => { ripple.setAttribute('cx', a.to[0]); ripple.setAttribute('cy', a.to[1]); ripple.classList.remove('go'); void ripple.getBoundingClientRect(); ripple.classList.add('go'); });
          t += 180;
        }
        later(t, () => applyState(a));
        t += a.wait || 750;
      }
      t += s.hold || 1400;
      later(t, () => { if (!paused) jump((n + 1) % o.steps.length, false); });
    }
    function pause(p) {
      paused = p;
      toggle.textContent = p ? 'Abspielen' : 'Anhalten';
      toggle.setAttribute('aria-pressed', String(p));
      if (!p) jump(i, false);
    }

    const frozen = PREVIEW && Number.isInteger(PREVIEW.artStep) ? PREVIEW.artStep : null;
    if (frozen !== null || reduced()) {
      paused = true;
      toggle.textContent = 'Abspielen';
      jump(frozen !== null ? Math.min(frozen, o.steps.length - 1) : o.keyStep, true);
      if (reduced()) toggle.hidden = true;   // ohne Bewegung: Schritte über die Punkte
    } else {
      toggle.textContent = 'Anhalten';
      jump(0, false);
    }
    return { el: fig };
  }

  // ---------- A1: FritzBox-Freigabe (Seite fb_guide) ----------
  // Eigene Schema-Zeichnung eines Router-Menüs (keine AVM-Optik). Rechnername erfunden.
  const FB_SVG = `
<svg class="fb" viewBox="0 0 640 330" aria-hidden="true" data-sub="0" data-act="none" data-scene="home" data-radio="0" data-chk="0" data-rows="0" data-app="http">
 <g class="cam">
  <rect class="win" x="1" y="1" width="638" height="328" rx="14"/>
  <path class="bar" d="M1 36 V15 A14 14 0 0 1 15 1 H625 A14 14 0 0 1 639 15 V36 Z"/>
  <circle class="dot" cx="20" cy="18" r="5"/><circle class="dot" cx="38" cy="18" r="5"/><circle class="dot" cx="56" cy="18" r="5"/>
  <rect class="addr" x="84" y="8" width="220" height="20" rx="10"/><text class="t-s t-gray" x="100" y="22">fritz.box</text>
  <path class="side" d="M1 36 H150 V329 H15 A14 14 0 0 1 1 315 Z"/>
  <line class="ln" x1="1" y1="36" x2="639" y2="36"/><line class="ln" x1="150" y1="36" x2="150" y2="329"/>
  <rect class="act act-internet" x="8" y="80" width="134" height="26" rx="8"/>
  <rect class="act act-freigaben" x="8" y="148" width="134" height="24" rx="8"/>
  <text class="t-m" x="20" y="66">Übersicht</text>
  <text class="t-m" x="20" y="98">Internet</text>
  <g class="sub">
   <text class="t-s" x="32" y="122">Online-Monitor</text>
   <text class="t-s" x="32" y="143">MyFRITZ!-Konto</text>
   <text class="t-s" x="32" y="164">Freigaben</text>
  </g>
  <g class="rest">
   <text class="t-m" x="20" y="126">Heimnetz</text>
   <text class="t-m" x="20" y="154">WLAN</text>
   <text class="t-m" x="20" y="182">System</text>
  </g>

  <g class="s s-home">
   <text class="t-h" x="174" y="72">Übersicht</text>
   <rect class="ph" x="174" y="92" width="300" height="10" rx="5"/><rect class="ph" x="174" y="112" width="220" height="10" rx="5"/>
   <rect class="ph" x="174" y="148" width="420" height="70" rx="10"/><rect class="ph" x="174" y="232" width="420" height="70" rx="10"/>
  </g>

  <g class="s s-list">
   <text class="t-h" x="174" y="72">Freigaben</text>
   <text class="t-m t-strong" x="174" y="102">Portfreigaben</text>
   <rect class="tab" x="174" y="109" width="94" height="3" rx="1.5"/>
   <rect class="ph" x="290" y="93" width="70" height="10" rx="5"/><rect class="ph" x="380" y="93" width="50" height="10" rx="5"/>
   <line class="ln" x1="174" y1="114" x2="620" y2="114"/>
   <rect class="ph" x="174" y="134" width="140" height="10" rx="5"/><rect class="ph" x="360" y="134" width="120" height="10" rx="5"/>
   <line class="ln" x1="174" y1="156" x2="620" y2="156"/>
   <rect class="ph" x="174" y="174" width="110" height="10" rx="5"/><rect class="ph" x="360" y="174" width="140" height="10" rx="5"/>
   <line class="ln" x1="174" y1="196" x2="620" y2="196"/>
   <rect class="btn" x="400" y="276" width="220" height="30" rx="15"/>
   <text class="t-s t-mid" x="510" y="295">Gerät für Freigaben hinzufügen</text>
  </g>

  <g class="s s-dev">
   <text class="t-h" x="174" y="72">Gerät für Freigaben hinzufügen</text>
   <text class="t-s t-gray" x="174" y="112">Gerät</text>
   <rect class="field" x="226" y="96" width="190" height="26" rx="7"/>
   <text class="t-m" x="238" y="114">mein-rechner</text><path class="caret" d="M398 106 l5 5 l5 -5"/>
   <text class="t-m t-strong" x="174" y="160">Freigaben</text>
   <line class="ln" x1="174" y1="170" x2="620" y2="170"/>
   <g class="rows0"><text class="t-s t-gray" x="174" y="194">Noch keine Freigaben</text></g>
   <g class="row-http">
    <text class="t-s" x="174" y="192">MyFRITZ!-Freigabe</text><text class="t-s" x="340" y="192">HTTP-Server</text>
    <line class="ln" x1="174" y1="202" x2="620" y2="202"/>
   </g>
   <g class="row-https"><text class="t-s" x="174" y="222">MyFRITZ!-Freigabe</text><text class="t-s" x="340" y="222">HTTPS-Server</text></g>
   <rect class="btn" x="174" y="246" width="130" height="28" rx="14"/><text class="t-s t-mid" x="239" y="264">Neue Freigabe</text>
   <rect class="btn btn-main" x="510" y="288" width="110" height="28" rx="14"/><text class="t-s t-mid t-on-main" x="565" y="306">Übernehmen</text>
  </g>

  <g class="s s-dlg">
   <rect class="veil" x="1" y="1" width="638" height="328" rx="14"/>
   <rect class="dlg" x="250" y="70" width="330" height="220" rx="12"/>
   <text class="t-m t-strong" x="268" y="98">Neue Freigabe</text>
   <circle class="radio" cx="275" cy="122" r="6.5"/><circle class="radio-on r1" cx="275" cy="122" r="3.5"/>
   <text class="t-m" x="290" y="127">MyFRITZ!-Freigabe</text>
   <circle class="radio" cx="275" cy="147" r="6.5"/><circle class="radio-on r2" cx="275" cy="147" r="3.5"/>
   <text class="t-m" x="290" y="152">Portfreigabe</text>
   <text class="t-s t-gray" x="268" y="187">Anwendung</text>
   <rect class="field" x="352" y="171" width="180" height="24" rx="7"/>
   <text class="t-s app-http" x="363" y="187">HTTP-Server</text><text class="t-s app-https" x="363" y="187">HTTPS-Server</text><path class="caret" d="M514 180 l5 5 l5 -5"/>
   <rect class="box" x="268" y="206" width="14" height="14" rx="3"/><path class="tick" d="M271 213 l3 3 l5 -6"/>
   <text class="t-m" x="290" y="218">Freigabe aktivieren</text>
   <rect class="btn btn-main" x="500" y="252" width="64" height="26" rx="13"/><text class="t-s t-mid t-on-main" x="532" y="269">OK</text>
  </g>

  <rect class="ring" x="0" y="0" width="0" height="0" rx="10"/>
  <circle class="ripple" cx="0" cy="0" r="14"/>
  <g class="cursor"><path d="M0 0 V17 L4.5 13 L7.6 20 L10.4 18.8 L7.4 12 H13 Z"/></g>
 </g>
</svg>`;

  // Zeiger-Spitze rechts neben die Knopfschrift, damit sie lesbar bleibt. Jeder Schritt endet auf dem Bild, das seine
  // Beschriftung zeigt (Standbild bei reduzierter Bewegung und für die Punkte).
  const ZOOM = { x: 415, y: 180, s: 1.45 };
  const FB_STEPS = [
    { cap: 'fritz.box im Browser öffnen, links „Internet“', start: { cam: null },
      acts: [{ to: [86, 88], click: true, set: { sub: '1', act: 'internet' } }], hold: 900 },
    { cap: '„Freigaben“ öffnen, Reiter „Portfreigaben“',
      acts: [{ to: [112, 162], click: true, set: { act: 'freigaben', scene: 'list' }, ring: [168, 86, 108, 30] }] },
    { cap: '„Gerät für Freigaben hinzufügen“, Rechner wählen',
      acts: [{ to: [612, 298], click: true, set: { scene: 'dev' } }, { to: [428, 116], ring: [220, 90, 202, 38], wait: 600 }] },
    { cap: '„Neue Freigabe“, oben „MyFRITZ!-Freigabe“ wählen',
      acts: [{ to: [290, 262], click: true, set: { scene: 'dlg', app: 'http' }, cam: ZOOM },
        { to: [414, 129], click: true, set: { radio: '1' }, ring: [262, 110, 160, 26] }] },
    { cap: '„HTTP-Server“, Haken bei „Freigabe aktivieren“', start: { cam: ZOOM },
      acts: [{ to: [512, 187], ring: [347, 166, 190, 34], wait: 900 },
        { to: [424, 220], click: true, set: { chk: '1' }, ring: [262, 200, 168, 26] }] },
    { cap: '„OK“, die Freigabe steht jetzt in der Liste', start: { cam: ZOOM, ring: [262, 200, 168, 26] },
      acts: [{ to: [553, 269], click: true, ring: [494, 246, 76, 38], wait: 500 },
        { set: { scene: 'dev', rows: '1', radio: '0', chk: '0' }, cam: null, ring: [168, 176, 456, 30] }] },
    { cap: 'Dasselbe noch einmal mit „HTTPS-Server“',
      acts: [{ to: [290, 262], click: true, set: { scene: 'dlg', app: 'https', radio: '1', chk: '1' }, cam: ZOOM, ring: [347, 166, 190, 34], wait: 1300 },
        { to: [553, 269], click: true, set: { scene: 'dev', rows: '2', radio: '0', chk: '0' }, cam: null, ring: [168, 206, 456, 26] }], hold: 1800 },
    { cap: 'Unten „Übernehmen“ klicken',
      acts: [{ to: [613, 311], click: true, ring: [504, 282, 122, 40] }], hold: 2400 },
  ];

  function fbShare() {
    return guided({ name: 'fb-share', svg: FB_SVG, steps: FB_STEPS, keyStep: 3, cursor: [330, 250],
      initial: { sub: '0', act: 'none', scene: 'home', radio: '0', chk: '0', rows: '0', app: 'http' } });
  }

  // ---------- A2: Charakter des Bots (Seite h:OWNER_PERSONA) ----------
  // Handy-Ausschnitt nach dem Analog der Site (phone-frame-*.html, .tg-*), Farben aus den Tokens. Beispiel-Begrüßung je
  // Charakter im Ton von packages/core/contexts/persona_styles.md (Butler siezt). Unbekannter Code → Standard.
  const PERSONA_Q = 'Hallo! Wer bist du?';
  const PERSONA_A = {
    neutral: 'Hallo! Ich bin dein Bot für den Haushalt. Frag mich einfach, was du brauchst.',
    butler: 'Guten Tag. Ich stehe Ihnen für alles rund um den Haushalt zu Diensten. Womit darf ich behilflich sein?',
    sportscaster: 'Und da ist der Anpfiff! Ich bin dein Bot für den Haushalt. Was steht heute auf dem Spielplan?',
    sage: 'Willkommen, mein Freund. Ich begleite dich durch den Haushalt. Wer fragt, findet den Weg.',
  };

  function phone(name, label, chat) {
    return h('div', { class: 'phone', role: 'img', 'aria-label': label },
      h('div', { class: 'screen' },
        h('div', { class: 'island' }),
        h('div', { class: 'statusbar' }, h('span', { text: '9:41' }), fromMarkup('<svg class="icons" viewBox="0 0 46 11" aria-hidden="true">'
          + '<rect x="0" y="7" width="3" height="4" rx="1"/><rect x="4.5" y="5" width="3" height="6" rx="1"/><rect x="9" y="2.5" width="3" height="8.5" rx="1"/>'
          + '<rect x="13.5" y="0" width="3" height="11" rx="1"/><rect class="batt" x="22.5" y="0.5" width="21" height="10" rx="3"/><rect x="24.5" y="2.5" width="15" height="6" rx="1.5"/></svg>')),
        h('div', { class: 'tg-header' }, h('span', { class: 'tg-avatar' }, fromMarkup(MARK)), h('span', { class: 'tg-title', text: 'Dein Bot' })),
        h('div', { class: 'tg-chat' }, chat)));
  }

  function persona(page) {
    const reply = h('div', { class: 'msg msg-in' });
    const typing = h('div', { class: 'msg msg-in typing', 'aria-hidden': 'true' }, h('i'), h('i'), h('i'));
    const fig = h('figure', { class: 'art art-phone', 'data-art': 'persona' },
      phone('persona', 'Beispiel-Chat mit deinem Bot', [h('div', { class: 'msg msg-out', text: PERSONA_Q }), reply, typing]),
      h('figcaption', { class: 'art-cap art-note', text: 'So begrüßt dich dein Bot (Beispiel). Nur der Ton ändert sich, nicht die Inhalte.' }));
    let t = null;
    const show = (code) => { reply.textContent = PERSONA_A[code] || PERSONA_A.neutral; };
    show(page.value);
    function select(code) {
      clearTimeout(t);
      if (reduced()) { show(code); return; }
      fig.classList.add('busy');
      t = setTimeout(() => { if (!fig.isConnected) return; show(code); fig.classList.remove('busy'); }, 650);
    }
    return { el: fig, select };
  }

  // ---------- Zuordnung Seite → Bild (die eine Adresse) ----------
  const ART = {
    fb_guide: fbShare,
    'h:OWNER_PERSONA': persona,
  };

  window.WizardArt = {
    mount(page) {
      const f = page && ART[page.id];
      return f ? f(page) : null;
    },
  };
})();
