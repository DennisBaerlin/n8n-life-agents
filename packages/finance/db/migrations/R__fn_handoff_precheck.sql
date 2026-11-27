-- ============================================================
-- fn_handoff_precheck (READ, STABLE) -- Vorpruefung eines vereinbarten Plan-Eintrags: fertiger Aufruf oder klarer Grund
--   Registry-Feld core.advisors.handoff_check_fn (Signatur (jsonb) -> jsonb). Aufrufer: agent.fn_advisor_save_section beim
--   Vereinbaren (mode agree, je Eintrag im Probelauf) und core.fn_handoff_register (mode recheck).
--   Beim Eintragen wird damit nichts mehr entschieden: der Aufruf ist geprueft, Wahl und Aufteilung sind beim Vereinbaren
--   geklaert, das Modell rechnet nicht.
--   Eingabe p: {mode agree|recheck, kind, payload, option?, wanted?} (domain, chat_id, text, task_id, status werden nicht
--   gebraucht). payload = Werkzeug-Eingabe in der Form von finance.fn_handoff_tool_spec (Namen, nie Kennungen), dazu
--   optional tool (Werkzeug-Schluessel; sonst aus kind und Ziel-Feld abgeleitet) und die Plan-Felder until_amount (Raten bis
--   zu diesem Gesamtbetrag) und, nur bei kind savings_goal, schedule_unit/schedule_interval (Rhythmus der Quelle).
--   recheck: wanted (falls gesetzt, auch eine Liste) bzw. payload wird erneut geprueft. Fuer eine erledigte Aufgabe reicht
--   core.fn_handoff_register als wanted nur die vereinbarten Aufrufe, zu denen noch nichts eingetragen ist.
--   Rueckgabe:
--     {ok:true, call:{tool, input}} | {ok:true, calls:[…]} (Namen der eindeutig gefundenen Sachen; relative Daten beim
--       Vereinbaren zu ISO aufgeloest, damit das Soll fest bleibt) | {ok:true} (kind other ohne Werkzeug-Felder).
--     {ok:true, unsupported:true, blocked_code, call? | calls?, reason} "geht noch nicht": target_missing (Sache gibt es nicht;
--       Wahl und Aufteilung eines "bis Betrag" sind dann trotzdem schon geklaert, das Soll traegt nie until_amount),
--       tool_missing (Werkzeug passt nicht zur Art), goal_irregular_payments (Sparziel aus nicht monatlicher Quelle),
--       pay_until_amount (bis Betrag ohne monatlichen Rhythmus), end_date_future (Ende beim Anlegen eines Sparplans).
--       call = das Soll, soweit baubar (wird als wanted gespeichert und im recheck erneut geprueft; bei
--       goal_irregular_payments mit schedule_unit/schedule_interval).
--     {ok:false, code:'handoff_ref_ambiguous', field, candidates:[{id, label}], reason}
--     {ok:false, code:'handoff_not_enterable', missing:[…] | unknown:[…], reason} (missing 'change' = Aenderung ohne Feld)
--     {ok:false, code:'handoff_choice_needed', options:[{key, label_key, params, calls, recommended, reason_key}], reason} mit
--       genau einer empfohlenen; erneut mit option:<key>.
--   Namen: finance.fn_handoff_resolve_ref. Tests: tests/db/finance/test_fn_handoff_precheck.sql
-- ============================================================

-- fn_handoff_resolve_ref: ein Name einer Werkzeug-Eingabe -> {hits, name, candidates:[{id, label}]}. Arten: account, savings_goal,
-- savings_plan, recurring_payment, pension, insurance, loan (die letzten beiden nur fuer das Abhaken, finance.fn_cancel_handoff_task). Erst der Aufloeser des
-- Werkzeugs (exakt, dann ohne Gross-/Kleinschreibung), bei 0 Treffern Teil-Namen unter aktiven Sachen derselben Art.
-- Konten eines Kindes (core.fn_household_persons role child) sind nie Teil-Namen-Kandidat: Geld der Kinder nur bei genauer
-- Nennung. name = gespeicherter Name bei genau einem Treffer.
CREATE OR REPLACE FUNCTION finance.fn_handoff_resolve_ref(p_type text, p_name text, p_account_types text[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_n    int;
    v_c    jsonb;
    v_q    text := lower(btrim(COALESCE(p_name, '')));
BEGIN
    IF p_type = 'account' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_account(p_name, p_account_types) r;
    ELSIF p_type = 'savings_goal' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_savings_goal(p_name, TRUE) r;
    ELSIF p_type = 'savings_plan' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_savings_plan(p_name, TRUE) r;
    ELSIF p_type = 'recurring_payment' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_recurring_payment(p_name, FALSE) r;
    ELSIF p_type = 'pension' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_pension(p_name, TRUE) r;
    ELSIF p_type = 'insurance' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_insurance(p_name, TRUE) r;
    ELSIF p_type = 'loan' THEN
        SELECT r.hit_count, r.candidates INTO v_n, v_c FROM finance.fn_resolve_loan(p_name, FALSE) r;
    END IF;
    IF COALESCE(v_n, 0) = 0 AND v_q <> '' THEN
        IF p_type = 'account' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name,
                       'label', finance.fn_account_label(a.emoji, a.account_type, a.name)) ORDER BY a.id), '[]'::jsonb)
              INTO v_n, v_c
              FROM finance.accounts a
             WHERE a.status = 'active' AND strpos(lower(a.name), v_q) > 0
               AND (p_account_types IS NULL OR a.account_type::text = ANY (p_account_types))
               AND NOT EXISTS (SELECT 1 FROM core.fn_household_persons() hp
                                WHERE hp.person_id = a.owner_person_id AND hp.role = 'child');
        ELSIF p_type = 'savings_goal' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name) ORDER BY g.id), '[]'::jsonb)
              INTO v_n, v_c FROM finance.savings_goals g WHERE g.status = 'active' AND strpos(lower(g.name), v_q) > 0;
        ELSIF p_type = 'savings_plan' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', sp.id, 'name', sp.name) ORDER BY sp.id), '[]'::jsonb)
              INTO v_n, v_c FROM finance.savings_plans sp WHERE sp.status = 'active' AND strpos(lower(sp.name), v_q) > 0;
        ELSIF p_type = 'recurring_payment' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name) ORDER BY r.id), '[]'::jsonb)
              INTO v_n, v_c FROM finance.recurring_payments r
             WHERE strpos(lower(r.name), v_q) > 0
               AND NOT EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = r.id);
        ELSIF p_type = 'pension' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', pe.id, 'name', pe.name) ORDER BY pe.id), '[]'::jsonb)
              INTO v_n, v_c FROM finance.pension pe WHERE pe.status = 'active' AND strpos(lower(pe.name), v_q) > 0;
        ELSIF p_type = 'insurance' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name) ORDER BY i.id), '[]'::jsonb)
              INTO v_n, v_c FROM finance.insurances i WHERE i.status = 'active' AND strpos(lower(i.name), v_q) > 0;
        ELSIF p_type = 'loan' THEN
            SELECT count(*), COALESCE(jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name) ORDER BY l.id), '[]'::jsonb)
              INTO v_n, v_c FROM finance.loans l WHERE strpos(lower(l.name), v_q) > 0;
        END IF;
    END IF;
    RETURN jsonb_build_object('hits', COALESCE(v_n, 0),
        'name', CASE WHEN v_n = 1 THEN v_c->0->>'name' END,
        'candidates', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', COALESCE(x->>'id', x->>'loan_id')::int, 'label', COALESCE(x->>'label', x->>'name')))
                                  FROM jsonb_array_elements(v_c) x), '[]'::jsonb));
END;
$$;

-- fn_handoff_check_call: Pruefung eines Eintrags (Art, Werkzeug-Eingabe, Wahl) -> Rueckgabe-Vertrag oben. Eigene fn, weil der
-- recheck eine Liste von Aufrufen einzeln prueft.
CREATE OR REPLACE FUNCTION finance.fn_handoff_check_call(p_kind text, p_payload jsonb, p_option text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_spec   jsonb := finance.fn_handoff_tool_spec();
    v_pl     jsonb := CASE WHEN jsonb_typeof(p_payload) = 'object' THEN p_payload ELSE '{}'::jsonb END;
    v_tool   text := NULLIF(btrim(COALESCE(v_pl->>'tool', '')), '');
    v_s      jsonb;
    v_in     jsonb;
    v_unit   text;
    v_ival   text;
    v_until  numeric;
    v_miss   text[] := '{}';
    v_unk    text[];
    v_f      text;
    v_g      jsonb;
    v_ref    jsonb;
    v_res    jsonb;
    v_amt    numeric;
    v_first  date;
    v_dom    smallint;
    v_n      int;
    v_rest   numeric;
    v_dates  date[];
    v_main   jsonb;
    v_opts   jsonb;
    v_chosen jsonb;
    v_cur    text;
    v_gone   jsonb := '{}'::jsonb;   -- "geht noch nicht", solange eine genannte Sache fehlt; haengt am fertigen Ergebnis
BEGIN
    -- Werkzeug: genannt (muss zur Art passen) oder abgeleitet
    IF v_tool IS NOT NULL THEN
        v_s := v_spec->v_tool;
        IF v_s IS NULL OR NOT (v_s->'kinds' ? p_kind) THEN
            RETURN jsonb_build_object('ok', true, 'unsupported', true, 'blocked_code', 'tool_missing',
                'reason', format('No tool can enter "%s" for an entry of kind %s.', v_tool, p_kind));
        END IF;
    ELSIF p_kind = 'other' THEN
        v_tool := CASE WHEN NULLIF(btrim(COALESCE(v_pl->>'pension_name', '')), '') IS NOT NULL THEN 'set_pension'
                       WHEN NULLIF(btrim(COALESCE(v_pl->>'pension_type', '')), '') IS NOT NULL
                         OR NULLIF(btrim(COALESCE(v_pl->>'name', '')), '') IS NOT NULL THEN 'create_pension' END;
        IF v_tool IS NULL THEN
            RETURN jsonb_build_object('ok', true);
        END IF;
    ELSE
        v_tool := CASE p_kind
            -- nur ein genau benanntes Ziel wird geaendert; ein Teil-Name traefe sonst ein anderes Ziel. Auch mit neuem Topf
            -- (reserve_account_name) bleibt es eine Aenderung: ein zweites Ziel gleichen Namens lehnte das Anlegen ab
            WHEN 'savings_goal' THEN CASE WHEN (SELECT r.hit_count FROM finance.fn_resolve_savings_goal(v_pl->>'goal_name', TRUE) r) > 0
                                          THEN 'set_savings_goal' ELSE 'create_savings_goal' END
            WHEN 'savings_plan' THEN CASE WHEN v_pl ? 'savings_plan_name' THEN 'set_savings_plan' ELSE 'create_savings_plan' END
            WHEN 'recurring_payment' THEN CASE WHEN v_pl ? 'payment_name' THEN 'set_recurring_payment' ELSE 'create_recurring_payment' END
            WHEN 'recurring_transfer' THEN CASE WHEN v_pl ? 'payment_name' THEN 'set_recurring_payment' ELSE 'create_recurring_transfer' END
        END;
        IF v_tool IS NULL THEN
            RETURN jsonb_build_object('ok', true, 'unsupported', true, 'blocked_code', 'tool_missing',
                'reason', format('No tool enters entries of kind %s.', p_kind));
        END IF;
    END IF;
    v_s  := v_spec->v_tool;
    v_in := v_pl - 'tool' - 'until_amount';
    v_until := CASE WHEN (v_pl->>'until_amount') ~ '^[0-9]+(\.[0-9]+)?$' THEN (v_pl->>'until_amount')::numeric END;
    -- relative Daten ("in 2 years") werden beim Vereinbaren fest: das Soll darf nicht mit jedem Tag wandern, sonst
    -- meldete finance.fn_handoff_diff einen korrekt eingetragenen Termin am naechsten Tag als Abweichung
    FOR v_f IN SELECT k FROM jsonb_object_keys(v_in) k
                WHERE k IN ('first_payment_date', 'valid_from', 'valid_to', 'target_date', 'effective_from',
                            'retirement_start_date', 'value_updated_at') LOOP
        IF core.fn_resolve_date(v_in->>v_f) IS NOT NULL THEN
            v_in := v_in || jsonb_build_object(v_f, core.fn_resolve_date(v_in->>v_f)::text);
        END IF;
    END LOOP;

    -- Plan-Felder, die kein Werkzeug kennt
    IF p_kind = 'savings_goal' THEN
        v_unit := lower(btrim(COALESCE(v_in->>'schedule_unit', 'month')));
        v_ival := btrim(COALESCE(v_in->>'schedule_interval', '1'));
        IF v_unit <> 'month' OR v_ival <> '1' THEN
            -- der Rhythmus bleibt im Soll: der recheck darf ein vierteljaehrliches Ziel nie als monatliches durchlassen
            RETURN jsonb_build_object('ok', true, 'unsupported', true, 'blocked_code', 'goal_irregular_payments',
                'call', jsonb_build_object('tool', v_tool, 'input', v_in),
                'reason', 'A savings goal can only be funded by a monthly rate so far.');
        END IF;
        v_in := v_in - 'schedule_unit' - 'schedule_interval';
    END IF;
    IF v_tool = 'create_savings_plan' AND NULLIF(btrim(COALESCE(v_in->>'valid_to', '')), '') IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'unsupported', true, 'blocked_code', 'end_date_future',
            'call', jsonb_build_object('tool', v_tool, 'input', v_in),
            'reason', 'A new savings plan cannot carry its end yet; it can be set once the plan exists.');
    END IF;

    -- Form: fremde Felder, Pflichtfelder
    SELECT array_agg(k ORDER BY k) INTO v_unk FROM jsonb_object_keys(v_in) k WHERE NOT (v_s->'inputs' ? k);
    IF v_unk IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_enterable', 'unknown', to_jsonb(v_unk),
            'reason', format('Fields not known to %s: %s. Valid fields: %s.', v_tool, array_to_string(v_unk, ', '),
                             (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_s->'inputs') x)));
    END IF;
    v_in := (SELECT COALESCE(jsonb_object_agg(key, value), '{}'::jsonb) FROM jsonb_each(v_in)
              WHERE value <> 'null'::jsonb AND btrim(value #>> '{}') <> '');
    FOR v_f IN SELECT jsonb_array_elements_text(v_s->'required') LOOP
        IF NOT (v_in ? v_f) THEN v_miss := v_miss || v_f; END IF;
    END LOOP;
    FOR v_g IN SELECT jsonb_array_elements(COALESCE(v_s->'one_of', '[]'::jsonb)) LOOP
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_g) x WHERE v_in ? x) THEN
            v_miss := v_miss || (SELECT string_agg(x, '|') FROM jsonb_array_elements_text(v_g) x);
        END IF;
    END LOOP;
    FOR v_f, v_g IN SELECT key, value FROM jsonb_each(COALESCE(v_s->'requires_if', '{}'::jsonb)) LOOP
        IF v_in ? v_f THEN
            v_miss := v_miss || ARRAY(SELECT x FROM jsonb_array_elements_text(v_g) x WHERE NOT (v_in ? x));
        END IF;
    END LOOP;
    IF v_s ? 'target' AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v_in) k WHERE k NOT IN (v_s->>'target', 'notes')) THEN
        v_miss := v_miss || 'change'::text;
    END IF;
    IF cardinality(v_miss) > 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_enterable', 'missing', to_jsonb(v_miss),
            'reason', format('This entry cannot be made with one tap yet; missing: %s. Ask the user now, while agreeing it.',
                             array_to_string(v_miss, ', ')));
    END IF;

    -- Namen: eindeutig -> gespeicherter Name; mehrdeutig -> Rueckfrage; fehlt -> geht noch nicht
    FOR v_f, v_ref IN SELECT key, value FROM jsonb_each(COALESCE(v_s->'refs', '{}'::jsonb)) LOOP
        CONTINUE WHEN NOT (v_in ? v_f);
        v_res := finance.fn_handoff_resolve_ref(v_ref->>'type', v_in->>v_f,
                     CASE WHEN v_ref ? 'account_types' THEN ARRAY(SELECT jsonb_array_elements_text(v_ref->'account_types')) END);
        IF (v_res->>'hits')::int > 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_ref_ambiguous', 'field', v_f, 'candidates', v_res->'candidates',
                'reason', format('"%s" (%s) matches %s entries. Ask the user which one, with the candidates as buttons.',
                                 v_in->>v_f, v_f, v_res->>'hits'));
        ELSIF (v_res->>'hits')::int = 0 THEN
            -- nicht sofort zurueck: Wahl und Aufteilung ("bis Betrag") werden trotzdem jetzt geklaert, damit das Soll fertige
            -- Aufrufe traegt und der recheck sie liefert, sobald die Sache existiert (der genannte Name bleibt stehen)
            IF v_gone = '{}'::jsonb THEN
                v_gone := jsonb_build_object('unsupported', true, 'blocked_code', 'target_missing',
                    'reason', format('"%s" (%s) does not exist yet; the entry waits until it does.', v_in->>v_f, v_f));
            END IF;
            CONTINUE;
        END IF;
        v_in := v_in || jsonb_build_object(v_f, v_res->>'name');
    END LOOP;

    IF v_until IS NULL THEN
        IF v_pl ? 'until_amount' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_not_enterable', 'missing', jsonb_build_array('until_amount'),
                'reason', 'until_amount must be a positive number.');
        END IF;
        RETURN jsonb_build_object('ok', true, 'call', jsonb_build_object('tool', v_tool, 'input', v_in)) || v_gone;
    END IF;

    -- Raten bis zu einem Gesamtbetrag: die DB rechnet Anzahl, Ende und Rest
    v_amt   := CASE WHEN (v_in->>'amount') ~ '^[0-9]+(\.[0-9]+)?$' THEN (v_in->>'amount')::numeric END;
    v_first := core.fn_resolve_date(v_in->>'first_payment_date');
    IF v_tool NOT IN ('create_recurring_transfer', 'create_recurring_payment')
       OR lower(COALESCE(v_in->>'schedule_unit', '')) <> 'month' OR COALESCE(v_in->>'schedule_interval', '1') <> '1'
       OR v_amt IS NULL OR v_amt <= 0 OR v_until <= 0 OR v_first IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'unsupported', true, 'blocked_code', 'pay_until_amount',
            'reason', 'Payments up to a total can only be split for a new monthly payment with an amount and a start date.');
    END IF;
    v_dom := CASE WHEN (v_in->>'schedule_day_of_month') ~ '^-?[0-9]+$' THEN (v_in->>'schedule_day_of_month')::smallint END;
    v_first := finance.fn_schedule_first_occurrence(v_first, 1, 'month', v_dom, NULL);
    v_n    := floor(v_until / v_amt)::int;
    v_rest := v_until - v_n * v_amt;
    SELECT array_agg(d ORDER BY d) INTO v_dates
      FROM (SELECT d FROM finance.fn_schedule_occurrences(v_first, 1, 'month', v_dom, NULL, v_first,
                                                            (v_first + make_interval(months => v_n + 2))::date) d
             ORDER BY d LIMIT v_n + 1) o;
    v_in := v_in || jsonb_build_object('first_payment_date', v_first::text);
    SELECT a.currency INTO v_cur FROM finance.accounts a
     WHERE a.name = COALESCE(v_in->>'from_account_name', v_in->>'account_name') AND a.status = 'active' ORDER BY a.id LIMIT 1;
    IF v_n = 0 THEN
        RETURN jsonb_build_object('ok', true, 'call', jsonb_build_object('tool', v_tool,
            'input', v_in || jsonb_build_object('amount', v_until, 'valid_to', v_first::text))) || v_gone;
    END IF;
    v_main := jsonb_build_object('tool', v_tool, 'input', v_in || jsonb_build_object('valid_to', v_dates[v_n]::text));
    IF v_rest = 0 THEN
        RETURN jsonb_build_object('ok', true, 'call', v_main) || v_gone;
    END IF;
    v_opts := jsonb_build_array(
        jsonb_build_object('key', 'rest_once', 'recommended', true,
            'label_key', 'finance.handoff.option.rest_once', 'reason_key', 'finance.handoff.option.rest_once_why',
            'params', jsonb_build_object('n', v_n, 'amount', core.fn_ui_money(v_amt, v_cur), 'rest', core.fn_ui_money(v_rest, v_cur),
                                    'rest_date', core.fn_ui_date(v_dates[v_n + 1]), 'total', core.fn_ui_money(v_until, v_cur)),
            'calls', jsonb_build_array(v_main, jsonb_build_object('tool', v_tool, 'input', v_in || jsonb_build_object(
                'amount', v_rest, 'first_payment_date', v_dates[v_n + 1]::text, 'valid_to', v_dates[v_n + 1]::text)))),
        jsonb_build_object('key', 'full_rates', 'recommended', false,
            'label_key', 'finance.handoff.option.full_rates', 'reason_key', 'finance.handoff.option.full_rates_why',
            'params', jsonb_build_object('n', v_n + 1, 'amount', core.fn_ui_money(v_amt, v_cur),
                                    'over', core.fn_ui_money((v_n + 1) * v_amt - v_until, v_cur), 'total', core.fn_ui_money(v_until, v_cur)),
            'calls', jsonb_build_array(jsonb_build_object('tool', v_tool,
                'input', v_in || jsonb_build_object('valid_to', v_dates[v_n + 1]::text)))));
    SELECT o INTO v_chosen FROM jsonb_array_elements(v_opts) o WHERE o->>'key' = p_option;
    IF v_chosen IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'calls', v_chosen->'calls') || v_gone;
    END IF;
    RETURN jsonb_build_object('ok', false, 'code', 'handoff_choice_needed', 'options', v_opts,
        'reason', 'The total is not a multiple of the rate. Ask the user with the options as buttons, the recommended one first, '
               || 'and its reason in one sentence; then save again with option set to the chosen key.');
END;
$$;

CREATE OR REPLACE FUNCTION finance.fn_handoff_precheck(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_kind  text := p->>'kind';
    v_w     jsonb := p->'wanted';
    v_c     jsonb;
    v_r     jsonb;
    v_calls jsonb := '[]'::jsonb;
BEGIN
    IF COALESCE(p->>'mode', 'agree') = 'recheck' THEN
        IF jsonb_typeof(v_w) IN ('object', 'array') THEN
            FOR v_c IN SELECT x FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_w) = 'array' THEN v_w ELSE jsonb_build_array(v_w) END) x LOOP
                v_r := finance.fn_handoff_check_call(v_kind, COALESCE(v_c->'input', '{}'::jsonb) || jsonb_build_object('tool', v_c->>'tool'), NULL);
                IF (v_r->>'ok')::boolean IS NOT TRUE OR (v_r->>'unsupported')::boolean IS TRUE OR NOT v_r ? 'call' THEN
                    RETURN v_r;
                END IF;
                v_calls := v_calls || jsonb_build_array(v_r->'call');
            END LOOP;
            RETURN CASE WHEN jsonb_typeof(v_w) = 'array' THEN jsonb_build_object('ok', true, 'calls', v_calls)
                        ELSE jsonb_build_object('ok', true, 'call', v_calls->0) END;
        END IF;
    END IF;
    RETURN finance.fn_handoff_check_call(v_kind, p->'payload', NULLIF(btrim(COALESCE(p->>'option', '')), ''));
END;
$$;
