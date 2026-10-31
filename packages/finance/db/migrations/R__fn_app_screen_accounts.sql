-- ============================================================
-- finance.fn_app_screen_accounts(p jsonb) — Mini-App-Bildschirm „Konten“ (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), ersetzt „Zahlungen“ (UX-Gesamtkonzept
--   2026-10-31, 5.2). Frage der Seite: Steht genug auf jedem Konto, und was bewegt sich in den naechsten Tagen?
--   Abschnitt finance.app.accounts.section: Frage: Was steht heute auf diesem Konto, reicht es bis zum naechsten Geldeingang, und was geht ab oder kommt rein?
--   Abschnitt finance.app.accounts.section_none: Frage: Welche Konten gibt es?
--   Konten = finance.fn_app_accounts_listed (die eine Regel: Haushalt ohne Kinder-Konten, sonst nur eigene); ein Konto
--   ohne Saldo und ohne Bewegung im naechsten Kalendermonat entfaellt (Verrechnungskonto 0).
--   Kein Hero (die Frage ist je Konto; ein Haushalts-„Abgaenge“ mischt Sparen mit Rechnungen).
--   Zeilen je Konto (hoechstens vier):
--     1 Stand heute — Saldo; sub „davon x frei“, wenn Ziel-Geld darauf liegt (finance.fn_account_free_balance); liegt mehr
--       Ziel-Geld darauf als Saldo -> warn „x mehr verplant als vorhanden“. Aufklappen: Zurueckgelegt fuer Ziele,
--       Besitzer (Haushalts-Sicht), Kontoauszug (Datum; ein Geld-Konto ohne Auszug und darum ohne Vorschau: „noch
--       keiner – schick einen im Chat“ — dieselbe Stelle bei jedem Konto, Owner-Abnahme 2026-10-31).
--     2 Urteil allein aus finance.fn_account_low_state (dieselbe Rechnung wie die Spiegel-Pille am Sparplan), nur mit
--       Abfluss im Horizont: outlook = „Tiefster Stand“ bis zum Geldeingang, Aufklappen = Bruecke (<= 8 Zeilen: Stand,
--       gebucht seit Abgleich, feste Ab-/Eingaenge, Alltag geschaetzt, Puffer, naechster Geldeingang, Umbuchungs-
--       Vorschlag nur Haushalt + alert); funding = „Reicht bis“ mit dem Monat, in dem das FREIE Geld aufgebraucht ist
--       (ohne Lauf-Ende „ueber <Monat> hinaus“; nie ein negativer Kontostand, Owner-Abnahme 2026-10-31). Pille nur
--       warn/alert, gebaut allein von finance.fn_app_low_state_pill (Konten-Zeile funding mit p_month_row: „x im Monat
--       mehr ab als rein“); Kurs fehlt -> gap ohne Pille.
--     3 Gehen ab im <Monat> / 4 Kommen rein im <Monat> — naechster voller Kalendermonat (Owner-Entscheid 2026-10-31: jede
--       Monatszahlung genau einmal, Ein- und Ausgaenge vergleichbar; die restlichen Tage dieses Monats stehen nur in der
--       Bruecke von Zeile 2, wo es sie gibt), Summe + Anzahl, Aufklappen = Einzelposten (finance.fn_app_payment_rows,
--       gedeckelt); nie eine Netto-Summe, kein Abschnittswert.
--   Reihenfolge: alert -> warn -> Alltagskonto (cash) -> uebrige -> Name.
--   ZERO-TRUST (core.fn_app_sees_household): eine Zahlung von einem verborgenen Konto erscheint als „Vom Haushalt“, ein
--   Geldeingang aus verborgener Quelle ohne Namen, der Umbuchungs-Vorschlag (nennt ein Haushaltskonto) nur im Haushalt.
--   params.probe = true -> {ok, empty, banners}: Konto-Hinweise der Startseite kommen nur von hier (P2): outlook warn
--   + alert, Ziel-Geld-Luecke nur alert (fn_account_low_state mit p_alert_only); Ziel = accounts.
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (Muster overview).
--   Tests: tests/db/finance/test_fn_app_screen_accounts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_accounts(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid      text;
    v_hh       boolean;
    v_probe    boolean := COALESCE(p -> 'params' -> 'probe' = 'true'::jsonb, false);
    v_today    date := CURRENT_DATE;
    v_from     date := (date_trunc('month', CURRENT_DATE) + interval '1 month')::date;
    v_until    date := (date_trunc('month', CURRENT_DATE) + interval '2 months' - interval '1 day')::date;
    v_acc      record;
    v_ls       jsonb;
    v_o        jsonb;
    v_b        jsonb;
    v_occ      jsonb;
    v_cur      text;
    v_free     numeric;
    v_res      numeric;
    v_items    jsonb;
    v_det      jsonb;
    v_pill     jsonb;
    v_rank     int;
    v_n        int;
    v_sum      numeric;
    v_banner   jsonb;
    v_sugg     jsonb;
    v_secs     jsonb := '[]'::jsonb;    -- [{rank, name, section}]
    v_banners  jsonb := '[]'::jsonb;
    v_shown    int := 0;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid   := p ->> 'person_id';
    v_hh    := core.fn_app_sees_household(v_pid);

    FOR v_acc IN
        SELECT a.id, a.name, a.currency, a.account_type::text AS account_type, a.last_reconciled_at,
               COALESCE(b.balance, 0) AS balance, hp.full_name AS owner_name
          FROM finance.fn_app_accounts_listed(v_pid) l(id)
          JOIN finance.accounts a ON a.id = l.id
          LEFT JOIN finance.account_balances b ON b.account_id = a.id
          LEFT JOIN core.fn_household_persons() hp ON hp.person_id = a.owner_person_id
         ORDER BY a.name, a.id
    LOOP
        v_cur := v_acc.currency;
        v_occ := finance.fn_app_payment_occurrences(v_acc.id, v_from, v_until, v_hh, v_pid);
        v_ls := finance.fn_account_low_state(v_acc.id, v_probe);
        -- leeres Konto ohne Bewegung entfaellt (B10) — ausser es traegt schon eine Warnung (Sparplan ab naechstem Monat)
        CONTINUE WHEN v_acc.balance = 0 AND jsonb_array_length(v_occ->'rows') = 0 AND v_ls->>'state' NOT IN ('warn', 'alert');
        v_shown := v_shown + 1;

        -- Banner (nur probe): outlook warn + alert, Ziel-Geld-Luecke nur alert
        IF v_probe THEN
            v_sugg := NULL;
            IF v_hh AND v_ls->>'state' = 'alert' AND v_ls->>'verdict' = 'buffer' THEN
                v_sugg := finance.fn_account_outlook(v_acc.id)->'suggestion';
            END IF;
            -- der EINE Hinweis-Text zum Urteil (auch Kinder-Konten im Ziele-probe)
            v_banner := finance.fn_app_low_state_banner(v_ls, v_acc.name, v_sugg);
            IF v_banner IS NOT NULL THEN
                v_banners := v_banners || jsonb_build_array(
                    v_banner || jsonb_build_object('target', jsonb_build_object('screen', 'accounts', 'params', '{}'::jsonb)));
            END IF;
            CONTINUE;
        END IF;

        v_rank := CASE WHEN v_acc.account_type = 'cash' THEN 3 ELSE 4 END;

        -- 1 Stand heute (+ frei / mehr verplant als vorhanden)
        v_free := finance.fn_account_free_balance(v_acc.id);
        v_res  := CASE WHEN v_free IS NULL THEN 0 ELSE GREATEST(v_acc.balance - v_free, 0) END;
        v_pill := NULL;
        IF v_res > v_acc.balance THEN
            v_pill := jsonb_build_object('state', 'warn', 'icon', 'alert',
                          'text', core.fn_ui_tpl('finance.app.accounts.pill_overcommitted',
                                      jsonb_build_object('amount', core.fn_ui_money(v_res - v_acc.balance, v_cur))));
            v_rank := LEAST(v_rank, 2);
        END IF;
        v_det := '[]'::jsonb;
        IF v_res > 0 THEN
            v_det := v_det || jsonb_build_object('label', core.fn_ui_tpl('finance.app.accounts.d_reserved'),
                                                 'value', core.fn_ui_money(v_res, v_cur));
        END IF;
        IF v_hh THEN
            v_det := v_det || jsonb_build_object('label', core.fn_ui_tpl('finance.app.accounts.d_owner'),
                                                 'value', COALESCE(to_jsonb(v_acc.owner_name), core.fn_ui_tpl('finance.app.common.joint')));
        END IF;
        -- Kontoauszug bei jedem Konto an derselben Stelle; ein Geld-Konto, dem ohne Auszug die Vorschau fehlt (kein Urteil),
        -- sagt dort, was fehlt und wer es behebt (ein Sparkonto mit „Reicht bis“ braucht keinen)
        IF v_acc.last_reconciled_at IS NOT NULL OR (v_acc.account_type = 'cash' AND v_ls->>'source' = 'none') THEN
            v_det := v_det || jsonb_build_object('label', core.fn_ui_tpl('finance.app.accounts.d_statement'),
                                                 'value', CASE WHEN v_acc.last_reconciled_at IS NOT NULL
                                                               THEN core.fn_ui_date(v_acc.last_reconciled_at)
                                                               ELSE core.fn_ui_tpl('finance.app.accounts.d_statement_none') END);
        END IF;
        v_items := jsonb_build_array(jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.accounts.balance_today'),
            'sub', CASE WHEN v_res > 0 AND v_pill IS NULL
                        THEN core.fn_ui_tpl('finance.app.accounts.free_of', jsonb_build_object('amount', core.fn_ui_money(v_free, v_cur))) END,
            'value', core.fn_ui_money(v_acc.balance, v_cur),
            'gap', v_acc.balance <> 0 AND finance.fn_to_eur(v_acc.balance, v_cur) IS NULL,
            'pill', v_pill, 'progress', NULL, 'target', NULL)
            || CASE WHEN jsonb_array_length(v_det) > 0 THEN jsonb_build_object('details', v_det) ELSE '{}'::jsonb END);

        -- 2 Tiefster Stand (Urteil aus fn_account_low_state): bei Abfluss im Horizont oder wenn es ein Urteil gibt (der
        --   Banner der Startseite zeigt nie auf ein Konto ohne passende Zeile)
        IF v_ls->>'source' <> 'none' AND ((v_ls->>'has_outflow')::boolean OR v_ls->>'state' IN ('warn', 'alert')) THEN
            -- die EINE Pille zum Urteil (auch Spiegel-Pille am Sparplan auf Ziele); die Zeile „Reicht bis“ traegt den
            -- Monat schon als Wert, ihre Pille sagt deshalb, warum (p_month_row)
            v_pill := finance.fn_app_low_state_pill(v_ls, v_ls->>'source' = 'funding');
            IF v_pill IS NOT NULL THEN
                v_rank := LEAST(v_rank, CASE v_pill->>'state' WHEN 'alert' THEN 1 ELSE 2 END);
            END IF;

            IF v_ls->>'source' = 'outlook' THEN
                v_o := finance.fn_account_outlook(v_acc.id);
                v_b := v_o->'bridge';
                v_det := '[]'::jsonb;
                IF jsonb_typeof(v_b) = 'object' THEN
                    -- Stand = der bestaetigte (Kontoauszug); eine spaeter erfasste, rueckdatierte Buchung zaehlt mit zu
                    -- „Gebucht seit“ — die Posten summieren weiter exakt auf den tiefsten Stand
                    v_sum := COALESCE((v_b->>'confirmed')::numeric, (v_b->>'base')::numeric);
                    v_det := v_det || jsonb_build_object(
                        'label', core.fn_ui_tpl('finance.app.accounts.b_start', jsonb_build_object('date', core.fn_ui_date((v_b->>'from')::date - 1))),
                        'value', core.fn_ui_money(v_sum, v_cur));
                    v_sum := (v_b->>'booked')::numeric + (v_b->>'base')::numeric - v_sum;
                    IF v_sum <> 0 THEN
                        v_det := v_det || jsonb_build_object(
                            'label', core.fn_ui_tpl('finance.app.accounts.b_booked', jsonb_build_object('date', core.fn_ui_date((v_b->>'from')::date))),
                            'value', core.fn_ui_money(v_sum, v_cur, v_sum > 0));
                    END IF;
                    IF (v_b->>'out')::numeric <> 0 THEN
                        v_det := v_det || jsonb_build_object(
                            'label', core.fn_ui_tpl('finance.app.accounts.b_out', jsonb_build_object('date', core.fn_ui_date((v_ls->>'low_date')::date))),
                            'value', core.fn_ui_money((v_b->>'out')::numeric, v_cur));
                    END IF;
                    IF (v_b->>'in')::numeric <> 0 THEN
                        v_det := v_det || jsonb_build_object(
                            'label', core.fn_ui_tpl('finance.app.accounts.b_in', jsonb_build_object('date', core.fn_ui_date((v_ls->>'low_date')::date))),
                            'value', core.fn_ui_money((v_b->>'in')::numeric, v_cur, true));
                    END IF;
                    IF (v_b->>'everyday')::numeric <> 0 THEN
                        v_det := v_det || jsonb_build_object(
                            'label', core.fn_ui_tpl('finance.app.accounts.b_everyday', jsonb_build_object(
                                         'per_day', core.fn_ui_money(abs((v_o->>'everyday_per_day')::numeric), v_cur),
                                         'days', core.fn_ui_num((v_b->>'days')::numeric))),
                            'value', core.fn_ui_money((v_b->>'everyday')::numeric, v_cur));
                    END IF;
                END IF;
                v_det := v_det || jsonb_build_object(
                    'label', core.fn_ui_tpl(CASE WHEN v_o->>'buffer_source' = 'account' THEN 'finance.app.accounts.b_buffer_account'
                                                 ELSE 'finance.app.accounts.b_buffer_default' END),
                    'value', core.fn_ui_money((v_o->>'buffer')::numeric, v_cur));
                IF v_o->>'next_income_date' IS NOT NULL THEN
                    v_det := v_det || jsonb_build_object(
                        'label', CASE WHEN v_hh OR EXISTS (
                                          SELECT 1 FROM finance.recurring_payments r JOIN finance.accounts sa ON sa.id = r.account_id
                                           WHERE r.id = (v_o->>'next_income_rp_id')::int
                                             AND (sa.id = v_acc.id OR sa.owner_person_id IS NOT DISTINCT FROM v_pid))
                                      THEN core.fn_ui_tpl('finance.app.accounts.b_income', jsonb_build_object('name', v_o->>'next_income_name'))
                                      ELSE core.fn_ui_tpl('finance.app.accounts.b_income_anon') END,
                        'value', core.fn_ui_tpl('finance.app.accounts.d_payment', jsonb_build_object(
                                     'date', core.fn_ui_date((v_o->>'next_income_date')::date),
                                     'amount', CASE WHEN v_o->>'next_income_amount' IS NOT NULL
                                                    THEN core.fn_ui_money((v_o->>'next_income_amount')::numeric, v_cur, true) END)));
                END IF;
                v_sugg := CASE WHEN v_hh AND v_pill->>'state' = 'alert' AND v_ls->>'verdict' = 'buffer' THEN v_o->'suggestion' END;
                IF jsonb_typeof(v_sugg) = 'object' THEN
                    v_det := v_det || jsonb_build_object(
                        'label', core.fn_ui_tpl('finance.app.accounts.b_suggest', jsonb_build_object(
                                     'amount', core.fn_ui_money((v_sugg->>'amount')::numeric, v_cur),
                                     'from', v_sugg->>'from_account', 'by', core.fn_ui_date((v_sugg->>'by_date')::date))),
                        'value', NULL);
                END IF;
                v_items := v_items || jsonb_build_object(
                    'label', core.fn_ui_tpl('finance.app.accounts.low'),
                    'sub', CASE WHEN v_o->>'next_income_date' IS NOT NULL
                                THEN core.fn_ui_tpl('finance.app.accounts.low_before_income', jsonb_build_object(
                                         'date', core.fn_ui_date((v_ls->>'low_date')::date),
                                         'income', core.fn_ui_date((v_o->>'next_income_date')::date)))
                                ELSE core.fn_ui_tpl('finance.app.accounts.low_on', jsonb_build_object('date', core.fn_ui_date((v_ls->>'low_date')::date))) END,
                    'value', core.fn_ui_money((v_ls->>'amount')::numeric, v_cur),
                    'gap', (v_ls->>'gap')::boolean, 'pill', v_pill, 'progress', NULL, 'target', NULL,
                    'details', v_det);
            ELSE
                -- Spar-/Deckungskonto: bis wann reicht das FREIE Geld (nie ein negativer Kontostand in 24 Monaten)
                v_items := v_items || jsonb_build_object(
                    'label', core.fn_ui_tpl(CASE WHEN v_ls->>'on_date' IS NOT NULL THEN 'finance.app.accounts.until'
                                                 ELSE 'finance.app.accounts.lasts' END),
                    'sub', core.fn_ui_tpl('finance.app.accounts.low_funding_sub', jsonb_build_object(
                               'out', core.fn_ui_money(abs(COALESCE((v_ls->>'monthly_out')::numeric, 0)), v_cur),
                               'in', core.fn_ui_money(COALESCE((v_ls->>'monthly_in')::numeric, 0), v_cur))),
                    'value', CASE WHEN v_ls->>'on_date' IS NOT NULL THEN core.fn_ui_month((v_ls->>'on_date')::date)
                                  WHEN v_ls->>'horizon_end' IS NOT NULL
                                  THEN core.fn_ui_tpl('finance.app.accounts.until_beyond', jsonb_build_object(
                                           'month', core.fn_ui_month((v_ls->>'horizon_end')::date))) END,
                    'gap', (v_ls->>'gap')::boolean, 'pill', v_pill, 'progress', NULL, 'target', NULL);
            END IF;
        END IF;

        -- 3 Gehen ab / 4 Kommen rein (getrennt, nie netto)
        FOR v_n IN 0..1 LOOP
            SELECT COALESCE(jsonb_agg(x), '[]'::jsonb), sum((x->>'amount')::numeric) INTO v_det, v_sum
              FROM jsonb_array_elements(v_occ->'rows') x
             WHERE CASE WHEN v_n = 0 THEN (x->>'amount')::numeric < 0 ELSE (x->>'amount')::numeric > 0 END;
            CONTINUE WHEN jsonb_array_length(v_det) = 0;
            v_items := v_items || jsonb_build_object(
                'label', core.fn_ui_tpl(CASE WHEN v_n = 0 THEN 'finance.app.accounts.out_month' ELSE 'finance.app.accounts.in_month' END,
                             jsonb_build_object('month', core.fn_ui_month(v_from, true))),
                'sub', core.fn_ui_tpl(CASE WHEN v_n = 0 AND jsonb_array_length(v_det) = 1 THEN 'finance.app.accounts.n_payment_one'
                                           WHEN v_n = 0 THEN 'finance.app.accounts.n_payments'
                                           WHEN jsonb_array_length(v_det) = 1 THEN 'finance.app.accounts.n_incoming_one'
                                           ELSE 'finance.app.accounts.n_incoming' END,
                           jsonb_build_object('n', core.fn_ui_num(jsonb_array_length(v_det)))),
                'value', core.fn_ui_money(v_sum, v_cur, v_n = 1),
                'gap', (v_occ->>'fx_gap')::boolean, 'pill', NULL, 'progress', NULL, 'target', NULL,
                'details', finance.fn_app_payment_rows(jsonb_build_object('rows', v_det)));
        END LOOP;

        v_secs := v_secs || jsonb_build_object('rank', v_rank, 'name', v_acc.name, 'section', jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.accounts.section', jsonb_build_object('account', v_acc.name)),
            'value', NULL,
            'empty', core.fn_ui_tpl('finance.app.accounts.empty'),
            'items', v_items));
    END LOOP;

    IF v_probe THEN
        SELECT COALESCE(jsonb_agg(b.e ORDER BY b.e->>'state' = 'alert' DESC, b.pos), '[]'::jsonb) INTO v_banners
          FROM jsonb_array_elements(v_banners) WITH ORDINALITY AS b(e, pos);
        RETURN jsonb_build_object('ok', true, 'empty', v_shown = 0, 'banners', v_banners);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.accounts.title'),
        'hero', NULL,
        'banners', '[]'::jsonb,
        'sections', CASE WHEN jsonb_array_length(v_secs) = 0
                         THEN jsonb_build_array(jsonb_build_object(
                                  'title', core.fn_ui_tpl('finance.app.accounts.section_none'),
                                  'empty', core.fn_ui_tpl('finance.app.accounts.empty'), 'items', '[]'::jsonb))
                         ELSE (SELECT jsonb_agg(c->'section' ORDER BY (c->>'rank')::int, c->>'name') FROM jsonb_array_elements(v_secs) c) END);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_accounts(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
