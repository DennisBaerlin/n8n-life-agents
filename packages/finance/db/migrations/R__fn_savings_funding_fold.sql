-- ============================================================
-- fn_savings_funding_fold (INTERNAL HELPER -- Event-Fold + Karten-Hinweis, nicht tool-facing)
--   „Woher kommt das Geld?" (Owner 2026-10-30, arch-challenge: Hinweis im Moment der Anlage wie YNAB Targets, Meldung
--   nur beim Uebergang wie SRE/Prometheus). Fuer jedes uebergebene Konto, das ein Deckungs-Konto ist
--   (finance.fn_funding_accounts, dieselbe Regel wie der Konten-Tab), liest der Helfer NACH dem Write
--   finance.fn_account_funding (die eine Rechnung, keine zweite Projektion) und liefert:
--   (1) eine Kartenzeile „Danach ..." (ungelatcht: Vorschau im Probelauf, Post-State-Vertrag) -- funding_ok,
--       funding_ok_drain (gedeckt, baut aber ab), funding_until (warn), funding_gap (alert), funding_timing (rein = raus,
--       der Eingang kommt aber nach der Abbuchung), bei p_state_only (kuenftige Ratenaenderung: monthly_in/out gelten
--       heute noch mit der alten Rate) nur Zustand + Datum: funding_ok_plain / funding_until_date / funding_gap_date;
--   (2) einen englischen Note-Teil fuer den Buchhalter. p_ask = true (Sparplan-Writes): nur bei warn/alert und nur wenn
--       core.fn_should_notify('finance', 'savings_funding:<konto>:<runs_out_on>') kippt -> Frage-Auftrag
--       „ASK the user ..." (Zeitpunkt-Variante: Hebel statt Frage). Der Latch-Schluessel traegt das „reicht bis"-Datum:
--       dieselbe Lage fragt nie doppelt (Probelauf + Write, Wiederholung), jede Aenderung der Lage auf irgendeinem Weg
--       (neuer Plan, Raten-Aenderung, Zubringer per set_recurring_payment, Einmal-Ueberweisung) ergibt einen neuen
--       Schluessel und fragt bei einer Luecke wieder -- kein Re-Arm-Pfad noetig, der an jedem Schreibweg haengen
--       muesste (Code-Review 2026-10-30). Je gefragter Lage bleibt eine kleine notification_state-Zeile stehen.
--       p_ask = false (Zubringer-/Zahlungs-Writes): Bericht ohne Frage, verbraucht keinen Latch -- bei warn/alert
--       immer, „gedeckt" nur fuer die Konten in p_report_ok (Geldeingang aufs Konto; eine Abbuchung, die die Deckung
--       nicht bricht, meldet nichts).
--   FREIES GELD (UX-Gesamtkonzept 2026-10-31): Ziel-Geld auf dem Konto ist nicht frei (fn_account_funding.reserved /
--   min_free) -> Kartenzeilen nennen den tiefsten freien Stand, die Note den freien Stand + „after X reserved for goals“.
--   „gedeckt“ (ok) nur fuer p_report_ok-Konten oder bei p_ask (sonst stuende bei jedem Dauerauftrag eine Zeile zum
--   Absender auf der Karte). neutral (Kurs fehlt, Alltagsausgaben unbekannt) -> nichts, keine Zeile. Fehlbetrag je Monat (monthly_gap) rechnet die
--   fn: -(monthly_in + monthly_out) + geschaetzte Alltagsausgaben (-everyday_per_day * fn_days_per_month), mindestens 0.
--   Bewusst ohne Stichtag-Filter (anders als savings_squeeze): die Projektion enthaelt kommende Zahlungen.
--   Kosten (belegte Ausnahme der Fold-Regel, docs/reference/finance.md): erst ein Index-Check (Konto ist Absender eines
--   Spar-Abflusses oder Konto einer Sparplan-rp), nur dann fn_funding_accounts und eine 24-Monats-Projektion (~0,1 s) je Deckungs-Konto.
--   VOLATILE (schreibt den Latch); im Probelauf (core.fn_dry_run) rollt der Savepoint den Latch mit zurueck.
--   Aufrufer: fn_create_savings_plan, fn_set_savings_plan (ask), fn_create_recurring_transfer (Quelle + Ziel, ok-Bericht
--   fuers Ziel), fn_create_recurring_payment (ok-Bericht nur bei Einnahme); card_lines fuegt fn_merge_fold zusammen.
--   RUECKGABE jsonb: '{}' oder {card_lines:[...]} + optional savings_funding {note, accounts:[{account_id, state,
--   monthly_in, monthly_out, monthly_gap, balance, min_projected, min_date, runs_out_on, asked, reserved, min_free}]}.
--   Tests: tests/db/finance/test_fn_savings_funding_fold.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_funding_fold(p_account_ids int[], p_ask boolean, p_state_only boolean DEFAULT FALSE,
                                                           p_report_ok int[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_id      int;
    v_name    text;
    v_f       jsonb;
    v_state   text;
    v_cur     text;
    v_in      numeric;
    v_out     numeric;
    v_every   numeric;
    v_gap     numeric;
    v_drain   numeric;
    v_key     text;
    v_line    jsonb;
    v_note    text;
    v_asked   boolean;
    v_date    date;
    t_in      text;
    t_out     text;
    t_gap     text;
    t_bal     text;
    t_min     text;
    t_every   text;
    t_drain   text;
    t_res     text;
    v_res     numeric;
    v_free_min numeric;
    v_free_dt  date;
    v_lines   jsonb := '[]'::jsonb;
    v_accts   jsonb := '[]'::jsonb;
    v_notes   text[] := '{}';
BEGIN
    FOR v_id IN SELECT DISTINCT x FROM unnest(p_account_ids) x WHERE x IS NOT NULL ORDER BY 1 LOOP
        -- billiger Index-Check zuerst (ein Gehaltskonto mit Netflix kostet nur diese Lookups), dann die eine Regel:
        -- das Konto schickt einen Spar-Abfluss (Uebertrag/Ziel-Rate/Vorsorge = Absender, UX-Gesamtkonzept Bug B2) oder
        -- bezahlt einen Sparplan
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM finance.recurring_payments r
                                   WHERE r.account_id = v_id AND r.amount < 0
                                     AND (r.target_account_id IS NOT NULL
                                          OR EXISTS (SELECT 1 FROM finance.savings_goals g WHERE g.recurring_payment_id = finance.fn_recurring_lineage_head(r.id))
                                          OR EXISTS (SELECT 1 FROM finance.pension pe WHERE pe.recurring_payment_id = finance.fn_recurring_lineage_head(r.id))))
                  AND NOT EXISTS (SELECT 1 FROM finance.recurring_payments r
                                    JOIN finance.savings_plans sp ON sp.recurring_payment_id = finance.fn_recurring_lineage_head(r.id)
                                   WHERE r.account_id = v_id);
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM finance.fn_funding_accounts() fa WHERE fa.account_id = v_id);
        v_f := finance.fn_account_funding(v_id);
        CONTINUE WHEN (v_f->>'ok')::boolean IS DISTINCT FROM true;
        v_state := v_f->>'state';
        CONTINUE WHEN v_state NOT IN ('ok', 'warn', 'alert');
        -- „gedeckt“ nur, wo der Write Geld bringt (p_report_ok) oder bei einer Sparplan-Frage (p_ask): sonst stuende bei
        -- jedem neuen Dauerauftrag eine gedeckt-Zeile zum Absender-Girokonto auf der Karte
        CONTINUE WHEN v_state = 'ok' AND NOT p_ask AND NOT (v_id = ANY (COALESCE(p_report_ok, '{}')));

        SELECT a.name INTO v_name FROM finance.accounts a WHERE a.id = v_id;
        v_cur   := v_f->>'currency';
        v_in    := (v_f->>'monthly_in')::numeric;
        v_out   := -(v_f->>'monthly_out')::numeric;
        v_every := CASE WHEN v_f->>'everyday' = 'estimated'
                        THEN round(-(v_f->>'everyday_per_day')::numeric * finance.fn_days_per_month(), 2) ELSE 0 END;
        v_drain := round(v_out - v_in + v_every, 2);
        v_gap   := GREATEST(v_drain, 0);
        v_date  := (v_f->>'runs_out_on')::date;
        v_asked := false;
        -- Ziel-Geld ist nicht frei (fn_account_funding: Schwelle): Stand und Tief nennen das FREIE Geld
        v_res   := COALESCE((v_f->>'reserved')::numeric, 0);
        v_free_min := COALESCE((v_f->>'min_free')::numeric, (v_f->>'min_projected')::numeric);
        v_free_dt  := COALESCE((v_f->>'min_free_date')::date, (v_f->>'min_date')::date);
        -- Betraege fuer die Note (Modell-Text): zwei Nachkommastellen + Waehrungscode des Kontos
        t_in    := to_char(v_in, 'FM999999999990.00') || ' ' || v_cur;
        t_out   := to_char(v_out, 'FM999999999990.00') || ' ' || v_cur;
        t_gap   := to_char(v_gap, 'FM999999999990.00') || ' ' || v_cur;
        t_bal   := to_char((v_f->>'balance')::numeric - v_res, 'FM999999999990.00') || ' ' || v_cur;
        t_min   := to_char(v_free_min, 'FM999999999990.00') || ' ' || v_cur;
        t_res   := CASE WHEN v_res > 0 THEN format(' (free money, after %s reserved for goals)',
                                                    to_char(v_res, 'FM999999999990.00') || ' ' || v_cur) ELSE '' END;
        t_every := to_char(v_every, 'FM999999999990.00') || ' ' || v_cur;
        t_drain := to_char(v_drain, 'FM999999999990.00') || ' ' || v_cur;
        v_note  := NULL;

        IF v_state = 'ok' THEN
            v_line := CASE
                WHEN p_state_only THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.funding_ok_plain',
                         'params', jsonb_build_object('account', v_name))
                WHEN v_drain > 0 THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.funding_ok_drain',
                         'params', jsonb_build_object('account', v_name, 'drain', core.fn_ui_money(v_drain, v_cur),
                                                      'min', core.fn_ui_money(v_free_min, v_cur),
                                                      'date', core.fn_ui_date(v_free_dt)))
                ELSE jsonb_build_object('kind', 'note', 'value', 'finance.note.funding_ok',
                         'params', jsonb_build_object('account', v_name, 'in', core.fn_ui_money(v_in, v_cur),
                                                      'out', core.fn_ui_money(v_out, v_cur))) END;
            IF NOT p_ask AND v_id = ANY (COALESCE(p_report_ok, '{}')) THEN
                v_note := format('Money check for the account "%s" after this change: covered%s.', v_name,
                    CASE WHEN p_state_only THEN ''
                         WHEN v_drain > 0 THEN format(' for the whole planning horizon - it shrinks by %s a month, lowest balance %s on %s%s',
                                                      t_drain,
                                                      t_min,
                                                      to_char(v_free_dt, 'DD.MM.YYYY'), t_res)
                         ELSE format(' - %s a month comes in, %s goes out', t_in,
                                     t_out) END);
            END IF;
        ELSE
            v_line := CASE
                WHEN p_state_only THEN jsonb_build_object('kind', 'note',
                         'value', CASE v_state WHEN 'alert' THEN 'finance.note.funding_gap_date' ELSE 'finance.note.funding_until_date' END,
                         'params', jsonb_build_object('account', v_name, 'date', core.fn_ui_date(v_date)))
                WHEN v_gap = 0 THEN jsonb_build_object('kind', 'note', 'value', 'finance.note.funding_timing',
                         'params', jsonb_build_object('account', v_name, 'date', core.fn_ui_date(v_date),
                                                      'min', core.fn_ui_money(v_free_min, v_cur),
                                                      'min_date', core.fn_ui_date(v_free_dt)))
                ELSE jsonb_build_object('kind', 'note',
                         'value', CASE v_state WHEN 'alert' THEN 'finance.note.funding_gap' ELSE 'finance.note.funding_until' END,
                         'params', jsonb_build_object('account', v_name, 'date', core.fn_ui_date(v_date),
                                                      'in', core.fn_ui_money(v_in, v_cur), 'out', core.fn_ui_money(v_out, v_cur))) END;
            -- Bericht (Zubringer) immer; Frage nur beim Latch-Uebergang dieser Lage (explizit getrennt: OR wertet nicht
            -- garantiert kurzschluessig aus, ein Bericht darf den Latch nie verbrauchen)
            IF p_ask THEN
                v_key   := 'savings_funding:' || v_id || ':' || v_date::text;
                v_asked := core.fn_should_notify('finance', v_key);
            END IF;
            IF NOT p_ask OR v_asked THEN
                v_note := CASE
                    WHEN p_state_only THEN format('Money check for the account "%s": with the new rate the balance lasts only until %s.%s',
                             v_name, to_char(v_date, 'DD.MM.YYYY'),
                             CASE WHEN p_ask THEN ' ASK the user where the missing money comes from (core rule 9, savings_funding).' ELSE '' END)
                    WHEN v_gap = 0 THEN format('Money check for the account "%s": as much comes in as goes out (%s a month), '
                             || 'but the incoming money arrives after the debits, so the balance drops to %s%s on %s and runs short '
                             || 'from %s. Tell the user and suggest moving the incoming standing transfer to a day before the '
                             || 'first debit of the month; no money is missing.',
                             v_name, t_in,
                             t_min, t_res,
                             to_char(v_free_dt, 'DD.MM.YYYY'), to_char(v_date, 'DD.MM.YYYY'))
                    ELSE format('Money check for the account "%s"%s: all regular debits from this account total %s a month%s, '
                             || '%s a month comes in, so %s a month is missing; the balance of %s%s lasts until %s.%s',
                             v_name, CASE WHEN p_ask THEN '' ELSE ' after this change' END,
                             t_out,
                             CASE WHEN v_every > 0 THEN format(' plus about %s estimated everyday spending',
                                                               t_every) ELSE '' END,
                             t_in, t_gap,
                             t_bal, t_res, to_char(v_date, 'DD.MM.YYYY'),
                             CASE WHEN p_ask THEN ' ASK the user where the missing money comes from (core rule 9, savings_funding).'
                                  ELSE '' END) END;
            END IF;
        END IF;

        v_lines := v_lines || jsonb_build_array(v_line);
        IF v_note IS NOT NULL THEN
            v_notes := v_notes || v_note;
            v_accts := v_accts || jsonb_build_array(jsonb_build_object(
                'account_id', v_id, 'state', v_state, 'monthly_in', v_in, 'monthly_out', v_out, 'monthly_gap', v_gap,
                'balance', (v_f->>'balance')::numeric, 'min_projected', (v_f->>'min_projected')::numeric,
                'min_date', v_f->'min_date', 'runs_out_on', v_f->'runs_out_on', 'asked', v_asked,
                'reserved', v_res, 'min_free', v_free_min));
        END IF;
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
        RETURN '{}'::jsonb;
    END IF;
    RETURN jsonb_build_object('card_lines', v_lines)
        || CASE WHEN cardinality(v_notes) > 0
                THEN jsonb_build_object('savings_funding', jsonb_build_object(
                         'note', array_to_string(v_notes, ' '), 'accounts', v_accts))
                ELSE '{}'::jsonb END;
END;
$$;
