-- ============================================================
-- V042 (finance) -- Sparziele mit Rate: Zieldatum auf den Tag der LETZTEN Rate
--
--   Das Zieldatum eines Ziels mit Rate ist der Tag der n-ten Rate (fn_savings_rate_schedule); ein Ziel, dessen Datum einen
--   Monat NACH der letzten Rate liegt (der (n+1)-te Rasterpunkt), bekommt hier einmalig das Datum der letzten Rate.
--   Sonst zaehlt eine spaetere Aenderung den Termin am Zieltag als weitere Rate mit (Ziel erhoeht -> zu kleine Rate).
--   Angefasst wird nur ein Ziel, das genau so entstanden ist: aktives Sparziel (kind goal) mit Rate (eine einzige, nie
--   geteilte Zeile der Raten-Kette, Ueberweisung in einen Topf), ohne verknuepften Sparplan, dessen Zieldatum ein
--   Rasterpunkt dieser Rate ist, vor dem k Raten liegen mit k x Rate >= Rest (Ziel - Hand-Zuordnung) und
--   (k-1) x Rate < Rest -- also die kleinste Zahl Raten, die das Ziel erreicht, plus der eine Termin am Zieltag.
--   Neues Datum = der k-te (letzte noetige) Rasterpunkt. Ein Ziel mit genanntem Datum rechnet die Rate aus der Zahl der
--   Termine bis einschliesslich Zieldatum und erfuellt (k-1) x Rate < Rest nicht -> bleibt unberuehrt; ebenso jedes schon
--   neu gerechnete Ziel (geteilte Kette). Re-run-sicher: nach dem Nachziehen liegen nur k-1 Raten vor dem Zieldatum.
-- ============================================================
WITH cand AS (
    SELECT sg.id, sg.target_date,
           greatest(sg.target_amount - greatest(coalesce((
               SELECT sum(finance.fn_to_eur(e.delta_native, e.currency, e.value_date))
               FROM finance.savings_goal_reserve_entries e
               WHERE e.savings_goal_id = sg.id AND e.kind = 'manual'), 0), 0), 0) AS rest,
           abs(rp.amount) AS rate,
           array(SELECT d FROM finance.fn_schedule_occurrences(
                     rp.first_payment_date, rp.schedule_interval, rp.schedule_unit, rp.schedule_day_of_month,
                     rp.schedule_days_of_month, greatest(rp.first_payment_date, rp.valid_from), sg.target_date) d
                 WHERE rp.valid_to IS NULL OR d < rp.valid_to
                 ORDER BY d) AS pts
    FROM finance.savings_goals sg
    JOIN finance.recurring_payments rp ON rp.id = sg.recurring_payment_id
    WHERE sg.status = 'active' AND sg.kind = 'goal' AND sg.target_amount > 0 AND sg.target_date IS NOT NULL
      AND rp.predecessor_id IS NULL AND rp.target_account_id IS NOT NULL AND rp.amount <> 0
      AND NOT EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = rp.id)
      AND NOT EXISTS (SELECT 1 FROM finance.savings_plans sp WHERE sp.savings_goal_id = sg.id)
), hit AS (
    -- k = 1 (eine Rate reicht): Datum = Tag der ersten Rate + 1 (wie fn_savings_rate_schedule), sonst der k-te Rasterpunkt
    SELECT c.id, CASE WHEN cardinality(c.pts) = 2 THEN c.pts[1] + 1 ELSE c.pts[cardinality(c.pts) - 1] END AS new_date
    FROM cand c
    WHERE cardinality(c.pts) >= 2 AND c.pts[cardinality(c.pts)] = c.target_date
      AND c.rest > 0
      AND c.rate * (cardinality(c.pts) - 1) >= c.rest
      AND c.rate * (cardinality(c.pts) - 2) < c.rest
)
UPDATE finance.savings_goals g SET target_date = h.new_date FROM hit h WHERE g.id = h.id;
