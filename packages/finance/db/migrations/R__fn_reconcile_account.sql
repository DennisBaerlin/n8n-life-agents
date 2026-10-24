-- ============================================================
-- fn_reconcile_account (ATOMIC WRITE)
--   Gleicht den Saldo eines Kontos ZUM STICHTAG ab (Audit Paket 2, Punkt 6): vergleicht den bestaetigten Saldo mit
--   fn_get_balance_as_of(Konto, Stichtag) -- vorher mit dem HEUTIGEN Saldo, sodass eine spaetere Buchung als Differenz
--   galt -- und legt bei Differenz eine Korrekturbuchung (category='reconciliation') AM Stichtag an; aktualisiert
--   last_reconciled_balance/last_reconciled_at. Der bestaetigte Saldo wird auf die Waehrungseinheit des Kontos
--   gerundet (currencies.minor_unit), bevor verglichen/gespeichert wird.
--   Eingabe jsonb: account_id, confirmed_balance, reconciliation_date (opt -> heute), notes.
--   Betraege NATIV in der Kontowaehrung (currency im Return fuer Tool/Approval).
--   KORRIGIERBAR (kein Write) -> {ok:false, reason} ueber finance.fn_reconcile_blocker (eine Adresse mit Batch +
--   Vorschau): Depot-/Kreditkonto; Stichtag in der Zukunft; Stichtag VOR dem letzten Abgleich.
--   OFFENE VORKOMMEN (Monats-Check WP-A): der bestaetigte Saldo enthaelt alle Bewegungen bis zum Stichtag. Offene
--   Dauerauftrags-Vorkommen dieses Kontos (Quelle oder Transfer-Ziel) mit Faelligkeit <= Stichtag - 10 Tage und offene
--   Zins-Vorkommen mit value_date <= Stichtag - 10 sind damit erledigt (passiert oder ausgefallen, der Saldo sagt es)
--   -> als Skip materialisiert ("gebucht" bleibt abgeleitet, nur "uebersprungen" materialisiert). Die 10 Tage
--   Karenz lassen eine spaet abgebuchte Faelligkeit (30.09. -> 02.10.) fuer den naechsten Auszug offen.
--   RUECKGABE: {ok:true, db_balance_before (Saldo zum Stichtag), confirmed_balance, difference, reconciliation_tx_id,
--   currency, balance_after (heutiger Saldo nach der Korrektur), skipped_occurrences (Anzahl so geschlossener
--   Vorkommen), skipped (Handles: [{recurring_payment_id, due_date} | {interest_period_end}] — die Ruecknahme eines
--   Kontoauszugs hebt genau diese wieder auf)}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reconcile_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_account   INT     := (p->>'account_id')::int;
    v_confirmed NUMERIC := (p->>'confirmed_balance')::numeric;
    v_date      DATE    := COALESCE(NULLIF(p->>'reconciliation_date', '')::date, core.fn_today());
    v_db_bal    NUMERIC;
    v_diff      NUMERIC;
    v_tx_id     INT;
    v_currency  TEXT;
    v_minor     SMALLINT;
    v_reason    TEXT;
    v_after     NUMERIC;
    v_skipped   INT := 0;
    v_n         JSONB;
    v_skip_list JSONB;
BEGIN
    -- FOR UPDATE: Saldo-Zeile sperren (Cron parallel Chat) -> Differenz/Korrekturbuchung auf konsistentem Stand.
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_account FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Account % has no balance row.', v_account;
    END IF;

    -- Korrigierbar: Kontotyp / Stichtag in der Zukunft / vor dem letzten Abgleich (eine Adresse mit Batch + Vorschau).
    v_reason := finance.fn_reconcile_blocker(v_account, v_date);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;

    SELECT a.currency, c.minor_unit INTO v_currency, v_minor
    FROM finance.accounts a JOIN finance.currencies c ON c.code = a.currency
    WHERE a.id = v_account;

    v_confirmed := ROUND(v_confirmed, COALESCE(v_minor, 2));
    v_db_bal    := finance.fn_get_balance_as_of(v_account, v_date);
    v_diff      := v_confirmed - v_db_bal;

    UPDATE finance.accounts
    SET last_reconciled_balance = v_confirmed,
        last_reconciled_at      = v_date
    WHERE id = v_account;

    -- Korrekturbuchung nur bei echter Differenz (nativ in Kontowaehrung), am Stichtag
    IF v_diff <> 0 THEN
        INSERT INTO finance.transactions
            (account_id, amount, transaction_date, category, description)
        VALUES (
            v_account,
            v_diff,
            v_date,
            'reconciliation',
            COALESCE(NULLIF(p->>'notes', ''), 'Saldo-Abgleich ' || v_date)
        )
        RETURNING id INTO v_tx_id;
    END IF;

    SELECT balance INTO v_after FROM finance.account_balances WHERE account_id = v_account;

    -- Offene Vorkommen <= Stichtag-10 sind im bestaetigten Saldo enthalten -> Skip (s. Kopf); die Menge liefert
    -- fn_reconcile_open_due (EINE Adresse mit der Karten-Vorschau von tool_reconcile_account).
    -- Die Menge wird EINMAL berechnet (MATERIALIZED) und speist beide Skip-INSERTs.
    WITH due AS MATERIALIZED (
        SELECT * FROM finance.fn_reconcile_open_due(v_account, v_date)),
    ins_r AS (
        INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date)
        SELECT d.recurring_payment_id, d.due_date FROM due d
        WHERE d.recurring_payment_id IS NOT NULL
        ON CONFLICT (recurring_payment_id, due_date) DO NOTHING
        RETURNING recurring_payment_id, due_date),
    ins_i AS (
        INSERT INTO finance.interest_skips (account_id, period_end)
        SELECT v_account, d.interest_period_end FROM due d
        WHERE d.interest_period_end IS NOT NULL
        ON CONFLICT (account_id, period_end) DO NOTHING
        RETURNING period_end)
    SELECT (SELECT COALESCE(jsonb_agg(jsonb_build_object('recurring_payment_id', r.recurring_payment_id, 'due_date', r.due_date)),
                            '[]'::jsonb) FROM ins_r r)
        || (SELECT COALESCE(jsonb_agg(jsonb_build_object('interest_period_end', i.period_end)), '[]'::jsonb) FROM ins_i i)
    INTO v_skip_list;
    v_skipped := jsonb_array_length(v_skip_list);

    RETURN jsonb_build_object(
        'ok',                   true,
        'db_balance_before',    v_db_bal,
        'confirmed_balance',    v_confirmed,
        'difference',           v_diff,
        'reconciliation_tx_id', v_tx_id,
        'currency',             v_currency,
        'balance_after',        v_after,
        'skipped_occurrences',  v_skipped,
        'skipped',              v_skip_list,
        'effective',            jsonb_build_object('reconciliation_date', v_date)
    );
END;
$$;
