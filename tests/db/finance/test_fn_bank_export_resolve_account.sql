-- ============================================================
-- test_fn_bank_export_resolve_account -- Konto-Waechter fuer Bank-Export-Dateien (fn_bank_export_resolve_account)
--   Live-Befund 2026-10-30 (Werte erfunden): zu einer Trade-Republic-CSV ohne Bildunterschrift riet der Agent ein
--   Bondora-Konto -> die Datei wurde gegen das falsche Profil geprueft. Jetzt entscheidet die DB:
--   (a) Datei-Profil <> Konto-Profil -> export_account_mismatch (+ passende Konten), in prepare UND im Lots-Probelauf;
--   (b) ohne account_name genau ein passendes Konto -> dieses (Depot nie Kandidat); (c) mehrere -> account_ambiguous;
--   (d) keins -> account_unknown mit Bank; (e) Konto ohne Bank-Feld nur ohne passendes Konto, andere Bank immer
--   mismatch; (f) genanntes Depot -> not_bookable mit Kandidaten. Fremde Konten mit Datei-Profil (Fixtures) sind im
--   Test geschlossen (Rollback).
-- ============================================================
BEGIN;
CREATE FUNCTION pg_temp.tr_row(p_d date, p_typ text, p_amt text, p_id text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_array(p_d::text || 'T10:00:00Z', p_d::text, 'DEFAULT', 'CASH', p_typ, '', '', '', '',
                             '', p_amt, '', '', 'EUR', '', '', '', 'Test', p_id, '', '', '', '');
$$;
DO $$
DECLARE
    T      DATE := core.fn_today();
    v_hdr  JSONB := '["datetime","date","account_type","category","type","asset_class","name","symbol","shares","price","amount","fee","tax","currency","original_amount","original_currency","fx_rate","description","transaction_id","counterparty_name","counterparty_iban","payment_reference","mcc_code"]';
    v_tr   INT; v_tr2 INT; v_gg INT; v_dkb INT; v_nob INT;
    v_p    JSONB;
    v_res  JSONB;
BEGIN
    -- fremde Konten mit Datei-Profil (Test-Fixtures) ruhen, damit die Kandidaten-Zaehlung nur dieses Szenario sieht
    UPDATE finance.accounts SET status = 'closed' WHERE finance.fn_bank_export_account_profile(id) IS NOT NULL;

    v_p := jsonb_build_object('source', 'file', 'closing_balance', '100',
        'table', jsonb_build_object('rows', jsonb_build_array(v_hdr,
            pg_temp.tr_row(T - 3, 'CARD_TRANSACTION', '-10.00', 'g-01'))));

    -- ---------- (d) kein Konto mit TR-Profil ----------
    v_res := finance.fn_statement_prepare(v_p);
    IF v_res->>'code' IS DISTINCT FROM 'account_unknown' OR v_res->>'bank' IS DISTINCT FROM 'Trade Republic'
       OR jsonb_array_length(v_res->'candidates') <> 0 THEN
        RAISE EXCEPTION 'FAIL [G1 kein TR-Konto -> account_unknown + Bank]: %', v_res;
    END IF;
    -- (e) Konto ohne Bank-Feld, kein TR-Konto vorhanden -> genanntes Konto gilt (kommt bis zur Startpunkt-Pruefung)
    v_nob := (finance.fn_create_account('{"name":"__t_ag_nobank__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_ag_nobank__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'no_starting_point' OR v_res->>'account_name' IS DISTINCT FROM '__t_ag_nobank__' THEN
        RAISE EXCEPTION 'FAIL [G2 Konto ohne Bank ohne TR-Konto -> akzeptiert]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [G1-G2 ohne TR-Konto]';

    -- ---------- Setup: TR-Cash, TR-Depot, Bondora, DKB ----------
    v_tr  := (finance.fn_create_account(jsonb_build_object('name', '__t_ag_tr__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic', 'opening_balance', 500, 'opening_balance_date', (T - 10)::text))->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_ag_trdepot__', 'account_type', 'stocks_depot',
                 'currency', 'EUR', 'bank', 'Trade Republic', 'settlement_id', v_tr));
    v_gg  := (finance.fn_create_account(jsonb_build_object('name', '__t_ag_gg__', 'account_type', 'p2p', 'currency', 'EUR',
                 'bank', 'Bondora', 'opening_balance', 300, 'opening_balance_date', (T - 10)::text))->>'account_id')::int;
    v_dkb := (finance.fn_create_account(jsonb_build_object('name', '__t_ag_dkb__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'DKB', 'opening_balance', 50, 'opening_balance_date', (T - 10)::text))->>'account_id')::int;
    IF v_tr IS NULL OR v_gg IS NULL OR v_dkb IS NULL THEN RAISE EXCEPTION 'SETUP accounts'; END IF;

    -- ---------- (a) Live-Fall: TR-Datei, Bondora-Konto genannt ----------
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_ag_gg__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'export_account_mismatch' OR v_res ? 'card_lines'
       OR v_res->>'bank' IS DISTINCT FROM 'Trade Republic' OR v_res->>'account_name' IS DISTINCT FROM '__t_ag_gg__'
       OR jsonb_array_length(v_res->'candidates') <> 1 OR (v_res->'candidates'->0->>'id')::int IS DISTINCT FROM v_tr THEN
        RAISE EXCEPTION 'FAIL [G3 TR-Datei auf Bondora -> mismatch]: %', v_res;
    END IF;
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, v_p || '{"account_name":"__t_ag_gg__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'export_account_mismatch' THEN
        RAISE EXCEPTION 'FAIL [G4 Lots-Probelauf: derselbe Waechter]: %', v_res;
    END IF;
    -- (e) andere eingetragene Bank -> immer mismatch
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_ag_dkb__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'export_account_mismatch' OR position('tool_set_account' IN v_res->>'reason') = 0 THEN
        RAISE EXCEPTION 'FAIL [G5 DKB-Konto -> mismatch + Hinweis Bank korrigieren]: %', v_res;
    END IF;
    -- (e) Konto ohne Bank-Feld, aber ein TR-Konto existiert -> mismatch
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_ag_nobank__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'export_account_mismatch' THEN
        RAISE EXCEPTION 'FAIL [G6 ohne Bank, TR-Konto vorhanden -> mismatch]: %', v_res;
    END IF;
    -- (f) genanntes TR-Depot -> not_bookable mit dem Cash-Konto als Kandidat (nie eine Kontostand-Frage zum Depot)
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_ag_trdepot__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'not_bookable' OR (v_res->'candidates'->0->>'id')::int IS DISTINCT FROM v_tr
       OR jsonb_array_length(v_res->'candidates') <> 1 THEN
        RAISE EXCEPTION 'FAIL [G7 Depot genannt -> not_bookable + Kandidat]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [G3-G7 Waechter mit genanntem Konto]';

    -- ---------- (b) ohne account_name: genau ein TR-Konto (Depot zaehlt nicht) ----------
    v_res := finance.fn_statement_prepare(v_p - 'closing_balance');
    IF v_res->>'code' IS DISTINCT FROM 'closing_balance_required' OR v_res->>'account_name' IS DISTINCT FROM '__t_ag_tr__' THEN
        RAISE EXCEPTION 'FAIL [G8 Vorauswahl -> Kontostand-Frage fuer das TR-Konto]: %', v_res;
    END IF;
    v_res := finance.fn_statement_prepare(v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'account_id')::int IS DISTINCT FROM v_tr THEN
        RAISE EXCEPTION 'FAIL [G9 Vorauswahl ok]: %', v_res;
    END IF;
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, v_p);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'account_name' IS DISTINCT FROM '__t_ag_tr__' THEN
        RAISE EXCEPTION 'FAIL [G10 Lots-Probelauf: Vorauswahl + Kontoname]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [G8-G10 Vorauswahl]';

    -- ---------- (c) zwei TR-Cash-Konten -> account_ambiguous ----------
    v_tr2 := (finance.fn_create_account(jsonb_build_object('name', '__t_ag_tr2__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Trade Republic'))->>'account_id')::int;
    v_res := finance.fn_statement_prepare(v_p);
    IF v_res->>'code' IS DISTINCT FROM 'account_ambiguous' OR jsonb_array_length(v_res->'candidates') <> 2
       OR (v_res->'candidates'->1->>'id')::int IS DISTINCT FROM v_tr2 THEN
        RAISE EXCEPTION 'FAIL [G11 zwei TR-Konten -> account_ambiguous]: %', v_res;
    END IF;
    -- mit Namen eines der beiden -> eindeutig
    v_res := finance.fn_statement_prepare(v_p || '{"account_name":"__t_ag_tr__"}'::jsonb);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'account_id')::int IS DISTINCT FROM v_tr THEN
        RAISE EXCEPTION 'FAIL [G12 genanntes TR-Konto]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [G11-G12 mehrere TR-Konten]';

    -- ---------- Waehrung: ein TR-Konto in USD ist nie Kandidat eines EUR-Exports, genannt -> currency_mismatch ----------
    PERFORM finance.fn_create_account(jsonb_build_object('name', '__t_ag_trusd__', 'account_type', 'cash', 'currency', 'USD',
                 'bank', 'Trade Republic'));
    v_res := finance.fn_statement_prepare(v_p);
    IF v_res->>'code' IS DISTINCT FROM 'account_ambiguous' OR jsonb_array_length(v_res->'candidates') <> 2 THEN
        RAISE EXCEPTION 'FAIL [G13 USD-Konto kein Kandidat]: %', v_res;
    END IF;
    v_res := core.fn_dry_run('finance.fn_replace_takeover_with_lots(jsonb)'::regprocedure, v_p || '{"account_name":"__t_ag_trusd__"}'::jsonb);
    IF v_res->>'code' IS DISTINCT FROM 'currency_mismatch' OR jsonb_array_length(v_res->'candidates') <> 2 THEN
        RAISE EXCEPTION 'FAIL [G14 genanntes USD-Konto -> currency_mismatch schon im Lots-Probelauf]: %', v_res;
    END IF;
    RAISE NOTICE 'PASS [G13-G14 Waehrung]';
END $$;
ROLLBACK;
