-- ============================================================
-- fn_import_balance_targets (READ, STABLE) -- Cash-/Verrechnungs-Salden aus einer Depot-Uebersicht zuordnen
--   Owner-Fall 2026-10-23: eine Trade-Republic-Vermoegensuebersicht druckt neben den Positionen den Cash-Stand des
--   Verrechnungskontos ("Cash 3.054,97", Stand 23.10.). Die Extraktion lieferte ihn als neues Konto -> als Dublette
--   eines FREMDEN Kontos abgelehnt und verworfen. Jetzt: tool_extract_finance_document stagt diese Zeilen NICHT,
--   sondern ordnet sie hier zu; der Agent bietet danach je Abweichung tool_reconcile_account an (eigene Karte,
--   Owner-Entscheid "zweite Karte statt neuer Import-Art").
--   Eingabe: p_batch_id (Staging-Batch derselben Extraktion, fuer In-Batch-Depots), p_rows jsonb-Array von
--     {depot?, depot_number?, depot_holder?, balance, balance_date}.
--   Je Zeile: Depot ueber fn_import_resolve_depot (Nummer -> extrahierter Name -> Inhaber; ohne ISIN/Symbol jeder
--   Depot-Typ) + fn_import_depot_conflict, dann dessen Verrechnungskonto (settlement_account_id). Nur BESTEHENDE
--   Konten: ein Depot, das erst in diesem Batch entsteht, bekommt seinen Saldo als opening_balance der Konto-Zeile
--   (Plan-Review: sonst Doppelbuchung, fn_get_balance_as_of zum Druckdatum waere 0). Pflicht: balance + balance_date
--   (nie "heute" raten: ein alter Stand ueberschriebe einen neueren). Zweite Zeile fuer dasselbe Konto = Fehler.
--   Blocker wie die Buchung (fn_reconcile_blocker: Depot-/Kreditkonto, Zukunft, vor dem letzten Abgleich).
--   RUECKGABE jsonb-Array, je Zeile {ok:true, account_name, currency, balance_date, balance_before, balance,
--   difference, skip_count} | {ok:false, error, row}. balance_before = fn_get_balance_as_of(Konto, Druckdatum);
--   skip_count = fn_reconcile_open_due (was der Abgleich als erledigt markiert).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_balance_targets(p_batch_id uuid, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_row     JSONB;
    v_out     JSONB := '[]'::jsonb;
    v_seen    INT[] := '{}';
    v_res     JSONB;
    v_depot   TEXT;
    v_err     TEXT;
    v_depot_id INT;
    v_acct    INT;
    v_name    TEXT;
    v_ccy     TEXT;
    v_minor   SMALLINT;
    v_bal     NUMERIC;
    v_date    DATE;
    v_before  NUMERIC;
BEGIN
    IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN RETURN '[]'::jsonb; END IF;
    FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
        v_err := NULL; v_acct := NULL; v_bal := NULL; v_date := NULL; v_depot_id := NULL;

        -- Betrag (Zahl oder deutsche Schreibweise "3.054,97") und Druckdatum
        BEGIN
            v_bal := CASE WHEN jsonb_typeof(v_row->'balance') = 'number' THEN (v_row->>'balance')::numeric
                          ELSE NULLIF(finance.fn_parse_de_numeric(v_row->>'balance', true), '')::numeric END;
        EXCEPTION WHEN OTHERS THEN v_bal := NULL; END;
        BEGIN
            v_date := NULLIF(v_row->>'balance_date', '')::date;
        EXCEPTION WHEN OTHERS THEN v_date := NULL; END;
        IF v_bal IS NULL THEN
            v_err := 'balance missing or not a number';
        ELSIF v_date IS NULL THEN
            v_err := 'balance_date (the printed as-of date of the balance) is required';
        END IF;

        -- Depot -> Verrechnungskonto (nur Bestand)
        IF v_err IS NULL THEN
            v_res   := finance.fn_import_resolve_depot(p_batch_id, v_row);
            v_depot := COALESCE(v_res->>'depot', NULLIF(btrim(COALESCE(v_row->>'depot', '')), ''));
            IF v_depot IS NULL THEN
                v_err := 'depot of this balance not found - ask the user which depot (or settlement account) it belongs to';
            ELSIF EXISTS (SELECT 1 FROM finance.import_staging s
                          WHERE s.batch_id = p_batch_id AND s.entity_type = 'account' AND s.status <> 'committed'
                            AND lower(s.payload->>'name') = lower(v_depot)) THEN
                v_err := format('depot "%s" is new in this import - put the cash balance as opening_balance on its settlement account row instead', v_depot);
            ELSE
                v_err := finance.fn_import_depot_conflict(p_batch_id, v_row || jsonb_build_object('depot', v_depot));
            END IF;
        END IF;
        IF v_err IS NULL THEN
            SELECT d.id, d.settlement_account_id INTO v_depot_id, v_acct
            FROM finance.accounts d
            WHERE d.status = 'active' AND lower(d.name) = lower(v_depot)
              AND d.account_type IN ('stocks_depot', 'crypto_depot')
            LIMIT 1;
            IF v_depot_id IS NULL THEN
                v_err := format('depot "%s" not found', v_depot);
            ELSIF v_acct IS NULL THEN
                v_err := format('depot "%s" has no settlement account', v_depot);
            ELSIF v_acct = ANY (v_seen) THEN
                v_err := format('more than one balance for the settlement account of depot "%s" in this document', v_depot);
            ELSE
                v_err := finance.fn_reconcile_blocker(v_acct, v_date);
            END IF;
        END IF;

        IF v_err IS NOT NULL THEN
            v_out := v_out || jsonb_build_array(jsonb_build_object('ok', false, 'error', v_err, 'row', v_row));
            CONTINUE;
        END IF;

        v_seen := v_seen || v_acct;
        SELECT a.name, a.currency, c.minor_unit INTO v_name, v_ccy, v_minor
        FROM finance.accounts a JOIN finance.currencies c ON c.code = a.currency WHERE a.id = v_acct;
        v_bal    := round(v_bal, COALESCE(v_minor, 2));   -- wie fn_reconcile_account
        v_before := finance.fn_get_balance_as_of(v_acct, v_date);
        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'ok', true, 'account_name', v_name, 'currency', v_ccy, 'balance_date', v_date,
            'balance_before', v_before, 'balance', v_bal, 'difference', v_bal - v_before,
            'skip_count', (SELECT count(*) FROM finance.fn_reconcile_open_due(v_acct, v_date))::int));
    END LOOP;
    RETURN v_out;
END;
$$;
