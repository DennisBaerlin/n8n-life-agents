-- ============================================================
-- fn_set_account_interest (ATOMIC WRITE)
--   Setzt/aendert den Zinssatz eines BESTEHENDEN Kontos. fn_create_account legt nur die
--   ERSTE Zinszeile an; dies ist der Nachtrag-/Aenderungs-Pfad.
--   ZWINGENDE Reihenfolge wegen finance_account_interest_rates_no_overlap (EXCLUDE gist):
--     1. aktuell offene Zeile (valid_to IS NULL) per valid_to = neues valid_from schliessen
--        (nur falls vorhanden -- Konto kann zinslos sein),
--     2. neue Zeile INSERTen. Das half-offene daterange '[)' verhindert dann Overlap.
--   Eingabe jsonb: account_id (im n8n aufgeloest), annual_rate (% p.a.), schedule_interval, schedule_unit,
--   schedule_day_of_month, valid_from (opt->CURRENT_DATE), day_count_convention, posting_day_of_month (gesetzt =
--   Arrears), auto_post -- alle optional.
--   WIRKSAME WERTE + Pruefungen kommen aus finance.fn_interest_rate_preview (dieselbe fn speist die HITL-Karte ->
--   Karte = Buchung). Audit Paket 2, Punkt 5: ein reiner Satzwechsel ERBT Kadenz, Abbuchungstag, posting_day_of_month
--   und auto_post der offenen Zeile (vorher Default 'year' -> Doppelverzinsung); ein Kadenzwechsel verankert das Raster
--   neu (finance.fn_interest_regimes); rueckdatieren vor die juengste verzinste Periode ist korrigierbar abgelehnt.
--   RUECKGABE: Erfolg -> {ok:true, interest_rate_id, closed_previous}. Korrigierbar (s. fn_interest_rate_preview,
--   Overlap mit einer historischen Periode) -> {ok:false, reason} OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_account_interest(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_acct     INT      := (p->>'account_id')::int;
    v_rate     NUMERIC  := NULLIF(p->>'annual_rate', '')::numeric;
    v_pre      JSONB;
    v_from     DATE;
    v_closed   BOOLEAN;
    v_new_id   INT;
BEGIN
    v_pre := finance.fn_interest_rate_preview(p);
    IF (v_pre->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_pre;
    END IF;
    v_from   := (v_pre->>'valid_from')::date;
    v_closed := (v_pre->>'closes_previous')::boolean;

    -- Close (offene Zeile) + Insert (neue Zeile) im selben Sub-Block: ein Overlap mit einer
    -- HISTORISCHEN (geschlossenen) Periode (Backdating) wuerde sonst als harter exclusion_violation
    -- RAISE + Owner-Alert feuern. Korrigierbar -> abfangen und {ok:false}; beide Writes rollen
    -- dabei zusammen zurueck (Savepoint am inneren BEGIN), kein Teilzustand (offene Zeile bliebe sonst zu).
    BEGIN
        IF v_closed THEN
            UPDATE finance.account_interest_rates
            SET valid_to = v_from
            WHERE account_id = v_acct AND valid_to IS NULL;
        END IF;

        INSERT INTO finance.account_interest_rates
            (account_id, annual_rate, schedule_interval, schedule_unit, schedule_day_of_month,
             day_count_convention, posting_day_of_month, auto_post, valid_from)
        VALUES (v_acct, v_rate,
                (v_pre->>'schedule_interval')::smallint,
                (v_pre->>'schedule_unit')::finance.schedule_unit,
                NULLIF(v_pre->>'schedule_day_of_month', '')::smallint,
                v_pre->>'day_count_convention',
                NULLIF(v_pre->>'posting_day_of_month', '')::smallint,
                (v_pre->>'auto_post')::boolean,
                v_from)
        RETURNING id INTO v_new_id;
    EXCEPTION WHEN exclusion_violation THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'valid_from (' || v_from || ') overlaps an existing interest-rate period for this account. Use a date after the latest period.');
    END;

    RETURN jsonb_build_object('ok', true, 'interest_rate_id', v_new_id, 'closed_previous', v_closed);
END;
$$;
