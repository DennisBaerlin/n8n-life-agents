-- ============================================================
-- fn_interest_due_open (READ — Zins-Faelligkeits-Kern, Spiegel zu fn_recurring_due_open)
--   Liefert je AKTIVEM verzinsten Einlagen-Konto (cash/fixed_deposit/p2p, s. fn_interest_eligible_account_type)
--     mit laufender Zinszeile die NOCH OFFENEN Zins-Vorkommen:
--     (account_id, value_date, period_start, period_end, auto_post).
--   Offen = NICHT gebucht (keine Scheduler-Zins-Tx mit interest_period_end = period_end) UND NICHT
--   uebersprungen (kein interest_skips mit period_end = period_end) UND period_end liegt NACH der juengsten
--   gebuchten/uebersprungenen Periode des Kontos (Audit Paket 2: ein Raster, das schon ueberholt ist -- z. B. aus
--   Bestandsdaten mit dem alten Default-'year'-Fehler -- wird nie nachtraeglich angeboten oder per auto_post doppelt
--   gebucht; der Cron bucht ohnehin aufsteigend). 90-Tage-Rueckfenster auf value_date.
--
--   KADENZ je REGIME (Audit Paket 2, Punkt 5; Quelle finance.fn_interest_regimes): vorher galt die Kadenz der
--     OFFENEN Zeile, verankert am ersten valid_from, fuer die ganze Historie -> ein Satzwechsel mit anderer Kadenz
--     ergab eine Periode ueber schon verzinste Monate (Doppelverzinsung). Jetzt: Raster je Regime ab dessen Anker
--     (Satzwechsel ohne Kadenzwechsel verschiebt die Grenzen NICHT); am Wechseltag gibt es KEINE eigene Gutschrift
--     (Live-Befund 2026-10-24), der Rest seit dem letzten Rasterpunkt des alten Regimes laeuft in die erste Periode des
--     neuen (fn_interest_effective_period_start). Die Rasterpunkte liefert finance.fn_interest_grid_point (EINE
--     Quelle, Init): dom -1 = Kalender-Enden (Monats-/Quartals-/Halbjahres-/Jahresende, Live-Befund 2026-10-24),
--     fester Tag / NULL = Anker-Raster. Der Anker selbst ist KEIN Gutschrift-Ende (period_end > anchor).
--   value_date = finance.fn_interest_value_date (period_end bzw. Arrears am posting_day_of_month des Folgemonats).
--   period_start = finance.fn_interest_effective_period_start (Raster-Beginn; erste Periode nach einem Rhythmuswechsel
--     ab dem letzten Rasterpunkt des alten Regimes; nie vor der juengsten erledigten Periode) -> dieselbe Regel wie
--     fn_interest_amount_due. ORDER BY period_end ASC.
--   "gebucht"/"uebersprungen" keyen auf interest_period_end / interest_skips.period_end, NICHT auf transaction_date.
--   Generische Zinseinnahmen (interest_period_end NULL) sind fuer den Scheduler unsichtbar.
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_interest_due_open(date);
CREATE OR REPLACE FUNCTION finance.fn_interest_due_open(p_until date)
RETURNS TABLE(account_id int, value_date date, period_start date, period_end date, auto_post boolean)
LANGUAGE sql STABLE AS $$
WITH acc AS (
    SELECT a.id AS aid, finance.fn_interest_last_done(a.id) AS last_done
    FROM finance.accounts a
    WHERE a.status = 'active'
      AND finance.fn_interest_eligible_account_type(a.account_type)   -- cash/fixed_deposit/p2p (EINE Adresse)
      AND EXISTS (SELECT 1 FROM finance.account_interest_rates o WHERE o.account_id = a.id AND o.valid_to IS NULL)
),
reg AS (
    SELECT acc.aid, acc.last_done, r.anchor, GREATEST(r.n, 1) AS n, r.unit AS u, r.dom, r.pdom,
           r.auto_post AS ap, r.regime_end,
           LEAST(COALESCE(r.regime_end, p_until), p_until) AS lim
    FROM acc, finance.fn_interest_regimes(acc.aid) r
),
occ AS (
    -- Rasterpunkte aus der EINEN Raster-Quelle (fn_interest_grid_point: Kalender-Raster bei dom -1, sonst Anker)
    SELECT reg.*, finance.fn_interest_grid_point(reg.anchor, k, reg.n, reg.u, reg.dom) AS pe
    FROM reg, generate_series(0, finance.fn_interest_grid_index(reg.anchor, reg.lim, reg.n, reg.u, reg.dom) + 2) AS k
),
grid AS (
    SELECT DISTINCT o.aid, o.pe, o.ap, o.last_done, o.anchor,
           finance.fn_interest_value_date(o.pe, o.pdom) AS vd,
           finance.fn_interest_period_start(o.anchor, o.pe, o.n, o.u, o.dom) AS gps
    FROM occ o
    WHERE o.pe > o.anchor                                       -- der Anker selbst ist KEIN Gutschrift-Ende
      AND o.pe <= o.lim                                         -- im Regime (Rasterpunkte bis einschliesslich Regime-Ende)
),
proj AS (
    -- Wirksamer Periodenbeginn = fn_interest_effective_period_start (dieselbe Regel wie fn_interest_amount_due). Nur die
    -- ERSTE Periode eines Regimes (Raster-Beginn = Anker) kann in ein frueheres Regime zurueckreichen -> nur dort die
    -- (teurere) fn; sonst ist sie identisch GREATEST(Raster-Beginn, juengste erledigte Periode).
    SELECT g.*,
           CASE WHEN g.gps = g.anchor THEN finance.fn_interest_effective_period_start(g.aid, g.pe)
                ELSE GREATEST(g.gps, g.last_done) END AS ps
    FROM grid g
)
-- Reicht die Periode in ein frueheres Regime zurueck (Rest seit dem letzten Rasterpunkt des alten Rhythmus), immer mit
-- Karte: auto_post des NEUEN Rhythmus (z. B. taeglich) gilt nicht fuer den Rest des alten.
SELECT p.aid, p.vd, p.ps, p.pe, (p.ap AND p.ps >= p.anchor)
FROM proj p
WHERE p.vd <= p_until
  AND p.vd >= p_until - 90                                      -- Rueck-Fenster auf value_date
  AND (p.last_done IS NULL OR p.pe > p.last_done)               -- nie hinter die juengste erledigte Periode
  AND NOT EXISTS (
      SELECT 1 FROM finance.transactions t
      WHERE t.account_id = p.aid AND t.category = 'interest' AND t.interest_period_end = p.pe)
  AND NOT EXISTS (
      SELECT 1 FROM finance.interest_skips s
      WHERE s.account_id = p.aid AND s.period_end = p.pe)
ORDER BY p.pe ASC;
$$;
