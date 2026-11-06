-- ============================================================
-- test_fn_opening_balance_reason -- Regel "liegt im Startbetrag" (Befund 2026-11-03, eine Adresse je Konto + Datum)
--   Vor dem Stichtag: gesetzt. Am Stichtag bei spaeterer Anlage (Endsaldo = Tagesende): gesetzt. Am Stichtag bei Anlage am
--   selben Tag ("morgens"): NULL. Nach dem Stichtag und ohne Stichtag: NULL. Werte erfunden.
-- ============================================================
BEGIN;
DO $$
DECLARE
    T DATE := core.fn_today();
    v_later INT; v_today INT; v_none INT; v_txt TEXT;
BEGIN
    v_later := (finance.fn_create_account(jsonb_build_object('name', '__t_obr_later__', 'account_type', 'cash', 'currency', 'EUR',
                   'opening_balance', 300, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_today := (finance.fn_create_account(jsonb_build_object('name', '__t_obr_today__', 'account_type', 'cash', 'currency', 'EUR',
                   'opening_balance', 300, 'opening_balance_date', T::text))->>'account_id')::int;
    v_none  := (finance.fn_create_account('{"name":"__t_obr_none__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

    v_txt := finance.fn_opening_balance_reason(v_later, T - 25);
    IF v_txt IS NULL OR position('__t_obr_later__' IN v_txt) = 0 OR position((T - 20)::text IN v_txt) = 0
       OR position((T - 25)::text IN v_txt) = 0 THEN
        RAISE EXCEPTION 'FAIL [O1 vor dem Stichtag: Text nennt Konto, Stichtag, Datum]: %', v_txt;
    END IF;
    IF finance.fn_opening_balance_reason(v_later, T - 20) IS NULL THEN
        RAISE EXCEPTION 'FAIL [O2 am Stichtag bei spaeterer Anlage gesetzt]';
    END IF;
    IF finance.fn_opening_balance_reason(v_later, T - 19) IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [O3 nach dem Stichtag NULL]';
    END IF;
    IF finance.fn_opening_balance_reason(v_today, T) IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [O4 am Stichtag bei Anlage am selben Tag NULL]';
    END IF;
    IF finance.fn_opening_balance_reason(v_today, T - 1) IS NULL THEN
        RAISE EXCEPTION 'FAIL [O5 Anlage heute, Datum gestern gesetzt]';
    END IF;
    IF finance.fn_opening_balance_reason(v_none, T - 500) IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [O6 ohne Stichtag NULL]';
    END IF;
    RAISE NOTICE 'PASS [fn_opening_balance_reason]';
END $$;
ROLLBACK;
