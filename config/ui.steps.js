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
