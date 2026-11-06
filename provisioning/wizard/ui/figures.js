// Bilder im Wizard (Owner-Runde 2026-11-06: „nur da, wo es passt“): fertige DOM-Bausteine ohne Nutzerdaten, ohne Nachladen.
// Seite -> Baustein steht im View-Modell (server.js pageFor: page.figure). Nur erfundene Beispielwerte.
// - Handy-Rahmen mit Chat: Analog der Site (docs/site/layouts/partials/phone-frame-*.html), Farben nur über Tokens.
// - Schema-Animation FritzBox: eigene Zeichnung, KEINE Optik der echten Oberfläche (Plan Einwand 13: keine AVM-Bilder oder
//   -Logos); nur die Menünamen stimmen (eine Quelle: docs/site/content/docs/fritzbox.md). Bewegung nur per CSS, bei
//   prefers-reduced-motion ein stehendes Bild.
'use strict';
(function () {
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }
  function add(parent, ...kids) { kids.forEach((k) => k && parent.appendChild(k)); return parent; }
  function mark() {
    const t = document.getElementById('mark-tpl');
    return t ? t.content.cloneNode(true) : null;
  }

  // phone({title, sub, avatar:'mark'|'B', msgs:[{out:bool, text, strong?}]}, label) -> Handy mit Telegram-Chat (Schema).
  function phone(o, label) {
    const fig = el('figure', 'fig fig-phone');
    const p = add(el('div', 'phone'));
    p.setAttribute('role', 'img');
    p.setAttribute('aria-label', label);
    const s = el('div', 'screen');
    const head = el('div', 'tg-header');
    const av = el('span', 'tg-avatar');
    if (o.avatar === 'mark') add(av, mark()); else av.textContent = o.avatar;
    const title = el('span', 'tg-title', o.title);
    add(title, el('small', null, o.sub));
    add(head, av, title);
    const chat = el('div', 'tg-chat');
    for (const m of o.msgs) {
      const b = el('div', 'msg ' + (m.out ? 'msg-out' : 'msg-in'), m.text);
      if (m.strong) add(b, el('br'), el('b', 'mono', m.strong));
      chat.appendChild(b);
    }
    add(s, el('div', 'island'), head, chat, add(el('div', 'tg-input'), el('span', 'field', 'Nachricht')));
    add(p, s);
    return add(fig, p, el('figcaption', null, label));
  }

  // FritzBox-Schema: Mauszeiger fährt zu Internet → Freigaben, klickt, das Bild zoomt auf „Neue Freigabe“, der Knopf leuchtet.
  function fritzbox() {
    const fig = el('figure', 'fig fig-fbx fig-wide');
    const box = el('div', 'fbx');
    box.setAttribute('role', 'img');
    box.setAttribute('aria-label', 'Schema: In der FritzBox auf Internet, dann Freigaben, dann auf Neue Freigabe klicken');
    const bar = add(el('div', 'fbx-bar'), el('span', 'fbx-dot'), el('span', 'fbx-dot'), el('span', 'fbx-dot'), el('span', 'fbx-url', 'fritz.box'));
    const stage = el('div', 'fbx-stage');
    const side = el('div', 'fbx-side');
    [['Übersicht'], ['Internet', 'fbx-open'], ['Online-Monitor', 'fbx-sub'], ['Freigaben', 'fbx-sub fbx-target1'], ['MyFRITZ!-Konto', 'fbx-sub'],
      ['Heimnetz'], ['System']].forEach(([t, c]) => side.appendChild(el('div', 'fbx-item ' + (c || ''), t)));
    const pane = el('div', 'fbx-pane');   // Rahmen schneidet ab, nur der Inhalt zoomt
    const zoom = el('div', 'fbx-zoom');
    add(zoom, add(el('div', 'fbx-tabs'), el('span', 'fbx-tab fbx-tab-on', 'Portfreigaben'), el('span', 'fbx-tab', 'Dienste')),
      add(el('div', 'fbx-row'), el('span', null, 'Dieser Rechner'), el('span', 'fbx-pen', '✎')),
      add(el('div', 'fbx-row fbx-row-dim'), el('span', null, 'Anderes Gerät'), el('span', 'fbx-pen', '✎')),
      el('span', 'fbx-btn fbx-target2', 'Neue Freigabe'));
    add(pane, zoom);
    add(stage, side, pane);
    const cursor = el('span', 'fbx-cursor');
    cursor.innerHTML = '<svg viewBox="0 0 16 22" width="16" height="22" aria-hidden="true"><path d="M1 1 L1 17 L5 13 L8 20 L11 19 L8 12 L14 12 Z" fill="var(--ink)" stroke="var(--bg)" stroke-width="1.2" stroke-linejoin="round"/></svg>';
    add(stage, cursor, el('span', 'fbx-ping fbx-ping1'), el('span', 'fbx-ping fbx-ping2'));
    add(box, bar, stage);
    return add(fig, box, el('figcaption', null, 'Schema, deine FritzBox sieht anders aus. Die Namen der Menüpunkte stimmen.'));
  }

  const FIG = {
    botfather: () => phone({ title: 'BotFather', sub: 'Bot', avatar: 'B', msgs: [
      { out: true, text: '/newbot' },
      { out: false, text: 'Alright, a new bot. How are we going to call it?' },
      { out: true, text: 'Mein Assistent' },
      { out: false, text: 'Good. Now choose a username. It must end in „bot“.' },
      { out: true, text: 'mein_assistent_bot' },
      { out: false, text: 'Done! Use this token to access the HTTP API:', strong: '123456789:ABC-Beispiel' },
    ] }, 'So sieht das Gespräch mit BotFather aus (Beispielnamen)'),
    fritzbox,
  };
  window.WIZARD_FIGURES = FIG;
})();
