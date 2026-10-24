-- ============================================================
-- fn_valid_schedule_dom (READ — schedule_day_of_month-Domaenen-Guard; DB prueft, nie das LLM)
--   TRUE gdw. der Buchungstag im gueltigen Bereich liegt: NULL (relativ zum Anker), -1 (Monatsletzter)
--   oder 1-28 (jeder Monat hat diese Tage). 29/30/31 sind VERBOTEN: sie overflowen kurze Monate (Feb 1 +
--   30 Tage = Mar 3) in der Perioden-Enumeration -> Kachel-Bruch (WP-2b). Der strukturelle Backstop ist der
--   CHECK (finance:V012, INLINE-Ausdruck WORTGLEICH) auf allen 4 schedule_day_of_month-Tabellen
--   (account_interest_rates/recurring_payments/loans/insurances); diese IMMUTABLE fn liefert den 11 Schreib-fns
--   die freundliche {ok:false}-Vorpruefung ("der 30." -> stattdessen Monatsletzter -1 waehlen).
--   EINE Regel, zwei Adressen (CHECK = Gesetz, fn = Komfort — Muster amount<>0, finance:V005).
-- ============================================================
-- Param int (nicht smallint): der smallint-Aufrufer v_dom up-castet implizit; Integer-Literale (Tests,
-- kuenftige Aufrufer) resolven direkt -> keine expliziten ::smallint-Casts noetig.
CREATE OR REPLACE FUNCTION finance.fn_valid_schedule_dom(p_dom int)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_dom IS NULL OR p_dom = -1 OR p_dom BETWEEN 1 AND 28;
$$;
