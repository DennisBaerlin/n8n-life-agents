-- ============================================================
-- fn_broker_plan_days (READ, IMMUTABLE) -- Vorbelegung des Depot-Kalenders bekannter Banken; die eine Adresse des Broker-Wissens
--   Eingabe: p_bank (accounts.bank). Rueckgabe: smallint[] der festen Monatstage, an denen die Bank Sparplaene
--   ausfuehrt, sonst NULL (= unbekannt -> fn_resolve_plan_schedule fragt den Nutzer einmal). Greift nur, solange
--   accounts.plan_execution_days NULL ist; der gelernte/korrigierte Depot-Wert schlaegt sie immer.
--   Eine weitere Bank = eine WHEN-Zeile (mit Quelle).
--   Trade Republic: 2./9./16./23. des Monats (Nicht-Handelstag -> naechster Handelstag); "woechentlich" = alle
--     vier Tage = 4x/Monat. Quellen (inoffiziell): finanzfluss.de/broker/trade-republic,
--     neuebanken.de/trade-republic-sparplan, traderepublic.community (zitiert den TR-Support).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_broker_plan_days(p_bank text)
RETURNS smallint[] LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_bank ILIKE '%trade republic%' THEN '{2,9,16,23}'::smallint[]
    END;
$$;
