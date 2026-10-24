-- ============================================================
-- fn_reconcile_accounts_preview (READ-ONLY)
--   Batch-Vorschau fuer tool_reconcile_accounts_batch: loest jeden Konto-Namen
--   auf, liest den DB-Saldo ZUM STICHTAG (fn_get_balance_as_of; reconciliation_date, Default heute) + Waehrung und
--   berechnet die Differenz zum auf die Waehrungseinheit gerundeten bestaetigten Saldo. Audit Paket 2: dieselben
--   Ablehnungen wie die Buchung (doppeltes Konto, finance.fn_reconcile_blocker) -> Vorschau = Buchung.
--   Eingabe jsonb: { accounts: [{account_name, confirmed_balance, reconciliation_date?, notes?}, ...] }
--   Rueckgabe:
--     - bei 0/>1 Treffer ODER leerer Liste: { ok:false, reason, candidates? }  (Tool -> Build-ToolError)
--     - sonst: { ok:true, n, rows:[{account_id, name, currency, db_balance, confirmed, diff, skip_count}] }
--   Read-only -> baut die EINE Approval-Summary, BEVOR geschrieben wird (CQRS-Read-Seite).
--   Phase B: Form-Guards (accounts Array NULL-sicher, confirmed_balance schlichte Zahl) als {ok:false} statt
--     Cast-RAISE — die Eingabe kommt vom Modell (Spiegel der Guards in fn_reconcile_accounts).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reconcile_accounts_preview(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct  JSONB;
    v_id    INT;
    v_hit   INT;
    v_cand  JSONB;
    v_bal   NUMERIC;
    v_cur   TEXT;
    v_conf  NUMERIC;
    v_date  DATE;
    v_minor SMALLINT;
    v_reason TEXT;
    v_rows  JSONB := '[]'::jsonb;
BEGIN
    IF jsonb_typeof(p->'accounts') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'accounts') = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'No accounts provided to reconcile (accounts must be a JSON array).');
    END IF;

    FOR v_acct IN SELECT * FROM jsonb_array_elements(p->'accounts') LOOP
        IF COALESCE(v_acct->>'confirmed_balance', '') !~ '^\s*[+-]?[0-9]+(\.[0-9]+)?\s*$' THEN
            RETURN jsonb_build_object('ok', false, 'reason', format(
                'confirmed_balance for %L must be a plain number like 1234.56, got %L',
                v_acct->>'account_name', v_acct->>'confirmed_balance'));
        END IF;

        IF NULLIF(v_acct->>'reconciliation_date', '') IS NOT NULL THEN
            BEGIN
                PERFORM (v_acct->>'reconciliation_date')::date;
            EXCEPTION WHEN OTHERS THEN
                RETURN jsonb_build_object('ok', false, 'reason', format(
                    'reconciliation_date for %L must be a date YYYY-MM-DD, got %L',
                    v_acct->>'account_name', v_acct->>'reconciliation_date'));
            END;
        END IF;

        SELECT id, hit_count, candidates INTO v_id, v_hit, v_cand
        FROM finance.fn_resolve_account(v_acct->>'account_name');

        IF v_hit <> 1 THEN
            RETURN jsonb_build_object(
                'ok', false,
                'reason', format('Account %L resolves to %s matches. Ask the user which exact account.',
                                 v_acct->>'account_name', v_hit),
                'candidates', v_cand);
        END IF;

        -- Audit Paket 2: dieselben Ablehnungen wie die Buchung (Pass 1 von fn_reconcile_accounts) + Saldo ZUM STICHTAG.
        IF v_rows @> jsonb_build_array(jsonb_build_object('account_id', v_id)) THEN
            RETURN jsonb_build_object('ok', false, 'reason', format(
                'Account %L is listed more than once; reconcile each account once per batch.', v_acct->>'account_name'));
        END IF;
        v_date := COALESCE(NULLIF(v_acct->>'reconciliation_date','')::date, CURRENT_DATE);
        v_reason := finance.fn_reconcile_blocker(v_id, v_date);
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_reason);
        END IF;

        SELECT a.currency, c.minor_unit INTO v_cur, v_minor
        FROM finance.accounts a JOIN finance.currencies c ON c.code = a.currency
        WHERE a.id = v_id;
        v_bal  := finance.fn_get_balance_as_of(v_id, v_date);
        v_conf := ROUND((v_acct->>'confirmed_balance')::numeric, COALESCE(v_minor, 2));

        v_rows := v_rows || jsonb_build_array(jsonb_build_object(
            'account_id', v_id,
            'name',       v_acct->>'account_name',
            'currency',   v_cur,
            'db_balance', v_bal,
            'confirmed',  v_conf,
            'diff',       v_conf - v_bal,
            -- 2026-10-23: offene Vorkommen, die der Abgleich als erledigt markiert (dieselbe Menge wie fn_reconcile_account)
            'skip_count', (SELECT count(*) FROM finance.fn_reconcile_open_due(v_id, v_date))::int));
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'n', jsonb_array_length(v_rows), 'rows', v_rows);
END;
$$;
