/* stickers.js -- Quelle der Persona-Sticker (Bot mit Gesicht, 2026-10-30; MIT wie das Repo, selbst gezeichnet).
 * Jede Figur ist aus Teilen zusammengesetzt (Koerper, Kopf, Gesicht je Ausdruck, Geste, Accessoire), damit alle
 * Sets denselben Stil haben. Ein Set je Persona-Code aus dem Core-Manifest personas.list; 'neutral' = Standard
 * (kleiner Roboter, Owner-Entscheid: ohne eigenen Namen). Ausdruecke: hallo, top, hmm, yay
 * (Auswahl: agent.fn_claim_persona_sticker).
 * Rendern: scripts/dev/render_stickers.ps1 -> render.html -> <code>_<ausdruck>.webp (512 px) in diesem Ordner.
 * Neue Persona = neuer Eintrag in PERSONAS + render_stickers.ps1; locale_lint (7b) verlangt die vier Dateien. */
(function (root) {
  'use strict';
  var L = '#2A2340';
  var S = 'stroke="' + L + '" stroke-width="3.5" stroke-linejoin="round" stroke-linecap="round"';
  var BODY = 'M30 190 C30 160 60 144 100 144 C140 144 170 160 170 190 Q170 197 163 197 L37 197 Q30 197 30 190 Z';
  var EXPR = ['hallo', 'top', 'hmm', 'yay'];

  function thick(d, color, w) {
    return '<path d="' + d + '" fill="none" stroke="' + L + '" stroke-width="' + (w + 6) + '" stroke-linecap="round"/>' +
           '<path d="' + d + '" fill="none" stroke="' + color + '" stroke-width="' + w + '" stroke-linecap="round"/>';
  }
  function star(x, y, s) {
    return '<path d="M' + x + ' ' + (y - s) + ' Q' + x + ' ' + y + ' ' + (x + s) + ' ' + y + ' Q' + x + ' ' + y + ' ' + x + ' ' + (y + s) +
           ' Q' + x + ' ' + y + ' ' + (x - s) + ' ' + y + ' Q' + x + ' ' + y + ' ' + x + ' ' + (y - s) + ' Z" fill="#FFD23F" stroke="' + L +
           '" stroke-width="2.5" stroke-linejoin="round"/>';
  }
  function leaf(x, y, r, c) {
    return '<g transform="translate(' + x + ' ' + y + ') rotate(' + r + ')"><path d="M0 -10 Q9 0 0 10 Q-9 0 0 -10 Z" fill="' + c +
           '" stroke="' + L + '" stroke-width="2.5"/><path d="M0 -8 L0 8" stroke="' + L + '" stroke-width="1.5"/></g>';
  }
  function confetti() {
    var bits = [[30, 40, '#FF6B6B', 20], [60, 18, '#FFD23F', -30], [150, 20, '#4ECDC4', 40], [178, 52, '#A78BFA', -15],
                [22, 80, '#4ECDC4', 60], [184, 92, '#FF6B6B', 25], [120, 8, '#A78BFA', 10]];
    return bits.map(function (b) {
      return '<rect x="' + (b[0] - 4) + '" y="' + (b[1] - 7) + '" width="8" height="14" rx="2" fill="' + b[2] + '" stroke="' + L +
             '" stroke-width="2" transform="rotate(' + b[3] + ' ' + b[0] + ' ' + b[1] + ')"/>';
    }).join('');
  }

  function eyes(ex, p) {
    var ink = p.ink || L;
    function open(x, y) {
      return '<ellipse cx="' + x + '" cy="' + y + '" rx="5.5" ry="7.5" fill="' + ink + '"/>' +
             (p.ink ? '' : '<circle cx="' + (x + 2) + '" cy="' + (y - 3) + '" r="2" fill="#fff"/>');
    }
    function happy(x) {
      return '<path d="M' + (x - 7) + ' 99 Q' + x + ' 89 ' + (x + 7) + ' 99" fill="none" stroke="' + ink + '" stroke-width="4" stroke-linecap="round"/>';
    }
    if (ex === 'hallo') return open(82, 96) + open(118, 96);
    if (ex === 'top') return open(82, 96) + happy(118);
    if (ex === 'hmm') return open(86, 92) + open(122, 92);
    return happy(82) + happy(118);
  }
  function brows(ex, p) {
    var l = ex === 'yay' ? 'M74 79 Q82 74 90 79' : 'M74 82 Q82 77 90 82';
    var r = ex === 'hmm' ? 'M110 76 Q118 69 126 75' : (ex === 'yay' ? 'M110 79 Q118 74 126 79' : 'M110 82 Q118 77 126 82');
    if (p.bushy) return thick(l, '#F4F2F8', 7) + thick(r, '#F4F2F8', 7);
    var ink = p.ink || L;
    return '<path d="' + l + '" fill="none" stroke="' + ink + '" stroke-width="3.5" stroke-linecap="round"/>' +
           '<path d="' + r + '" fill="none" stroke="' + ink + '" stroke-width="3.5" stroke-linecap="round"/>';
  }
  function blush(ex) {
    if (ex === 'hmm') return '';
    return '<ellipse cx="69" cy="111" rx="7" ry="4" fill="#FF8FA3" opacity=".6"/><ellipse cx="131" cy="111" rx="7" ry="4" fill="#FF8FA3" opacity=".6"/>';
  }
  function mouth(ex, p) {
    var ink = p.ink || L, inside = p.mouthFill || '#7B2D3B', tongue = !p.ink;
    var t = function (d) { return '<g transform="translate(0 ' + (p.mouthDY || 0) + ')">' + d + '</g>'; };
    if (ex === 'hallo') return t('<path d="M87 113 Q100 130 113 113 Z" fill="' + inside + '" stroke="' + ink + '" stroke-width="3" stroke-linejoin="round"/>' +
      (tongue ? '<path d="M93 121.5 Q100 117 107 121.5 Q100 127 93 121.5 Z" fill="#FF7A8A"/>' : ''));
    if (ex === 'yay') return t('<path d="M83 111 Q100 138 117 111 Z" fill="' + inside + '" stroke="' + ink + '" stroke-width="3" stroke-linejoin="round"/>' +
      (tongue ? '<path d="M91 124 Q100 118 109 124 Q100 131 91 124 Z" fill="#FF7A8A"/>' : ''));
    if (ex === 'top') return t('<path d="M89 116 Q102 124 113 112" fill="none" stroke="' + ink + '" stroke-width="3.5" stroke-linecap="round"/>');
    return t('<ellipse cx="105" cy="118" rx="4" ry="4.5" fill="' + inside + '" stroke="' + ink + '" stroke-width="3"/>');
  }
  function arms(ex, p) {
    function hand(x, y, r) { return '<circle cx="' + x + '" cy="' + y + '" r="' + (r || 12) + '" fill="' + p.hand + '" ' + S + '/>'; }
    if (ex === 'hallo') return thick('M150 170 Q170 152 172 118', p.arm, 18) + hand(172, 108) +
      '<path d="M187 92 Q193 101 189 111" fill="none" ' + S + '/><path d="M195 84 Q204 99 197 115" fill="none" ' + S + '/>';
    if (ex === 'top') return thick('M162 196 Q158 178 146 168', p.arm, 18) +
      '<rect x="131" y="131" width="11" height="25" rx="5.5" fill="' + p.hand + '" ' + S + '/>' +
      '<rect x="126" y="150" width="28" height="25" rx="9" fill="' + p.hand + '" ' + S + '/>' + star(166, 132, 9);
    if (ex === 'hmm') return thick('M152 196 Q144 170 118 152', p.arm, 18) + hand(113, 146, 11) +
      '<circle cx="164" cy="38" r="15" fill="#fff" ' + S + '/><path d="M158 33 Q158 26 164 26 Q170 26 170 32 Q170 36 164 39 L164 43" fill="none" ' + S + '/>' +
      '<circle cx="164" cy="49" r="2.2" fill="' + L + '"/><circle cx="146" cy="58" r="4" fill="#fff" ' + S + '/>';
    return thick('M50 170 Q30 152 30 118', p.arm, 18) + thick('M150 170 Q170 152 170 118', p.arm, 18) + hand(30, 108) + hand(170, 108);
  }
  function baseHead(p) {
    return '<rect x="89" y="128" width="22" height="22" fill="' + p.skin + '" ' + S + '/>' +
      '<circle cx="53" cy="98" r="9" fill="' + p.skin + '" ' + S + '/><circle cx="147" cy="98" r="9" fill="' + p.skin + '" ' + S + '/>' +
      '<circle cx="100" cy="92" r="48" fill="' + p.skin + '" ' + S + '/>';
  }

  var PERSONAS = {
    neutral: {   // Standard: kleiner Haus-Roboter (ohne Namen)
      skin: '#8FD3FF', arm: '#5BB8F0', hand: '#8FD3FF', ink: '#7CF3E6', mouthFill: '#3BB8B0',
      body: function () {
        return '<path d="' + BODY + '" fill="#5BB8F0" ' + S + '/><path d="M100 178 C90 170 86 162 92 158 C96 155 100 159 100 161 ' +
          'C100 159 104 155 108 158 C114 162 110 170 100 178 Z" fill="#FF6B8B" stroke="' + L + '" stroke-width="2.5"/>';
      },
      head: function (p) {
        return '<path d="M100 46 L100 28" ' + S + '/><circle cx="100" cy="23" r="7" fill="#FFC93C" ' + S + '/>' +
          '<rect x="89" y="128" width="22" height="20" fill="#5BB8F0" ' + S + '/><rect x="40" y="82" width="14" height="28" rx="6" fill="#5BB8F0" ' + S + '/>' +
          '<rect x="146" y="82" width="14" height="28" rx="6" fill="#5BB8F0" ' + S + '/>' +
          '<rect x="50" y="46" width="100" height="92" rx="36" fill="' + p.skin + '" ' + S + '/><rect x="62" y="64" width="76" height="66" rx="24" fill="#22314F" ' + S + '/>';
      }
    },
    butler: {
      skin: '#F7D6BC', arm: '#2E2B3F', hand: '#FFFFFF', mouthDY: 2,
      body: function () {
        return '<path d="' + BODY + '" fill="#2E2B3F" ' + S + '/><path d="M84 146 L100 180 L116 146 Z" fill="#fff" ' + S + '/>' +
          '<circle cx="100" cy="170" r="2.2" fill="' + L + '"/><path d="M100 153 L86 145 L86 161 Z" fill="#9B2D4E" ' + S + '/>' +
          '<path d="M100 153 L114 145 L114 161 Z" fill="#9B2D4E" ' + S + '/><circle cx="100" cy="153" r="4.5" fill="#9B2D4E" ' + S + '/>';
      },
      head: function (p) {
        return baseHead(p) +
          '<path d="M52 92 C46 54 76 36 102 38 C130 40 154 58 148 92 C146 76 136 64 118 60 C108 66 84 66 66 70 C58 76 54 84 52 92 Z" fill="#2B2738" ' + S + '/>' +
          '<path d="M116 52 Q108 45 96 45" fill="none" stroke="#5A5476" stroke-width="3" stroke-linecap="round"/>';
      },
      beforeMouth: function () {
        return '<path d="M85 109 Q93 102 100 107 Q107 102 115 109 Q108 113 100 110 Q92 113 85 109 Z" fill="#2B2738" stroke="' + L + '" stroke-width="2.5" stroke-linejoin="round"/>';
      },
      afterMouth: function () {
        return '<circle cx="118" cy="96" r="12.5" fill="rgba(255,255,255,.2)" stroke="#C9A227" stroke-width="3.5"/>' +
          '<path d="M130 100 Q142 122 134 146" fill="none" stroke="#C9A227" stroke-width="2"/>';
      }
    },
    sportscaster: {
      skin: '#C98E64', arm: '#FF7A3D', hand: '#C98E64',
      hideEyes: function (ex) { return ex === 'yay'; },
      body: function () {
        return '<path d="' + BODY + '" fill="#FF7A3D" ' + S + '/><path d="M80 148 L100 170 L120 148" fill="none" stroke="#15A3A0" stroke-width="7" stroke-linejoin="round"/>' +
          '<rect x="68" y="168" width="34" height="15" rx="4" fill="#E5293E" stroke="' + L + '" stroke-width="2.5"/>' +
          '<path d="M74 172 L74 179 L78 179 M81 172 L81 179 M84 172 L86.5 179 L89 172 M96 172 L92 172 L92 179 L96 179 M92 175.5 L95 175.5" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>';
      },
      head: function (p, ex) {
        return baseHead(p) +
          '<path d="M54 86 C50 52 76 38 100 40 C128 40 152 56 146 86 C140 70 126 62 110 64 C112 56 104 52 96 56 C84 58 64 66 54 86 Z" fill="#2A1A12" ' + S + '/>' +
          (ex === 'yay' ? '' : '<rect x="73" y="50" width="23" height="12" rx="5" fill="#1E2A3A" stroke="' + L + '" stroke-width="2.5"/>' +
            '<rect x="104" y="50" width="23" height="12" rx="5" fill="#1E2A3A" stroke="' + L + '" stroke-width="2.5"/>' +
            '<path d="M96 55 L104 55" stroke="' + L + '" stroke-width="2.5"/><path d="M78 59 L84 53" stroke="#6FE3DD" stroke-width="2" stroke-linecap="round"/>');
      },
      afterMouth: function (p, ex) {
        var s = '<path d="M47 92 C44 34 156 34 153 92" fill="none" stroke="' + L + '" stroke-width="11"/>' +
          '<path d="M47 92 C44 34 156 34 153 92" fill="none" stroke="#3A3F4B" stroke-width="5"/>' +
          '<rect x="38" y="83" width="17" height="29" rx="7" fill="#15A3A0" ' + S + '/><rect x="145" y="83" width="17" height="29" rx="7" fill="#15A3A0" ' + S + '/>' +
          thick('M47 110 Q52 128 72 129', '#3A3F4B', 3) + '<circle cx="75" cy="129" r="6" fill="#3A3F4B" ' + S + '/>';
        if (ex === 'yay') s += '<rect x="69" y="86" width="27" height="16" rx="6" fill="#1E2A3A" ' + S + '/><rect x="104" y="86" width="27" height="16" rx="6" fill="#1E2A3A" ' + S + '/>' +
          '<path d="M96 92 L104 92" ' + S + '/><path d="M75 98 L83 89" stroke="#6FE3DD" stroke-width="2.5" stroke-linecap="round"/>' +
          '<path d="M110 98 L118 89" stroke="#6FE3DD" stroke-width="2.5" stroke-linecap="round"/>';
        return s;
      }
    },
    sage: {
      skin: '#F2CDB0', arm: '#5B3F8C', hand: '#F2CDB0', bushy: true, mouthDY: 7,
      body: function () {
        return '<path d="' + BODY + '" fill="#5B3F8C" ' + S + '/><path d="M78 147 L100 188 L122 147" fill="none" stroke="#E3B23C" stroke-width="6" stroke-linejoin="round"/>';
      },
      head: function (p) {
        return '<circle cx="100" cy="40" r="14" fill="#ECEAF2" ' + S + '/>' + baseHead(p) +
          '<path d="M53 97 Q44 80 57 70 Q59 84 64 93 Z" fill="#ECEAF2" ' + S + '/><path d="M147 97 Q156 80 143 70 Q141 84 136 93 Z" fill="#ECEAF2" ' + S + '/>';
      },
      beforeMouth: function () {
        return '<circle cx="82" cy="96" r="11" fill="rgba(255,255,255,.18)" stroke="#7A5A2E" stroke-width="2.8"/>' +
          '<circle cx="118" cy="96" r="11" fill="rgba(255,255,255,.18)" stroke="#7A5A2E" stroke-width="2.8"/>' +
          '<path d="M93 95 Q100 90 107 95" fill="none" stroke="#7A5A2E" stroke-width="2.8"/>' +
          '<path d="M60 104 C58 150 80 182 100 190 C120 182 142 150 140 104 C130 122 116 129 100 129 C84 129 70 122 60 104 Z" fill="#F4F2F8" ' + S + '/>' +
          '<path d="M90 152 Q100 160 110 152" fill="none" stroke="#C9C4D6" stroke-width="2.5" stroke-linecap="round"/>' +
          '<path d="M94 170 Q100 175 106 170" fill="none" stroke="#C9C4D6" stroke-width="2.5" stroke-linecap="round"/>' +
          '<path d="M81 114 Q90 104 100 109 Q110 104 119 114 Q110 120 100 115 Q90 120 81 114 Z" fill="#F4F2F8" ' + S + '/>';
      },
      fx: function (ex) {
        return ex === 'yay' ? leaf(32, 46, -30, '#7CC47F') + leaf(172, 40, 35, '#A8D86E') + leaf(178, 92, 70, '#7CC47F') + leaf(22, 92, -60, '#A8D86E') : '';
      }
    }
  };

  // Ein vollstaendiges, eigenstaendiges SVG (Filter im eigenen <defs>: weisser Sticker-Rand + weicher Schatten)
  function render(code, ex) {
    var p = PERSONAS[code];
    if (!p || EXPR.indexOf(ex) < 0) throw new Error('unbekannter Sticker: ' + code + '_' + ex);
    var g = '';
    if (ex === 'yay' && !p.fx) g += confetti();
    if (p.fx) g += p.fx(ex);
    g += p.body(ex) + p.head(p, ex);
    if (!(p.hideEyes && p.hideEyes(ex))) g += eyes(ex, p);
    g += brows(ex, p);
    if (!p.ink) g += blush(ex);
    if (p.beforeMouth) g += p.beforeMouth(ex);
    g += mouth(ex, p);
    if (p.afterMouth) g += p.afterMouth(p, ex);
    g += arms(ex, p);
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-12 -12 224 224" width="512" height="512">' +
      '<defs><filter id="stk" x="-15%" y="-15%" width="130%" height="130%">' +
      '<feMorphology in="SourceAlpha" operator="dilate" radius="6" result="fat"/><feFlood flood-color="#FFFFFF" result="white"/>' +
      '<feComposite in="white" in2="fat" operator="in" result="outline"/><feGaussianBlur in="fat" stdDeviation="3" result="blur"/>' +
      '<feOffset in="blur" dy="3" result="sh"/><feFlood flood-color="#000" flood-opacity=".22"/><feComposite in2="sh" operator="in" result="shadow"/>' +
      '<feMerge><feMergeNode in="shadow"/><feMergeNode in="outline"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>' +
      '<g filter="url(#stk)">' + g + '</g></svg>';
  }

  root.LifeAgentsStickers = { codes: Object.keys(PERSONAS), expressions: EXPR.slice(), render: render };
})(this);
