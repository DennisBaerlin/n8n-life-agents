-- ============================================================
-- fn_bank_export_profiles (READ, IMMUTABLE) -- welche Bank kann ihren Umsatz-Export als Datei liefern (Bank-Import-Modul)
--   Die EINE Adresse fuer "welche Bank kann Datei-Import": fn_bank_export_normalize erkennt das Profil per Kopfzeilen-
--   Signatur (alle required-Spalten in einer der ersten 20 Zeilen; Muster Portfolio Performance Extractor / beangulp
--   identify()), fn_bank_export_account_profile ordnet ein Konto per bank_pattern zu (Monats-Erinnerung, Onboarding).
--   Das Dateiformat (CSV/xlsx) kennt das Profil nicht: der Leser im Workflow liefert ein rohes Raster.
--   Neues Profil = ein Eintrag hier + eine fn_bank_export_normalize_<bank> + ein CASE-Zweig im Dispatcher + Golden-File-Test.
--   RUECKGABE: [{key, bank, bank_pattern (POSIX-Regex, case-insensitiv gegen accounts.bank bzw. name), required[]}]
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_profiles()
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(
        jsonb_build_object('key', 'trade_republic_v1', 'bank', 'Trade Republic', 'bank_pattern', 'trade[[:space:]]*republic',
                           'required', jsonb_build_array('datetime', 'category', 'type', 'amount', 'currency')));
$$;
