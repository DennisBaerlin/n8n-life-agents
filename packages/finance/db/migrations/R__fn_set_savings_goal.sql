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
--   Eingabe jsonb: goal_id (im n8n aufgeloest), name, target_amount, target_date, status, replace_transfer (opt),
--   beneficiary_person_id (Slug; leer=unveraendert), reserve_account_id (opt, WS-A: Reserve-Topf
--   aendern -> rate.target_account_id; alte getaggte Buchungen bleiben dem Ziel zugeordnet),
--   priority (opt, WS-C1: kleiner = wichtiger; leer=unveraendert), notes,
--   link_savings_plan_name (opt, WS-B Stufe 2: einen Sparplan diesem Ziel ZUORDNEN -> savings_plans.
--   savings_goal_id), unlink_savings_plan_name (opt, WS-B Stufe 2: einen Sparplan vom Ziel LOESEN -> NULL;
--   nur wenn er an DIESES Ziel gebunden ist). Ein Ziel hat 0..N Sparplaene (+ <=1 Cash-Rate); je Aufruf wird
--   EIN Plan ver-/entknuepft. Die Quellen-Validierung laeuft VOR jedem Write -> {ok:false} bleibt write-frei.
--   stop_funders (opt bool, WS-B Stufe 3: Lebenszyklus "ERREICHT" -> ALLE Beitraege stoppen via
--   fn_stop_savings_goal_funders; Cash-Rate + verknuepfte Sparplaene paused, Ziel + Reserve UNBERUEHRT).
--   ZIELE OHNE RATE (Sparziel-Zweckbindung 2026-10-27): ein gedecktes Ziel (Rest <= 0) darf Datum/Betrag aendern ->
--   ok, covered=true, die Rate bleibt unveraendert (kein Rest, nichts neu zu rechnen). Laeuft KEINE Rate und bleibt
--   ein Rest: mit account_id (Abbuchungskonto) legt die fn die Rate an (Umbuchung in reserve_account_id bzw. den
--   abgeleiteten Topf = saldo-basiertes Konto mit dem groessten Anteil des Ziels); ohne -> ok mit code no_rate_running
--   + required_monthly_rate (frueher: new_monthly_rate gerechnet, aber still nicht gespeichert). Finanziert ein aktiver
--   Sparplan das Ziel, gibt es nur required_monthly_rate (keine eigene Rate).
--   BESTEHENDER DAUERAUFTRAG (2026-10-27, wie fn_create_savings_goal): fliesst vom Abbuchungskonto schon ein
--   freistehender Dauerauftrag in den Topf (fn_goal_transfer_candidates) -> ohne replace_transfer {ok:false,
--   code:'existing_transfer', transfers}; replace_transfer=true -> die neue Rate fuehrt ihn fort (sein Monatsbetrag, Tag,
--   naechster Termin; er endet dann, fn_end_recurring_chain), Rueckgabe replaced_transfer_id + required_monthly_rate
--   (falls abweichend) + card_lines (Hinweis); false -> zusaetzliche Rate; nicht monatlich -> code transfer_not_monthly.
--   RUECKGABE: {ok:true, goal_id, recurring_payment_id, new_monthly_rate (nur wenn eine Rate gesetzt/angelegt wurde),
--   covered?, required_monthly_rate?, code?, linked_savings_plan_id, paused_cash_rate, paused_plan_count} + optional
--   savings_squeeze (fn_savings_squeeze_fold, nur bei Raten-Aenderung: neu gerechnet, angelegt, reaktiviert, Topf
--   gewechselt, Beitraege gestoppt) (Post-State-Vertrag: kein Echo der Eingabe reserve_account_id). Korrigierbar
--   (target<=0, Zieldatum nicht in der Zukunft, reserve==funding, Reserve-Konto kein aktives saldo-basiertes Konto,
--   Topf fuer eine neue Rate fehlt, Status completed/cancelled (-> close_savings_goal), Sparplan nicht gefunden/
--   mehrdeutig, unlink eines nicht-gebundenen Plans, unbekannter status) -> {ok:false}.
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
    v_new_acct    INT     := NULLIF(p->>'account_id', '')::int;   -- 2026-10-27: Abbuchungskonto fuer eine NEUE Rate
    v_covered     BOOLEAN := false;
    v_need        NUMERIC;   -- noetige Rate auf dem Rest (auch ohne laufende Rate)
    v_new_pot     INT;       -- Topf einer neu angelegten Rate
    v_new_rp      INT;
    v_first       DATE;
    v_code        TEXT;
    v_has_plan    BOOLEAN;
    v_replace     BOOLEAN := CASE lower(btrim(COALESCE(p->>'replace_transfer', '')))
                                  WHEN 'true' THEN true WHEN 'false' THEN false END;   -- 2026-10-27
    v_cands       JSONB;
    v_old         JSONB;     -- fortgefuehrter Dauerauftrag (fn_goal_transfer_candidates)
    v_old_id      INT;
    v_dom         SMALLINT;
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
        -- aktives saldo-basiertes Konto, Ziel mit Sparrate, Topf <> Abbuchungskonto. Ohne laufende Rate, aber mit
        -- account_id (die Rate entsteht hier): nur die Konto-Regel gegen das neue Abbuchungskonto.
        v_funding_reason := CASE WHEN v_row.recurring_payment_id IS NULL AND v_new_acct IS NOT NULL
                                 THEN finance.fn_goal_reserve_account_reason(v_reserve, v_new_acct)
                                 ELSE finance.fn_goal_reserve_reason(v_id, v_reserve) END;
        IF v_funding_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_funding_reason);
        END IF;
    END IF;

    v_recompute  := (v_target IS NOT NULL OR v_tdate IS NOT NULL);
    v_eff_target := COALESCE(v_target, v_row.target_amount);
    v_eff_tdate  := COALESCE(v_tdate, v_row.target_date);
    v_rate := NULL;

    IF v_recompute OR (v_row.recurring_payment_id IS NULL AND v_new_acct IS NOT NULL) THEN
        IF v_eff_tdate <= CURRENT_DATE THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Target date (' || v_eff_tdate || ') must be in the future to recompute a monthly rate.');
        END IF;
        SELECT current_amount INTO v_saved FROM finance.savings_goal_progress WHERE id = v_id;
        v_saved := COALESCE(v_saved, 0);
        IF v_eff_target - v_saved <= 0 THEN
            v_covered := true;   -- gedeckt: Datum/Betrag aendern ist ok, eine Rate gibt es nicht neu zu rechnen
        ELSE
            -- Rest-Betrag / Rest-Monate (Best Practice: NICHT Gesamt/Gesamt).
            v_months := GREATEST(1, CEIL((v_eff_tdate - CURRENT_DATE) / finance.fn_days_per_month())::int);
            v_need   := CEIL((v_eff_target - v_saved) / v_months * 100) / 100;
        END IF;
    END IF;

    -- Wer bezahlt den Rest? Laufende Rate -> sie wird angepasst. Keine Rate: Sparplan (nur Info), neues Abbuchungskonto
    -- (Rate anlegen; Topf vorab validieren -> {ok:false} bleibt write-frei) oder Hinweis no_rate_running.
    IF v_need IS NOT NULL THEN
        IF v_row.recurring_payment_id IS NOT NULL THEN
            v_rate := v_need;
        ELSE
            -- "laeuft gerade" nur ueber active_recurring_payments (nie payment_status roh, .claude/rules/sql.md)
            v_has_plan := EXISTS (SELECT 1 FROM finance.savings_plans sp
                                  JOIN finance.active_recurring_payments a ON a.id = sp.recurring_payment_id
                                  WHERE sp.savings_goal_id = v_id);
            IF NOT v_has_plan AND v_new_acct IS NOT NULL THEN
                v_new_pot := COALESCE(v_reserve,
                    (SELECT r.account_id FROM finance.fn_goal_reserve_accounts(v_id) r
                      ORDER BY r.share DESC, r.account_id LIMIT 1));
                IF v_new_pot IS NULL THEN
                    RETURN jsonb_build_object('ok', false,
                        'reason', 'Name the savings account the new monthly rate goes to (reserve_account_name: a cash/Tagesgeld, '
                               || 'fixed-deposit or P2P account) - this goal has no money on such an account yet.');
                END IF;
                v_funding_reason := finance.fn_goal_reserve_account_reason(v_new_pot, v_new_acct);
                IF v_funding_reason IS NULL AND NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_new_acct AND status = 'active') THEN
                    v_funding_reason := 'The funding (debit) account must be an active account.';
                END IF;
                IF v_funding_reason IS NOT NULL THEN
                    RETURN jsonb_build_object('ok', false, 'reason', v_funding_reason);
                END IF;
                v_rate := v_need;
                -- Bestehender Dauerauftrag vom Abbuchungskonto in den Topf (wie fn_create_savings_goal, eine Adresse
                -- fn_goal_transfer_candidates): ohne Antwort existing_transfer; true -> die Rate fuehrt ihn fort (sein
                -- Betrag, Tag, naechster Termin), er endet dann; false -> zusaetzliche Rate.
                IF v_replace IS DISTINCT FROM false THEN
                    v_cands := finance.fn_goal_transfer_candidates(v_new_pot, v_new_acct);
                    IF jsonb_array_length(v_cands) > 0 AND v_replace IS NULL THEN
                        RETURN jsonb_build_object('ok', false, 'code', 'existing_transfer', 'transfers', v_cands,
                            'reason', 'A standing transfer from this account already pays into the savings account: '
                                   || (SELECT string_agg('"' || (e->>'name') || '" (' || to_char((e->>'amount')::numeric, 'FM999999990D00')
                                                         || ' ' || (e->>'currency') || ', ' || (e->>'rhythm') || ')', '; ')
                                       FROM jsonb_array_elements(v_cands) e)
                                   || '. Do NOT delete it. Ask the user whether it IS the savings rate of this goal: yes -> '
                                   || 'call again with replace_transfer=true (the goal continues it on the same day); no -> '
                                   || 'replace_transfer=false.');
                    END IF;
                    IF v_replace THEN
                        IF jsonb_array_length(v_cands) <> 1 THEN
                            RETURN jsonb_build_object('ok', false, 'code', 'existing_transfer', 'transfers', v_cands,
                                'reason', CASE WHEN jsonb_array_length(v_cands) = 0
                                               THEN 'There is no standing transfer from this account into the savings account to continue - leave replace_transfer empty.'
                                               ELSE 'Several standing transfers match - ask the user which one.' END);
                        END IF;
                        v_old := v_cands->0;
                        IF (v_old->>'replaceable')::boolean IS DISTINCT FROM true OR v_old->>'next_due' IS NULL THEN
                            RETURN jsonb_build_object('ok', false, 'code', 'transfer_not_monthly',
                                'reason', 'The standing transfer "' || (v_old->>'name') || '" runs ' || (v_old->>'rhythm')
                                       || ' - a savings goal rate is monthly, so it cannot continue it.');
                        END IF;
                        v_rate := (v_old->>'monthly_amount')::numeric;
                    END IF;
                END IF;
            ELSIF NOT v_has_plan THEN
                v_code := 'no_rate_running';
            END IF;
        END IF;
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
    ELSIF v_new_pot IS NOT NULL THEN
        -- Neue Rate fuer ein Ziel ohne Rate (oben validiert): wie fn_create_savings_goal ein Transfer in den Topf, erste
        -- Rate am naechsten Termin des Abbuchungstags ab heute (Raster des Schedulers).
        -- Fortgefuehrter Dauerauftrag: sein Tag + naechster Termin.
        v_dom := NULLIF(p->>'schedule_day_of_month', '')::smallint;
        IF v_old IS NOT NULL THEN
            v_first := (v_old->>'next_due')::date;
            v_dom   := NULLIF(v_old->>'day', '')::smallint;
        ELSE
            SELECT min(d) INTO v_first
            FROM finance.fn_schedule_occurrences(core.fn_today(), 1, 'month', v_dom, NULL, core.fn_today(), core.fn_today() + 62) d;
        END IF;
        v_new_rp := finance.fn_add_recurring_payment(
            v_new_acct, -v_rate, left('Sparrate ' || COALESCE(NULLIF(p->>'name', ''), v_row.name), 100),
            1::smallint, 'month'::finance.schedule_unit, v_dom, v_first,
            finance.fn_recurring_valid_from(v_new_acct, v_first), NULL, NULL, NULL);
        UPDATE finance.recurring_payments SET target_account_id = v_new_pot WHERE id = v_new_rp;
        UPDATE finance.savings_goals SET recurring_payment_id = v_new_rp WHERE id = v_id;
        v_row.recurring_payment_id := v_new_rp;
        -- der fortgefuehrte Dauerauftrag endet am ersten Termin der Rate (nie gueltig + ohne Buchung -> geloescht)
        IF v_old IS NOT NULL THEN
            v_old_id := (v_old->>'id')::int;
            IF v_first <= (SELECT valid_from FROM finance.recurring_payments WHERE id = v_old_id)
               AND NOT EXISTS (SELECT 1 FROM finance.transactions t
                               WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_old_id))) THEN
                DELETE FROM finance.recurring_payments WHERE id = v_old_id;
            ELSE
                PERFORM finance.fn_end_recurring_chain(v_old_id, v_first);
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
        || CASE WHEN v_covered THEN jsonb_build_object('covered', true) ELSE '{}'::jsonb END
        || CASE WHEN v_need IS NOT NULL AND (v_rate IS NULL OR (v_old IS NOT NULL AND v_need <> v_rate))
                THEN jsonb_build_object('required_monthly_rate', v_need) ELSE '{}'::jsonb END
        || CASE WHEN v_old_id IS NOT NULL THEN jsonb_build_object('replaced_transfer_id', v_old_id,
                    'card_lines', jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.goal_replaces_transfer',
                        'params', jsonb_build_object('name', v_old->>'name', 'date', core.fn_ui_date(v_first)))))
                ELSE '{}'::jsonb END
        || CASE WHEN v_code IS NOT NULL THEN jsonb_build_object('code', v_code,
                    'note', 'No monthly rate is running for this goal; it still needs ' || to_char(v_need, 'FM999999990D00')
                            || ' EUR per month. To start one, call again with the account the rate is debited from (account_name).')
                -- gedeckt, aber eine Rate laeuft weiter (Code-Review 2026-10-27): nicht still weiter einzahlen lassen
                WHEN v_covered AND v_row.recurring_payment_id IS NOT NULL AND NOT v_stop_funders
                     AND EXISTS (SELECT 1 FROM finance.active_recurring_payments a
                                 WHERE a.id = ANY (ARRAY(SELECT finance.fn_recurring_lineage(v_row.recurring_payment_id))))
                THEN jsonb_build_object('code', 'covered_rate_running',
                    'note', 'The goal is now covered, but its monthly rate keeps running. Ask the user whether to stop the '
                            || 'contributions (call again with stop_funders=true); the money stays earmarked.')
                ELSE '{}'::jsonb END
        -- nur wenn sich die Sparrate aendert (neu gerechnet, angelegt, reaktiviert, Topf gewechselt, Beitraege gestoppt);
        -- reine Stammdaten-/Notiz-/Sparplan-Link-Edits falten nichts
        || CASE WHEN v_rate IS NOT NULL OR v_status = 'active' OR v_reserve IS NOT NULL OR v_stop_funders
                THEN finance.fn_savings_squeeze_fold() ELSE '{}'::jsonb END;
END;
$$;
