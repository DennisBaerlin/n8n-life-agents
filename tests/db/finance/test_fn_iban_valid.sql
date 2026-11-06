-- tests/db/finance/test_fn_iban_valid.sql
-- IBAN-Pruefziffer (ISO 13616, mod 97) als DB-Gesetz (Paket DB-ist-das-Gesetz S7, Owner-Frage 2026-10-23: "im Auszug
-- stehen viele IBANs" -> eine verlesene IBAN darf nie als "neues Konto" durchgehen):
--   (1) finance.fn_iban_valid: gueltig / eine Ziffer falsch / keine IBAN-Form (Depotnummer, maskierte Karte) = TRUE.
--   (2) fn_create_account + fn_set_account lehnen eine IBAN mit falscher Pruefziffer ab ({ok:false}).
--   (3) CHECK finance_accounts_iban_chk haelt auch an fns vorbei.
--   (4) fn_statement_prepare: verlesene Kopf-IBAN -> code=unreadable (nicht account_unknown).
BEGIN;

DO $$
DECLARE v_r jsonb; v_a int;
BEGIN
  IF NOT finance.fn_iban_valid('DE89370400440532013000') OR NOT finance.fn_iban_valid('de89 3704 0044 0532 0130 00')
     OR finance.fn_iban_valid('DE89370400440532013001') OR finance.fn_iban_valid('DE88370400440532013000')
     OR NOT finance.fn_iban_valid('7712345') OR NOT finance.fn_iban_valid('DE89 **** **** 3000')
     OR NOT finance.fn_iban_valid('DE89XXXXXXXXXXXXXX3000') OR NOT finance.fn_iban_valid('GB82WEST12345698765432')
     OR NOT finance.fn_iban_valid(NULL) THEN
    RAISE EXCEPTION 'FAIL fn_iban_valid [gueltig/Ziffer falsch/keine IBAN-Form/NULL]'; END IF;

  v_r := finance.fn_create_account('{"name":"__iban_bad__","account_type":"cash","account_number":"DE89 3704 0044 0532 0130 01"}'::jsonb);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'invalid_iban' THEN
    RAISE EXCEPTION 'FAIL create_account [IBAN falsche Pruefziffer]: %', v_r; END IF;

  v_a := (finance.fn_create_account('{"name":"__iban_ok__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_r := finance.fn_set_account(jsonb_build_object('account_id', v_a, 'account_number', 'DE89370400440532013001'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'invalid_iban' THEN
    RAISE EXCEPTION 'FAIL set_account [IBAN falsche Pruefziffer]: %', v_r; END IF;

  BEGIN
    UPDATE finance.accounts SET account_number = 'DE89370400440532013001' WHERE id = v_a;
    RAISE EXCEPTION 'FAIL CHECK [IBAN falsche Pruefziffer am fn vorbei geschrieben]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  v_r := finance.fn_statement_prepare(jsonb_build_object('account_number', 'DE89370400440532013001', 'currency', 'EUR',
           'period_start', CURRENT_DATE - 40, 'period_end', CURRENT_DATE - 10, 'opening_balance', 0, 'closing_balance', 0,
           'lines', '[]'::jsonb));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'unreadable' THEN
    RAISE EXCEPTION 'FAIL statement_prepare [verlesene IBAN -> unreadable]: %', v_r; END IF;

  RAISE NOTICE 'PASS IBAN-Pruefziffer [fn, create/set_account, CHECK, Monats-Check unreadable]';
END $$;

ROLLBACK;
