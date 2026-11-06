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
