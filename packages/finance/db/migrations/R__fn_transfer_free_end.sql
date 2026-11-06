-- ============================================================
-- fn_transfer_free_end (WRITE HELPER, 2026-11-01 "Umschichtung mit Enddatum")
--   Setzt das Ende eines laufenden freistehenden Uebertrags-Dauerauftrags so, dass er nur FREIES Geld der Quelle
--   verbraucht: spaetester Termin, mit dem die Quelle nicht frueher unter ihr Ziel-Geld faellt als ohne diesen Auftrag.
--   Keine zweite Rechnung: fn_account_funding der Quelle (langer Horizont 120 Monate) rechnet runs_out_on
--     Basis  = ohne den Auftrag (Kopf kurz pausiert),
--     offen  = mit dem Auftrag ohne Ende -> Quelle faellt am Tag X unter das Ziel-Geld,
--     Suche  = Halbierung ueber die Termine vor X (weniger Ueberweisungen = nie frueher unter dem Ziel-Geld, also monoton;
--              weitere Abgaenge teilen sich das freie Geld). Meist passt schon der letzte Termin vor X (ein Aufruf).
--   Gespeichert exklusiv = Termin + 1, Status wie vorher. Gerufen von fn_create_recurring_transfer /
--   fn_set_recurring_payment (until_free_money) NACH dem Insert/Update; bei {ok:false} rollt der Aufrufer seinen Write per
--   Savepoint zurueck (Sentinel LA002), es bleibt kein halber Write.
--   RUECKGABE: {ok:true, last_execution (inklusiv), free_after (freies Geld am tiefsten Punkt danach), horizon_end}
--   Korrigierbar {ok:false, code, reason}: not_transfer (kein Uebertrag/Entitaets-Zahlung/Kreditkonto), not_running (Kette
--   pausiert oder schon beendet: ein neues Ende liesse alte Termine wieder faellig werden), funding_unknown (Ampel neutral:
--   Alltagsausgaben unbekannt oder Kurs fehlt -> das Ende waere zu spaet), source_short (+ on_date: die Quelle faellt auch
--   ohne diesen Auftrag an diesem Tag unter das Ziel-Geld), no_free_money (schon der naechste Termin fasst Ziel-Geld an),
--   free_money_beyond_horizon (reicht laenger als der Horizont -> Enddatum nennen).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_transfer_free_end(p_rp_id int)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_head   finance.recurring_payments%ROWTYPE;
    v_f      JSONB;
    v_base   DATE;      -- runs_out_on ohne den Auftrag (NULL = nie im Horizont)
    v_out_on DATE;
    v_occ    DATE[];    -- Termine vor v_out_on, aufsteigend
    v_lo     INT := 0;  -- so viele Termine passen sicher (0 = keiner)
    v_hi     INT;       -- so viele passen nicht (bzw. noch ungeprueft: Start = alle)
    v_mid    INT;
    v_name   TEXT;
BEGIN
    SELECT * INTO v_head FROM finance.recurring_payments WHERE id = finance.fn_recurring_lineage_head(p_rp_id);
    IF NOT FOUND OR v_head.target_account_id IS NULL OR finance.fn_recurring_owner(v_head.id) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_transfer',
            'reason', '"Until the free money is used up" only works for a standing transfer between own accounts.');
    END IF;
    IF v_head.status <> 'active' OR (v_head.valid_to IS NOT NULL AND v_head.valid_to <= CURRENT_DATE) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_running',
            'reason', 'This standing transfer is paused or already ended - it cannot run until the free money is used up. Set up a new one instead.');
    END IF;
    SELECT name INTO v_name FROM finance.accounts WHERE id = v_head.account_id;

    -- Basis: Quelle ohne diesen Auftrag
    UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_head.id;
    v_f := finance.fn_account_funding(v_head.account_id, false, 120);
    IF (v_f->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_transfer', 'reason', v_f->>'reason');
    END IF;
    v_base := (v_f->>'runs_out_on')::date;
    UPDATE finance.recurring_payments SET status = v_head.status, valid_to = NULL WHERE id = v_head.id;

    v_f := finance.fn_account_funding(v_head.account_id, false, 120);
    IF v_f->>'state' = 'neutral' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'funding_unknown',
            'reason', 'The free money on "' || v_name || '" cannot be projected (unknown everyday spending or a missing exchange rate) - ask the user for an end date instead.');
    END IF;
    v_out_on := (v_f->>'runs_out_on')::date;
    IF v_out_on IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'free_money_beyond_horizon', 'horizon_end', v_f->'horizon_end',
            'reason', 'The free money on "' || v_name || '" lasts beyond ' || (v_f->>'horizon_end') || ' - ask the user for an end date instead.');
    END IF;
    IF v_out_on = v_base THEN
        RETURN jsonb_build_object('ok', false, 'code', 'source_short', 'on_date', v_base,
            'reason', '"' || v_name || '" falls below the money of its savings goals on ' || v_base || ' even without this transfer - ask the user for an end date instead.');
    END IF;

    SELECT array_agg(o.d ORDER BY o.d) INTO v_occ
      FROM finance.fn_schedule_occurrences(v_head.first_payment_date, v_head.schedule_interval, v_head.schedule_unit,
                                           v_head.schedule_day_of_month, v_head.schedule_days_of_month,
                                           GREATEST(v_head.valid_from, CURRENT_DATE), v_out_on - 1) AS o(d);
    v_hi := COALESCE(cardinality(v_occ), 0);

    -- Zuerst alle Termine vor X (der Normalfall), sonst Halbierung zwischen v_lo (passt) und v_hi (passt nicht)
    v_mid := v_hi;
    WHILE v_mid > v_lo LOOP
        UPDATE finance.recurring_payments SET valid_to = v_occ[v_mid] + 1 WHERE id = v_head.id;
        v_f := finance.fn_account_funding(v_head.account_id, false, 120);
        IF COALESCE((v_f->>'runs_out_on')::date, 'infinity'::date) >= COALESCE(v_base, 'infinity'::date) THEN
            v_lo := v_mid;
        ELSE
            v_hi := v_mid;
        END IF;
        v_mid := (v_lo + v_hi) / 2;
    END LOOP;

    IF v_lo = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_free_money',
            'reason', 'Already the next transfer would use money that belongs to savings goals on "' || v_name || '" - nothing is free to move.');
    END IF;

    UPDATE finance.recurring_payments SET valid_to = v_occ[v_lo] + 1 WHERE id = v_head.id;
    v_f := finance.fn_account_funding(v_head.account_id, false, 120);   -- Post-State mit dem endgueltigen Ende
    RETURN jsonb_build_object('ok', true, 'last_execution', v_occ[v_lo],
        'free_after', v_f->'min_free', 'horizon_end', v_f->'horizon_end');
END;
$$;
