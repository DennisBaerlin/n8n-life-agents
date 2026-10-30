-- ============================================================
-- finance.fn_app_screen_payments(p jsonb) — Mini-App-Bildschirm „Zahlungen“ (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12, Design-Regeln dort), Vertrag wie
--   finance.fn_app_screen_overview. EIN ABSCHNITT JE KONTO (Transparenz 2026-10-30):
--   * Vorschau-Konto (finance.fn_coverage_accounts: cash, aktiv, mit Kontoauszug — dieselbe Auswahl wie die
--     Berater-Warnung): Bruecke aus finance.fn_account_outlook bis zum tiefsten Stand, die Posten summieren exakt darauf:
--     Stand (bestaetigt) [+ Korrektur rueckdatierter Buchungen] [+ gebucht seit Abgleich] + feste Abgaenge + feste
--     Eingaenge (Einzelvorkommen aus finance.fn_account_planned_flows, dieselben Betraege wie die Reihe, wiederholte
--     zusammengefasst ueber finance.fn_app_payment_rows) + Alltagsausgaben geschaetzt (je Auszug aus
--     finance.fn_account_everyday_basis, fruehester markiert, einmalige Grossausgaben mit Summe + Grenze, „vorlaeufig“
--     bei nur einem Auszug) = tiefster Stand (Ampel). Dazu Puffer (Standard / je Konto + Knapp-Schwelle), naechster
--     Geldeingang, Umbuchungs-Vorschlag (nur Haushalt + alert), weitere Zahlungen bis zum Fensterende.
--     Ampel aus der DB: Kontowaehrung ohne Kurs -> neutral + gap, shortfall > 0 -> alert,
--     min_projected < finance.coverage_warn_factor x buffer -> warn, sonst ok. Reihenfolge alert, warn, ok, neutral, Name.
--     Darstellung (Mini-App UX 2026-10-30, Ergebnis zuerst): „Tiefster Stand“ ist immer die erste Zeile, der Abschnitt
--     traegt keinen Wert (Abschnittswert = nur eine Summe). Konto ok -> genau zwei Zeilen: Tiefster Stand (Aufklappen = die
--     Bruecke als Posten-Liste inkl. Alltag je Auszug, Puffer, naechster Geldeingang) + „Zahlungen bis Fensterende“
--     (Aufklappen = alle Vorkommen ab heute); warn/alert/neutral -> die Bruecke bleibt offen (Handlung noetig).
--   * Konto ohne Vorschau mit Zahlungen im Fenster [heute, heute + finance.app_payments_days]: grauer Hinweis
--     (section.note) „keine Vorschau“ mit Grund (cash: noch kein Kontoauszug; andere Kontoart: Vorschau nur fuer
--     Giro/Tagesgeld) + die Vorkommen aus finance.fn_app_payment_occurrences (eigener Uebertrag: Abgang bei der Quelle,
--     Eingang beim Ziel, in Kontowaehrung), wiederholte zusammengefasst; Abschnittswert = ihre Summe (NULL bei fehlendem
--     Kurs). Danach, nach Name.
--   Hero: Summe der kommenden Abgaenge ohne Uebertraege in EUR, positiv (das Label sagt „Abgaenge“; gap bei fehlendem Kurs).
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alles. Sonst nur eigene Konten; eine
--     Zahlung von einem verborgenen Konto erscheint nur auf dem eigenen Ziel-Konto als neutrale Zeile „vom Haushalt“ (auch
--     in details), ein Geldeingang aus verborgener Quelle ohne Namen, ein verborgenes Ziel als „Haushalt“. Der
--     Umbuchungs-Vorschlag (nennt ein Haushaltskonto) erscheint nur in der Haushalts-Sicht. Die Antwort traegt keine IDs.
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
    v_out      numeric;
    v_gap      boolean;
    v_cov      jsonb := '[]'::jsonb;   -- [{rank, name, section}]
    v_other    jsonb := '[]'::jsonb;
    v_sections jsonb;
    v_banners  jsonb := '[]'::jsonb;
    v_acc      record;
    v_o        jsonb;
    v_b        jsonb;
    v_state    text;
    v_cur      text;
    v_sugg     jsonb;
    v_low      jsonb;
    v_items    jsonb;
    v_bridge   jsonb;      -- Posten der Bruecke (Zeilen); bei ok als Aufklapp-Liste der Zeile „Tiefster Stand“
    v_flat     jsonb;      -- dieselben Posten als Schluessel/Wert-Liste
    v_det      jsonb;
    v_occ      jsonb;
    v_n        int;
    v_cnt      int;
    v_amt      numeric;
    v_conf     numeric;
    v_start    numeric;
    v_lowitem  jsonb;
    v_probe    boolean := COALESCE(p -> 'params' -> 'probe' = 'true'::jsonb, false);
    v_ncov     int := 0;    -- Vorschau-Konten mit Ergebnis (probe: empty)
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

    -- ===== Vorschau-Konten: Bruecke je Konto + Banner (beides aus derselben gefilterten Konten-Menge) =====
    FOR v_acc IN
        SELECT a.id, a.name, a.currency
          FROM finance.fn_coverage_accounts() c(id)
          JOIN finance.accounts a ON a.id = c.id
         WHERE v_hh OR a.owner_person_id = v_pid
         ORDER BY a.name, a.id
    LOOP
        v_o := finance.fn_account_outlook(v_acc.id);
        CONTINUE WHEN (v_o->>'ok') IS DISTINCT FROM 'true';
        v_cur := v_acc.currency;
        v_b   := v_o->'bridge';
        v_state := CASE
            WHEN v_cur <> 'EUR' AND finance.fn_to_eur_unrounded(1, v_cur) IS NULL THEN 'neutral'
            WHEN (v_o->>'shortfall')::numeric > 0 THEN 'alert'
            WHEN (v_o->>'min_projected')::numeric < v_factor * (v_o->>'buffer')::numeric THEN 'warn'
            ELSE 'ok' END;
        v_low := jsonb_build_object('amount', core.fn_ui_money((v_o->>'min_projected')::numeric, v_cur),
                                    'date',   core.fn_ui_date((v_o->>'min_date')::date));
        v_sugg := CASE WHEN v_hh AND v_state = 'alert' THEN v_o->'suggestion' END;
        IF v_state IN ('alert', 'warn') THEN
            v_banners := v_banners || jsonb_build_array(jsonb_build_object(
                'state', v_state,
                'icon', CASE v_state WHEN 'warn' THEN 'clock' ELSE 'alert' END,
                'text', CASE
                    WHEN v_state = 'warn' THEN core.fn_ui_tpl('finance.app.payments.banner_tight',
                        jsonb_build_object('account', v_acc.name, 'min', v_low->'amount', 'date', v_low->'date'))
                    WHEN jsonb_typeof(v_sugg) = 'object' THEN core.fn_ui_tpl('finance.app.payments.banner_short_suggest',
                        jsonb_build_object('account', v_acc.name, 'min', v_low->'amount', 'date', v_low->'date',
                            'amount', core.fn_ui_money((v_sugg->>'amount')::numeric, v_cur),
                            'from', v_sugg->>'from_account',
                            'by', core.fn_ui_date((v_sugg->>'by_date')::date)))
                    ELSE core.fn_ui_tpl('finance.app.payments.banner_short',
                        jsonb_build_object('account', v_acc.name, 'min', v_low->'amount', 'date', v_low->'date')) END,
                'target', jsonb_build_object('screen', 'payments', 'params', '{}'::jsonb)));
        END IF;
        v_ncov := v_ncov + 1;
        -- probe (jeder App-Start) braucht nur Banner + empty: keine Bruecke bauen; ohne Tief keine Bruecke
        CONTINUE WHEN v_probe OR v_b IS NULL;
        v_bridge := '[]'::jsonb;

        -- Stand (bestaetigt) + ggf. Korrektur (rueckdatierte Buchung vor dem Abgleich) + gebucht seit dem Abgleich
        v_conf  := (v_b->>'confirmed')::numeric;
        v_start := COALESCE(v_conf, (v_b->>'base')::numeric);
        v_bridge := v_bridge || jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_start',
                         jsonb_build_object('date', core.fn_ui_date((v_b->>'from')::date - 1))),
            'sub', NULL, 'value', core.fn_ui_money(v_start, v_cur), 'gap', false,
            'pill', NULL, 'progress', NULL, 'target', NULL);
        IF (v_b->>'base')::numeric <> v_start THEN
            v_bridge := v_bridge || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_correction'),
                'sub', NULL, 'value', core.fn_ui_money((v_b->>'base')::numeric - v_start, v_cur), 'gap', false,
                'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;
        IF (v_b->>'booked')::numeric <> 0 THEN
            v_bridge := v_bridge || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_booked',
                             jsonb_build_object('date', core.fn_ui_date((v_b->>'from')::date))),
                'sub', NULL, 'value', core.fn_ui_money((v_b->>'booked')::numeric, v_cur), 'gap', false,
                'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;

        -- feste Ab-/Eingaenge bis zum Tief (Einzelvorkommen = dieselbe Quelle wie die Reihe, wiederholte zusammengefasst)
        v_occ := finance.fn_app_payment_occurrences(v_acc.id, (v_b->>'from')::date, (v_o->>'min_date')::date, v_hh, v_pid);
        FOR v_n IN 0..1 LOOP
            SELECT COALESCE(jsonb_agg(x), '[]'::jsonb), count(*) INTO v_det, v_cnt
              FROM jsonb_array_elements(v_occ->'rows') x
             WHERE CASE WHEN v_n = 0 THEN (x->>'amount')::numeric < 0 ELSE (x->>'amount')::numeric > 0 END;
            IF v_cnt > 0 THEN
                v_bridge := v_bridge || jsonb_build_object(
                    'label', core.fn_ui_tpl(CASE WHEN v_n = 0 THEN 'finance.app.payments.b_out' ELSE 'finance.app.payments.b_in' END,
                                 jsonb_build_object('date', v_low->'date')),
                    'sub', core.fn_ui_tpl('finance.app.payments.b_count', jsonb_build_object('count', core.fn_ui_num(v_cnt))),
                    'value', core.fn_ui_money((v_b->>CASE WHEN v_n = 0 THEN 'out' ELSE 'in' END)::numeric, v_cur, v_n = 1), 'gap', false,
                    'pill', NULL, 'progress', NULL, 'target', NULL,
                    'details', finance.fn_app_payment_rows(jsonb_build_object('mode', 'details', 'rows', v_det)));
            END IF;
        END LOOP;

        -- Alltagsausgaben (geschaetzt): je Tag x Tage; aufklappbar je Auszug, fruehester markiert; direkt danach je
        -- Auszug mit einmaligen Grossausgaben deren Summe + Grenze (zaehlen nicht zum Tageswert, Owner-Entscheid 2026-10-30)
        SELECT jsonb_agg(d.row ORDER BY e.period_end DESC, d.k)
          INTO v_det
          FROM finance.fn_account_everyday_basis(v_acc.id) e
         CROSS JOIN LATERAL (VALUES
                (0, jsonb_build_object(
                    'label', core.fn_ui_tpl('finance.app.payments.d_statement', jsonb_build_object(
                                 'from', core.fn_ui_date(e.period_start), 'to', core.fn_ui_date(e.period_end))),
                    'value', core.fn_ui_tpl(CASE WHEN e.counted THEN 'finance.app.payments.d_rate'
                                                 ELSE 'finance.app.payments.d_rate_earliest' END,
                                 jsonb_build_object('per_day', core.fn_ui_money(abs(e.per_day), v_cur))))),
                -- Betraege ohne Vorzeichen wie die Raten daneben
                (1, jsonb_build_object(
                    'label', core.fn_ui_tpl('finance.app.payments.d_oneoff'),
                    'value', core.fn_ui_tpl('finance.app.payments.d_oneoff_value', jsonb_build_object(
                                 'amount', core.fn_ui_money(abs(e.oneoff_out), v_cur),
                                 'threshold', core.fn_ui_money(e.oneoff_threshold, v_cur)))))) d(k, row)
         WHERE d.k = 0 OR e.oneoff_out < 0;
        v_bridge := v_bridge || jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_everyday'),
            'sub', core.fn_ui_tpl(CASE WHEN (v_o->>'provisional')::boolean THEN 'finance.app.payments.b_everyday_sub_provisional'
                                       ELSE 'finance.app.payments.b_everyday_sub' END,
                       jsonb_build_object('per_day', core.fn_ui_money(abs((v_o->>'everyday_per_day')::numeric), v_cur),
                                          'days', core.fn_ui_num((v_b->>'days')::numeric))),
            'value', core.fn_ui_money((v_b->>'everyday')::numeric, v_cur), 'gap', false,
            'pill', NULL, 'progress', NULL, 'target', NULL, 'details', COALESCE(v_det, '[]'::jsonb));

        -- Puffer
        v_bridge := v_bridge || jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_buffer'),
            'sub', core.fn_ui_tpl(CASE WHEN v_o->>'buffer_source' = 'account' THEN 'finance.app.payments.b_buffer_account'
                                       ELSE 'finance.app.payments.b_buffer_default' END,
                       jsonb_build_object('tight', core.fn_ui_money(v_factor * (v_o->>'buffer')::numeric, v_cur))),
            'value', core.fn_ui_money((v_o->>'buffer')::numeric, v_cur), 'gap', false,
            'pill', NULL, 'progress', NULL, 'target', NULL);

        -- naechster Geldeingang: Name nur, wenn die Quelle sichtbar ist (Haushalt oder eigenes Konto)
        IF v_o->>'next_income_date' IS NOT NULL THEN
            v_bridge := v_bridge || jsonb_build_object(
                'label', CASE WHEN v_hh OR EXISTS (
                                  SELECT 1 FROM finance.recurring_payments r JOIN finance.accounts sa ON sa.id = r.account_id
                                   WHERE r.id = (v_o->>'next_income_rp_id')::int
                                     AND sa.owner_person_id IS NOT DISTINCT FROM v_pid)
                              THEN core.fn_ui_tpl('finance.app.payments.b_income',
                                       jsonb_build_object('name', v_o->>'next_income_name'))
                              ELSE core.fn_ui_tpl('finance.app.payments.b_income_anon') END,
                'sub', core.fn_ui_tpl('finance.app.payments.b_on',
                           jsonb_build_object('date', core.fn_ui_date((v_o->>'next_income_date')::date))),
                'value', CASE WHEN v_o->>'next_income_amount' IS NOT NULL
                              THEN core.fn_ui_money((v_o->>'next_income_amount')::numeric, v_cur, true) END,
                'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;

        -- Umbuchungs-Vorschlag (nennt ein Haushaltskonto -> nur Haushalts-Sicht; v_sugg oben, nur bei alert)
        IF jsonb_typeof(v_sugg) = 'object' THEN
            v_bridge := v_bridge || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_suggest', jsonb_build_object(
                             'amount', core.fn_ui_money((v_sugg->>'amount')::numeric, v_cur),
                             'from', v_sugg->>'from_account', 'by', core.fn_ui_date((v_sugg->>'by_date')::date))),
                'sub', NULL, 'value', NULL, 'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;

        -- tiefster Stand (Ampel) = Ergebnis, steht immer zuerst
        v_lowitem := jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_low'),
            'sub', core.fn_ui_tpl('finance.app.payments.b_on', jsonb_build_object('date', v_low->'date')),
            'value', v_low->'amount', 'gap', v_state = 'neutral',
            'pill', jsonb_build_object(
                'state', v_state,
                'icon', CASE v_state WHEN 'ok' THEN 'check' WHEN 'warn' THEN 'clock' WHEN 'neutral' THEN 'info' ELSE 'alert' END,
                'text', CASE v_state
                    WHEN 'alert' THEN core.fn_ui_tpl('finance.app.payments.pill_short')
                    WHEN 'warn'  THEN core.fn_ui_tpl('finance.app.payments.pill_tight')
                    WHEN 'ok'    THEN core.fn_ui_tpl('finance.app.payments.pill_ok')
                    ELSE core.fn_ui_tpl('finance.app.payments.pill_no_rate') END),
            'progress', NULL, 'target', NULL);

        IF v_state = 'ok' THEN
            -- Konto reicht: die Bruecke als Posten-Liste im Aufklappen (Posten + Alltag je Auszug, nicht verschachtelbar)
            SELECT jsonb_agg(x.d ORDER BY x.o1, x.o2) INTO v_flat FROM (
                SELECT b.o AS o1, 0 AS o2, jsonb_build_object(
                           'label', CASE WHEN b.e->'label'->>'value' = 'finance.app.payments.b_everyday' THEN b.e->'sub'
                                         WHEN b.e->'label'->>'value' = 'finance.app.payments.b_buffer' THEN core.fn_ui_tpl(
                                              'finance.app.payments.b_buffer_kv', jsonb_build_object('detail', b.e->'sub'))
                                         ELSE b.e->'label' END,
                           'value', CASE WHEN b.e->'label'->>'value' LIKE 'finance.app.payments.b_income%'
                                         THEN core.fn_ui_tpl('finance.app.payments.d_payment', jsonb_build_object(
                                                  'date', b.e->'sub'->'params'->'date', 'amount', b.e->'value'))
                                         ELSE b.e->'value' END) AS d
                  FROM jsonb_array_elements(v_bridge) WITH ORDINALITY AS b(e, o)
                UNION ALL
                SELECT b.o, dd.o, dd.e
                  FROM jsonb_array_elements(v_bridge) WITH ORDINALITY AS b(e, o)
                 CROSS JOIN LATERAL jsonb_array_elements(b.e->'details') WITH ORDINALITY AS dd(e, o)
                 WHERE b.e->'label'->>'value' = 'finance.app.payments.b_everyday') x;
            v_items := jsonb_build_array(v_lowitem || jsonb_build_object('details', COALESCE(v_flat, '[]'::jsonb)));
            -- alle Zahlungen ab heute bis zum Fensterende (Vollstaendigkeit: nichts verschwindet aus der Liste)
            v_occ := finance.fn_app_payment_occurrences(v_acc.id, v_today, v_until, v_hh, v_pid);
            SELECT count(*), sum((x->>'amount')::numeric) INTO v_cnt, v_amt FROM jsonb_array_elements(v_occ->'rows') x;
            IF v_cnt > 0 THEN
                v_items := v_items || jsonb_build_object(
                    'label', core.fn_ui_tpl('finance.app.payments.b_window', jsonb_build_object('date', core.fn_ui_date(v_until))),
                    'sub', core.fn_ui_tpl('finance.app.payments.b_count', jsonb_build_object('count', core.fn_ui_num(v_cnt))),
                    'value', core.fn_ui_money(v_amt, v_cur, v_amt > 0), 'gap', false,
                    'pill', NULL, 'progress', NULL, 'target', NULL,
                    'details', finance.fn_app_payment_rows(jsonb_build_object('mode', 'details', 'rows', v_occ->'rows')));
            END IF;
        ELSE
            -- Handlung noetig: Ergebnis zuerst, darunter die offene Bruecke + weitere Zahlungen nach dem Tief
            v_items := jsonb_build_array(v_lowitem) || v_bridge;
            v_occ := finance.fn_app_payment_occurrences(v_acc.id, GREATEST((v_o->>'min_date')::date + 1, v_today), v_until, v_hh, v_pid);
            SELECT count(*), sum((x->>'amount')::numeric) INTO v_cnt, v_amt FROM jsonb_array_elements(v_occ->'rows') x;
            IF v_cnt > 0 THEN
                v_items := v_items || jsonb_build_object(
                    'label', core.fn_ui_tpl('finance.app.payments.b_later', jsonb_build_object('date', core.fn_ui_date(v_until))),
                    'sub', core.fn_ui_tpl('finance.app.payments.b_count', jsonb_build_object('count', core.fn_ui_num(v_cnt))),
                    'value', core.fn_ui_money(v_amt, v_cur, v_amt > 0), 'gap', false,
                    'pill', NULL, 'progress', NULL, 'target', NULL,
                    'details', finance.fn_app_payment_rows(jsonb_build_object('mode', 'details', 'rows', v_occ->'rows')));
            END IF;
        END IF;

        v_cov := v_cov || jsonb_build_object(
            'rank', CASE v_state WHEN 'alert' THEN 1 WHEN 'warn' THEN 2 WHEN 'ok' THEN 3 ELSE 4 END,
            'name', v_acc.name,
            'section', jsonb_build_object(
                'title', core.fn_ui_tpl('finance.app.payments.section_account', jsonb_build_object('account', v_acc.name)),
                'value', NULL,
                'empty', core.fn_ui_tpl('finance.app.payments.empty'),
                'items', v_items));

    END LOOP;

    IF v_probe THEN
        SELECT COALESCE(jsonb_agg(b.e ORDER BY b.e->>'state' = 'alert' DESC, b.pos), '[]'::jsonb) INTO v_banners
          FROM jsonb_array_elements(v_banners) WITH ORDINALITY AS b(e, pos);
        RETURN jsonb_build_object('ok', true,
            'empty', v_ncov = 0 AND NOT EXISTS (
                SELECT 1 FROM finance.fn_upcoming_payments(v_today, v_until) u
                  JOIN finance.accounts sa ON sa.id = u.account_id
                  LEFT JOIN finance.accounts ta ON ta.id = u.target_account_id
                 WHERE v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid OR ta.owner_person_id IS NOT DISTINCT FROM v_pid),
            'banners', v_banners);
    END IF;

    -- ===== Hero: kommende Abgaenge ohne Uebertraege von sichtbaren Konten in EUR =====
    SELECT COALESCE(sum(finance.fn_to_eur(u.amount, sa.currency)), 0),
           COALESCE(bool_or(finance.fn_to_eur(u.amount, sa.currency) IS NULL), false)
      INTO v_out, v_gap
      FROM finance.fn_upcoming_payments(v_today, v_until) u
      JOIN finance.accounts sa ON sa.id = u.account_id
     WHERE (v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid)
       AND u.target_account_id IS NULL AND u.amount < 0;

    -- ===== Konten OHNE Vorschau mit Zahlungen im Fenster: Hinweis + Vorkommen (Quelle UND Ziel eines Uebertrags) =====
    FOR v_acc IN
        SELECT a.id, a.name, a.currency, a.account_type
          FROM finance.accounts a
         WHERE a.status = 'active'
           AND (v_hh OR a.owner_person_id IS NOT DISTINCT FROM v_pid)
           AND a.id NOT IN (SELECT cc.id FROM finance.fn_coverage_accounts() cc(id))
         ORDER BY a.name, a.id
    LOOP
        v_occ := finance.fn_app_payment_occurrences(v_acc.id, v_today, v_until, v_hh, v_pid);
        CONTINUE WHEN jsonb_array_length(v_occ->'rows') = 0;
        SELECT sum((x->>'amount')::numeric) INTO v_amt FROM jsonb_array_elements(v_occ->'rows') x;
        v_other := v_other || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.payments.section_account', jsonb_build_object('account', v_acc.name)),
            'value', CASE WHEN NOT (v_occ->>'fx_gap')::boolean THEN core.fn_ui_money(v_amt, v_acc.currency, v_amt > 0) END,
            -- Grund: Vorschau gibt es nur fuer cash-Konten (fn_coverage_accounts); ein cash-Konto ohne Vorschau hat noch
            -- keinen Kontoauszug (Live-Befund 2026-10-30: P2P mit Auszug)
            'note', core.fn_ui_tpl(CASE WHEN v_acc.account_type::text = 'cash' THEN 'finance.app.payments.no_outlook'
                                        ELSE 'finance.app.payments.no_outlook_type' END),
            'empty', core.fn_ui_tpl('finance.app.payments.empty'),
            'items', finance.fn_app_payment_rows(jsonb_build_object('mode', 'items', 'rows', v_occ->'rows')));
    END LOOP;

    SELECT COALESCE(jsonb_agg(c->'section' ORDER BY (c->>'rank')::int, c->>'name'), '[]'::jsonb) || v_other
      INTO v_sections
      FROM jsonb_array_elements(v_cov) c;

    IF jsonb_array_length(v_sections) = 0 THEN
        v_sections := jsonb_build_array(jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.payments.section_upcoming'),
            'empty', core.fn_ui_tpl('finance.app.payments.empty'), 'items', '[]'::jsonb));
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.payments.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.hero',
                                    jsonb_build_object('days', core.fn_ui_num(v_until - v_today))),
            'value', core.fn_ui_money(abs(v_out), 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_payments(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
