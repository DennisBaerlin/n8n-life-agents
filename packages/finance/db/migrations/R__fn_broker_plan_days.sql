-- ============================================================
-- fn_broker_plan_days (READ — Vorbelegung des Depot-Kalenders bekannter Banken; die EINE Adresse des Broker-Wissens)
--   Liefert die festen Monatstage, an denen eine bekannte Bank Sparplaene ausfuehrt (aus accounts.bank erkannt),
--   sonst NULL (= unbekannt -> fn_resolve_plan_schedule fragt den Nutzer einmal). Greift nur, solange der
--   Depot-Kalender accounts.plan_execution_days NULL ist; der gelernte/korrigierte Depot-Wert schlaegt sie immer.
--   Eine weitere Bank = eine WHEN-Zeile (mit Quelle).
--   Trade Republic: 2./9./16./23. des Monats (Nicht-Handelstag -> naechster Handelstag); "woechentlich" = alle
--     vier Tage = 4x/Monat. Quellen (inoffiziell, Stand 10/2026): finanzfluss.de/broker/trade-republic,
--     neuebanken.de/trade-republic-sparplan, traderepublic.community (zitiert den TR-Support).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_broker_plan_days(p_bank text)
RETURNS smallint[] LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_bank ILIKE '%trade republic%' THEN '{2,9,16,23}'::smallint[]
    END;
$$;
