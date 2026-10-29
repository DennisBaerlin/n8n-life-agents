-- ============================================================
-- fn_bank_export_profiles (READ, IMMUTABLE) -- welche Bank kann ihren Umsatz-Export als Datei liefern (Bank-Import-Modul)
--   Die EINE Adresse fuer "welche Bank kann Datei-Import": fn_bank_export_normalize erkennt das Profil per Kopfzeilen-
--   Signatur (alle required-Spalten in einer der ersten 20 Zeilen; Muster Portfolio Performance Extractor / beangulp
--   identify()), fn_bank_export_account_profile ordnet ein Konto per bank_pattern zu (Monats-Erinnerung, Onboarding).
--   Das Dateiformat (CSV/xlsx) kennt das Profil nicht: der Leser im Workflow liefert ein rohes Raster.
--   Neues Profil = ein Eintrag hier + eine fn_bank_export_normalize_<bank> + ein CASE-Zweig im Dispatcher + Golden-File-Test.
--   printed_balance: die Datei druckt Zeitraum + Anfangs-/Endstand (gedruckter Auszug, kein Owner-Saldo noetig);
--   sonst nennt der Owner den App-Kontostand. Bondora (Go&Grow-Kontoauszug, xlsx): withdrawal_fee = pauschale Gebuehr
--   je Auszahlung (Bondora-Hilfe: 1 EUR), small_inflow_max = Grenze fuer Kleinst-Gutschriften alter Bondora-Kredite
--   (legacy_return, gebucht als eine Summe mit legacy_return_label).
--   RUECKGABE: [{key, bank, bank_pattern (POSIX-Regex, case-insensitiv gegen accounts.bank bzw. name), required[],
--   printed_balance, withdrawal_fee?, small_inflow_max?, legacy_return_label?}]
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_profiles()
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(
        jsonb_build_object('key', 'trade_republic_v1', 'bank', 'Trade Republic', 'bank_pattern', 'trade[[:space:]]*republic',
                           'required', jsonb_build_array('datetime', 'category', 'type', 'amount', 'currency'),
                           'printed_balance', false),
        jsonb_build_object('key', 'bondora_go_grow_v1', 'bank', 'Bondora', 'bank_pattern', 'bondora|go[[:space:]]*&[[:space:]]*grow',
                           'required', jsonb_build_array('date', 'payment type', 'in', 'out', 'balance'),
                           'printed_balance', true, 'withdrawal_fee', 1.00, 'small_inflow_max', 1.00,
                           'legacy_return_label', 'Rückflüsse Bondora-Altkredite'));
$$;
