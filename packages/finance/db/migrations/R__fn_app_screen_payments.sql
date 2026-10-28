-- ============================================================
-- finance.fn_app_screen_payments(p jsonb) — Mini-App-Bildschirm „Zahlungen“ (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Vertrag wie finance.fn_app_screen_overview.
--   Abschnitt 1 „Kommende Zahlungen“: offene Dauerauftrags-Vorkommen [heute, heute + finance.app_payments_days] aus
--     finance.fn_upcoming_payments (Betrag = was die Buchung nimmt, signiert aus Sicht des gezeigten Kontos).
--   Abschnitt 2 „Kontovorschau“: je Konto aus finance.fn_coverage_accounts (cash, aktiv, mit Kontoauszug — dieselbe
--     Auswahl wie die Berater-Warnung) finance.fn_account_outlook, davon NUR estimated_today, min_projected, min_date,
--     shortfall, buffer (Allow-List; nie next_income_name/account_name der Vorschau). Ampel aus der DB:
--     Kontowaehrung ohne Kurs -> neutral + gap (der Puffer waere unumgerechnet), shortfall > 0 -> alert,
--     min_projected < finance.coverage_warn_factor x buffer -> warn, sonst ok.
--   Hero: Summe der kommenden Abgaenge ohne Uebertraege in EUR (gap bei fehlendem Kurs).
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alles. Sonst nur Zahlungen VOM eigenen
--     Konto (Ziel-Konto, das man nicht sieht -> neutraler Key „Haushalt“) und Uebertraege AUF das eigene Konto von einem
--     verborgenen Konto -> neutrale Zeile „vom Haushalt“ ohne Namen der Zahlung. Der Umbuchungs-Vorschlag (nennt ein
--     Haushaltskonto) erscheint nur im alert-Banner der Haushalts-Sicht. Die Antwort traegt keine IDs.
--   params.probe = true -> {ok, empty, banners} (Banner nur hier: alert/warn je Vorschau-Konto, Ziel = payments).
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (Muster overview).
--   Tests: tests/db/finance/test_fn_app_screen_payments.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_payments(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid      text;
    v_hh       boolean;
    v_today    date := CURRENT_DATE;
    v_until    date;
    v_factor   numeric;
    v_rows     jsonb;
    v_out      numeric;
    v_gap      boolean;
    v_look     jsonb := '[]'::jsonb;
    v_banners  jsonb := '[]'::jsonb;
    v_acc      record;
    v_o        jsonb;
    v_state    text;
    v_sugg     jsonb;
    v_low      jsonb;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid    := p ->> 'person_id';
    v_hh     := core.fn_app_sees_household(v_pid);
    v_until  := v_today + COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'app_payments_days'), '')::int, 30);
    v_factor := COALESCE(NULLIF(core.fn_config_get('finance', 'finance', 'coverage_warn_factor'), '')::numeric, 2);

    -- Kontovorschau + Banner (beides aus derselben gefilterten Konten-Menge)
    FOR v_acc IN
        SELECT a.id, a.name, a.currency
          FROM finance.fn_coverage_accounts() c(id)
          JOIN finance.accounts a ON a.id = c.id
         WHERE v_hh OR a.owner_person_id = v_pid
         ORDER BY a.name, a.id
    LOOP
        v_o := finance.fn_account_outlook(v_acc.id);
        CONTINUE WHEN (v_o->>'ok') IS DISTINCT FROM 'true';
        v_state := CASE
            WHEN v_acc.currency <> 'EUR' AND finance.fn_to_eur_unrounded(1, v_acc.currency) IS NULL THEN 'neutral'
            WHEN (v_o->>'shortfall')::numeric > 0 THEN 'alert'
            WHEN (v_o->>'min_projected')::numeric < v_factor * (v_o->>'buffer')::numeric THEN 'warn'
            ELSE 'ok' END;
        v_low := jsonb_build_object('amount', core.fn_ui_money((v_o->>'min_projected')::numeric, v_acc.currency),
                                    'date',   core.fn_ui_date((v_o->>'min_date')::date));
        v_look := v_look || jsonb_build_array(jsonb_build_object(
            'label', v_acc.name,
            'sub', core.fn_ui_tpl('finance.app.payments.low_point', v_low),
            'value', core.fn_ui_money((v_o->>'estimated_today')::numeric, v_acc.currency),
            'gap', v_state = 'neutral',
            'pill', jsonb_build_object(
                'state', v_state,
                'icon', CASE v_state WHEN 'ok' THEN 'check' WHEN 'warn' THEN 'clock' WHEN 'neutral' THEN 'info' ELSE 'alert' END,
                'text', CASE v_state
                    WHEN 'alert' THEN core.fn_ui_tpl('finance.app.payments.pill_short')
                    WHEN 'warn'  THEN core.fn_ui_tpl('finance.app.payments.pill_tight')
                    WHEN 'ok'    THEN core.fn_ui_tpl('finance.app.payments.pill_ok')
                    ELSE core.fn_ui_tpl('finance.app.payments.pill_no_rate') END),
            'progress', NULL,
            'target', NULL));
        IF v_state IN ('alert', 'warn') THEN
            v_sugg := CASE WHEN v_hh AND v_state = 'alert' THEN v_o->'suggestion' END;
            v_banners := v_banners || jsonb_build_array(jsonb_build_object(
                'state', v_state,
                'icon', CASE v_state WHEN 'warn' THEN 'clock' ELSE 'alert' END,
                'text', CASE
                    WHEN v_state = 'warn' THEN core.fn_ui_tpl('finance.app.payments.banner_tight',
                        jsonb_build_object('account', v_acc.name, 'min', v_low->'amount', 'date', v_low->'date'))
                    WHEN jsonb_typeof(v_sugg) = 'object' THEN core.fn_ui_tpl('finance.app.payments.banner_short_suggest',
                        jsonb_build_object('account', v_acc.name, 'min', v_low->'amount', 'date', v_low->'date',
                            'amount', core.fn_ui_money((v_sugg->>'amount')::numeric, v_acc.currency),
                            'from', v_sugg->>'from_account',
                            'by', core.fn_ui_date((v_sugg->>'by_date')::date)))
                    ELSE core.fn_ui_tpl('finance.app.payments.banner_short',
                        jsonb_build_object('account', v_acc.name, 'min', v_low->'amount', 'date', v_low->'date')) END,
                'target', jsonb_build_object('screen', 'payments', 'params', '{}'::jsonb)));
        END IF;
    END LOOP;

    -- Kommende Zahlungen: sichtbare Quelle (benannt) oder sichtbares Ziel bei verborgener Quelle (neutral)
    WITH u AS (
        SELECT u.due_date, u.amount, u.planned_amount, u.target_account_id, r.name AS rp_name,
               -- IS NOT DISTINCT FROM: ein Haushaltskonto (owner NULL) waere mit "=" NULL statt false, NOT NULL faellt
               -- in einem CASE durch -> Name eines verborgenen Kontos (im Test gefangen)
               sa.name AS src_name, sa.currency AS src_cur, (v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid) AS src_vis,
               ta.name AS tgt_name, ta.currency AS tgt_cur,
               (ta.id IS NOT NULL AND (v_hh OR ta.owner_person_id IS NOT DISTINCT FROM v_pid)) AS tgt_vis
          FROM finance.fn_upcoming_payments(v_today, v_until) u
          JOIN finance.recurring_payments r ON r.id = u.recurring_payment_id
          JOIN finance.accounts sa ON sa.id = u.account_id
          LEFT JOIN finance.accounts ta ON ta.id = u.target_account_id
    ), shown AS (
        SELECT u.due_date,
               CASE WHEN u.src_vis THEN to_jsonb(u.rp_name)
                    ELSE core.fn_ui_tpl('finance.app.payments.from_household') END AS label,
               CASE WHEN NOT u.src_vis
                        THEN core.fn_ui_tpl('finance.app.payments.due', jsonb_build_object(
                                 'date', core.fn_ui_date(u.due_date), 'account', u.tgt_name))
                    WHEN u.target_account_id IS NULL
                        THEN core.fn_ui_tpl('finance.app.payments.due', jsonb_build_object(
                                 'date', core.fn_ui_date(u.due_date), 'account', u.src_name))
                    ELSE core.fn_ui_tpl('finance.app.payments.due_to', jsonb_build_object(
                             'date', core.fn_ui_date(u.due_date), 'account', u.src_name,
                             'to', CASE WHEN u.tgt_vis THEN to_jsonb(u.tgt_name)
                                        ELSE core.fn_ui_tpl('finance.app.payments.household') END)) END AS sub,
               -- der Zeilenbetrag ist in der Quellwaehrung (auch fuer die neutrale Ziel-Zeile)
               CASE WHEN u.src_vis THEN core.fn_ui_money(u.amount, u.src_cur)
                    ELSE core.fn_ui_money(abs(u.planned_amount), u.src_cur) END AS value,
               CASE WHEN u.src_vis AND u.target_account_id IS NULL AND u.amount < 0 THEN u.amount END AS out_native,
               u.src_cur
          FROM u
         WHERE u.src_vis OR u.tgt_vis
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('label', s.label, 'sub', s.sub, 'value', s.value, 'gap', false,
                                                 'pill', NULL, 'progress', NULL, 'target', NULL)
                              ORDER BY s.due_date, s.label::text), '[]'::jsonb),
           COALESCE(sum(finance.fn_to_eur(s.out_native, s.src_cur)), 0),
           COALESCE(bool_or(s.out_native IS NOT NULL AND finance.fn_to_eur(s.out_native, s.src_cur) IS NULL), false)
      INTO v_rows, v_out, v_gap
      FROM shown s;

    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        SELECT COALESCE(jsonb_agg(b.e ORDER BY b.e->>'state' = 'alert' DESC, b.pos), '[]'::jsonb) INTO v_banners
          FROM jsonb_array_elements(v_banners) WITH ORDINALITY AS b(e, pos);
        RETURN jsonb_build_object('ok', true,
            'empty', jsonb_array_length(v_rows) = 0 AND jsonb_array_length(v_look) = 0,
            'banners', v_banners);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.payments.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.hero',
                                    jsonb_build_object('days', core.fn_ui_num(v_until - v_today))),
            'value', core.fn_ui_money(v_out, 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', jsonb_build_array(
            jsonb_build_object('title', core.fn_ui_tpl('finance.app.payments.section_upcoming'),
                               'empty', core.fn_ui_tpl('finance.app.payments.empty'), 'items', v_rows),
            jsonb_build_object('title', core.fn_ui_tpl('finance.app.payments.section_outlook'),
                               'empty', core.fn_ui_tpl('finance.app.payments.empty_outlook'), 'items', v_look)));
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_payments(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
