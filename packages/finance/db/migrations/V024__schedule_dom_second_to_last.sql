-- ============================================================
-- V024 (finance) — schedule_day_of_month-Domaene um -2 (vorletzter Tag des Monats) erweitern.
--
--   WARUM: Live-Befund 2026-10-24 — Kreditraten werden "einen Tag vor dem Monatsletzten" abgebucht; die Domaene kannte
--   nur 1-28 | -1 | NULL (V012). -2 kachelt wie -1 ohne Overflow (Monatsende - 1 Tag, fn_recurring_due_open).
--   Gilt fuer die ZAHLUNGS-Tabellen recurring_payments/loans/insurances. account_interest_rates behaelt bewusst
--   {NULL,-1,1-28} (finance_air_schedule_dom_chk aus V012 unveraendert): das Zins-Raster (fn_interest_grid_*) kennt nur
--   -1 als Kalender-Ende, ein -2 fiele dort in den Fest-Tag-Zweig (dom-1 = -3 Tage) -> falsche Perioden; Banken
--   schreiben Zinsen nie am vorletzten Tag gut. fn_interest_terms_reason lehnt -2 vorher freundlich ab.
--   Der freundliche {ok:false}-Guard lebt in fn_valid_schedule_dom / fn_schedule_dom_reason (WORTGLEICHER Ausdruck).
--
--   Nur Erweiterung (Bestand bleibt gueltig) -> kein Pre-Flight noetig. Re-run-sicher (DROP CONSTRAINT IF EXISTS + ADD).
--   APPLY-ORDER: Inits (Tabellen) -> V (hier) -> R (fns).
-- ============================================================

DO $$ BEGIN
    ALTER TABLE finance.recurring_payments DROP CONSTRAINT IF EXISTS finance_rp_schedule_dom_chk;
    ALTER TABLE finance.recurring_payments ADD CONSTRAINT finance_rp_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month IN (-1, -2) OR schedule_day_of_month BETWEEN 1 AND 28);

    ALTER TABLE finance.loans DROP CONSTRAINT IF EXISTS finance_loans_schedule_dom_chk;
    ALTER TABLE finance.loans ADD CONSTRAINT finance_loans_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month IN (-1, -2) OR schedule_day_of_month BETWEEN 1 AND 28);

    ALTER TABLE finance.insurances DROP CONSTRAINT IF EXISTS finance_insurances_schedule_dom_chk;
    ALTER TABLE finance.insurances ADD CONSTRAINT finance_insurances_schedule_dom_chk
        CHECK (schedule_day_of_month IS NULL OR schedule_day_of_month IN (-1, -2) OR schedule_day_of_month BETWEEN 1 AND 28);
END $$;
