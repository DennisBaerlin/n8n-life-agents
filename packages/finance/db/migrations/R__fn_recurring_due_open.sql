-- ============================================================
-- fn_recurring_due_open (READ — Faelligkeits-Kern des Schedulers)
--   Liefert (recurring_payment_id, due_date) fuer alle Vorkommen mit p_from <= due_date <= p_until,
--   die NOCH OFFEN sind = NICHT gebucht (kein Tx mit recurring_payment_id + recurring_due_date = due_date —
--   Monats-Check WP-A: Identitaet ist die Faelligkeit, nicht das Buchungsdatum; eine Abbuchung am Ist-Datum schliesst
--   das Vorkommen) UND NICHT uebersprungen (kein Skip).
--   Zwei Signaturen: (p_from, p_until) = expliziter Zeitraum (Kontoauszug-Zeitraum, Deckungs-Vorschau; ein Quartal
--   sprengt die 90 Tage); (p_until) = Scheduler-Sicht mit 90-Tage-Rueckfenster, delegiert an die 2-arg-Form.
--   KEINE DEFAULT-Argumente ergaenzen: (date) und (date, date DEFAULT ...) machten jeden 1-arg-Aufruf mehrdeutig.
--   Faelligkeit je schedule_unit aus first_payment_date/interval/day_of_month abgeleitet; bei unit=month mit
--   schedule_days_of_month (feste Monatstage, z. B. Broker-Kalender) je Raster-Monat JEDER Tag der Liste (eigener
--   Zweig; der Einzeltag-Zweig schliesst diese Zeilen aus -> kein zusaetzlicher Anker-Termin).
--   GUELTIGKEIT halboffen [valid_from, valid_to) wie alle Views/close_*/Split (Audit F2a): ein Vorkommen
--   AM valid_to ist nicht mehr faellig (vorher inklusiv -> am Split-Stichtag alte UND neue Rate faellig);
--   Vorkommen VOR valid_from sind nicht faellig (first_payment_date bleibt reiner Rhythmus-Anker -> Split
--   und Eroeffnungssaldo-Stichtag blenden bereits erledigte Alt-Raten aus, ohne den Takt zu verschieben).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_due_open(p_from date, p_until date)
RETURNS TABLE(recurring_payment_id int, due_date date)
LANGUAGE sql STABLE AS $$
WITH rp AS (
    SELECT id,
           first_payment_date        AS f,
           GREATEST(schedule_interval, 1) AS n,
           schedule_unit             AS u,
           schedule_day_of_month     AS dom,
           schedule_days_of_month    AS days,
           valid_to
    FROM finance.recurring_payments
    WHERE status = 'active'
      AND valid_from <= p_until
      AND first_payment_date <= p_until
),
occ AS (
    -- DAY: f, f+n, f+2n, ...
    SELECT rp.id, gs::date AS d
    FROM rp, generate_series(rp.f, p_until, (rp.n || ' days')::interval) gs
    WHERE rp.u = 'day'
    UNION ALL
    -- WEEK
    SELECT rp.id, gs::date
    FROM rp, generate_series(rp.f, p_until, (rp.n * 7 || ' days')::interval) gs
    WHERE rp.u = 'week'
    UNION ALL
    -- MONTH: alle n Monate; Tag aus dom (-1=Monatsletzter, -2=vorletzter Tag, NULL=Tag von f mit Monatsend-Clamping)
    SELECT rp.id,
           CASE
             WHEN rp.dom IN (-1, -2) THEN
               (date_trunc('month', rp.f) + (k * rp.n || ' months')::interval + interval '1 month'
                + (rp.dom || ' days')::interval)::date
             WHEN rp.dom IS NULL THEN
               (rp.f + (k * rp.n || ' months')::interval)::date
             ELSE
               (date_trunc('month', rp.f) + (k * rp.n || ' months')::interval + ((rp.dom - 1) || ' days')::interval)::date
           END AS d
    FROM rp,
         generate_series(0,
             ((EXTRACT(YEAR FROM age(p_until, rp.f))::int * 12
               + EXTRACT(MONTH FROM age(p_until, rp.f))::int) / rp.n) + 1) AS k
    WHERE rp.u = 'month' AND rp.days IS NULL
    UNION ALL
    -- MONTH mit festen Tagen: alle n Monate jeder Tag der Liste (Tage 1-28 per CHECK -> kein Monatsend-Overflow)
    SELECT rp.id,
           (date_trunc('month', rp.f) + (k * rp.n || ' months')::interval + ((dd - 1) || ' days')::interval)::date
    FROM rp,
         generate_series(0,
             ((EXTRACT(YEAR FROM age(p_until, rp.f))::int * 12
               + EXTRACT(MONTH FROM age(p_until, rp.f))::int) / rp.n) + 1) AS k,
         unnest(rp.days) AS dd
    WHERE rp.u = 'month' AND rp.days IS NOT NULL
    UNION ALL
    -- YEAR
    SELECT rp.id, (rp.f + (k * rp.n || ' years')::interval)::date
    FROM rp,
         generate_series(0, (EXTRACT(YEAR FROM age(p_until, rp.f))::int / rp.n) + 1) AS k
    WHERE rp.u = 'year'
)
SELECT o.id, o.d
FROM occ o
JOIN finance.recurring_payments r ON r.id = o.id
WHERE o.d >= r.first_payment_date
  AND o.d <= p_until
  AND o.d >= p_from
  AND o.d >= r.valid_from                                   -- halboffen [valid_from, valid_to)
  AND (r.valid_to IS NULL OR o.d < r.valid_to)
  AND NOT EXISTS (
      SELECT 1 FROM finance.transactions t
      WHERE t.recurring_payment_id = o.id AND t.recurring_due_date = o.d)
  AND NOT EXISTS (
      SELECT 1 FROM finance.recurring_payment_skips s
      WHERE s.recurring_payment_id = o.id AND s.due_date = o.d);
$$;

-- Scheduler-Sicht: 90-Tage-Rueckfenster gegen Endlos-Listen.
CREATE OR REPLACE FUNCTION finance.fn_recurring_due_open(p_until date)
RETURNS TABLE(recurring_payment_id int, due_date date)
LANGUAGE sql STABLE AS $$
    SELECT o.recurring_payment_id, o.due_date FROM finance.fn_recurring_due_open(p_until - 90, p_until) o;
$$;
