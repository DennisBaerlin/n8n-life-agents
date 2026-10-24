-- ============================================================
-- fn_reconcile_accounts (ATOMIC BATCH WRITE)
--   Gleicht MEHRERE Konten in EINER Transaktion ab (alles-oder-nichts): ein HITL-Gate
--   im Tool deckt den ganzen Batch ab (analog Multi-Leg = ein logischer Write).
--   Eingabe jsonb: { accounts: [{account_name, confirmed_balance, reconciliation_date?, notes?}, ...] }
--   ZWEI Paesse fuer echte Atomaritaet:
--     Pass 1: ALLE Namen aufloesen. Faellt einer (0/>1) -> RETURN {ok:false} BEVOR irgendetwas
--             geschrieben wurde (RETURN ohne RAISE committed den bisherigen TX-Stand -> ein
--             Schreiben-dann-Abbrechen waere ein Teilzustand; darum vor dem ersten Write pruefen).
--     Pass 2: je Konto an finance.fn_reconcile_account delegieren -> EINE Quelle der Reconcile-Logik (DRY).
--             Ein RAISE dort (echte Ausnahme) rollt die ganze TX zurueck.
--   Phase B: Eingaben kommen vom Modell -> Form-Guards in Pass 1 als {ok:false} statt Cast-RAISE (Absturz +
--     Owner-Alert): accounts muss ein Array sein (NULL-sicher — vorher lieferte ein fehlender Key still
--     ok:true/count 0), confirmed_balance eine schlichte Zahl, reconciliation_date ein gueltiges Datum.
--   Audit Paket 2: Pass 1 lehnt zusaetzlich ein doppeltes Konto im Batch und die Gruende aus
--     finance.fn_reconcile_blocker ab (Depot-/Kreditkonto, Stichtag Zukunft / vor letztem Abgleich) -- identisch
--     mit fn_reconcile_accounts_preview -> Vorschau = Buchung.
--   Rueckgabe: { ok:false, reason } | { ok:true, count, results:[{ok, account_id, account_name,
--              currency, db_balance_before, confirmed_balance, difference, reconciliation_tx_id, balance_after}] }
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reconcile_accounts(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_acct    JSONB;
    v_id      INT;
    v_hit     INT;
    v_one     JSONB;
    v_resolved JSONB := '[]'::jsonb;   -- [{account_id, confirmed_balance, reconciliation_date, notes, account_name}]
    v_results JSONB := '[]'::jsonb;
    v_reason  TEXT;
    v_reject  JSONB;
BEGIN
    IF jsonb_typeof(p->'accounts') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'accounts') = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'No accounts provided to reconcile (accounts must be a JSON array).');
    END IF;

    -- Pass 1: alles aufloesen + Form pruefen, NICHTS schreiben.
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

        SELECT id, hit_count INTO v_id, v_hit
        FROM finance.fn_resolve_account(v_acct->>'account_name');

        IF v_hit <> 1 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', format('Account %L resolves to %s matches.', v_acct->>'account_name', v_hit));
        END IF;

        -- Audit Paket 2: ein Konto nur EINMAL je Batch (sonst wiche die Vorschau -- je Zeile gegen den DB-Stand --
        -- von der Buchung ab, die nacheinander korrigiert); Kontotyp/Stichtag wie im Einzel-Abgleich.
        IF v_resolved @> jsonb_build_array(jsonb_build_object('account_id', v_id)) THEN
            RETURN jsonb_build_object('ok', false, 'reason', format(
                'Account %L is listed more than once; reconcile each account once per batch.', v_acct->>'account_name'));
        END IF;
        v_reason := finance.fn_reconcile_blocker(v_id,
            COALESCE(NULLIF(v_acct->>'reconciliation_date','')::date, CURRENT_DATE));
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_reason);
        END IF;

        v_resolved := v_resolved || jsonb_build_array(jsonb_build_object(
            'account_id',          v_id,
            'account_name',        v_acct->>'account_name',
            'confirmed_balance',   (v_acct->>'confirmed_balance')::numeric,
            'reconciliation_date', COALESCE(NULLIF(v_acct->>'reconciliation_date',''), CURRENT_DATE::text),
            'notes',               v_acct->>'notes'));
    END LOOP;

    -- Pass 2: jetzt schreiben. Pass 1 hat gegen den ALTSTAND geprueft; ein Konto kann im selben Stapel doppelt stehen
    -- oder sich seitdem geaendert haben -> eine Ablehnung hier rollt den GANZEN Stapel zurueck (Block-Savepoint,
    -- Sentinel LA002, Muster fn_import_bundle) und kommt als {ok:false, reason, account_name} zurueck, kein Teilzustand
    -- und kein Owner-Alarm. Echte Exceptions der delegierten fn werden nicht abgefangen.
    BEGIN
        FOR v_acct IN SELECT * FROM jsonb_array_elements(v_resolved) LOOP
            SELECT finance.fn_reconcile_account(jsonb_build_object(
                'account_id',          (v_acct->>'account_id')::int,
                'confirmed_balance',   (v_acct->>'confirmed_balance')::numeric,
                'reconciliation_date', v_acct->>'reconciliation_date',
                'notes',               v_acct->>'notes'
            )) INTO v_one;
            IF (v_one->>'ok')::boolean IS DISTINCT FROM true THEN
                v_reject := jsonb_build_object('ok', false, 'account_name', v_acct->>'account_name',
                    'reason', 'Account "' || (v_acct->>'account_name') || '": ' || COALESCE(v_one->>'reason', 'rejected')
                              || ' - nothing was saved for the whole batch.');
                RAISE EXCEPTION USING ERRCODE = 'LA002', MESSAGE = 'reconcile batch rolled back';
            END IF;

            v_results := v_results || jsonb_build_array(
                v_one || jsonb_build_object('account_id', (v_acct->>'account_id')::int,
                                            'account_name', v_acct->>'account_name'));
        END LOOP;
    EXCEPTION WHEN SQLSTATE 'LA002' THEN
        RETURN v_reject;
    END;

    RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_results), 'results', v_results);
END;
$$;
