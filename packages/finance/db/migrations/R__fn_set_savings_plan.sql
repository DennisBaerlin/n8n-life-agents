-- ============================================================
-- fn_set_savings_plan (ATOMIC WRITE)
--   Aendert einen Sparplan (Betrag/Kadenz/Status/Notiz). Partielles Update.
--   BETRAGS- ODER KADENZ-AENDERUNG = Validity-Split ueber den gemeinsamen Helfer fn_split_recurring_payment
--   (wie fn_set_recurring_payment; Status/Ende/Anker geerbt -> ein pausierter Plan bleibt pausiert);
--   plan.recurring_payment_id zeigt danach auf das neue RP (Kopf-Regel des Helfers). Damit bleibt die Rate-/
--   Kadenz-Geschichte im RP-Log (Vorgaenger-Kette) erhalten. Audit F2c(4): UEBERFAELLIGE offene Ausfuehrungen der
--   Kette vor dem Stichtag -> {ok:false, open_due_date} (erst buchen/ueberspringen). Eine KUENFTIGE Ausfuehrung vor
--   dem Stichtag ist erlaubt (Audit Paket 2, Punkt 3): sie bleibt auf der alten rp und wird ueber die Kette weiter
--   als Sparplan-Ausfuehrung erkannt (Erinnerung, fn_savings_plan_next_execution).
--   REAKTIVIEREN (Audit Paket 2, Punkt 1): status=active auf einem Plan, dessen rp beendet ist (Soft-Close,
--   valid_to <= Stichtag) -> Folge-rp ab dem Stichtag (fn_reopen_recurring_payment; Raster geerbt, Luecke nie
--   faellig). Vorher blieb valid_to stehen -> "aktiv", aber nie faellig.
--   WS-B Stufe 2 (Edge-Reviewer): schedule_unit/schedule_interval sind editierbar — ein "50 €/Woche"-
--   Sparplan laesst sich auf "monatlich" umstellen, ohne den Betrag neu nennen zu muessen (nicht-genannte
--   Kadenz-/Betrags-Felder uebernimmt der Split aus der alten Zeile). Eine reine Kadenz-Aenderung loest
--   denselben Split aus; der Betrag bleibt erhalten.
--   STATUS-KASKADE: paused -> RP.status=paused; active -> RP.status=active IN-PLACE, auf allen noch laufenden
--   Gliedern der Vorgaenger-Kette
--   (kein Split noetig, da sich weder Betrag noch Kadenz aendern).
--   FESTE MONATSTAGE: ein genannter Rhythmus (schedule_unit/_interval) wird wie beim Anlegen ueber den Depot-Kalender
--   abgeleitet (fn_resolve_plan_schedule, Stichtag = erste Ausfuehrung zu den neuen Bedingungen, muss bei festem
--   Kalender ein Kalendertag sein); andere Tage = Kadenzwechsel = Split. depot_execution_days (rohe Nutzer-Antwort)
--   korrigiert den Depot-Kalender (nur zusammen mit einem Rhythmus) und wird im selben Write am Depot gespeichert.
--   Eine reine Betrags-Aenderung erbt die Tage (fn_split_recurring_payment).
--   Eingabe jsonb: savings_plan_name, new_amount (opt, pos), schedule_unit (opt, day|week|month|year),
--   schedule_interval (opt, pos), depot_execution_days (opt), status (opt, paused|active),
--   valid_from (opt, Stichtag des Splits; default heute), notes (opt),
--   beneficiary_person_id (opt, Slug; leer=unveraendert),
--   asset_class (opt -- Phase L WS-6: Anlageklasse korrigieren; leer=unveraendert; Format-Verstoss -> {ok:false}).
--   RUECKGABE: {ok:true, savings_plan_id, recurring_payment_id, split}; bei split=true zusaetzlich previous_rp_id,
--   schedule_unit/schedule_interval und schedule_days ("2, 9, 16, 23" oder null) der neuen Zeile (gespeichert, fuer
--   die Karte) sowie monthly_amount (Betrag je Monat, positiv);
--   bei Reaktivierung einer beendeten rp zusaetzlich reopened=true + previous_rp_id; optional savings_squeeze
--   (fn_savings_squeeze_fold: Sparraten leeren das Girokonto) - nur wenn sich die laufende Rate aendert (Split/
--   Reaktivierung mit Stichtag <= heute, Status-Wechsel), nie bei reinen Notiz-/Anlageklasse-/Person-Edits.
--   NO-CHANGE (Livebefund 2026-10-27): genannter Rhythmus/Betrag gleich den gespeicherten Bedingungen (feste Tage =
--   Nutzer-Rhythmus week/1 bzw. week/2) -> kein Split; ohne weitere Felder {ok:false, code:'no_change', rhythm,
--   amount_per_execution, monthly_amount} (geprueft VOR den Split-Vorbedingungen).
--   Korrigierbar (nicht gefunden, new_amount<=0, Stichtag<=aktueller valid_from, asset_class-Format) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_savings_plan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name      TEXT              := p->>'savings_plan_name';
    v_amount    NUMERIC           := NULLIF(p->>'new_amount', '')::numeric;
    v_unit_new  finance.schedule_unit := NULLIF(p->>'schedule_unit', '')::finance.schedule_unit;     -- WS-B2: Kadenz editierbar
    v_interval_new SMALLINT       := NULLIF(p->>'schedule_interval', '')::smallint;                  -- WS-B2
    v_status    finance.payment_status := NULLIF(p->>'status', '')::finance.payment_status;
    v_from      DATE;
    v_asset_cls TEXT              := NULLIF(p->>'asset_class', '');   -- WS-6: Anlageklasse korrigierbar (leer=unveraendert)
    v_plan      finance.savings_plans%ROWTYPE;
    v_rp        finance.recurring_payments%ROWTYPE;
    v_resolve   RECORD;
    v_new_rp_id INT;
    v_signed    NUMERIC;
    v_split     BOOLEAN;
    v_open_due  DATE;
    v_split_res JSONB;
    v_cal_in    TEXT              := NULLIF(p->>'depot_execution_days', '');
    v_sched     JSONB;
    v_days      SMALLINT[];
    v_dom       SMALLINT;
    v_dates     JSONB;
    v_user_unit finance.schedule_unit;
    v_user_int  SMALLINT;
    v_label     TEXT;
BEGIN
    -- relative Datumsangabe ("in 1 month") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['valid_from']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_from := COALESCE(NULLIF(p->>'valid_from', '')::date, core.fn_today());
    -- Plan aufloesen (inkl. paused, damit Pause/Resume auf paused Plans funktioniert)
    SELECT r.id, r.hit_count INTO v_resolve
    FROM finance.fn_resolve_savings_plan(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'No savings plan found matching "' || v_name || '".');
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Multiple savings plans match "' || v_name || '". Please be more specific.',
            'hit_count', v_resolve.hit_count);
    END IF;

    SELECT * INTO v_plan FROM finance.savings_plans WHERE id = v_resolve.id;
    SELECT * INTO v_rp   FROM finance.recurring_payments WHERE id = v_plan.recurring_payment_id;

    -- WS-6: Anlageklasse-Format vor jedem Write pruefen (mirror create) -> {ok:false} OHNE Write.
    IF v_asset_cls IS NOT NULL AND v_asset_cls !~ '^[a-z0-9_]+$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'asset_class tag must be lowercase letters/digits/underscore (e.g. sp500), got: ' || v_asset_cls);
    END IF;

    -- NUTZER-Rhythmus der Kopf-Zeile (die Bedingungen ab jedem gueltigen Stichtag, der Split setzt immer nach ihrem
    -- valid_from an): feste Monatstage sind fuer den Nutzer "woechentlich" (>= 4 Tage) bzw. "zweimal im Monat" -> week/1
    -- bzw. week/2; sonst die gespeicherten Werte. Eine Adresse fuer den No-Change-Vergleich und den Resolver-Aufruf.
    v_user_unit := CASE WHEN v_rp.schedule_days_of_month IS NOT NULL THEN 'week'::finance.schedule_unit
                        ELSE v_rp.schedule_unit END;
    v_user_int  := CASE WHEN v_rp.schedule_days_of_month IS NOT NULL
                        THEN (CASE WHEN cardinality(v_rp.schedule_days_of_month) >= 4 THEN 1 ELSE 2 END)::smallint
                        ELSE v_rp.schedule_interval END;

    -- NO-CHANGE (Livebefund 2026-10-27): genannter Rhythmus/Betrag = gespeichert -> kein Split. VOR den Split-
    -- Vorbedingungen (der Livefall scheiterte sonst schon am Stichtag und der Agent bot einen identischen Split an).
    -- Nichts anderes genannt -> {ok:false, code:'no_change'} mit Rhythmus + Monatsbetrag; sonst weiter in-place.
    IF (v_amount IS NOT NULL OR v_unit_new IS NOT NULL OR v_interval_new IS NOT NULL) AND v_cal_in IS NULL
       AND (v_amount IS NULL OR v_amount = abs(v_rp.amount))
       AND COALESCE(v_unit_new, v_user_unit) = v_user_unit
       AND COALESCE(v_interval_new, v_user_int) = v_user_int THEN
        IF v_status IS NULL AND NULLIF(p->>'notes', '') IS NULL AND NULLIF(p->>'beneficiary_person_id', '') IS NULL
           AND v_asset_cls IS NULL THEN
            v_label := finance.fn_schedule_label(v_rp.schedule_unit, v_rp.schedule_interval, v_rp.schedule_day_of_month,
                                                 v_rp.schedule_days_of_month);
            RETURN jsonb_build_object('ok', false, 'code', 'no_change',
                'rhythm', v_label,
                'amount_per_execution', abs(v_rp.amount),
                'monthly_amount', abs(v_rp.monthly_equivalent),
                'reason', 'Nothing to change: savings plan "' || v_plan.name || '" is already stored as ' || v_label
                       || ' with ' || to_char(abs(v_rp.amount), 'FM999999990D00') || ' '
                       || (SELECT a.currency FROM finance.accounts a WHERE a.id = v_rp.account_id)
                       || ' per execution = ' || to_char(abs(v_rp.monthly_equivalent), 'FM999999990D00')
                       || ' per month. Tell the user it already runs that way; do not offer a change.');
        END IF;
        v_amount := NULL; v_unit_new := NULL; v_interval_new := NULL;
    END IF;

    -- WS-B Stufe 2: Betrags- ODER Kadenz-Aenderung loest den Validity-Split aus (nicht-genannte Felder
    -- uebernimmt der Split aus der alten Zeile -> eine reine Kadenz-Aenderung erhaelt den Betrag).
    v_split := (v_amount IS NOT NULL) OR (v_unit_new IS NOT NULL) OR (v_interval_new IS NOT NULL) OR (v_cal_in IS NOT NULL);
    IF v_cal_in IS NOT NULL AND v_unit_new IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'To correct the bank''s execution days, also pass the plan rhythm as the user names it '
                   || '(schedule_unit/schedule_interval, e.g. week + 1 for weekly).');
    END IF;

    -- ATOMARITAET (Cold-Eyes): die korrigierbaren Split-Vorbedingungen VOR jedem Write pruefen. Der {ok:false}-
    -- Pfad RAISEt nicht -> er rollt nichts zurueck; laegen die orthogonalen beneficiary-/asset_class-UPDATEs
    -- davor, hinterliesse ein abgelehnter Aufruf (z. B. new_amount<=0 zusammen mit asset_class) eine stille
    -- Teil-Mutation. Erst ablehnen, dann mutieren.
    IF v_split THEN
        IF v_amount IS NOT NULL AND v_amount <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'New amount must be a positive number, got ' || v_amount || '.');
        END IF;
        IF v_from <= v_rp.valid_from THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Effective date (' || v_from || ') must be after the current entry valid_from ('
                       || v_rp.valid_from || ').',
                'current_valid_from', v_rp.valid_from);
        END IF;
        -- Audit F2c(4): UEBERFAELLIGE offene (weder gebuchte noch uebersprungene) Ausfuehrungen der Kette vor dem
        -- Stichtag -> erst buchen/ueberspringen (Hygiene). Kuenftige Ausfuehrungen vor dem Stichtag bleiben auf der
        -- alten rp und laufen ueber die Kette weiter als Sparplan (Audit Paket 2, Punkt 3).
        SELECT min(o.due_date) INTO v_open_due
        FROM finance.fn_recurring_due_open(LEAST(v_from - 1, CURRENT_DATE)) o
        WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp.id));
        IF v_open_due IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The savings plan still has an execution due on ' || v_open_due || ' at the old terms. '
                       || 'Book that execution (book_savings_plan_execution) or skip it first, or choose an '
                       || 'effective date on or before ' || v_open_due || '.',
                'open_due_date', v_open_due);
        END IF;
        -- Kadenzwechsel: Rhythmus ueber den Depot-Kalender ableiten (wie fn_create_savings_plan); Stichtag = erste
        -- Ausfuehrung zu den neuen Bedingungen
        IF v_unit_new IS NOT NULL OR v_interval_new IS NOT NULL THEN
            -- Nicht genannte Teile aus dem NUTZER-Rhythmus der alten Zeile: feste Monatstage sind fuer den Nutzer
            -- "woechentlich" (4 Tage) bzw. "zweimal im Monat" (2 Tage) -> week/1 bzw. week/2; sonst die gespeicherten
            -- Werte ("alle zwei Wochen" bei einem 2./9./16./23.-Plan wird so nie "alle zwei Monate").
            v_sched := finance.fn_resolve_plan_schedule(v_plan.depot_id,
                COALESCE(v_unit_new, v_user_unit), COALESCE(v_interval_new, v_user_int), NULL, v_from, v_cal_in);
            IF (v_sched->>'ok')::boolean IS DISTINCT FROM true THEN
                RETURN v_sched;
            END IF;
            v_unit_new     := (v_sched->>'schedule_unit')::finance.schedule_unit;
            v_interval_new := (v_sched->>'schedule_interval')::smallint;
            v_dom          := (v_sched->>'schedule_day_of_month')::smallint;
            v_days         := COALESCE(finance.fn_jsonb_smallint_array(v_sched->'schedule_days_of_month'),
                                       '{}');   -- '{}' = Tage der alten Zeile leeren
        END IF;
    END IF;

    -- Validity-Split ueber den gemeinsamen Helfer (Audit F2: Status/Ende/Anker geerbt -> ein pausierter Plan
    -- bleibt pausiert; Kadenz aus dem Override ODER der alten Zeile; Abbuchungstag uebernommen). Laeuft VOR den
    -- orthogonalen UPDATEs: ein {ok:false} des Helfers (Guards) darf keine Teil-Mutation hinterlassen.
    IF v_split THEN
        -- Betrag: neuer Betrag (Vorzeichen aus der alten Zeile = immer Ausgabe) ODER den alten uebernehmen
        -- (reine Kadenz-Aenderung).
        v_signed := CASE WHEN v_amount IS NOT NULL
                         THEN (CASE WHEN v_rp.amount < 0 THEN -1 ELSE 1 END) * v_amount
                         ELSE v_rp.amount END;
        v_split_res := finance.fn_split_recurring_payment(
            v_rp.id, v_from, v_signed, v_interval_new, v_unit_new, v_dom, NULL, NULL, NULL, v_days);
        IF (v_split_res->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_split_res;
        END IF;
        v_new_rp_id := (v_split_res->>'recurring_payment_id')::int;
        PERFORM finance.fn_set_depot_plan_calendar(v_plan.depot_id, v_sched);   -- NULL v_sched (kein Kadenzwechsel) = no-op
    END IF;

    -- WS-4: beguenstigte Person (Slug, im Tool aufgeloest) — orthogonal zum Betrags-/Status-Pfad,
    -- daher ein eigenes partielles Update (leer=unveraendert; greift fuer split- UND in-place-Zweig).
    IF NULLIF(p->>'beneficiary_person_id', '') IS NOT NULL THEN
        UPDATE finance.savings_plans
        SET beneficiary_person_id = p->>'beneficiary_person_id'
        WHERE id = v_plan.id;
    END IF;

    -- WS-6: Anlageklasse korrigieren — orthogonal zum Betrags-/Status-Pfad (wie beneficiary_person_id), eigenes
    -- partielles Update (leer=unveraendert; greift fuer split- UND in-place-Zweig). Vererbt sich ab der naechsten
    -- Ausfuehrung; bereits getaggte Holdings bleiben unveraendert (fn_book_stock_buy taggt nur beim Anlegen).
    IF v_asset_cls IS NOT NULL THEN
        UPDATE finance.savings_plans
        SET asset_class = v_asset_cls
        WHERE id = v_plan.id;
    END IF;

    IF v_split THEN
        -- BETRAGS-/KADENZ-AENDERUNG: der Split lief bereits VOR den orthogonalen UPDATEs (s. oben -> v_new_rp_id);
        -- der Helfer hat den Plan schon auf das neue RP gesetzt (Kopf-Regel).
        UPDATE finance.savings_plans
        SET notes = COALESCE(NULLIF(p->>'notes', ''), notes)
        WHERE id = v_plan.id;

        RETURN jsonb_build_object(
            'ok',                   true,
            'effective',            (v_dates->'resolved') || jsonb_build_object('valid_from', to_char(v_from, 'YYYY-MM-DD')),
            'savings_plan_id',      v_plan.id,
            'recurring_payment_id', v_new_rp_id,
            'previous_rp_id',       v_rp.id,
            'split',                true,
            'schedule_unit',        (SELECT r.schedule_unit FROM finance.recurring_payments r WHERE r.id = v_new_rp_id),
            'schedule_interval',    (SELECT r.schedule_interval FROM finance.recurring_payments r WHERE r.id = v_new_rp_id),
            'monthly_amount',       (SELECT abs(r.monthly_equivalent) FROM finance.recurring_payments r WHERE r.id = v_new_rp_id),
            'schedule_days',        (SELECT array_to_string(r.schedule_days_of_month, ', ')
                                     FROM finance.recurring_payments r WHERE r.id = v_new_rp_id))
            -- kuenftiger Stichtag: der neue Betrag ist im Post-State noch nicht aktiv -> kein Fold (der Cron faengt es)
            || CASE WHEN v_from <= CURRENT_DATE THEN finance.fn_savings_squeeze_fold() ELSE '{}'::jsonb END;
    ELSE
        -- REAKTIVIEREN einer beendeten rp (Soft-Close) -> Folge-rp ab dem Stichtag (Audit Paket 2, Punkt 1).
        IF v_status = 'active' AND v_rp.valid_to IS NOT NULL AND v_rp.valid_to <= v_from THEN
            v_split_res := finance.fn_reopen_recurring_payment(v_rp.id, v_from);
            IF (v_split_res->>'ok')::boolean IS DISTINCT FROM true THEN
                RETURN v_split_res;
            END IF;
            UPDATE finance.savings_plans
            SET status = 'active',
                notes  = COALESCE(NULLIF(p->>'notes', ''), notes)
            WHERE id = v_plan.id;
            RETURN jsonb_build_object(
                'ok',                   true,
                'effective',            (v_dates->'resolved') || jsonb_build_object('valid_from', to_char(v_from, 'YYYY-MM-DD')),
                'savings_plan_id',      v_plan.id,
                'recurring_payment_id', (v_split_res->>'recurring_payment_id')::int,
                'previous_rp_id',       v_rp.id,
                'split',                false,
                'reopened',             true)
                || CASE WHEN v_from <= CURRENT_DATE THEN finance.fn_savings_squeeze_fold() ELSE '{}'::jsonb END;
        END IF;

        -- IN-PLACE: Status und/oder Notizen
        IF v_status IS NOT NULL THEN
            UPDATE finance.savings_plans
            SET status = v_status::finance.payment_status,
                notes  = COALESCE(NULLIF(p->>'notes', ''), notes)
            WHERE id = v_plan.id;

            -- Kaskade auf ALLE noch laufenden Glieder der Kette (Audit Paket 2: eine alte rp mit noch anstehender
            -- Ausfuehrung pausiert/laeuft mit dem Plan; beendete Glieder bleiben unberuehrt)
            UPDATE finance.recurring_payments
            SET status = v_status
            WHERE id IN (SELECT finance.fn_recurring_lineage(v_plan.recurring_payment_id))
              AND (valid_to IS NULL OR valid_to > CURRENT_DATE);
        ELSE
            -- Nur Notiz
            UPDATE finance.savings_plans
            SET notes = COALESCE(NULLIF(p->>'notes', ''), notes)
            WHERE id = v_plan.id;
        END IF;

        RETURN jsonb_build_object(
            'ok',                   true,
            'effective',            (v_dates->'resolved') || jsonb_build_object('valid_from', to_char(v_from, 'YYYY-MM-DD')),
            'savings_plan_id',      v_plan.id,
            'recurring_payment_id', v_plan.recurring_payment_id,
            'split',                false)
            -- nur ein Status-Wechsel aendert die laufende Sparrate; reine Notiz-/Anlageklasse-/Person-Edits falten nichts
            || CASE WHEN v_status IS NOT NULL THEN finance.fn_savings_squeeze_fold() ELSE '{}'::jsonb END;
    END IF;
END;
$$;
