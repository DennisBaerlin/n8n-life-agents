-- ============================================================
-- fn_skip_interest_occurrence (ATOMIC WRITE — Spiegel zu fn_skip_recurring_occurrence)
--   Materialisiert ein uebersprungenes Zins-Vorkommen (account_id, period_end) in interest_skips
--   -> fn_interest_due_open blendet es danach aus. Skip ist ERSATZLOS (kein Nachholen im Folgemonat;
--   period_start der Folgeperiode bleibt ihr regulaerer Schedule-Schritt). Idempotent (ON CONFLICT DO NOTHING).
--   interest_skips.period_end ist der stabile Perioden-Identitaets-Key (kongruent zu
--   fn_book_interest_occurrence; PK (account_id, period_end)). Eingabe jsonb: account_id, period_end.
--   RUECKGABE: {ok:true}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_skip_interest_occurrence(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_acct INT  := (p->>'account_id')::int;
    v_pend DATE := (p->>'period_end')::date;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_acct) THEN
        RAISE EXCEPTION 'Account % not found.', v_acct;
    END IF;
    IF v_pend IS NULL THEN
        RAISE EXCEPTION 'period_end is required to skip an interest occurrence.';
    END IF;

    INSERT INTO finance.interest_skips (account_id, period_end)
    VALUES (v_acct, v_pend)
    ON CONFLICT (account_id, period_end) DO NOTHING;

    RETURN jsonb_build_object('ok', true);
END;
$$;
