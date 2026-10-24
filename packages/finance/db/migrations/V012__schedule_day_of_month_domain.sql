-- ============================================================
-- V012 (finance) — schedule_day_of_month-Domaenen-CHECK (1-28 | -1 | NULL) auf allen 4 tragenden Tabellen.
--
--   WARUM: Ein FESTER Buchungstag in {29,30,31} overflowt kurze Monate in der Perioden-Enumeration
--   (fn_interest_due_open / fn_recurring_due_open MONTH-Zweig: date_trunc('month')+(dom-1) Tage -> Feb 1 + 29
--   Tage = Mar 1, +30 = Mar 3) -> die Perioden kacheln nicht mehr lueckenlos (WP-2b, arch-challenge-surfaced).
--   Die dokumentierte Domaene war seit je 1-28 | -1 | NULL (finance.tables_init.sql, 4x Spalten-Kommentar),
--   aber UNENFORCED (kein CHECK). arch-Arbiter + Opus-Plan-Review: die Invariante an der TIEFSTEN Schicht
--   verankern (CHECK = Gesetz); "der 30." waehlt man als Monatsletzter (-1), den kurze Monate ohnehin brauchen.
--   Der freundliche {ok:false}-Guard lebt in fn_valid_schedule_dom (WORTGLEICHER Ausdruck), gerufen von den
--   11 Schreib-fns; day/week/year + dom 1-28 + -1 kacheln korrekt und bleiben erlaubt.
--
--   PRE-FLIGHT (fail-loud): eine Bestands-Zeile ausserhalb der Domaene bricht die Migration mit Zeilen-ids ab —
--   ein Buchungstag still auf einen anderen Tag zu aendern waere schlimmer als ein sichtbarer Stopp. Single-User
--   + totes Prod -> in der Praxis leer (Fresh-DB: die Inits legen leere Tabellen an, der CHECK greift auf 0 Zeilen).
--
--   APPLY-ORDER: Inits (Tabellen) -> V (hier: Pre-Flight + CHECK) -> R (fns inkl. fn_valid_schedule_dom).
--   Re-run-sicher (DROP CONSTRAINT IF EXISTS + ADD).
-- ============================================================

-- (1) Pre-Flight: Domaenen-Verletzungen ueber alle 4 Tabellen sammeln; falls vorhanden -> fail-loud mit ids.
DO $$
DECLARE v_bad TEXT;
BEGIN
    SELECT string_agg(t || ' [' || ids || ']', '; ') INTO v_bad
    FROM (
        SELECT 'account_interest_rates' AS t, string_agg(id::text, ',' ORDER BY id) AS ids
          FROM finance.account_interest_rates
         WHERE schedule_day_of_month IS NOT NULL AND schedule_day_of_month <> -1
           AND schedule_day_of_month NOT BETWEEN 1 AND 28
        UNION ALL
        SELECT 'recurring_payments', string_agg(id::text, ',' ORDER BY id)
          FROM finance.recurring_payments
         WHERE schedule_day_of_month IS NOT NULL AND schedule_day_of_month <> -1
           AND schedule_day_of_month NOT BETWEEN 1 AND 28
        UNION ALL
        SELECT 'loans', string_agg(id::text, ',' ORDER BY id)
          FROM finance.loans
         WHERE schedule_day_of_month IS NOT NULL AND schedule_day_of_month <> -1
           AND schedule_day_of_month NOT BETWEEN 1 AND 28
        UNION ALL
        SELECT 'insurances', string_agg(id::text, ',' ORDER BY id)
          FROM finance.insurances
         WHERE schedule_day_of_month IS NOT NULL AND schedule_day_of_month <> -1
           AND schedule_day_of_month NOT BETWEEN 1 AND 28
    ) q
    WHERE q.ids IS NOT NULL;

    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'V012 pre-flight: schedule_day_of_month ausserhalb der Domaene (1-28 | -1 | NULL) in %. Diese Zeilen auf einen gueltigen Tag (1-28) oder -1 (Monatsletzter) korrigieren, dann erneut migrieren.', v_bad;
    END IF;
END $$;

-- (2) Domaenen-CHECK auf allen 4 Tabellen (idempotent DROP+ADD; INLINE-Ausdruck == fn_valid_schedule_dom).
DO $$ BEGIN
    ALTER TABLE finance.account_interest_rates DROP CONSTRAINT IF EXISTS finance_air_schedule_dom_chk;
    ALTER TABLE finance.account_interest_rates ADD CONSTRAINT finance_air_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month = -1 OR schedule_day_of_month BETWEEN 1 AND 28);

    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_rp_schedule_dom_chk;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_rp_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month = -1 OR schedule_day_of_month BETWEEN 1 AND 28);

    ALTER TABLE finance.loans DROP CONSTRAINT IF EXISTS finance_loans_schedule_dom_chk;
    ALTER TABLE finance.loans ADD CONSTRAINT finance_loans_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month = -1 OR schedule_day_of_month BETWEEN 1 AND 28);

    ALTER TABLE finance.insurances DROP CONSTRAINT IF EXISTS finance_insurances_schedule_dom_chk;
    ALTER TABLE finance.insurances ADD CONSTRAINT finance_insurances_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month = -1 OR schedule_day_of_month BETWEEN 1 AND 28);
END $$;
