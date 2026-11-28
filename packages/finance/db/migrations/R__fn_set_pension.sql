-- ============================================================
-- fn_set_pension (ATOMIC WRITE)
--   Aendert eine bestehende Altersvorsorge (Wert/Status/Stammdaten/Beitrag). Partielles Update
--   ("nicht gesendet = unveraendert").
--   Wird current_value gesetzt ohne value_updated_at -> value_updated_at = heute (core.fn_today).
--   Beitrag (steht nur an der Beitrags-Kette):
--     - contribution_amount je Abbuchung, roh und positiv -> fn_change_owned_recurring: Korrektur direkt nach der Anlage
--       in place, sonst neues Glied ab effective_from (Default: naechster noch nicht erledigter Termin) -- der alte Beitrag
--       bleibt Historie, ein ueberfaelliger offener Termin behaelt seinen Betrag. Gleicher Beitrag im gleichen Rhythmus
--       = keine Aenderung. Ein neuer Rhythmus nur zusammen mit dem Betrag.
--     - Beitrag 0 gibt es nicht: beitragsfrei stellen = status 'paused' (eine Adresse).
--     - Vorsorge ohne Beitrag (recurring_payment_id NULL): der Beitrag legt die Kette an -- effective_from = erste
--       Abbuchung und debit_account_id sind dann Pflicht, Rhythmus Default 1 x Monat (wie fn_create_pension).
--     - Ist schon eine Aenderung geplant (Kopf beginnt in der Zukunft), ersetzt ein Beitrag ohne effective_from den
--       geplanten ab dessen Start; ein effective_from davor -> {ok:false}.
--   Status-Kaskade ueber alle Glieder der Beitrags-Kette: status in ('paused','paid_out') -> 'paused' (Beitrag verlaesst
--   den Cashflow); status='active' -> 'active'; ist der Beitrag beendet (fn_close_pension), entsteht eine Folge-Zeile ab
--   heute (fn_reopen_recurring_payment). status='active' + Beitrag im selben Aufruf: erst reaktivieren, dann der Beitrag.
--   Namen: eine Umbenennung fuehrt 'AV-Beitrag <Name>' an der Beitrags-Kette mit.
--   Eingabe jsonb: pension_id (im n8n via fn_resolve_pension aufgeloest), name, provider,
--   contract_number, owner_person_id (Slug; leer=unveraendert), current_value, value_updated_at, guaranteed_monthly_pension,
--   retirement_start_date, status ('active'|'paused'|'paid_out'), notes, contribution_amount, effective_from,
--   schedule_interval, schedule_unit, debit_account_id (nur beim ersten Beitrag).
--   RUECKGABE: {ok:true, pension_id, recurring_payment_id (Kopf der Beitrags-Kette, nach einem Reaktivieren die Folge-Zeile),
--   effective (aufgeloeste relative Daten)}; nur bei geaendertem oder erstem Beitrag zusaetzlich split, previous_id (nur Split),
--   first_due (erster Termin mit dem neuen Beitrag), contribution_amount (je Abbuchung), monthly_contribution (Monatswert),
--   previous_contribution_amount (Beitrag davor am Stichtag; fehlt beim ersten Beitrag).
--   Korrigierbar (nicht aufloesbares Datum -> code invalid_date, current_value<0, unbekannter status/Rhythmus,
--   gesetzliche Rente mit Monatsrente/Wert oder als zweite aktive der Person, Beitrag <= 0, Rhythmus/Stichtag ohne Beitrag,
--   Konto ausser beim ersten Beitrag, Beitrag an einer nicht aktiven Vorsorge, erster Beitrag ohne effective_from/Konto
--   oder auf ein nicht buchbares Konto, Stichtag vor einer geplanten Aenderung, Split-Guards) -> {ok:false}.
--   RAISE bei unbekannter pension_id und wenn fn_reopen_recurring_payment den beendeten Beitrag nicht reaktiviert.
--   handoff_task_id (optional): Eintrag einer vereinbarten Plan-Aufgabe -> finance.fn_with_handoff (Pruefung, Abschluss
--   im selben Write, Kartenzeile core.hitl.handoff_note).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_pension(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id       INT     := (p->>'pension_id')::int;
    v_cv       NUMERIC := NULLIF(p->>'current_value', '')::numeric;
    v_status   finance.pension_status;   -- Cast erst nach dem Enum-Guard
    v_reason   TEXT    := COALESCE(finance.fn_enum_reason('finance.pension_status'::regtype, p->>'status', 'status'),
                                   finance.fn_enum_reason('finance.schedule_unit'::regtype, p->>'schedule_unit', 'schedule_unit'));
    v_pen      finance.pension%ROWTYPE;
    v_rp       INT;
    v_dates    JSONB;
    v_reopen   JSONB;
    v_today    DATE    := core.fn_today();
    v_contrib  NUMERIC := NULLIF(p->>'contribution_amount', '')::numeric;
    v_eff      DATE;
    v_interval SMALLINT;
    v_unit     finance.schedule_unit;
    v_acct     INT     := NULLIF(p->>'debit_account_id', '')::int;   -- nur fuer den ersten Beitrag
    v_cur      finance.recurring_payments%ROWTYPE;
    v_head     finance.recurring_payments%ROWTYPE;
    v_added    BOOLEAN := false;
    v_chg      JSONB;
    v_post     JSONB   := '{}'::jsonb;
BEGIN
    -- Vereinbarte Plan-Aufgabe (Uebergabe Berater -> Buchhalter): pruefen, schreiben, abschliessen in einer Transaktion
    IF NULLIF(btrim(COALESCE(p->>'handoff_task_id', '')), '') IS NOT NULL THEN
        RETURN finance.fn_with_handoff('finance.fn_set_pension(jsonb)'::regprocedure, p);
    END IF;
    -- relative Datumsangaben ("yesterday") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['value_updated_at', 'retirement_start_date', 'effective_from']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_eff := NULLIF(p->>'effective_from', '')::date;
    SELECT * INTO v_pen FROM finance.pension WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pension % not found.', v_id;
    END IF;
    v_rp := v_pen.recurring_payment_id;
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_status := NULLIF(p->>'status', '')::finance.pension_status;
    v_unit   := NULLIF(p->>'schedule_unit', '')::finance.schedule_unit;
    -- Rhythmus-Intervall: ganze Zahl >= 1 (Text wie 'quarterly' -> {ok:false} statt Cast-Fehler mit Owner-Alarm)
    IF NULLIF(btrim(p->>'schedule_interval'), '') IS NOT NULL
       AND (CASE WHEN btrim(p->>'schedule_interval') ~ '^[0-9]{1,3}$' THEN btrim(p->>'schedule_interval')::int < 1 ELSE true END) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The payment interval (schedule_interval) must be a whole number of at least 1, got "' || (p->>'schedule_interval') || '".');
    END IF;
    v_interval := NULLIF(btrim(p->>'schedule_interval'), '')::smallint;

    -- Korrigierbar: Wert darf nicht negativ sein.
    IF v_cv IS NOT NULL AND v_cv < 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Current value must not be negative, got ' || v_cv || '.');
    END IF;
    -- Gesetzliche Rente (Spiegel CHECK finance_pension_statutory_no_amounts / UNIQUE finance_pension_statutory_uq).
    IF v_pen.pension_type = 'statutory' THEN
        IF v_cv IS NOT NULL OR NULLIF(p->>'guaranteed_monthly_pension', '') IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'A statutory pension stores no monthly pension or value of its own - those figures belong to its '
                       || 'Renteninformation (send the new statement as a PDF).');
        END IF;
        IF COALESCE(v_status, v_pen.status) = 'active' AND EXISTS (
               SELECT 1 FROM finance.pension o
                WHERE o.id <> v_id AND o.pension_type = 'statutory' AND o.status = 'active'
                  AND o.owner_person_id IS NOT DISTINCT FROM COALESCE(NULLIF(p->>'owner_person_id', ''), v_pen.owner_person_id)) THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'This person already has another active statutory pension - only one is possible.');
        END IF;
    END IF;

    -- Beitrag: alle korrigierbaren Ablehnungen vor dem ersten Write
    SELECT * INTO v_head FROM finance.recurring_payments WHERE id = finance.fn_recurring_lineage_head(v_rp);
    SELECT * INTO v_cur  FROM finance.recurring_payments WHERE id = finance.fn_recurring_current(v_rp, COALESCE(v_eff, v_today));
    IF v_contrib IS NOT NULL AND v_contrib <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The contribution must be positive, got ' || v_contrib || '. To stop paying contributions (Beitragsfreistellung) '
                   || 'set status paused instead - the contribution then leaves the cashflow and the value stays.');
    END IF;
    IF v_contrib IS NULL AND (v_interval IS NOT NULL OR v_unit IS NOT NULL OR v_eff IS NOT NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A payment rhythm or an effective date is only taken together with the new contribution per debit '
                   || '(contribution_amount) - ask the user for it.');
    END IF;
    IF v_acct IS NOT NULL AND (v_rp IS NOT NULL OR v_contrib IS NULL) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A debit account is only taken together with the first contribution of a provision that has none yet - '
                   || 'the debit account of a recorded contribution cannot be changed here.');
    END IF;
    IF v_contrib IS NOT NULL AND COALESCE(v_status, v_pen.status) <> 'active' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This provision is ' || COALESCE(v_status, v_pen.status) || ' - a contribution can only be set on an active '
                   || 'provision (set status active in the same call if contributions start again).');
    END IF;
    IF v_contrib IS NOT NULL AND v_rp IS NULL THEN
        IF v_eff IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'This provision has no contribution yet: adding one needs the date of its first debit (effective_from) - ask the user.');
        END IF;
        IF v_acct IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'This provision has no contribution yet: adding one needs the debit account it is paid from - ask the user.');
        END IF;
        v_reason := finance.fn_bookable_account_reason(v_acct);
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_reason);
        END IF;
        v_added := true;
    END IF;
    -- Geplante Aenderung (Kopf mit Vorgaenger beginnt erst): ein Stichtag davor liesse zwei kuenftige Wechsel entstehen
    IF v_contrib IS NOT NULL AND v_eff IS NOT NULL AND v_head.predecessor_id IS NOT NULL
       AND v_head.valid_from > v_today AND v_eff < v_head.valid_from THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A contribution change is already planned from ' || v_head.valid_from || '. Give an effective date on or after '
                   || 'that day, or leave it empty to replace the planned contribution from ' || v_head.valid_from || '.',
            'planned_from', v_head.valid_from);
    END IF;

    -- Ein {ok:false} des Ketten-Helfers nach den ersten Writes -> SQLSTATE FN001 -> Rollback des Blocks -> {ok:false}
    BEGIN
        UPDATE finance.pension SET
            name                       = COALESCE(NULLIF(p->>'name', ''), name),
            provider                   = COALESCE(NULLIF(p->>'provider', ''), provider),
            contract_number            = COALESCE(NULLIF(p->>'contract_number', ''), contract_number),
            owner_person_id            = COALESCE(NULLIF(p->>'owner_person_id', ''), owner_person_id),  -- Slug; leer=unveraendert

            current_value              = COALESCE(v_cv, current_value),
            value_updated_at           = CASE
                                             WHEN v_cv IS NOT NULL
                                             THEN COALESCE(NULLIF(p->>'value_updated_at', '')::date, v_today)
                                             ELSE COALESCE(NULLIF(p->>'value_updated_at', '')::date, value_updated_at)
                                         END,
            guaranteed_monthly_pension = COALESCE(NULLIF(p->>'guaranteed_monthly_pension', '')::numeric, guaranteed_monthly_pension),
            retirement_start_date      = COALESCE(NULLIF(p->>'retirement_start_date', '')::date, retirement_start_date),
            status                     = COALESCE(v_status, status),
            notes                      = COALESCE(NULLIF(p->>'notes', ''), notes)
        WHERE id = v_id;

        -- Namenskopie 'AV-Beitrag <Name>' an der Beitrags-Kette mitfuehren (fn_rename_owned_recurring)
        PERFORM finance.fn_rename_owned_recurring(v_rp, 'AV-Beitrag', v_pen.name, NULLIF(p->>'name', ''));

        -- Status-Kaskade auf die ganze Beitrags-Kette: nach einer geplanten Aenderung laeuft neben dem Kopf noch das
        -- heutige Glied, nur den Kopf zu pausieren liesse den Beitrag weiter faellig werden.
        IF v_status IS NOT NULL AND v_rp IS NOT NULL THEN
            IF v_status = 'active' AND finance.fn_recurring_chain_ended(v_rp, v_today) THEN
                -- beendeter Beitrag (fn_close_pension): nur 'active' zu setzen ergaebe "aktiv", aber nie wieder faellig ->
                -- Folge-Zeile ab heute; der Helfer setzt die Vorsorge auf sie (fn_repoint_recurring_owners).
                v_reopen := finance.fn_reopen_recurring_payment(v_rp, v_today);
                IF (v_reopen->>'ok')::boolean IS DISTINCT FROM true THEN
                    RAISE EXCEPTION 'Pension % contribution could not be reopened: %', v_id, v_reopen->>'reason';
                END IF;
                v_rp := (v_reopen->>'recurring_payment_id')::int;
            ELSE
                UPDATE finance.recurring_payments
                SET status = CASE WHEN v_status = 'active' THEN 'active' ELSE 'paused' END::finance.payment_status
                WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))
                  AND (valid_to IS NULL OR valid_to > v_today);
            END IF;
        END IF;

        IF v_added THEN
            v_eff := finance.fn_schedule_first_occurrence(v_eff, COALESCE(v_interval, 1::smallint),
                         COALESCE(v_unit, 'month'::finance.schedule_unit), NULL, NULL);
            v_rp := finance.fn_add_recurring_payment(
                v_acct, -v_contrib, left('AV-Beitrag ' || COALESCE(NULLIF(p->>'name', ''), v_pen.name), 100),
                COALESCE(v_interval, 1::smallint), COALESCE(v_unit, 'month'::finance.schedule_unit), NULL, v_eff,
                finance.fn_recurring_valid_from(v_acct, v_eff), NULL, NULL, NULL);
            UPDATE finance.pension SET recurring_payment_id = v_rp WHERE id = v_id;
            v_chg := jsonb_build_object('split', false);
        ELSIF v_contrib IS NOT NULL THEN
            -- nach einem Reaktivieren ist das massgebliche Glied die Folge-Zeile
            SELECT * INTO v_cur FROM finance.recurring_payments WHERE id = finance.fn_recurring_current(v_rp, COALESCE(v_eff, v_today));
            IF v_contrib <> abs(v_cur.amount) OR COALESCE(v_interval, v_cur.schedule_interval) <> v_cur.schedule_interval
               OR COALESCE(v_unit, v_cur.schedule_unit) <> v_cur.schedule_unit THEN
                v_chg := finance.fn_change_owned_recurring(v_rp, v_eff, -v_contrib, v_interval, v_unit, NULL);
                IF (v_chg->>'ok')::boolean IS DISTINCT FROM true THEN
                    RAISE EXCEPTION USING ERRCODE = 'FN001', MESSAGE = COALESCE(v_chg->>'reason', 'contribution change refused');
                END IF;
                v_rp := (v_chg->>'recurring_payment_id')::int;
                v_chg := v_chg || jsonb_build_object('previous_contribution_amount', abs(v_cur.amount));
            END IF;
        END IF;
    EXCEPTION WHEN SQLSTATE 'FN001' THEN
        RETURN v_chg;
    END;

    IF v_chg IS NOT NULL THEN
        SELECT jsonb_strip_nulls(jsonb_build_object(
                   'split', v_chg->'split', 'previous_id', v_chg->'previous_id',
                   'first_due', finance.fn_recurring_first_due(r.id),
                   'contribution_amount', abs(r.amount), 'monthly_contribution', abs(r.monthly_equivalent),
                   'previous_contribution_amount', v_chg->'previous_contribution_amount'))
          INTO v_post FROM finance.recurring_payments r WHERE r.id = v_rp;
    END IF;

    RETURN jsonb_build_object('ok', true, 'pension_id', v_id, 'recurring_payment_id', v_rp) || v_post
        || jsonb_build_object('effective', v_dates->'resolved');
END;
$$;
