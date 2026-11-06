-- ============================================================
-- V021 (finance) — spiegelnder CHECK zur IBAN-Pruefziffer (Paket DB-ist-das-Gesetz S7, 2026-10-23):
--   ein AKTIVES Konto darf keine IBAN-foermige Nummer mit falscher Pruefziffer tragen (finance.fn_iban_valid,
--   Init-Baseline-Helfer in finance.tables_init.sql, ISO 13616 mod 97; mit X/* maskierte Nummern gelten als gueltig).
--   Freundlicher Guard: fn_create_account / fn_set_account ({ok:false, code:'invalid_iban'}), fn_statement_prepare
--   (verlesene Kopf-IBAN -> unreadable). Depot-/Kartennummern sind keine IBAN-Form -> erlaubt.
--
--   BESTAND (Muster der Kontonummer-Bereinigung in finance.tables_init.sql, kein Abbruch von `lifeagents update`):
--   eine falsche IBAN auf einem aktiven Konto wird geleert (NOTICE mit id + Name) — der naechste Kontoauszug lernt
--   sie neu, und seine Karte zeigt die gespeicherte IBAN. Geschlossene Konten bleiben unberuehrt (Historie; der CHECK
--   gilt nur fuer aktive, wie V020). Re-run-sicher.
--   APPLY-ORDER: Inits (fn_iban_valid) -> V (hier) -> R.
-- ============================================================

DO $$
DECLARE v_bad TEXT;
BEGIN
    SELECT string_agg(id::text || ' (' || name || ': ' || account_number || ')', ', ' ORDER BY id) INTO v_bad
      FROM finance.accounts
     WHERE status = 'active' AND account_number IS NOT NULL AND NOT finance.fn_iban_valid(account_number);
    IF v_bad IS NOT NULL THEN
        UPDATE finance.accounts SET account_number = NULL
         WHERE status = 'active' AND account_number IS NOT NULL AND NOT finance.fn_iban_valid(account_number);
        RAISE NOTICE 'V021: IBAN mit falscher Pruefziffer geleert (der naechste Kontoauszug lernt sie neu): %', v_bad;
    END IF;
END $$;

DO $$ BEGIN
    ALTER TABLE finance.accounts DROP CONSTRAINT IF EXISTS finance_accounts_iban_chk;
    ALTER TABLE finance.accounts ADD CONSTRAINT finance_accounts_iban_chk
        CHECK (status <> 'active' OR account_number IS NULL OR finance.fn_iban_valid(account_number));
END $$;
