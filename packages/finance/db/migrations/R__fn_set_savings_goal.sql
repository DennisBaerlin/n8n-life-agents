-- ============================================================
-- fn_set_savings_goal (ATOMIC WRITE)
--   Aendert ein Sparziel (Zielbetrag/Datum/Status/Stammdaten). Partielles Update.
--   RATEN-NEUBERECHNUNG (Best Practice aus der Recherche): bei geaendertem target_amount ODER
--   target_date wird die monatliche Sparrate ueber REST-Betrag / REST-Zeit neu gerechnet
--   (NICHT Gesamt/Gesamt -- haeufiger App-Bug). Rest = effektiver Zielbetrag - bereits gespart
--   (finance_savings_goal_progress.current_amount); Rest-Monate ab heute bis Zieldatum.
--   Die neu berechnete Rate wird in die verknuepfte recurring_payment IN-PLACE geschrieben (Befund B); sie wird auf
--   den Cent AUFGERUNDET (Audit Paket 2, Punkt 15: sonst erreichen die Raten das Ziel um Cents nicht).
--   STATUS: completed/cancelled -> {ok:false} mit Verweis auf close_savings_goal (Audit Paket 2, Punkt 4: set umging
--   das Close-Gate "Reserve ~0 oder force" und gab Reserven still frei). active -> rp 'active'; ist die Rate beendet
--   (valid_to <= heute, nach close_savings_goal) -> Folge-rp ab heute (fn_reopen_recurring_payment), Ziel zeigt auf sie.
--   Eingabe jsonb: goal_id (im n8n aufgeloest), name, target_amount, target_date, status,
--   beneficiary_person_id (Slug; leer=unveraendert), reserve_account_id (opt, WS-A: Reserve-Topf
--   aendern -> rate.target_account_id; alte getaggte Buchungen bleiben dem Ziel zugeordnet),
--   priority (opt, WS-C1: kleiner = wichtiger; leer=unveraendert), notes,
--   link_savings_plan_name (opt, WS-B Stufe 2: einen Sparplan diesem Ziel ZUORDNEN -> savings_plans.
--   savings_goal_id), unlink_savings_plan_name (opt, WS-B Stufe 2: einen Sparplan vom Ziel LOESEN -> NULL;
--   nur wenn er an DIESES Ziel gebunden ist). Ein Ziel hat 0..N Sparplaene (+ <=1 Cash-Rate); je Aufruf wird
--   EIN Plan ver-/entknuepft. Die Quellen-Validierung laeuft VOR jedem Write -> {ok:false} bleibt write-frei.
--   stop_funders (opt bool, WS-B Stufe 3: Lebenszyklus "ERREICHT" -> ALLE Beitraege stoppen via
--   fn_stop_savings_goal_funders; Cash-Rate + verknuepfte Sparplaene paused, Ziel + Reserve UNBERUEHRT).
--   RUECKGABE: {ok:true, goal_id, recurring_payment_id, new_monthly_rate, linked_savings_plan_id,
--   paused_cash_rate, paused_plan_count} + optional savings_squeeze (fn_savings_squeeze_fold, nur bei Raten-
--   Aenderung: neu gerechnet, reaktiviert, Topf gewechselt, Beitraege gestoppt) (Post-State-Vertrag: kein Echo der Eingabe
--   reserve_account_id). Korrigierbar (target<=0, Zieldatum nicht in
--   der Zukunft, Ziel bereits gedeckt, reserve==funding, Reserve-Konto kein aktives cash/fixed_deposit-Konto,
--   Status completed/cancelled (-> close_savings_goal), Sparplan nicht gefunden/mehrdeutig, unlink eines
--   nicht-gebundenen Plans, unbekannter status) -> {ok:false}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_savings_goal(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id        INT     := (p->>'goal_id')::int;
    v_target    NUMERIC := NULLIF(p->>'target_amount', '')::numeric;
    v_tdate     DATE;
    v_status    finance.goal_status;   -- Cast erst nach dem Enum-Guard (Import-Haertung)
    v_reason    TEXT    := finance.fn_enum_reason('finance.goal_status'::regtype, p->>'status', 'status');
    v_reserve   INT     := NULLIF(p->>'reserve_account_id', '')::int;  -- WS-A: Reserve-Topf aendern (rate.target_account_id)
    v_funding_reason TEXT;   -- fn_goal_reserve_reason (eine Adresse fuer die Topf-Regeln)
    v_row       finance.savings_goals%ROWTYPE;
    v_saved     NUMERIC;
    v_eff_target NUMERIC;
    v_eff_tdate  DATE;
    v_months    INT;
    v_rate      NUMERIC;
    v_recompute BOOLEAN;
    v_link_name   TEXT := NULLIF(p->>'link_savings_plan_name', '');     -- WS-B2: Sparplan zuordnen
    v_unlink_name TEXT := NULLIF(p->>'unlink_savings_plan_name', '');   -- WS-B2: Sparplan loesen
    v_plan_res    RECORD;
    v_link_plan   INT;   -- validierte Plan-ID zum Verknuepfen (Apply nach den Goal-Writes)
    v_unlink_plan INT;   -- validierte Plan-ID zum Loesen
    v_touched_plan INT;  -- zuletzt ver-/entknuepfter Plan (Return-Handle)
    v_stop_funders BOOLEAN := COALESCE(NULLIF(p->>'stop_funders', '')::boolean, false);  -- WS-B3: alle Beitraege stoppen
    v_stop_res    jsonb;
    v_reopen      jsonb;   -- Audit Paket 2: Folge-rp bei Reaktivierung einer beendeten Rate
    v_dates       JSONB;
BEGIN
    -- relative Datumsangabe ("in 2 years") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['target_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_tdate := NULLIF(p->>'target_date', '')::date;
    SELECT * INTO v_row FROM finance.savings_goals WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Savings goal % not found.', v_id;
    END IF;
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    v_status := NULLIF(p->>'status', '')::finance.goal_status;

    -- Audit Paket 2, Punkt 4: Abschluss nur ueber close_savings_goal (dort das Gate Reserve ~0 oder force).
    IF v_status IN ('completed', 'cancelled') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A savings goal is completed or cancelled with close_savings_goal (it checks the remaining '
                   || 'reserve first), not by changing its status.');
    END IF;

    IF v_target IS NOT NULL AND v_target <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Target amount must be a positive number, got ' || v_target || '.');
    END IF;

    -- WS-A: Reserve-Topf setzen/aendern -> die Sparrate wird (kuenftig) eine Umbuchung in diesen Topf.
    -- Guard reserve<>funding (funding = recurring_payments.account_id, die Soll-Quelle), Wortlaut wie create.
    -- Alte getaggte Buchungen bleiben unberuehrt (nur kuenftiges Routing der Rate aendert sich).
    IF v_reserve IS NOT NULL THEN
        -- Gleiche Regel wie fn_create_savings_goal und das Umschichten (fn_goal_reserve_reason, die eine Adresse):
        -- aktives cash-/Festgeld-Konto, Ziel mit Sparrate, Topf <> Abbuchungskonto.
        v_funding_reason := finance.fn_goal_reserve_reason(v_id, v_reserve);
        IF v_funding_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_funding_reason);
        END IF;
    END IF;

    v_recompute  := (v_target IS NOT NULL OR v_tdate IS NOT NULL);
    v_eff_target := COALESCE(v_target, v_row.target_amount);
    v_eff_tdate  := COALESCE(v_tdate, v_row.target_date);
    v_rate := NULL;

    IF v_recompute THEN
        IF v_eff_tdate <= CURRENT_DATE THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Target date (' || v_eff_tdate || ') must be in the future to recompute a monthly rate.');
        END IF;
        SELECT current_amount INTO v_saved FROM finance.savings_goal_progress WHERE id = v_id;
        v_saved := COALESCE(v_saved, 0);
        IF v_eff_target - v_saved <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Goal is already funded (saved ' || v_saved || ' >= target ' || v_eff_target || '). Consider completing it instead.',
                'current_amount', v_saved);
        END IF;
        -- Rest-Betrag / Rest-Monate (Best Practice: NICHT Gesamt/Gesamt).
        v_months := GREATEST(1, CEIL((v_eff_tdate - CURRENT_DATE) / finance.fn_days_per_month())::int);
        v_rate   := CEIL((v_eff_target - v_saved) / v_months * 100) / 100;
    END IF;

    -- WS-B Stufe 2: Quellen-Verknuepfung VALIDIEREN (vor jedem Write -> {ok:false} bleibt write-frei/atomar).
    -- Sparplan-Name -> ID (inkl. paused: p_active_only=FALSE); 0/>1 = korrigierbar. unlink nur, wenn der Plan
    -- an DIESES Ziel gebunden ist (ein fremd-gebundener Plan bleibt unangetastet).
    IF v_link_name IS NOT NULL THEN
        SELECT r.id, r.hit_count INTO v_plan_res FROM finance.fn_resolve_savings_plan(v_link_name, FALSE) r;
        IF v_plan_res.hit_count = 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'No savings plan found matching "' || v_link_name || '" to link to this goal.');
        END IF;
        IF v_plan_res.hit_count > 1 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Multiple savings plans match "' || v_link_name || '". Please be more specific.',
                'hit_count', v_plan_res.hit_count);
        END IF;
        -- Ein Sparplan gehoert zu EINEM Ziel: ein bereits an ein ANDERES Ziel gebundener Plan wird NICHT
        -- stillschweigend umgehaengt (das waere ein ueberraschender Seiteneffekt). Erst loesen, dann neu binden.
        IF EXISTS (SELECT 1 FROM finance.savings_plans
                   WHERE id = v_plan_res.id AND savings_goal_id IS NOT NULL AND savings_goal_id <> v_id) THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Savings plan "' || v_link_name || '" is already linked to a different goal. Unlink it from that goal first, then link it here.');
        END IF;
        v_link_plan := v_plan_res.id;
    END IF;
    IF v_unlink_name IS NOT NULL THEN
        SELECT r.id, r.hit_count INTO v_plan_res FROM finance.fn_resolve_savings_plan(v_unlink_name, FALSE) r;
        IF v_plan_res.hit_count = 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'No savings plan found matching "' || v_unlink_name || '" to unlink.');
        END IF;
        IF v_plan_res.hit_count > 1 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Multiple savings plans match "' || v_unlink_name || '". Please be more specific.',
                'hit_count', v_plan_res.hit_count);
        END IF;
        IF NOT EXISTS (SELECT 1 FROM finance.savings_plans WHERE id = v_plan_res.id AND savings_goal_id = v_id) THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Savings plan "' || v_unlink_name || '" is not linked to this goal — nothing to unlink.');
        END IF;
        v_unlink_plan := v_plan_res.id;
    END IF;

    UPDATE finance.savings_goals SET
        name          = COALESCE(NULLIF(p->>'name', ''), name),
        target_amount = COALESCE(v_target, target_amount),
        target_date   = COALESCE(v_tdate, target_date),
        status        = COALESCE(v_status, status),
        priority      = COALESCE(NULLIF(p->>'priority', '')::smallint, priority),  -- WS-C1: Engpass-Reihung; leer=unveraendert
        beneficiary_person_id = COALESCE(NULLIF(p->>'beneficiary_person_id', ''), beneficiary_person_id),  -- WS-4: beguenstigte Person (Slug); leer=unveraendert
        notes         = COALESCE(NULLIF(p->>'notes', ''), notes)
    WHERE id = v_id;

    -- Namenskopie 'Sparrate <Name>' an der Raten-Kette mitfuehren (WP2, fn_rename_owned_recurring).
    PERFORM finance.fn_rename_owned_recurring(v_row.recurring_payment_id, 'Sparrate', v_row.name, NULLIF(p->>'name', ''));

    IF v_row.recurring_payment_id IS NOT NULL THEN
        IF v_reserve IS NOT NULL THEN
            -- Rate wird Umbuchung in den Reserve-Topf (fn_book_recurring_occurrence delegiert dann an den Transfer-Pfad);
            -- auf ALLE laufenden Zeilen der Raten-Kette (nach einer Raten-Aenderung laeuft die Vorgaengerzeile weiter).
            PERFORM finance.fn_apply_goal_reserve(v_id, v_reserve);
        END IF;
        IF v_rate IS NOT NULL THEN
            UPDATE finance.recurring_payments SET amount = -v_rate WHERE id = v_row.recurring_payment_id;
        END IF;
        IF v_status = 'active' THEN
            IF EXISTS (SELECT 1 FROM finance.recurring_payments
                       WHERE id = v_row.recurring_payment_id AND valid_to IS NOT NULL AND valid_to <= CURRENT_DATE) THEN
                -- beendete Rate (nach close_savings_goal) -> Folge-rp ab heute; der Helfer setzt das Ziel auf sie.
                v_reopen := finance.fn_reopen_recurring_payment(v_row.recurring_payment_id, CURRENT_DATE);
                IF (v_reopen->>'ok')::boolean IS DISTINCT FROM true THEN
                    RAISE EXCEPTION 'Reopening the savings rate of goal % failed: %', v_id, v_reopen->>'reason';
                END IF;
                v_row.recurring_payment_id := (v_reopen->>'recurring_payment_id')::int;
            ELSE
                UPDATE finance.recurring_payments SET status = 'active' WHERE id = v_row.recurring_payment_id;
            END IF;
        END IF;
    END IF;

    -- WS-B Stufe 2: Quellen-Verknuepfung ANWENDEN (oben validiert). link -> savings_goal_id=Ziel; unlink -> NULL.
    IF v_link_plan IS NOT NULL THEN
        UPDATE finance.savings_plans SET savings_goal_id = v_id WHERE id = v_link_plan;
        v_touched_plan := v_link_plan;
    END IF;
    IF v_unlink_plan IS NOT NULL THEN
        UPDATE finance.savings_plans SET savings_goal_id = NULL WHERE id = v_unlink_plan;
        v_touched_plan := v_unlink_plan;
    END IF;

    -- WS-B Stufe 3: Lebenszyklus "ERREICHT" — auf Wunsch ALLE Beitraege stoppen (Cash-Rate + verknuepfte
    -- Sparplaene + deren rps), Ziel + Reserve UNBERUEHRT ("erreicht != ausgegeben"). Delegiert an die
    -- eigenstaendige fn (eigener db_test); hier nur das Flag durchreichen + Zaehler folden.
    IF v_stop_funders THEN
        v_stop_res := finance.fn_stop_savings_goal_funders(jsonb_build_object('goal_id', v_id));
    END IF;

    RETURN jsonb_build_object('ok', true, 'goal_id', v_id, 'effective', v_dates->'resolved',
        'recurring_payment_id', v_row.recurring_payment_id, 'new_monthly_rate', v_rate,
        'linked_savings_plan_id', v_touched_plan,
        -- Post-State der Funder-Pausierung (kein Input-Echo): was WIRKLICH pausiert wurde. Ohne stop_funders
        -- ist v_stop_res NULL -> COALESCE auf false/0 (nichts gestoppt), nie SQL-NULL im Return-Vertrag.
        'paused_cash_rate',  COALESCE((v_stop_res->>'paused_cash_rate')::boolean, false),
        'paused_plan_count', COALESCE((v_stop_res->>'paused_plan_count')::int, 0))
        -- nur wenn sich die Sparrate aendert (neu gerechnet, reaktiviert, Topf gewechselt, Beitraege gestoppt);
        -- reine Stammdaten-/Notiz-/Sparplan-Link-Edits falten nichts
        || CASE WHEN v_rate IS NOT NULL OR v_status = 'active' OR v_reserve IS NOT NULL OR v_stop_funders
                THEN finance.fn_savings_squeeze_fold() ELSE '{}'::jsonb END;
END;
$$;
