-- ============================================================
-- test_fn_bank_export_load -- geteilte Lade-Sequenz fuer Bank-Export-Dateien (fn_bank_export_load)
--   normalize -> Konto-Waechter (fn_bank_export_resolve_account mit den Waehrungen der Datei) -> Sub-Konto-Waechter.
--   Konsumenten: fn_get_recurring_suggestions, fn_replace_takeover_with_lots (Werte frei erfunden).
--   L1 Fehler des Lesers kommen unveraendert durch; L2 Konto-Waechter (falsche Bank -> export_account_mismatch);
--   L3 N26-Datei mit zwei Spaces -> multiple_sub_accounts; L4 ok -> Leser-Rueckgabe + account_id/account_name.
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.n26(p_d date, p_partner text, p_iban text, p_amt text, p_space text DEFAULT 'Hauptkonto')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text, p_d::text, p_partner, p_iban, 'Debit Transfer', '', p_space, p_amt, '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["Booking Date","Value Date","Partner Name","Partner Iban","Type","Payment Reference","Account Name","Amount (EUR)","Original Amount","Original Currency","Exchange Rate"]';
    v_n26  INT;
    v_res  JSONB;
BEGIN
    UPDATE finance.accounts SET status = 'closed' WHERE finance.fn_bank_export_account_profile(id) IS NOT NULL;
    v_n26 := (finance.fn_create_account(jsonb_build_object('name', '__t_bl_n26__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'N26', 'opening_balance', 100, 'opening_balance_date', (T - 30)::text))->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_bl_dkb__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'DKB', 'opening_balance', 100, 'opening_balance_date', (T - 30)::text));

    -- L1: kein bekanntes Profil
    v_res := finance.fn_bank_export_load(jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array('["a","b"]'::jsonb, '["1","2"]'::jsonb))));
    IF v_res->>'code' IS DISTINCT FROM 'export_profile_unknown' THEN
        RAISE EXCEPTION 'FAIL [L1 Leser-Fehler durchgereicht]: %', v_res;
    END IF;

    -- L2: N26-Datei, DKB-Konto genannt -> Konto-Waechter
    v_res := finance.fn_bank_export_load(jsonb_build_object('account_name', '__t_bl_dkb__', 'table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr, pg_temp.n26(T - 3, 'Test GmbH', '', '-10.00')))));
    IF v_res->>'code' IS DISTINCT FROM 'export_account_mismatch' OR v_res ? 'rows' THEN
        RAISE EXCEPTION 'FAIL [L2 Konto-Waechter]: %', v_res;
    END IF;

    -- L3: zwei Spaces in einer Datei
    v_res := finance.fn_bank_export_load(jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr, pg_temp.n26(T - 3, 'Test GmbH', '', '-10.00'),
                                   pg_temp.n26(T - 2, 'Test GmbH', '', '-10.00', 'Sparen')))));
    IF v_res->>'code' IS DISTINCT FROM 'multiple_sub_accounts' OR jsonb_array_length(v_res->'account_types') <> 2 THEN
        RAISE EXCEPTION 'FAIL [L3 mehrere Spaces]: %', v_res;
    END IF;

    -- L4: ok, ohne Kontoname -> das eine N26-Konto
    v_res := finance.fn_bank_export_load(jsonb_build_object('table', jsonb_build_object('rows',
                 jsonb_build_array(v_hdr, pg_temp.n26(T - 3, 'Test GmbH', '', '-10.00')))));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'account_id')::int IS DISTINCT FROM v_n26
       OR v_res->>'account_name' IS DISTINCT FROM '__t_bl_n26__' OR v_res->>'profile' IS DISTINCT FROM 'n26_v1'
       OR jsonb_array_length(v_res->'rows') <> 1 THEN
        RAISE EXCEPTION 'FAIL [L4 ok + Konto]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [L1-L4 fn_bank_export_load]';
END $$;
ROLLBACK;
