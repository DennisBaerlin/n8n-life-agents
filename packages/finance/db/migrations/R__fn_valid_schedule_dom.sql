-- ============================================================
-- fn_valid_schedule_dom (READ — schedule_day_of_month-Domaenen-Guard; DB prueft, nie das LLM)
--   TRUE gdw. der Buchungstag im gueltigen Bereich liegt: NULL (relativ zum Anker), -1 (Monatsletzter),
--   -2 (vorletzter Tag des Monats, Live-Befund 2026-10-24) oder 1-28 (jeder Monat hat diese Tage). 29/30/31 sind
--   VERBOTEN: sie overflowen kurze Monate (Feb 1 + 30 Tage = Mar 3) in der Perioden-Enumeration -> Kachel-Bruch (WP-2b).
--   Der strukturelle Backstop ist der CHECK (finance:V024, INLINE-Ausdruck WORTGLEICH) auf recurring_payments/loans/
--   insurances; account_interest_rates kennt nur -1 (finance:V012, Zins-Raster), dort lehnt fn_interest_terms_reason
--   -2 vorher ab. Den freundlichen {ok:false}-Text liefert fn_schedule_dom_reason (die EINE Adresse).
--   EINE Regel, zwei Adressen (CHECK = Gesetz, fn = Komfort — Muster amount<>0, finance:V005).
-- ============================================================
-- Param int (nicht smallint): der smallint-Aufrufer v_dom up-castet implizit; Integer-Literale (Tests,
-- kuenftige Aufrufer) resolven direkt -> keine expliziten ::smallint-Casts noetig.
CREATE OR REPLACE FUNCTION finance.fn_valid_schedule_dom(p_dom int)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_dom IS NULL OR p_dom IN (-1, -2) OR p_dom BETWEEN 1 AND 28;
$$;
