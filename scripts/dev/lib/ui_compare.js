// Vergleichsseite (build_ui_compare.ps1): zeigt zwei Staende der echten Mini-App nebeneinander und markiert jede
// Abweichung aus dem gerenderten DOM, damit keine Aenderung von Hand vergessen wird. Eingabe: window.__CMP__ = {light, dark}
// je {vorher, nachher} als Base64 und screens = [{id, title}].
(function () {
  var C = window.__CMP__;
  var L = document.getElementById('L'), R = document.getElementById('R');
  var scheme = 'light', cur = 0;
  // Farben, die in keiner Oberflaeche vorkommen: Sonst haelt der Owner eine Markierung fuer eine Anzeige der App.
  var GREY = 'repeating-linear-gradient(135deg,rgba(128,128,128,.28) 0 5px,transparent 5px 10px)!important';
  var STYLE = '.cmp-chg{outline:2px solid #E6007E;outline-offset:1px;background:rgba(230,0,126,.20)!important;border-radius:4px}' +
    '.cmp-old{outline:2px dashed #8C8C8C;outline-offset:1px;background:' + GREY + ';border-radius:4px}' +
    '.cmp-new{outline:3px solid #E6007E;outline-offset:-3px;background:rgba(230,0,126,.20)!important}' +
    '.cmp-gone{outline:2px dashed #8C8C8C;outline-offset:-2px;background:' + GREY + '}' +
    '.cmp-moved{outline:3px dashed #E6007E;outline-offset:-3px;background:rgba(230,0,126,.12)!important}';

  function dec(b) { return new TextDecoder().decode(Uint8Array.from(atob(b), function (c) { return c.charCodeAt(0); })); }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function txt(el) { return el ? el.textContent.replace(/\s+/g, ' ').trim() : ''; }
  function all(root, sel) { return Array.prototype.slice.call(root.querySelectorAll(sel)); }

  function load(frame, html) {
    return new Promise(function (res) { frame.onload = function () { res(); }; frame.srcdoc = html; });
  }
  async function loadBoth() {
    await Promise.all([load(L, dec(C[scheme].vorher)), load(R, dec(C[scheme].nachher))]);
    await wait(350);
    [L, R].forEach(function (f) { var s = f.contentDocument.createElement('style'); s.textContent = STYLE; f.contentDocument.head.appendChild(s); });
  }
  async function open(i) {
    [L, R].forEach(function (f) { var t = all(f.contentDocument, '.tab')[i]; if (t) t.click(); });
    await wait(260);
  }
  function items(doc) {
    return all(doc, '.item').map(function (el) {
      var sec = el.closest('.sec');
      return { el: el, sec: sec ? txt(sec.querySelector('.sec-title')) : '', label: txt(el.querySelector('.label')), text: txt(el) };
    });
  }
  function expand(it) { var t = it.el.querySelector('.toggle'); if (t && t.getAttribute('aria-expanded') !== 'true') t.click(); }

  function markUnits(a, b, cls) {
    // Art + Text: Ein Satz, der nur vom Untertitel ins Aufklappen wandert, ist auch eine Aenderung.
    var key = function (u) { return u.className.split(' ')[0] + '|' + txt(u); };
    var n = 0, have = all(b.el, '.label,.sub,.value,.pill,.kv').map(key);
    all(a.el, '.label,.sub,.value,.pill,.kv').forEach(function (u) {
      if (have.indexOf(key(u)) < 0) { u.classList.add(cls); n++; if (u.classList.contains('kv')) expand(a); }
    });
    return n;
  }
  function markItems(self, other, oldSide) {
    var n = 0;
    self.forEach(function (it) {
      var same = other.filter(function (o) { return o.sec === it.sec && o.label === it.label; })[0];
      if (same) {
        if (same.text !== it.text) n += markUnits(it, same, oldSide ? 'cmp-old' : 'cmp-chg');
        return;
      }
      var moved = other.filter(function (o) { return o.label === it.label; })[0];
      it.el.classList.add(moved ? 'cmp-moved' : (oldSide ? 'cmp-gone' : 'cmp-new'));
      n++;
    });
    return n;
  }
  function markHeads(a, b, cls) {
    var n = 0;
    all(a, '.hero-label,.hero-value,.hero-note,.sec-title,.banner').forEach(function (u) {
      if (all(b, '.' + u.className.split(' ')[0]).map(txt).indexOf(txt(u)) < 0) { u.classList.add(cls); n++; }
    });
    var key = function (u) { var s = u.closest('.sec'); return txt(s && s.querySelector('.sec-title')) + '|' + txt(u); };
    var other = all(b, '.sec-value').map(key);
    all(a, '.sec-value').forEach(function (u) { if (other.indexOf(key(u)) < 0) { u.classList.add(cls); n++; } });
    return n;
  }
  function fit() {
    [L, R].forEach(function (f) { f.style.height = '200px'; });
    var h = Math.max(L.contentDocument.documentElement.scrollHeight, R.contentDocument.documentElement.scrollHeight);
    [L, R].forEach(function (f) { f.style.height = (h + 8) + 'px'; });
  }
  function mark() {
    var a = L.contentDocument, b = R.contentDocument, ia = items(a), ib = items(b);
    var n = markItems(ib, ia, false) + markHeads(b, a, 'cmp-chg');
    markItems(ia, ib, true); markHeads(a, b, 'cmp-old');
    return n;
  }
  async function show(i) {
    cur = i;
    await loadBoth();
    await open(i);
    var n = mark();
    await wait(120);
    fit();
    all(document, '#tabs button').forEach(function (x, k) { x.classList.toggle('on', k === i); });
    return n;
  }
  async function start() {
    var bar = document.getElementById('tabs');
    C.screens.forEach(function (s, i) {
      var b = document.createElement('button');
      b.dataset.t = s.title; b.textContent = s.title;
      b.onclick = function () { show(i); };
      bar.appendChild(b);
    });
    document.getElementById('scheme').onclick = function () { scheme = scheme === 'light' ? 'dark' : 'light'; show(cur); };
    // Erst alle Reiter durchzaehlen: Der Owner sieht sofort, wo sich etwas aendert.
    for (var i = C.screens.length - 1; i >= 0; i--) {
      var n = await show(i);
      var b = bar.children[i];
      b.textContent = b.dataset.t + (n ? ' (' + n + ')' : ' (keine)');
      b.classList.toggle('none', !n);
    }
  }
  start();
})();
