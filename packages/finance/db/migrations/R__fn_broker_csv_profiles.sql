-- ============================================================
-- fn_broker_csv_profiles (READ, IMMUTABLE) -- welche Bank kann ihren Umsatz-Export als CSV liefern (Broker-CSV Paket B)
--   Die EINE Adresse fuer "welche Bank kann CSV": fn_broker_csv_normalize erkennt das Profil per Header-Signatur
--   (alle required-Spalten vorhanden, Muster Portfolio Performance TradeRepublicCSVExtractor / beangulp identify()),
--   fn_broker_csv_account_profile ordnet ein Konto per bank_pattern zu (Monats-Erinnerung, Onboarding-Hinweis).
--   Neues Profil = ein Eintrag hier + eine Typ-Zuordnung in fn_broker_csv_normalize + Golden-File-Test.
--   RUECKGABE: [{key, bank, bank_pattern (POSIX-Regex, case-insensitiv gegen accounts.bank bzw. name), required[]}]
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_broker_csv_profiles()
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(
        jsonb_build_object('key', 'trade_republic_v1', 'bank', 'Trade Republic', 'bank_pattern', 'trade[[:space:]]*republic',
                           'required', jsonb_build_array('datetime', 'category', 'type', 'amount', 'currency')));
$$;
