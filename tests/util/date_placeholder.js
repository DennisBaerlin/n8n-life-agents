// Datums-Platzhalter {{date:<offset>[@<tag>]}} fuer die Test-Attrappen: JS-Zwilling von scripts/lib/date_placeholder.ps1
// (Grammatik dort), beide gegen tests/util/date_placeholder_vectors.json geprueft (scripts/dev/date_placeholder_test.ps1).
// Eine Kopie fuer beide Attrappen: tests/mock_llm/server.js (Szenarien) und tests/mock_telegram/server.js (Test-Dateien mit
// Zeilen relativ zu heute); die enable_mock_*-Skripte kopieren die Datei neben den jeweiligen server.js.
// Ein verfehlter Platzhalter wirft.
'use strict';
function utcDate(y, m, d) { return new Date(Date.UTC(y, m, d)); }
function addMonthsClamped(d, n) {
  const first = utcDate(d.getUTCFullYear(), d.getUTCMonth() + n, 1);
  const last = utcDate(first.getUTCFullYear(), first.getUTCMonth() + 1, 0).getUTCDate();
  return utcDate(first.getUTCFullYear(), first.getUTCMonth(), Math.min(d.getUTCDate(), last));
}
function datePlaceholderValue(expr, today) {
  const m = /^([+-]?)(\d+)([dwm])(?:@(-?\d{1,2}))?$/.exec(expr);
  if (!m) throw new Error('Ungueltiger Datums-Platzhalter {{date:' + expr + '}}');
  let n = parseInt(m[2], 10); if (m[1] === '-') n = -n;
  let d = utcDate(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
  if (m[3] === 'd') d = new Date(d.getTime() + n * 86400000);
  else if (m[3] === 'w') d = new Date(d.getTime() + 7 * n * 86400000);
  else d = addMonthsClamped(d, n);
  if (m[4] !== undefined) {
    const day = parseInt(m[4], 10);
    if (day === 0 || Math.abs(day) > 31) throw new Error('Ungueltiger Datums-Platzhalter {{date:' + expr + '}}: Tag ausserhalb 1-31 bzw. -1..-31');
    for (let k = 0; k <= 12; k++) {
      const first = utcDate(d.getUTCFullYear(), d.getUTCMonth() + k, 1);
      const dim = utcDate(first.getUTCFullYear(), first.getUTCMonth() + 1, 0).getUTCDate();
      const want = day > 0 ? day : dim + day + 1;   // @-1 = letzter, @-2 = vorletzter Tag
      if (want < 1 || want > dim) continue;
      const cand = utcDate(first.getUTCFullYear(), first.getUTCMonth(), want);
      if (cand.getTime() >= d.getTime()) { d = cand; break; }
    }
  }
  return d.toISOString().slice(0, 10);
}
// Bezugstag: MOCK_LLM_TODAY (YYYY-MM-DD) haelt einen Lauf auf einem Tag, auch ueber 00:00 UTC; ohne die Variable gilt die
// aktuelle UTC-Zeit. Mock-LLM: der Tag des Harness (enable_mock_llm.ps1 schreibt ihn in den State); Mock-Telegram: der Tag der
// Datenbank (core.fn_today, enable_mock_telegram.ps1), mit dem Prepare und setup_sql/verify_sql rechnen.
function referenceDay() {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(process.env.MOCK_LLM_TODAY || '');
  return m ? utcDate(+m[1], +m[2] - 1, +m[3]) : new Date();
}
function resolveDatePlaceholders(v, today) {
  today = today || referenceDay();
  if (typeof v === 'string') return v.indexOf('{{date:') === -1 ? v : v.replace(/\{\{date:([^}]*)\}\}/g, (all, e) => datePlaceholderValue(e, today));
  if (Array.isArray(v)) return v.map((x) => resolveDatePlaceholders(x, today));
  if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v)) o[k] = resolveDatePlaceholders(v[k], today); return o; }
  return v;
}
module.exports = { datePlaceholderValue, resolveDatePlaceholders, referenceDay };
