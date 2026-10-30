-- ============================================================
-- test_fn_iban_strict -- lernbare IBAN ("Import zuerst"): Form + nicht maskiert + Pruefziffer. fn_iban_valid laesst
--   Nicht-IBANs bewusst durch (Kopf-Nummer eines Auszugs darf auch eine Kartennummer sein) und taugt nicht zum Lernen.
--   IBANs erfunden.
-- ============================================================
BEGIN;
DO $$
BEGIN
    IF NOT finance.fn_iban_strict('DE89 3704 0044 0532 0130 00') OR NOT finance.fn_iban_strict('de89370400440532013000') THEN
        RAISE EXCEPTION 'FAIL [I1 gueltige IBAN, Leerzeichen/Kleinschrift egal]';
    END IF;
    IF finance.fn_iban_strict('DE89370400440532013001') THEN RAISE EXCEPTION 'FAIL [I2 falsche Pruefziffer]'; END IF;
    IF finance.fn_iban_strict('DE89XXXXXXXXXXXXXX3000') THEN RAISE EXCEPTION 'FAIL [I3 maskiert]'; END IF;
    IF finance.fn_iban_strict('1234567890') OR finance.fn_iban_strict('BON123456') THEN RAISE EXCEPTION 'FAIL [I4 keine IBAN-Form]'; END IF;
    IF finance.fn_iban_strict(NULL) IS DISTINCT FROM false OR finance.fn_iban_strict('') IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [I5 NULL/leer = false]';
    END IF;
    RAISE NOTICE 'PASS [I1-I5 fn_iban_strict]';
END $$;
ROLLBACK;
