-- ============================================================
-- fn_recurring_due_open (READ, STABLE — Faelligkeits-Kern des Schedulers)
--   Liefert (recurring_payment_id, due_date) fuer alle Vorkommen mit p_from <= due_date <= p_until,
--   die noch offen sind = nicht gebucht (kein Tx mit recurring_payment_id + recurring_due_date = due_date —
--   Identitaet ist die Faelligkeit, nicht das Buchungsdatum; eine Abbuchung am Ist-Datum schliesst
--   das Vorkommen) und nicht uebersprungen (kein Skip). Nur Zeilen mit status 'active'.
--   Zwei Signaturen: (p_from, p_until) = expliziter Zeitraum (Kontoauszug-Zeitraum, Deckungs-Vorschau; ein Quartal
--   sprengt die 90 Tage); (p_until) = Scheduler-Sicht mit 90-Tage-Rueckfenster, delegiert an die 2-arg-Form.
--   Keine DEFAULT-Argumente ergaenzen: (date) und (date, date DEFAULT ...) machten jeden 1-arg-Aufruf mehrdeutig.
--   Das Raster (first_payment_date/interval/unit/day_of_month bzw. feste Monatstage) rechnet die eine reine fn
--   finance.fn_schedule_occurrences (Init) -- dieselbe nutzt die Restschuld-Vorschau fn_loan_balance_at.
--   Gueltigkeit halboffen [valid_from, valid_to) wie alle Views/close_*/Split: ein Vorkommen
--   am valid_to ist nicht mehr faellig (sonst waeren am Split-Stichtag alte und neue Rate faellig);
--   Vorkommen vor valid_from sind nicht faellig (first_payment_date bleibt reiner Rhythmus-Anker -> Split
--   und Eroeffnungssaldo-Stichtag blenden bereits erledigte Alt-Raten aus, ohne den Takt zu verschieben).
--   Eingabe: p_from (nur 2-arg), p_until. Rueckgabe: TABLE(recurring_payment_id, due_date).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_due_open(p_from date, p_until date)
RETURNS TABLE(recurring_payment_id int, due_date date)
LANGUAGE sql STABLE AS $$
SELECT r.id, o.d
FROM finance.recurring_payments r
CROSS JOIN LATERAL finance.fn_schedule_occurrences(
    r.first_payment_date, r.schedule_interval, r.schedule_unit, r.schedule_day_of_month, r.schedule_days_of_month,
    GREATEST(p_from, r.valid_from), p_until) AS o(d)
WHERE r.status = 'active'
  AND r.valid_from <= p_until
  AND r.first_payment_date <= p_until
  AND (r.valid_to IS NULL OR o.d < r.valid_to)              -- halboffen [valid_from, valid_to)
  AND NOT EXISTS (
      SELECT 1 FROM finance.transactions t
      WHERE t.recurring_payment_id = r.id AND t.recurring_due_date = o.d)
  AND NOT EXISTS (
      SELECT 1 FROM finance.recurring_payment_skips s
      WHERE s.recurring_payment_id = r.id AND s.due_date = o.d);
$$;

-- Scheduler-Sicht: 90-Tage-Rueckfenster gegen Endlos-Listen.
CREATE OR REPLACE FUNCTION finance.fn_recurring_due_open(p_until date)
RETURNS TABLE(recurring_payment_id int, due_date date)
LANGUAGE sql STABLE AS $$
    SELECT o.recurring_payment_id, o.due_date FROM finance.fn_recurring_due_open(p_until - 90, p_until) o;
$$;
