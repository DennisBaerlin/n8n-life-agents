-- ============================================================
-- fn_create_savings_goal (ATOMIC WRITE)
--   Legt in EINER Transaktion an: (1) Sparziel, (2) optional die Zuordnung eines Startbestands (Journal, kind manual,
--   ueber fn_book_savings_reservation), (3) optional die monatliche Sparrate als recurring_payment (Umbuchung in den
--   Topf) ODER die Verknuepfung mit einem Sparplan.
--   RATE/ZIELDATUM RECHNET DIE DB (nicht das LLM, Root-CLAUDE.md *Das LLM rechnet NICHT*): der Nutzer nennt
--   target_amount + GENAU EINES von {target_date, monthly_savings_rate}; fn_savings_rate_schedule leitet die fehlende
--   Groesse auf dem REST ab (Ziel - Startbestand; eine Quelle, auch read-only fuer den HITL-Preview im Tool).
--   MITTELVERWENDUNG ZUERST (Sparziel-Zweckbindung 2026-10-27): ein Ziel braucht nicht zwingend eine Rate. Quellen:
--     * already_saved (opt): Geld, das schon auf dem Topf liegt -> Zuordnung ohne Ueberweisung (saldo-basiert in
--       Kontowaehrung, hoechstens der freie Saldo; Depot in EUR).
--     * Rate (nur fuer den Rest > 0, ohne Sparplan, Topf saldo-basiert): account_id (Abbuchungskonto) ist dann Pflicht.
--     * savings_plan (opt, Name): der Sparplan finanziert das Ziel (seine Kaeufe fuettern die Depot-Reserve); dann KEINE
--       eigene Rate, die Karte zeigt Sparplan-Betrag vs. noetige Rate.
--     Rest <= 0 -> Rate 0, keine recurring_payment, kein Abbuchungskonto noetig (target_date Pflicht).
--   SPARPLAENE (2026-10-27): savings_plan nimmt einen oder mehrere Namen (komma-getrennt; erst der ganze Text als ein
--   Name). Ohne target_date und Rate folgt das Zieldatum aus ihrem Monatsbetrag (aktive Plaene, heute gueltiges Glied,
--   in EUR).
--   BESTEHENDER DAUERAUFTRAG in den Topf (fn_goal_transfer_candidates; Livebefund 2026-10-27): im Raten-Pfad ohne
--   replace_transfer -> {ok:false, code:'existing_transfer', transfers}; replace_transfer=true -> die Ziel-Rate fuehrt
--   ihn fort (sein Konto, Tag, naechster Termin = erste Rate, Betrag = sein Monatsbetrag; bei genanntem Datum zeigt die
--   Karte die noetige Rate), er endet an diesem Tag (fn_goal_end_transfer: offene Termine davor bleiben faellig; nie gueltig + ohne Buchung ->
--   geloescht); Quellen + Rate/Datum aus fn_savings_goal_funding (eine Ableitung mit der Import-Karte);
--   nicht monatlich -> code transfer_not_monthly; replace_transfer=false -> zusaetzliche Rate.
--   Karten-Hinweise (card_lines): aehnliches Ziel, "gedeckt, Rate 0", Sparplan-Betrag vs. noetige Rate, und bei
--   Depot-Topf/Sparplan ein Ziel im Umschicht-Fenster (advisor.derisk_window_months) -> Kursrisiko-Hinweis.
--   Eingabe jsonb: name, goal_type, target_amount, target_date (opt), monthly_savings_rate (opt), already_saved (opt),
--   savings_plan (opt), replace_transfer (opt, true|false), account_id (Abbuchungskonto, in n8n aufgeloest; nur fuer
--   eine Rate), reserve_account_id
--   (PFLICHT: Topf = Konto des Ziel-Geldes; saldo-basiert (fn_goal_pot_account_types) oder ein Depot, Depot nur mit
--   Startbestand/Sparplan), schedule_day_of_month, first_payment_date (opt, WP2: leer = naechster Termin ab heute laut
--   fn_savings_rate_schedule), priority (opt, WS-C1: kleiner = wichtiger), notes,
--   beneficiary_person_id (opt, Slug; leer = Inhaber des Spartopfs, fn_default_beneficiary; Topf ohne Inhaber -> NULL).
--   SPARKONTO-PFLICHT (Audit Paket 3): ohne Topf liefe eine Rate als nackte Abbuchung ins Leere -> Fortschritt 0. Der
--   Topf ist Gesetz in der fn (auch fuer den Import-Pfad), nicht nur im Tool.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, goal_id, recurring_payment_id (NULL ohne Rate), monthly_rate (eigene Rate,
--   0 ohne), target_date, first_payment_date, months (Raten-Monate auf dem Rest), current_amount (Stand nach dem
--   Startbestand, EUR), savings_plan_id (erster verknuepfter Plan, sonst NULL), savings_plan_ids (alle),
--   replaced_transfer_id (fortgefuehrter Dauerauftrag), required_monthly_rate + plan_monthly_amount (Summe; nur mit
--   Sparplan), card_lines, beneficiary_person_id, beneficiary_name (ueber core.fn_household_persons, D10), effective
--   {beneficiary_person_id, first_payment_date, reserve_currency}}
--   + optional savings_squeeze (fn_savings_squeeze_fold).
--   Korrigierbar (Topf fehlt/ungeeignet, Zielbetrag<=0, Startbestand<0 oder mehr als frei, weder Datum noch Rate,
--   Datum vor first_payment, Rate ohne Abbuchungskonto, Rate in ein Depot, Sparplan nicht gefunden/mehrdeutig/schon
--   gebunden) -> {ok:false, reason} OHNE Write (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_create_savings_goal(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_goal_id INT;
    v_rp_id   INT;
    v_sched   JSONB;
    v_sim     TEXT;
    v_rate    NUMERIC;
    v_date    DATE;
    v_acct    INT      := NULLIF(p->>'account_id', '')::int;
    v_reserve INT      := NULLIF(p->>'reserve_account_id', '')::int;   -- WS-A: Ziel-Topf (Reserve-Konto)
    v_saved   NUMERIC  := COALESCE(NULLIF(p->>'already_saved', '')::numeric, 0);
    v_saved_eur NUMERIC;
    v_plan_id INT;
    v_plan_monthly NUMERIC;
    v_rtype   finance.account_type;
    v_rccy    TEXT;
    v_rstatus finance.account_status;
    v_depot   BOOLEAN;
    v_free    NUMERIC;
    v_ear     JSONB;
    v_first   DATE;      -- erste Rate: genannt oder Default aus fn_savings_rate_schedule (WP2)
    v_dom     SMALLINT := NULLIF(p->>'schedule_day_of_month', '')::smallint;
    v_why     TEXT;      -- fn_goal_reserve_account_reason
    v_benef   TEXT     := finance.fn_default_beneficiary(p->>'beneficiary_person_id', v_reserve);  -- genannt > Topf-Inhaber
    v_dates   JSONB;
    v_cur     NUMERIC;
    v_lines   JSONB;
    v_plan_ids   INT[];     -- 2026-10-27: ein oder mehrere Sparplaene (fn_savings_goal_funding)
    v_plan_names TEXT;
    v_old        JSONB;     -- fortgefuehrter Dauerauftrag
    v_old_id     INT;
    v_need       NUMERIC;   -- noetige Rate bei genanntem Datum (nur Karten-Hinweis)
BEGIN
    -- relative Datumsangaben ("in 2 years") -> ISO, damit effective sie fest in den Write nach der Karte traegt
    -- (fn_savings_rate_schedule loest dieselben Keys fuer die Karte auf); nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['target_date', 'first_payment_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    -- WP-2b: fester Buchungstag 1-28, -1 (Monatsletzter) oder -2 (vorletzter Tag); 29/30/31 overflowen kurze Monate.
    IF finance.fn_schedule_dom_reason(v_dom) IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', finance.fn_schedule_dom_reason(v_dom));
    END IF;
    IF v_saved < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'already_saved cannot be negative, got ' || v_saved || '.');
    END IF;
    -- Audit Paket 3: Sparkonto-Pflicht (Gesetz in der fn; Tool + Import pruefen vorab nur als Komfort).
    IF v_reserve IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A savings goal needs a savings account (reserve) where the money is kept - otherwise the '
                   || 'progress cannot be measured. Ask the user which account holds or receives the money '
                   || '(cash/Tagesgeld, fixed deposit, P2P, or a depot with a savings plan), or offer to create one with '
                   || 'tool_create_account first.');
    END IF;
    SELECT account_type, currency, status INTO v_rtype, v_rccy, v_rstatus FROM finance.accounts WHERE id = v_reserve;
    v_depot := v_rtype IN ('stocks_depot', 'crypto_depot');
    IF v_depot THEN
        IF v_rstatus IS DISTINCT FROM 'active' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'The depot of the goal must be an active account.');
        END IF;
    ELSE
        -- Konto-Regel des Topfs (eine Adresse mit set/relocate): aktives saldo-basiertes Konto, nicht das Abbuchungskonto.
        v_why := finance.fn_goal_reserve_account_reason(v_reserve, v_acct);
        IF v_why IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_why);
        END IF;
    END IF;

    -- Startbestand: hoechstens der freie Saldo des Topfs (saldo-basiert; eine Adresse fn_account_free_balance).
    IF v_saved > 0 AND NOT v_depot THEN
        v_free := finance.fn_account_free_balance(v_reserve);
        IF v_saved > COALESCE(v_free, 0) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'insufficient_free_balance',
                'free', round(GREATEST(COALESCE(v_free, 0), 0), 2),
                'reason', 'Only ' || to_char(GREATEST(COALESCE(v_free, 0), 0), 'FM999999990D00') || ' ' || v_rccy
                       || ' on the savings account are not yet earmarked for savings goals - the money already saved '
                       || 'cannot be more than that.');
        END IF;
    END IF;
    -- Sparziele rechnen in EUR: ein Startbestand auf einem Fremdwaehrungs-Topf zaehlt mit seinem EUR-Wert; ohne Kurs
    -- korrigierbar ablehnen statt den nativen Betrag still als EUR zu nehmen.
    v_saved_eur := CASE WHEN v_depot OR v_saved = 0 THEN v_saved ELSE finance.fn_to_eur(v_saved, v_rccy) END;
    IF v_saved_eur IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'No exchange rate for ' || v_rccy || ' yet - the money already saved cannot be valued in EUR. Try again later.');
    END IF;

    -- Quellen + Rate/Zieldatum: EINE Ableitung mit der Import-Karte (fn_savings_goal_funding): Sparplaene (einer oder
    -- mehrere, Datum aus ihrem Monatsbetrag), ein bestehender Dauerauftrag in den Topf (existing_transfer /
    -- replace_transfer, VOR jeder anderen Raten-Pruefung), dann fn_savings_rate_schedule auf dem Rest.
    v_sched := finance.fn_savings_goal_funding(p, v_reserve, v_depot, v_acct, v_saved_eur);
    IF (v_sched->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_sched;   -- {ok:false, reason[, code]} unveraendert durchreichen
    END IF;
    v_rate  := (v_sched->>'monthly_rate')::numeric;
    v_need  := (v_sched->>'needed_rate')::numeric;
    v_date  := (v_sched->>'target_date')::date;
    v_first := (v_sched->>'first_payment_date')::date;
    v_acct  := (v_sched->>'account_id')::int;
    v_dom   := (v_sched->>'schedule_day_of_month')::smallint;
    v_old   := CASE WHEN jsonb_typeof(v_sched->'transfer') = 'object' THEN v_sched->'transfer' END;
    IF jsonb_typeof(v_sched->'plan_ids') = 'array' THEN
        v_plan_ids := ARRAY(SELECT x::int FROM jsonb_array_elements_text(v_sched->'plan_ids') x);
    END IF;
    v_plan_id      := v_plan_ids[1];
    v_plan_names   := v_sched->>'plan_names';
    v_plan_monthly := (v_sched->>'plan_monthly')::numeric;

    -- Eigene Rate nur fuer einen Rest > 0 ohne Sparplan: sie fliesst in einen saldo-basierten Topf, vom Abbuchungskonto.
    IF v_rate > 0 AND v_plan_id IS NULL THEN
        IF v_depot THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'A monthly rate cannot be paid into a depot directly. Link the savings plan that buys into it '
                       || '(savings_plan), or choose a cash/Tagesgeld, fixed-deposit or P2P account as the savings account.');
        END IF;
        IF v_acct IS NULL OR NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_acct AND status = 'active') THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'The goal still needs ' || to_char(v_rate, 'FM999999990D00') || ' EUR per month. Ask the user from '
                       || 'which account the monthly rate is debited (an active account), or whether money that already '
                       || 'lies on an account belongs to the goal.');
        END IF;
    END IF;

    -- Karten-Hinweis (hohe Schwelle): aktives Sparziel mit gleichem Zielbetrag und gleichem Zieldatum
    SELECT g.name INTO v_sim FROM finance.savings_goals g
     WHERE g.status = 'active' AND g.target_amount = NULLIF(p->>'target_amount', '')::numeric AND g.target_date = v_date
     ORDER BY g.id LIMIT 1;

    -- 1. Sparziel (target_date = vom Helper aufgeloest, egal ob genannt oder berechnet)
    INSERT INTO finance.savings_goals
        (name, goal_type, target_amount, target_date, status, priority, notes, beneficiary_person_id)
    VALUES (
        p->>'name',
        NULLIF(p->>'goal_type', ''),
        (p->>'target_amount')::numeric,
        v_date,
        'active',
        NULLIF(p->>'priority', '')::smallint,     -- WS-C1: Engpass-Reihung (kleiner = wichtiger; leer=NULL=unpriorisiert)
        NULLIF(p->>'notes', ''),
        v_benef                                   -- WS-4: genannte Person, sonst Topf-Inhaber; NULL=Haushalt. FK->agent.persons.
    )
    RETURNING id INTO v_goal_id;

    -- 2. Startbestand zuordnen (dieselbe fn wie die spaetere Zuordnung; der Guard oben hat ihn schon geprueft).
    IF v_saved > 0 THEN
        v_ear := finance.fn_book_savings_reservation(jsonb_build_object(
            'savings_goal_id', v_goal_id, 'account_id', v_reserve, 'amount', v_saved));
        IF (v_ear->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'Earmarking the starting amount of savings goal % failed: %', v_goal_id, v_ear->>'reason';
        END IF;
    END IF;

    -- 3a. Sparrate als recurring_payment (monatlich, negativ = Ausgabe vom Konto) via gemeinsamen Helper; WS-A: die
    --     Rate ist eine UMBUCHUNG in den Topf (fn_book_recurring_transfer bucht zwei-beinig und stempelt savings_goal_id
    --     aufs Haben-Bein -> Fortschritt = Topf-Anteil).
    IF v_rate > 0 AND v_plan_id IS NULL THEN
        v_rp_id := finance.fn_add_recurring_payment(
            v_acct, -v_rate, left('Sparrate ' || (p->>'name'), 100),
            1::smallint, 'month'::finance.schedule_unit, v_dom, v_first, finance.fn_recurring_valid_from(v_acct, v_first), NULL, NULL, NULL);
        UPDATE finance.savings_goals SET recurring_payment_id = v_rp_id WHERE id = v_goal_id;
        UPDATE finance.recurring_payments SET target_account_id = v_reserve WHERE id = v_rp_id;
        -- Fortgefuehrter Dauerauftrag endet am ersten Termin der Ziel-Rate (Historie + Buchungen bleiben); hat er nie
        -- gegolten und keine Buchung, verschwindet er ganz (keine leere Zeile).
        IF v_old IS NOT NULL THEN
            v_old_id := (v_old->>'id')::int;
            PERFORM finance.fn_goal_end_transfer(v_old_id, v_first);
        END IF;
    END IF;

    -- 3b. Sparplaene verknuepfen: ihre Kaeufe fuettern die Depot-Reserve des Ziels (fn_book_stock_buy).
    IF v_plan_ids IS NOT NULL THEN
        UPDATE finance.savings_plans SET savings_goal_id = v_goal_id WHERE id = ANY (v_plan_ids);
    END IF;

    SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal_id;
    v_lines := finance.fn_similar_note(v_sim)
        || CASE WHEN v_rate = 0 THEN jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.goal_covered'))
                ELSE '[]'::jsonb END
        -- Sparplaene vs. noetige Rate nur, wenn sie abweichen (Datum oder Rate genannt); ein aus den Plaenen
        -- abgeleitetes Datum braucht keinen Vergleich.
        || CASE WHEN v_plan_ids IS NOT NULL AND v_rate > 0 AND v_rate <> v_plan_monthly THEN jsonb_build_array(jsonb_build_object(
                    'kind', 'note', 'value', 'finance.note.goal_plan_rate',
                    'params', jsonb_build_object('plan', v_plan_names, 'monthly', core.fn_ui_money(COALESCE(v_plan_monthly, 0)),
                                                 'needed', core.fn_ui_money(v_rate))))
                ELSE '[]'::jsonb END
        -- Fortgefuehrter Dauerauftrag: was mit ihm geschieht + (bei genanntem Datum) welche Rate noetig waere.
        || CASE WHEN v_old IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
                    'kind', 'note', 'value', 'finance.note.goal_replaces_transfer',
                    'params', jsonb_build_object('name', v_old->>'name', 'date', core.fn_ui_date(v_first))))
                ELSE '[]'::jsonb END
        || CASE WHEN v_old IS NOT NULL AND v_need IS NOT NULL AND v_need <> v_rate THEN jsonb_build_array(jsonb_build_object(
                    'kind', 'note', 'value', 'finance.note.goal_transfer_rate',
                    'params', jsonb_build_object('name', v_old->>'name', 'monthly', core.fn_ui_money(v_rate),
                                                 'needed', core.fn_ui_money(v_need))))
                ELSE '[]'::jsonb END
        -- Umschicht-Fenster (2026-10-27): Depot-Geld oder Sparplan fuer ein Ziel, das schon im Glide-Path-Fenster liegt
        -- (Config advisor.derisk_window_months, wie fn_savings_goal_derisk_status) -> Hinweis auf das Kursrisiko.
        || CASE WHEN (v_depot OR v_plan_id IS NOT NULL)
                     AND v_date <= (current_date + make_interval(months =>
                         GREATEST(COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_window_months'), '')::int, 60), 1)))::date
                THEN jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.goal_derisk_window',
                         'params', jsonb_build_object('date', core.fn_ui_date(v_date))))
                ELSE '[]'::jsonb END;

    -- Phase L WS-4: Ueber-Spar-Sofort-Hinweis (Event-Fold, geteilter Helfer fn_savings_squeeze_fold). ERST HIER —
    -- nach dem target_account_id-UPDATE ist die Rate als Sparen in monthly_cashflow_summary. Auch bei schon
    -- bestehendem Pflicht-Defizit (frei < 0) warnt der Helfer - die neue Rate vertieft es; diese fn faltet kein
    -- cashflow_coverage, sonst bliebe die Anlage ohne jeden Hinweis.
    RETURN jsonb_build_object('ok', true, 'goal_id', v_goal_id, 'recurring_payment_id', v_rp_id,
        'monthly_rate', CASE WHEN v_rp_id IS NOT NULL THEN v_rate ELSE 0 END,
        'target_date', v_date, 'first_payment_date', v_first, 'months', (v_sched->>'months')::int,
        'current_amount', round(COALESCE(v_cur, 0), 2),
        'savings_plan_id', v_plan_id,
        'savings_plan_ids', to_jsonb(v_plan_ids),
        'replaced_transfer_id', v_old_id,
        'card_lines', v_lines,
        'beneficiary_person_id', v_benef,
        'beneficiary_name', (SELECT hp.full_name FROM core.fn_household_persons() hp WHERE hp.person_id = v_benef),
        -- effective geht fest in den echten Write (New-FnWriteGate): erste Rate, wie die Karte sie zeigt (auch nach
        -- Mitternacht); Waehrung des Startbestands fuer die Karte (Depot-Zuordnung = EUR, sonst Kontowaehrung).
        'effective', (v_dates->'resolved') || jsonb_strip_nulls(jsonb_build_object('beneficiary_person_id', v_benef,
                         'first_payment_date', to_char(v_first, 'YYYY-MM-DD'),
                         -- erste Rate weder genannt noch vom Dauerauftrag -> Karte markiert sie als Vorgabe
                         'first_payment_defaulted', (v_sched->>'first_defaulted')::boolean,
                         'reserve_currency', CASE WHEN v_depot THEN 'EUR' ELSE v_rccy END,
                         -- fortgefuehrter Dauerauftrag: Abbuchungskonto + Tag fuer die Karte ('' statt NULL, damit kein
                         -- genannter Tag aus Start durchscheint; die fn leitet beide im Write erneut gleich ab)
                         'account_name', CASE WHEN v_old IS NOT NULL THEN (SELECT a.name FROM finance.accounts a WHERE a.id = v_acct) END,
                         'schedule_day_of_month', CASE WHEN v_old IS NOT NULL THEN COALESCE(v_dom::text, '') END)))
        || CASE WHEN v_plan_id IS NOT NULL
                THEN jsonb_build_object('required_monthly_rate', v_rate, 'plan_monthly_amount', v_plan_monthly)
                ELSE '{}'::jsonb END
        || finance.fn_savings_squeeze_fold();
END;
$$;
