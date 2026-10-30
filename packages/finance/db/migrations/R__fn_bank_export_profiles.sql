-- ============================================================
-- fn_bank_export_profiles (READ, IMMUTABLE) -- welche Bank kann ihren Umsatz-Export als Datei liefern (Bank-Import-Modul)
--   Die EINE Adresse fuer "welche Bank kann Datei-Import": fn_bank_export_normalize erkennt das Profil per Kopfzeilen-
--   Signatur (alle required-Spalten in einer der ersten 20 Zeilen; Muster Portfolio Performance Extractor / beangulp
--   identify()), fn_bank_export_account_profile ordnet ein Konto per bank_pattern zu (Monats-Erinnerung, Onboarding).
--   Das Dateiformat (CSV/xlsx) kennt das Profil nicht: der Leser im Workflow liefert ein rohes Raster.
--   Neues Profil = ein Eintrag hier + eine fn_bank_export_normalize_<bank> + ein CASE-Zweig im Dispatcher + Golden-File-Test.
--   printed_balance: die Datei druckt Zeitraum + Anfangs-/Endstand (gedruckter Auszug, kein Owner-Saldo noetig);
--   sonst nennt der Owner den App-Kontostand.
--   Bondora (Go&Grow-Kontoauszug, xlsx): withdrawal_fee = pauschale Gebuehr je Auszahlung (Bondora-Hilfe: 1 EUR), small_inflow_max = Grenze fuer Kleinst-Gutschriften alter Bondora-Kredite
--   (legacy_return, gebucht als eine Summe mit legacy_return_label).
--   header_aliases: Kopfzeilen-Namen einer anderen Export-Sprache -> kanonischer Spaltenname aus required (Bondora
--   exportiert in der Sprache des Nutzerkontos, gleicher Aufbau; Livebefund 2026-10-30 deutsch). Der Dispatcher setzt
--   sie vor Erkennung und Spalten-Index ein; sprachige Zellen jenseits der Kopfzeile uebersetzt die Profil-fn.
--   RUECKGABE: [{key, bank, bank_pattern (POSIX-Regex, case-insensitiv gegen accounts.bank bzw. name), required[],
--   header_aliases?, printed_balance, withdrawal_fee?, small_inflow_max?, legacy_return_label?, counterparty_pattern?}]
--   counterparty_pattern: Gegenpart-Name des Anbieter-Sammelkontos (Pool-Regel in fn_statement_prepare: Ein-/Auszahlungen
--   auf einem Bankkonto ohne eigene Gegen-IBAN werden einem P2P-Konto dieses Profils zugeordnet).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_profiles()
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(
        jsonb_build_object('key', 'trade_republic_v1', 'bank', 'Trade Republic', 'bank_pattern', 'trade[[:space:]-]*republic',
                           'required', jsonb_build_array('datetime', 'category', 'type', 'amount', 'currency'),
                           'printed_balance', false),
        jsonb_build_object('key', 'bondora_go_grow_v1', 'bank', 'Bondora', 'bank_pattern', 'bondora|go[[:space:]]*&[[:space:]]*grow',
                           'required', jsonb_build_array('date', 'payment type', 'in', 'out', 'balance'),
                           'header_aliases', jsonb_build_object('datum', 'date', 'zahlungsart', 'payment type',
                                                                'eingänge', 'in', 'ausgänge', 'out', 'guthaben', 'balance'),
                           'printed_balance', true, 'withdrawal_fee', 1.00, 'small_inflow_max', 1.00,
                           'counterparty_pattern', 'bondora|go[[:space:]]*&[[:space:]]*grow',
                           'legacy_return_label', 'Rückflüsse Bondora-Altkredite'),
        jsonb_build_object('key', 'n26_v1', 'bank', 'N26', 'bank_pattern', '(^|[^[:alnum:]])n[[:space:]-]*26([^[:alnum:]]|$)',
                           'required', jsonb_build_array('booking date', 'value date', 'partner name', 'type', 'amount (eur)'),
                           'printed_balance', false));
$$;
