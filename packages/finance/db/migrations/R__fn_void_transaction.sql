-- ============================================================
-- fn_void_transaction (ATOMIC WRITE) -- Hard-DELETE einer Fehlbuchung
--   Loescht eine Transaktion; die Trigger rechnen Saldo, holding.shares, holding.average_purchase_price
--   und die Kredit-Restschuld (= Saldo des Kreditkontos) danach KORREKT aus den verbleibenden Zeilen neu.
--   Identifikation per transaction_id (Agent liest die letzte(n) Buchung(en) via postgres_select).
--
--   KONTEXT-SCHUTZ (damit kein Entitaets-Status kaputtgeht):
--   1. MULTI-LEG-EVENTS (transfer/loan) werden mit ihrer GANZEN logischen Gruppe geloescht (atomar, nie nur
--      ein Bein) -- primaer per group_id (von der Write-fn gestempelt), Fallback (loan_id, transaction_date) fuer Altdaten ohne group_id.
--   2. OVERSELL-GUARD: wuerde das Loeschen einen Depot-Bestand NEGATIV machen (ein spaeterer Verkauf
--      haengt am zu loeschenden Kauf), wird abgelehnt -> {ok:false}; erst die spaetere Tx voiden.
--   3. Die HOLDING-Zeile wird NIE geloescht: der shares-Trigger setzt nur shares (ggf. 0); die Zeile
--      (inkl. ISIN) bleibt fuer Historie/spaetere Dividenden bestehen.
--   4. SPARZIEL-RESERVE (Audit F4): haengt an einer geloeschten Kauf-Tx eine Reserve-Journal-Zeile
--      (source_tx_id), wird eine GEGENZEILE kind='void' angehaengt (delta=-original, gleiche currency/
--      value_date) -> current_amount bleibt konserviert, das Journal bleibt append-only. Wuerde die Reserve
--      (Ziel, Depot) dadurch negativ (Reserve schon freigegeben) -> {ok:false}, nichts geloescht.
--   5. STATUS-RUECKNAHME (Audit F5 + Paket 2): traegt ein abbezahlter Kredit (paid_off, Vorzustand in
--      loans.settled_from von fn_mark_loan_paid_off) NACH dem Loeschen wieder Restschuld, gehen Kredit und Raten-rp
--      exakt auf den Zustand davor zurueck -- egal ob die Abloesung, die letzte Rate oder eine fruehere Rate
--      storniert wurde. Altbestand ohne settled_from (Abloesung): active, ohne Rate paused -- CHECK
--      active_needs_annuity -- und die von der Abloesung beendete Rate wieder aktiv, nur paused + valid_to =
--      Abloesedatum. Ein geloeschter Verkaufserloes
--      (real_estate.sale_tx_id) setzt die Immobilie auf active (current_value bleibt der Verkaufspreis).
--   Eingabe jsonb: transaction_id.
--   RUECKGABE: {ok:true, deleted_count, transaction_ids, reverted_loans, reverted_real_estate}.
--   Korrigierbar (Oversell-nach-Void, Reserve wuerde negativ) -> {ok:false}.
--   RAISE nur bei not-found (der Agent uebergibt eine gelesene id).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_void_transaction(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id    INT := (p->>'transaction_id')::int;
    v_tx    finance.transactions%ROWTYPE;
    v_ids   INT[];
    v_bad   RECORD;
    v_count INT;
    v_loans JSONB := '[]'::jsonb;
    v_loan_ids INT[];
    v_res   JSONB := '[]'::jsonb;
BEGIN
    SELECT * INTO v_tx FROM finance.transactions WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Transaction % not found.', v_id;
    END IF;

    -- 1. Logische Gruppe bestimmen (so tief wie moeglich -> strukturell, nicht heuristisch):
    --    (a) group_id = der neue Standard: transfer- + loan-Beine teilen eine group_id (von der
    --        jeweiligen Write-fn gestempelt) -> die GANZE Gruppe atomar entfernen,
    --    (b) Fallback fuer Altbestand OHNE group_id: Kredit-Event ueber (loan_id, transaction_date),
    --    (c) sonst nur diese eine Tx.
    IF v_tx.group_id IS NOT NULL THEN
        SELECT array_agg(id) INTO v_ids
        FROM finance.transactions WHERE group_id = v_tx.group_id;
    ELSIF v_tx.loan_id IS NOT NULL THEN
        SELECT array_agg(id) INTO v_ids
        FROM finance.transactions
        WHERE loan_id = v_tx.loan_id AND transaction_date = v_tx.transaction_date;
    ELSE
        v_ids := ARRAY[v_id];
    END IF;

    -- 2. Oversell-Guard: kein betroffenes Depot darf nach dem Void negativ werden.
    FOR v_bad IN
        SELECT h.id AS holding_id, h.symbol,
               COALESCE(SUM(t.shares), 0)
                 - COALESCE(SUM(t.shares) FILTER (WHERE t.id = ANY(v_ids)), 0) AS resulting
        FROM finance.transactions t
        JOIN finance.depot_holdings h ON h.id = t.holding_id
        WHERE t.holding_id IN (
            SELECT DISTINCT holding_id FROM finance.transactions
            WHERE id = ANY(v_ids) AND holding_id IS NOT NULL
        )
        GROUP BY h.id, h.symbol
    LOOP
        IF v_bad.resulting < 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Voiding this would make holding ' || v_bad.symbol || ' shares negative ('
                       || v_bad.resulting || '); a later sell depends on it. Void the later transaction(s) first.',
                'holding_id', v_bad.holding_id, 'resulting_shares', v_bad.resulting);
        END IF;
    END LOOP;

    -- 2b. Reserve-Guard (Audit F4): die Gegenzeilen duerfen keine (Ziel, Depot)-Reserve negativ machen.
    --     Summe in EUR wie fn_book_savings_reservation (Σ fn_to_eur(delta_native, currency, value_date)).
    FOR v_bad IN
        SELECT g.name AS goal_name, e.savings_goal_id, e.account_id,
               (SELECT COALESCE(sum(finance.fn_to_eur(a.delta_native, a.currency, a.value_date)), 0)
                FROM finance.savings_goal_reserve_entries a
                WHERE a.savings_goal_id = e.savings_goal_id AND a.account_id = e.account_id)
               - COALESCE(sum(finance.fn_to_eur(e.delta_native, e.currency, e.value_date)), 0) AS resulting
        FROM finance.savings_goal_reserve_entries e
        JOIN finance.savings_goals g ON g.id = e.savings_goal_id
        WHERE e.source_tx_id = ANY(v_ids)
        GROUP BY g.name, e.savings_goal_id, e.account_id
    LOOP
        IF v_bad.resulting < -0.005 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Voiding this purchase would make the reserve of savings goal "' || v_bad.goal_name
                       || '" negative (' || round(v_bad.resulting, 2) || ' EUR) because that reserve was already '
                       || 'released. Restore the reserve first (book_savings_reservation), then void.',
                'savings_goal_id', v_bad.savings_goal_id, 'resulting_reserve', round(v_bad.resulting, 2));
        END IF;
    END LOOP;

    -- 3. Void-Audit: geloeschtes Payload als JSONB festhalten (gleiche Transaktion -> bei Rollback weg).
    INSERT INTO finance.transaction_audit (transaction_id, payload)
    SELECT id, to_jsonb(t.*) FROM finance.transactions t WHERE id = ANY(v_ids);

    -- 3b. Reserve-Gegenzeilen (append-only; source_tx_id der Ursprungszeile faellt beim DELETE per FK auf NULL).
    INSERT INTO finance.savings_goal_reserve_entries
        (savings_goal_id, account_id, delta_native, currency, value_date, source_tx_id, kind)
    SELECT savings_goal_id, account_id, -delta_native, currency, value_date, NULL, 'void'
    FROM finance.savings_goal_reserve_entries
    WHERE source_tx_id = ANY(v_ids);

    -- 3c. Status-Ruecknahme ALTBESTAND (Abloesung ohne loans.settled_from, vor Audit F5): Kredit active (ohne Rate
    --     paused), die von der Abloesung beendete Rate (paused + valid_to = Abloesedatum) wieder aktiv. Kredite MIT
    --     settled_from stellt Schritt 4b NACH dem Loeschen generisch her (Abloesung UND letzte Rate).
    v_loan_ids := ARRAY(SELECT DISTINCT loan_id FROM finance.transactions WHERE id = ANY(v_ids) AND loan_id IS NOT NULL);
    WITH s AS (
        SELECT DISTINCT loan_id, transaction_date
        FROM finance.transactions
        WHERE id = ANY(v_ids) AND category = 'settlement' AND loan_id IS NOT NULL
    ), pre AS (
        SELECT lo.id, lo.monthly_annuity, lo.recurring_payment_id, s.transaction_date
        FROM finance.loans lo JOIN s ON s.loan_id = lo.id
        WHERE lo.status = 'paid_off' AND lo.settled_from IS NULL
    ), l AS (
        UPDATE finance.loans lo
        SET status = CASE WHEN pre.monthly_annuity IS NULL THEN 'paused'::finance.loan_status
                          ELSE 'active'::finance.loan_status END
        FROM pre
        WHERE lo.id = pre.id
        RETURNING lo.id, lo.status
    ), r AS (
        UPDATE finance.recurring_payments rp
        SET status = 'active', valid_to = NULL
        FROM pre
        WHERE rp.id = pre.recurring_payment_id
          AND rp.status = 'paused' AND rp.valid_to = pre.transaction_date
          AND pre.monthly_annuity IS NOT NULL
        RETURNING rp.id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('loan_id', l.id, 'status', l.status) ORDER BY l.id), '[]'::jsonb)
    INTO v_loans FROM l;

    -- 3d. Status-Ruecknahme Immobilienverkauf (sale_tx_id; current_value bleibt der Verkaufspreis = juengste Schaetzung).
    WITH u AS (
        UPDATE finance.real_estate
        SET status = 'active'
        WHERE sale_tx_id = ANY(v_ids) AND status = 'sold'
        RETURNING id
    )
    SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) INTO v_res FROM u;

    -- 4. Hard-DELETE der Gruppe; Trigger pflegen balance/shares/avg/Restschuld neu (Holding-Zeile bleibt).
    DELETE FROM finance.transactions WHERE id = ANY(v_ids);
    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- 4b. Status-Ruecknahme "abbezahlt" (Audit F5 + Paket 2): jeder betroffene Kredit, der paid_off ist, einen
    --     gespeicherten Vorzustand (settled_from, von fn_mark_loan_paid_off) hat und NACH dem Loeschen wieder
    --     Restschuld traegt, geht exakt auf diesen Zustand zurueck: Kredit-Status, Raten-rp (settled_from.rp_id)
    --     mit Status + Ende. Deckt Abloesung, letzte Rate und den Void einer FRUEHEREN Rate nach der Abzahlung ab.
    WITH pre AS (
        SELECT lo.id, lo.settled_from
        FROM finance.loans lo
        JOIN finance.account_balances b ON b.account_id = lo.loan_account_id
        WHERE lo.id = ANY(v_loan_ids) AND lo.status = 'paid_off' AND lo.settled_from IS NOT NULL
          AND b.balance < 0
    ), l AS (
        UPDATE finance.loans lo
        SET status = (pre.settled_from->>'status')::finance.loan_status,
            settled_from = NULL
        FROM pre
        WHERE lo.id = pre.id
        RETURNING lo.id, lo.status
    ), r AS (
        UPDATE finance.recurring_payments rp
        SET status   = (pre.settled_from->>'rp_status')::finance.payment_status,
            valid_to = (pre.settled_from->>'rp_valid_to')::date
        FROM pre
        WHERE rp.id = COALESCE((pre.settled_from->>'rp_id')::int,
                               (SELECT recurring_payment_id FROM finance.loans WHERE id = pre.id))
          AND pre.settled_from->>'rp_status' IS NOT NULL
        RETURNING rp.id
    )
    SELECT v_loans || COALESCE(jsonb_agg(jsonb_build_object('loan_id', l.id, 'status', l.status) ORDER BY l.id), '[]'::jsonb)
    INTO v_loans FROM l;

    RETURN jsonb_build_object('ok', true, 'deleted_count', v_count, 'transaction_ids', to_jsonb(v_ids),
        'reverted_loans', v_loans, 'reverted_real_estate', v_res);
END;
$$;
