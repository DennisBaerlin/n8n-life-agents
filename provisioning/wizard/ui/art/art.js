// Wizard-Bilder: Illustrationen und geführte Animationen neben den Fragen (Schnittstelle zu app.js: WizardArt.mount(page)).
// - Welche Seite welches Bild bekommt, steht nur hier (ART unten); app.js hängt das Ergebnis vor den Abstand über den Knöpfen.
// - Platz: Das Bild bekommt nur den Raum zwischen Inhalt und angehefteter Knopfleiste (App-Fenster 760 × 640) und passt sich
//   ihm an (art.css: Container-Abfragen auf die eigene Höhe); fehlt er, entfällt es.
// - Fremde Oberflächen (FritzBox, später Anthropic, Google …): wirklichkeitsgetreu nach recherchierten Vorlagen nachgezeichnet
//   (Anordnung, Reihenfolge, Wortlaut der Menüs, Reiter, Knöpfe und Felder), aber eigene Vektor-Zeichnung: kein Logo, kein
//   Schriftzug als Grafik, keine Pixel-Kopie. Farben angenähert über die Tokens, immer hell (Klasse art-light, wie der QR-Code).
//   Wortlaut FritzBox: FRITZ!OS 8 (Wissensdatenbank des Herstellers + Bildschirmfotos, Quellen im Bericht der Bild-Session);
//   Schritte wie docs/site/content/docs/fritzbox.md.
// - Sicherheit/CSP: SVG nur aus festen Texten dieser Datei (nie Server- oder Nutzertext in innerHTML), kein style-Attribut im
//   Markup; Lage und Zoom setzt der Takt über element.style (CSSOM, von style-src 'self' nicht betroffen).
// - Bewegung: Takt stoppt, sobald das Bild nicht mehr im Dokument hängt. prefers-reduced-motion → stehendes Bild des
//   wichtigsten Schritts. Vorschau-Aufnahmen: WIZARD_PREVIEW.artStep bzw. window.WIZARD_ART_STEP = n hält Schritt n fest.
// Nur erfundene Werte (Rechner- und Gerätenamen, Bot-Name); Adressen nur als graue Balken.
'use strict';
(function () {
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
  // Projekt-Zeichen: die eine Quelle setzt der Server als <template id="mark-tpl"> in die Seite (ui/mark.html); Farben über
  // --mark/--mark-check (art.css). Fehlt es, bleibt der Platz leer.
  function mark() {
    const t = document.getElementById('mark-tpl');
    const s = t && t.content && t.content.querySelector('svg');
    return s ? s.cloneNode(true) : null;
  }

  // ---------- Geführte Animation: Mauszeiger, Klick, Lupe mit Zoom, Leuchtrahmen; Schritt für Schritt per Klick ----------
  // o = { name, svg, width, height, steps, cursor, initial, label, light, hint, link, takes }
  // steps[i] = { cap, start: {set, cam, ring}, acts: [{ to:[x,y], click, set, ring, cam, wait }], hint }
  // set = data-*-Attribute am <svg> (art.css entscheidet, was sichtbar ist); ring = [x,y,b,h] Leuchtrahmen oder null;
  // cam = {x,y,s} Lupe auf Punkt x,y mit Zoom s, null = Zoom 1. Ohne cam folgt die Lupe dem Ziel des Zeigers (to).
  // Ablauf (Owner 2026-11-06): Schritt 1 läuft beim Öffnen einmal ab und bleibt stehen; weiter nur per Klick („Nächster
  // Schritt“ macht dann auf sich aufmerksam), „Zurück“, Punkte zum Springen, „Nochmal zeigen“. Jeder angesteuerte Schritt
  // spielt seine Bewegung einmal ruhig ab und endet auf dem Bild, das seine Beschriftung zeigt. Die Knöpfe liegen im
  // Bildrahmen, damit sie nicht mit Zurück/Weiter des Wizards verwechselt werden. Tastatur: Pfeil links/rechts im Rahmen.
  // Seiten-Hinweis (page.note) und Anleitungs-Link (page.link) übernimmt das Bild (takes), damit die Zeichnung Platz hat:
  // Hinweis an den Schritten mit hint: true, Link in der Knopfleiste. Ohne Bild zeigt app.js beides wie bisher.
  function guided(o) {
    const W = o.width, H = o.height, N = o.steps.length, SLOW = 1.5, MINK = 0.86;
    const fig = h('figure', { class: 'art art-guide', 'data-art': o.name });
    const svg = fromMarkup(o.svg);
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    const cam = svg.querySelector('.cam');
    const ring = svg.querySelector('.ring');
    const cursor = svg.querySelector('.cursor');
    const ripple = svg.querySelector('.ripple');
    const stage = h('div', { class: 'art-stage' + (o.light ? ' art-light' : ''), role: 'img', 'aria-label': o.label }, svg);
    const hintBox = o.hint ? h('p', { class: 'art-hint', role: 'note', text: o.hint }) : null;   // Server-Text: nur textContent
    const line = h('p', { class: 'art-line', 'aria-live': 'polite' });
    const btn = (cls, text, fn, label) => h('button', { type: 'button', class: 'art-btn ' + cls, 'aria-label': label || null, on: { click: fn } }, text);
    const back = btn('art-back', '‹ Schritt zurück', () => go(i - 1));
    const again = btn('art-again', '↻ Nochmal zeigen', () => go(i));
    const next = btn('art-next', 'Nächster Schritt ›', () => go(i + 1));
    const dots = o.steps.map((s, k) => h('button', { type: 'button', class: 'art-dot', 'aria-label': `Schritt ${k + 1} von ${N}: ${s.cap}`, title: `Schritt ${k + 1}`, on: { click: () => go(k) } }));
    // Anleitungs-Link (Ziel vom Server) als kleine Marke oben rechts im Bild, damit die Zeichnung Platz behält
    const guide = o.link ? h('a', { class: 'art-guide-link', href: o.link.href, target: '_blank', rel: 'noopener noreferrer', title: o.link.label, text: 'Ausführliche Anleitung ↗' }) : null;
    const bar = h('figcaption', { class: 'art-bar' }, line,
      h('div', { class: 'art-ctl' }, back, h('span', { class: 'art-dots' }, dots), again, next));
    // Schrittliste: für Screenreader immer, sichtbar als Rückfall, wenn für die Zeichnung kein Platz ist (art.css)
    fig.append(h('div', { class: 'art-frame' }, stage, guide, hintBox, bar), h('ol', { class: 'art-list sr' }, o.steps.map((s) => h('li', { text: s.cap }))));
    fig.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' && i + 1 < N) { e.preventDefault(); go(i + 1); next.focus(); }
      if (e.key === 'ArrowLeft' && i > 0) { e.preventDefault(); go(i - 1); back.focus(); }
    });

    let i = 0, timers = [], seen = false, measured = false, born = Date.now(), view = { w: W, h: H, free: H }, focus = { x: o.cursor[0], y: o.cursor[1], s: 1 };
    const clear = () => { timers.forEach(clearTimeout); timers = []; };
    function later(ms, fn) {
      timers.push(setTimeout(() => {
        if (fig.isConnected) { seen = true; if (!measured) measured = measure(); }
        else if (seen || Date.now() - born > 5000) { clear(); return; }   // Seite gewechselt: Takt beenden
        fn();
      }, ms));
    }
    // Sichtfenster in Zeichnungs-Einheiten: volle Breite, Höhe nach dem Platz der Bühne
    function measure() {
      const r = stage.getBoundingClientRect();
      if (r.width < 10 || r.height < 10) return false;
      const k = Math.max(r.width / W, MINK);   // schmale Spalte: Schrift lesbar halten, die Lupe schwenkt dann auch seitlich
      const vw = Math.min(W, r.width / k), vh = Math.min(H, r.height / k);
      view = { w: vw, h: vh, free: vh };
      svg.setAttribute('viewBox', `0 0 ${vw.toFixed(1)} ${vh.toFixed(1)}`);
      return true;
    }
    function setCam(f) {
      focus = f;
      const s = f.s || 1, clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
      const tx = W * s <= view.w ? (view.w - W * s) / 2 : clamp(view.w / 2 - f.x * s, view.w - W * s, 0);
      const ty = H * s <= view.free ? 0 : clamp(view.free / 2 - f.y * s, view.free - H * s, 0);
      cam.style.transform = `translate(${tx.toFixed(1)}px, ${ty.toFixed(1)}px) scale(${s})`;
    }
    function setRing(r) {
      ring.classList.toggle('on', !!r);
      if (r) { ring.setAttribute('x', r[0]); ring.setAttribute('y', r[1]); ring.setAttribute('width', r[2]); ring.setAttribute('height', r[3]); }
    }
    function setCursor(p) { cursor.style.transform = `translate(${p[0]}px, ${p[1]}px)`; }
    // Lupe nach einem Schritt-Teil: eigenes cam gewinnt, sonst folgt sie dem Zeiger bei gleichem Zoom
    function nextFocus(f, a) {
      if ('cam' in a) return a.cam ? { x: a.cam.x, y: a.cam.y, s: a.cam.s } : { x: a.to ? a.to[0] : f.x, y: a.to ? a.to[1] : f.y, s: 1 };
      return a.to ? { x: a.to[0], y: a.to[1], s: f.s } : f;
    }
    function applyPart(a) {
      for (const [k, v] of Object.entries(a.set || {})) svg.setAttribute('data-' + k, v);
      if ('ring' in a) setRing(a.ring);
      setCam(nextFocus(focus, a));
    }
    // Zustand zu Beginn von Schritt n (alles davor aufaddiert), damit Springen und Festhalten stimmen
    function stateAt(n) {
      const st = { set: Object.assign({}, o.initial), ring: null, cursor: o.cursor, focus: { x: o.cursor[0], y: o.cursor[1], s: 1 } };
      const add = (x) => {
        Object.assign(st.set, x.set || {});
        if ('ring' in x) st.ring = x.ring;
        st.focus = nextFocus(st.focus, x);
        if (x.to) st.cursor = x.to;
      };
      for (let k = 0; k <= n && k < N; k++) {
        const s = o.steps[k];
        st.ring = null;
        add(s.start || {});
        if (k < n) for (const a of s.acts || []) add(a);
      }
      return st;
    }
    function caption(n) {
      line.replaceChildren(h('b', { text: `Schritt ${n + 1} von ${N}: ` }), o.steps[n].cap);
      dots.forEach((d, k) => { d.classList.toggle('on', k === n); d.setAttribute('aria-current', k === n ? 'step' : 'false'); });
      back.disabled = n === 0;
      next.hidden = n + 1 >= N;   // letzter Schritt: kein Neustart-Knopf neben dem Hauptknopf des Wizards
      if (hintBox) hintBox.hidden = !o.steps[n].hint;
    }
    function instant(fn) {   // ohne Übergänge springen
      fig.classList.add('instant');
      fn();
      void svg.getBoundingClientRect();
      fig.classList.remove('instant');
    }
    // Schritt fertig: „Nächster Schritt“ macht kurz auf sich aufmerksam, im selben Aussehen wie der Weiter-Hinweis des
    // Wizards (Klasse la-nudge aus config/ui.nudge.css, als Kopie in app.css derselben Seite: 2 Pulse à 1,5 s, ohne
    // Bewegung nur ein Rahmen). Die Zeitsteuerung von UiNudge gehört dem Wizard-Knopf und bleibt unberührt.
    function ready(on) {
      fig.classList.toggle('done', on);
      next.classList.remove('la-nudge');
      if (on && !next.hidden) { void next.offsetWidth; next.classList.add('la-nudge'); later(3200, () => next.classList.remove('la-nudge')); }
    }
    function go(n, still) {   // Schritt n zeigen; still = gleich das Endbild ohne Bewegung
      if (n < 0 || n >= N) return;
      clear();
      i = n;
      caption(n);
      ready(false);
      const quiet = still || reduced();
      instant(() => {
        const st = stateAt(n);
        for (const [k, v] of Object.entries(st.set)) svg.setAttribute('data-' + k, v);
        setRing(st.ring);
        setCam(st.focus);
        setCursor(st.cursor);
        if (quiet) for (const a of o.steps[n].acts || []) { applyPart(a); if (a.to) setCursor(a.to); }
      });
      if (quiet) { ready(true); return; }
      let t = 700;
      for (const a of o.steps[n].acts || []) {
        if (a.to) { later(t, () => { setCursor(a.to); setCam(nextFocus(focus, { to: a.to })); }); t += 1400; }
        if (a.click) {
          later(t, () => { ripple.setAttribute('cx', a.to[0]); ripple.setAttribute('cy', a.to[1]); ripple.classList.remove('go'); void ripple.getBoundingClientRect(); ripple.classList.add('go'); });
          t += 260;
        }
        later(t, () => applyPart(a));
        t += (a.wait || 750) * SLOW;
      }
      later(t, () => ready(true));
    }
    // Platz ändert sich (Fenster, Inhalt darüber): Sichtfenster neu, Lupe ohne Übergang nachführen
    if (window.ResizeObserver) new ResizeObserver(() => { if (measure()) { measured = true; instant(() => setCam(focus)); } }).observe(stage);

    const pv = window.WIZARD_PREVIEW;   // nur in Vorschau-Aufnahmen gesetzt (erst beim Einbau lesen: art.js lädt vor der Attrappe)
    const want = pv ? (Number.isInteger(pv.artStep) ? pv.artStep : window.WIZARD_ART_STEP) : undefined;
    if (Number.isInteger(want)) go(Math.min(want, N - 1), true);
    else go(0);   // Schritt 1 läuft einmal von selbst, dann steht er
    return { el: fig, takes: o.takes || [] };
  }

  // ---------- A1: FritzBox-Freigabe (Seite fb_guide) ----------
  // Nachzeichnung der FRITZ!OS-8-Oberfläche: Kopfleiste, Menü links, Inhalt rechts; Seiten „Internet › Freigaben“ (Reiter
  // „Portfreigaben“), Geräteseite „Freigabe“ mit „‹ Zurück“, Dialog „Freigabe anlegen“. Kein Logo (Fläche bleibt leer).
  const CHK = (x, y) => `<rect class="box" x="${x}" y="${y}" width="13" height="13" rx="2"/>`;
  const ICON = (y) => `<rect class="ico" x="18" y="${y - 12}" width="14" height="14" rx="4"/>`;   // Platzhalter für die Menü-Symbole
  const FB_SVG = `
<svg class="fb" aria-hidden="true" preserveAspectRatio="xMidYMin meet" data-sub="0" data-act="none" data-scene="home" data-radio="0" data-chk="0" data-rows="0" data-app="http">
 <g class="cam">
  <rect class="pg" x="0" y="0" width="780" height="680"/>
  <rect class="hdr" x="0" y="0" width="780" height="58"/>
  <text class="t-hdr" x="214" y="37">FRITZ!Box</text>
  <rect class="hbtn" x="566" y="16" width="80" height="26" rx="3"/><text class="t-hbtn" x="606" y="33">MyFRITZ!</text>
  <rect class="hbtn" x="654" y="16" width="84" height="26" rx="3"/><text class="t-hbtn" x="696" y="33">FRITZ!NAS</text>
  <circle class="hdot" cx="760" cy="22" r="2"/><circle class="hdot" cx="760" cy="29" r="2"/><circle class="hdot" cx="760" cy="36" r="2"/>
  <rect class="nav" x="0" y="58" width="200" height="622"/><line class="ln" x1="200" y1="58" x2="200" y2="680"/>

  <rect class="act act-freigaben" x="8" y="210" width="184" height="26" rx="4"/>
  ${ICON(88)}<text class="t-n" x="42" y="88">Übersicht</text>
  ${ICON(120)}<text class="t-n t-int" x="42" y="120">Internet</text><path class="chev" d="M176 112 l5 5 l5 -5"/><path class="chev-up" d="M176 117 l5 -5 l5 5"/>
  <g class="sub">
   <text class="t-sub" x="42" y="146">Online-Monitor</text>
   <text class="t-sub" x="42" y="172">Zugangsdaten</text>
   <text class="t-sub" x="42" y="198">Filter</text>
   <text class="t-sub t-fg" x="42" y="228">Freigaben</text>
   <text class="t-sub" x="42" y="256">MyFRITZ!-Konto</text>
  </g>
  <g class="rest">
   ${ICON(152)}<text class="t-n" x="42" y="152">Telefonie</text>
   ${ICON(182)}<text class="t-n" x="42" y="182">Heimnetz</text>
   ${ICON(212)}<text class="t-n" x="42" y="212">WLAN</text>
   ${ICON(242)}<text class="t-n" x="42" y="242">Smart Home</text>
   ${ICON(272)}<text class="t-n" x="42" y="272">Diagnose</text>
   ${ICON(302)}<text class="t-n" x="42" y="302">System</text>
   <line class="ln" x1="12" y1="320" x2="188" y2="320"/>
   ${ICON(346)}<text class="t-n" x="42" y="346">Assistenten</text>
   ${ICON(376)}<text class="t-n" x="42" y="376">Hilfe und Info</text>
  </g>

  <g class="s s-home">
   <text class="t-h" x="222" y="96">Übersicht</text>
   <rect class="ph" x="222" y="114" width="300" height="9" rx="4"/><rect class="ph" x="222" y="132" width="220" height="9" rx="4"/>
   <rect class="card" x="222" y="160" width="536" height="120" rx="4"/><rect class="card" x="222" y="296" width="536" height="120" rx="4"/>
  </g>

  <g class="s s-list">
   <circle class="ico-c" cx="230" cy="90" r="8"/><text class="t-m" x="246" y="95">Internet</text><text class="t-m t-gray" x="308" y="95">›</text><text class="t-m" x="322" y="95">Freigaben</text>
   <circle class="help" cx="748" cy="90" r="11"/><text class="t-help" x="748" y="95">?</text>
   <rect class="tab-on" x="222" y="108" width="104" height="30"/><rect class="tab-line" x="222" y="135" width="104" height="3"/>
   <text class="t-tab t-strong" x="274" y="128">Portfreigaben</text>
   <rect class="tab-off" x="330" y="108" width="124" height="30"/><text class="t-tab" x="392" y="128">FRITZ!Box-Dienste</text>
   <rect class="tab-off" x="458" y="108" width="68" height="30"/><text class="t-tab" x="492" y="128">DynDNS</text>
   <rect class="tab-off" x="530" y="108" width="94" height="30"/><text class="t-tab" x="577" y="128">VPN (IPSec)</text>
   <rect class="tab-off" x="628" y="108" width="130" height="30"/><text class="t-tab" x="693" y="128">VPN (WireGuard)</text>
   <line class="ln" x1="222" y1="138" x2="758" y2="138"/>
   <rect class="ph" x="222" y="152" width="520" height="8" rx="4"/><rect class="ph" x="222" y="168" width="360" height="8" rx="4"/>
   <rect class="tbl" x="222" y="186" width="536" height="64"/>
   <text class="t-th" x="230" y="204">Gerät / Name</text><text class="t-th" x="340" y="204">IP-Adresse</text><text class="t-th" x="440" y="204">Freigaben</text>
   <text class="t-th" x="530" y="200">Port extern</text><text class="t-th" x="530" y="213">vergeben IPv4</text>
   <text class="t-th" x="618" y="200">Port extern</text><text class="t-th" x="618" y="213">vergeben IPv6</text>
   <line class="ln" x1="222" y1="220" x2="758" y2="220"/>
   <text class="t-s" x="230" y="240">drucker</text><rect class="ph" x="340" y="232" width="70" height="8" rx="4"/>
   <circle class="ibtn" cx="716" cy="235" r="11"/><path class="pen" d="M711 240 l8 -8 l2 2 l-8 8 h-2 z"/>
   <circle class="ibtn" cx="744" cy="235" r="11"/><path class="bin" d="M739 230 h10 M741 230 v10 h6 v-10"/>
   <rect class="btn2" x="474" y="262" width="194" height="26" rx="3"/><text class="t-btn2" x="571" y="279">Gerät für Freigaben hinzufügen</text>
   <rect class="btn2" x="674" y="262" width="84" height="26" rx="3"/><text class="t-btn2" x="716" y="279">Aktualisieren</text>
   <line class="ln" x1="222" y1="304" x2="758" y2="304"/>
   <rect class="ph" x="222" y="318" width="430" height="8" rx="4"/>
   <rect class="btn2" x="674" y="334" width="84" height="26" rx="3"/><text class="t-btn2" x="716" y="351">Deaktivieren</text>
   <line class="ln" x1="200" y1="378" x2="780" y2="378"/>
   <rect class="btn-off" x="580" y="392" width="88" height="28" rx="3"/><text class="t-off" x="624" y="410">Übernehmen</text>
   <rect class="btn-off" x="674" y="392" width="84" height="28" rx="3"/><text class="t-off" x="716" y="410">Verwerfen</text>
  </g>

  <g class="s s-dev">
   <rect class="btn1" x="222" y="76" width="78" height="26" rx="3"/><text class="t-btn1" x="261" y="93">‹ Zurück</text>
   <text class="t-m" x="312" y="94">Freigabe</text>
   <circle class="help" cx="748" cy="89" r="11"/><text class="t-help" x="748" y="94">?</text>
   <text class="t-lbl" x="240" y="128">Gerät</text>
   <rect class="field" x="360" y="110" width="200" height="26" rx="3"/><text class="t-s" x="370" y="128">mein-rechner</text><path class="caret" d="M540 120 l5 5 l5 -5"/>
   <text class="t-lbl" x="240" y="162">IPv4-Adresse</text><rect class="field-off" x="360" y="146" width="200" height="24" rx="3"/><rect class="ph" x="370" y="154" width="90" height="8" rx="4"/>
   <text class="t-lbl" x="240" y="194">MAC-Adresse</text><rect class="field-off" x="360" y="178" width="200" height="24" rx="3"/><rect class="ph" x="370" y="186" width="110" height="8" rx="4"/>
   <text class="t-lbl" x="252" y="226">IPv6 Interface-ID</text><text class="t-s" x="360" y="226">: :</text>
   <rect class="field" x="378" y="210" width="40" height="24" rx="3"/><rect class="field" x="428" y="210" width="40" height="24" rx="3"/>
   <rect class="field" x="478" y="210" width="40" height="24" rx="3"/><rect class="field" x="528" y="210" width="40" height="24" rx="3"/>
   ${CHK(240, 243)}<text class="t-s" x="262" y="254">Selbstständige Portfreigaben für dieses Gerät erlauben.</text>
   <line class="ln" x1="222" y1="270" x2="758" y2="270"/>
   <text class="t-m t-strong" x="222" y="294">IPv4-Einstellungen</text>
   ${CHK(240, 305)}<text class="t-s" x="262" y="316">Dieses Gerät komplett für den Internetzugriff über IPv4 freigeben (Exposed Host).</text>
   <text class="t-s" x="240" y="334">Diese Einstellung kann nur für ein Gerät aktiviert werden.</text>
   <line class="ln" x1="222" y1="348" x2="758" y2="348"/>
   <text class="t-m t-strong" x="222" y="372">IPv6-Einstellungen</text>
   ${CHK(240, 383)}<text class="t-s" x="262" y="394">PING6 freigeben.</text>
   ${CHK(240, 405)}<text class="t-s" x="262" y="416">Firewall für delegierte IPv6-Präfixe dieses Gerätes öffnen.</text>
   ${CHK(240, 427)}<text class="t-s" x="262" y="438">Dieses Gerät komplett für den Internetzugriff über IPv6 freigeben (Exposed Host).</text>
   <line class="ln" x1="222" y1="454" x2="758" y2="454"/>
   <text class="t-m t-strong" x="222" y="478">Freigaben</text>
   <rect class="tbl" x="222" y="490" width="536" height="80"/><rect class="th" x="222" y="490" width="536" height="22"/>
   <text class="t-th" x="230" y="505">Status</text><text class="t-th" x="290" y="505">Bezeichnung</text><text class="t-th" x="420" y="505">Protokoll</text>
   <text class="t-th" x="490" y="505">IP-Adresse im Internet</text><text class="t-th" x="640" y="505">Port extern vergeben</text>
   <g class="row-http">
    <circle class="okdot" cx="238" cy="525" r="5"/><text class="t-s" x="290" y="530">HTTP-Server</text><text class="t-s" x="420" y="530">TCP</text>
    <rect class="ph" x="490" y="522" width="80" height="8" rx="4"/><text class="t-s" x="640" y="530">80</text>
    <circle class="ibtn" cx="716" cy="526" r="10"/><path class="pen" d="M711 531 l8 -8 l2 2 l-8 8 h-2 z"/>
    <circle class="ibtn" cx="744" cy="526" r="10"/><path class="bin" d="M739 521 h10 M741 521 v10 h6 v-10"/>
   </g>
   <g class="row-https">
    <rect class="zebra" x="223" y="540" width="534" height="28"/>
    <circle class="okdot" cx="238" cy="554" r="5"/><text class="t-s" x="290" y="559">HTTPS-Server</text><text class="t-s" x="420" y="559">TCP</text>
    <rect class="ph" x="490" y="551" width="80" height="8" rx="4"/><text class="t-s" x="640" y="559">443</text>
    <circle class="ibtn" cx="716" cy="555" r="10"/><path class="pen" d="M711 560 l8 -8 l2 2 l-8 8 h-2 z"/>
    <circle class="ibtn" cx="744" cy="555" r="10"/><path class="bin" d="M739 550 h10 M741 550 v10 h6 v-10"/>
   </g>
   <rect class="btn2" x="662" y="582" width="96" height="26" rx="3"/><text class="t-btn2" x="710" y="599">Neue Freigabe</text>
   <line class="ln" x1="200" y1="622" x2="780" y2="622"/>
   <rect class="btn1" x="668" y="634" width="90" height="28" rx="3"/><text class="t-btn1" x="713" y="652">Übernehmen</text>
  </g>

  <g class="s s-dlg">
   <rect class="veil" x="0" y="0" width="780" height="680"/>
   <rect class="dlg" x="250" y="170" width="430" height="370" rx="4"/>
   <rect class="dlg-hd" x="250" y="170" width="430" height="36" rx="4"/>
   <text class="t-m t-strong" x="268" y="193">Freigabe anlegen</text>
   <circle class="radio" cx="276" cy="232" r="7"/><circle class="radio-on r1" cx="276" cy="232" r="4"/>
   <text class="t-m" x="292" y="237">MyFRITZ!-Freigabe</text>
   <text class="t-lbl" x="300" y="273">Anwendung</text>
   <rect class="field sel" x="430" y="256" width="228" height="28" rx="3"/>
   <text class="t-s app-http" x="440" y="275">HTTP-Server</text><text class="t-s app-https" x="440" y="275">HTTPS-Server</text><path class="caret" d="M638 267 l5 5 l5 -5"/>
   <text class="t-lbl" x="300" y="311">Verzeichnis (optional)</text><rect class="field" x="430" y="294" width="228" height="28" rx="3"/>
   <text class="t-lbl" x="300" y="349">MyFRITZ!-Adresse</text><rect class="field-off" x="430" y="332" width="228" height="28" rx="3"/>
   <circle class="radio" cx="276" cy="382" r="7"/><circle class="radio-on r2" cx="276" cy="382" r="4"/>
   <text class="t-m" x="292" y="387">Portfreigabe</text>
   <line class="ln" x1="266" y1="406" x2="664" y2="406"/>
   <rect class="box" x="269" y="421" width="14" height="14" rx="2"/><path class="tick" d="M272 428 l3 3 l6 -7"/>
   <text class="t-m" x="292" y="433">Freigabe aktivieren</text>
   <rect class="btn2" x="476" y="492" width="94" height="30" rx="3"/><text class="t-btn2" x="523" y="512">OK</text>
   <rect class="btn-off" x="576" y="492" width="94" height="30" rx="3"/><text class="t-off" x="623" y="512">Abbrechen</text>
  </g>

  <rect class="ring" x="0" y="0" width="0" height="0" rx="6"/>
  <circle class="ripple" cx="0" cy="0" r="14"/>
  <g class="cursor"><path d="M0 0 V17 L4.5 13 L7.6 20 L10.4 18.8 L7.4 12 H13 Z"/></g>
 </g>
</svg>`;

  // Zeiger-Spitze neben die Schrift, damit sie lesbar bleibt. Jeder Schritt endet auf dem Bild, das seine Beschriftung zeigt
  // (Standbild bei reduzierter Bewegung und für die Punkte).
  const DLG = { x: 465, y: 300, s: 1.2 };
  const FB_STEPS = [
    { cap: 'fritz.box im Browser öffnen, links „Internet“',
      acts: [{ to: [104, 112], click: true, set: { sub: '1' }, ring: [10, 102, 184, 26] }] },
    { cap: '„Freigaben“, Reiter „Portfreigaben“',
      acts: [{ to: [116, 230], click: true, set: { act: 'freigaben', scene: 'list' } }, { to: [330, 132], ring: [220, 106, 108, 34], wait: 700 }] },
    { cap: '„Gerät für Freigaben hinzufügen“, Rechner wählen',
      acts: [{ to: [664, 282], click: true, set: { scene: 'dev' } }, { to: [566, 132], ring: [356, 106, 208, 34], wait: 700 }] },
    { cap: '„Neue Freigabe“, oben „MyFRITZ!-Freigabe“',
      acts: [{ to: [752, 602], click: true, set: { scene: 'dlg', app: 'http' }, cam: DLG },
        { to: [418, 240], click: true, set: { radio: '1' }, ring: [264, 220, 160, 26] }] },
    { cap: '„HTTP-Server“, Haken bei „Freigabe aktivieren“',
      acts: [{ to: [652, 280], ring: [426, 252, 236, 36], wait: 900 },
        { to: [424, 436], click: true, set: { chk: '1' }, ring: [264, 416, 160, 26] }] },
    { cap: '„OK“, die Freigabe steht jetzt in der Liste', hint: true,
      acts: [{ to: [552, 516], click: true, ring: [472, 488, 102, 38], wait: 500 },
        { set: { scene: 'dev', rows: '1', radio: '0', chk: '0' }, cam: { x: 490, y: 520, s: 1 }, ring: [224, 513, 532, 26] }] },
    { cap: 'Dasselbe noch einmal mit „HTTPS-Server“',
      acts: [{ to: [752, 602], click: true, set: { scene: 'dlg', app: 'https', radio: '1', chk: '1' }, cam: DLG, ring: [426, 252, 236, 36], wait: 1300 },
        { to: [552, 516], click: true, set: { scene: 'dev', rows: '2', radio: '0', chk: '0' }, cam: { x: 490, y: 545, s: 1 }, ring: [224, 541, 532, 26] },
        { to: [700, 562], cam: { x: 490, y: 545, s: 1 }, wait: 400 }] },
    { cap: 'Unten „Übernehmen“ klicken',
      acts: [{ to: [754, 656], click: true, cam: { x: 490, y: 600, s: 1 }, ring: [664, 630, 98, 36] }] },
  ];

  // Seiten-Hinweis „Freigabe existiert bereits“ gehört zum Speichern mit „OK“ (Schritt 6) und steht dort im Bild.
  function fbShare(page) {
    const note = page.note && page.note.text ? page.note.text : null;
    const link = page.link && page.link.href ? page.link : null;
    return guided({ name: 'fb-share', svg: FB_SVG, width: 780, height: 680, steps: FB_STEPS, cursor: [420, 160], light: true,
      label: 'Nachgezeichnete FritzBox-Oberfläche: der Weg zu den Freigaben, Schritt für Schritt',
      hint: note, link, takes: [note ? 'note' : null, link ? 'link' : null].filter(Boolean),
      initial: { sub: '0', act: 'none', scene: 'home', radio: '0', chk: '0', rows: '0', app: 'http' } });
  }

  // ---------- A2: Charakter des Bots (Seite h:OWNER_PERSONA) ----------
  // Handy-Ausschnitt nach dem Analog der Site (phone-frame-*.html, .tg-*), Farben aus den Tokens. Zeigt, was der Bot wirklich
  // tut: Rahmensatz des Charakters (fester Katalogtext core.persona.frame.<code>.1, mit Emoji) vor einer neutralen Antwort, in der
  // im Setup gewählten Sprache; darunter der Sticker, den der Bot in Telegram schickt. Rahmensätze und Sticker-Adresse liefert der
  // Server je Option (o.frame[lang] aus dem Core-Katalog, o.sticker aus packages/core/build/stickers), page.lang die gewählte
  // Sprache. Fehlt etwas, bleibt nur die neutrale Antwort.
  // Hier stehen nur die Beispiel-Frage und die neutrale Antwort selbst (Bildtext, keine Bot-Sprechweise).
  const CHAT = {
    de: { bot: 'Dein Bot', q: 'Was steht heute an?', a: 'Für heute ist nichts eingetragen.' },
    en: { bot: 'Your bot', q: "What's on today?", a: 'Nothing is scheduled for today.' },
    ko: { bot: '나의 봇', q: '오늘 일정 있어?', a: '오늘은 예정된 일이 없어요.' },
  };

  function phone(label, title, chat) {
    return h('div', { class: 'ph-frame', role: 'img', 'aria-label': label },
      h('div', { class: 'ph-screen' },
        h('div', { class: 'island' }),
        h('div', { class: 'statusbar' }, h('span', { text: '9:41' }), fromMarkup('<svg class="icons" viewBox="0 0 46 11" aria-hidden="true">'
          + '<rect x="0" y="7" width="3" height="4" rx="1"/><rect x="4.5" y="5" width="3" height="6" rx="1"/><rect x="9" y="2.5" width="3" height="8.5" rx="1"/>'
          + '<rect x="13.5" y="0" width="3" height="11" rx="1"/><rect class="batt" x="22.5" y="0.5" width="21" height="10" rx="3"/><rect x="24.5" y="2.5" width="15" height="6" rx="1.5"/></svg>')),
        h('div', { class: 'tg-header' }, h('span', { class: 'tg-avatar' }, mark()), title),
        h('div', { class: 'tg-chat' }, chat)));
  }

  function persona(page) {
    const lang = CHAT[page.lang] ? page.lang : 'de';
    const t = CHAT[lang];
    const opts = {};
    for (const o of page.options || []) opts[o.value] = o;
    const frame = h('span', { class: 'frame' });
    const reply = h('div', { class: 'msg msg-in', lang }, frame, h('span', { text: t.a }));
    const sticker = h('img', { class: 'sticker', alt: '', 'aria-hidden': 'true', width: '512', height: '512', decoding: 'async' });
    const typing = h('div', { class: 'msg msg-in typing', 'aria-hidden': 'true' }, h('i'), h('i'), h('i'));
    const fig = h('figure', { class: 'art art-phone', 'data-art': 'persona' },
      h('div', { class: 'art-box' },
        phone('Beispiel-Chat mit deinem Bot', h('span', { class: 'tg-title', text: t.bot, lang }),
          [h('div', { class: 'msg msg-out', text: t.q, lang }), reply, sticker, typing])));   // „was gleich bleibt“ sagt der Seitentext
    let timer = null;
    const show = (code) => {
      const o = opts[code] || {};
      const f = o.frame && (o.frame[lang] || o.frame.de);
      frame.textContent = f || '';
      frame.hidden = !f;
      if (o.sticker) sticker.src = o.sticker;
      sticker.hidden = !o.sticker;
    };
    show(page.value);
    function select(code) {
      clearTimeout(timer);
      if (reduced()) { show(code); return; }
      fig.classList.add('busy');
      timer = setTimeout(() => { if (!fig.isConnected) return; show(code); fig.classList.remove('busy'); }, 650);
    }
    return { el: fig, select, side: true };   // neben die Auswahl (app.js .with-art), unter der Auswahl wäre bei 640 px kein Platz
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
