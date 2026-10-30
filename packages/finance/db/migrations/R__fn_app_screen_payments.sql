-- ============================================================
-- finance.fn_app_screen_payments(p jsonb) — Mini-App-Bildschirm „Zahlungen“ (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Vertrag wie finance.fn_app_screen_overview.
--   EIN ABSCHNITT JE KONTO (Transparenz 2026-10-30; vorher eine gemischte Zahlungsliste + Kontovorschau ohne Herleitung):
--   * Vorschau-Konto (finance.fn_coverage_accounts: cash, aktiv, mit Kontoauszug — dieselbe Auswahl wie die
--     Berater-Warnung): Bruecke aus finance.fn_account_outlook bis zum tiefsten Stand, die Zeilen summieren exakt darauf:
--     Stand (bestaetigt) [+ Korrektur rueckdatierter Buchungen] [+ gebucht seit Abgleich] + feste Abgaenge + feste
--     Eingaenge (aufklappbar: Einzelvorkommen aus finance.fn_account_planned_flows, dieselben Betraege wie die Reihe)
--     + Alltagsausgaben geschaetzt (aufklappbar: je Auszug aus finance.fn_account_everyday_basis, fruehester markiert,
--     danach je Auszug die einmaligen Grossausgaben, die nicht zaehlen (Summe + Grenze), „vorlaeufig“ bei nur einem
--     Auszug) = tiefster Stand (Ampel). Dazu Puffer (Standard / je Konto + Knapp-Schwelle),
--     naechster Geldeingang, Umbuchungs-Vorschlag (nur Haushalt + alert), weitere Zahlungen bis zum Fensterende.
--     Ampel aus der DB: Kontowaehrung ohne Kurs -> neutral + gap, shortfall > 0 -> alert,
--     min_projected < finance.coverage_warn_factor x buffer -> warn, sonst ok. Reihenfolge alert, warn, ok, neutral, Name.
--   * Konto ohne Vorschau mit Zahlungen im Fenster [heute, heute + finance.app_payments_days]: Hinweis „keine
--     Vorschau“ mit Grund (cash: noch kein Kontoauszug; andere Kontoart: Vorschau nur fuer Giro/Tagesgeld) + die
--     Zahlungen, Abschnittswert = ihre Summe (Kontowaehrung). Danach, nach Name.
--   Hero: Summe der kommenden Abgaenge ohne Uebertraege in EUR (gap bei fehlendem Kurs).
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
    v_other    jsonb;
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
    v_det      jsonb;
    v_n        int;
    v_cnt      int;
    v_amt      numeric;
    v_conf     numeric;
    v_start    numeric;
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
        v_items := '[]'::jsonb;

        -- Stand (bestaetigt) + ggf. Korrektur (rueckdatierte Buchung vor dem Abgleich) + gebucht seit dem Abgleich
        v_conf  := (v_b->>'confirmed')::numeric;
        v_start := COALESCE(v_conf, (v_b->>'base')::numeric);
        v_items := v_items || jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_start',
                         jsonb_build_object('date', core.fn_ui_date((v_b->>'from')::date - 1))),
            'sub', NULL, 'value', core.fn_ui_money(v_start, v_cur), 'gap', false,
            'pill', NULL, 'progress', NULL, 'target', NULL);
        IF (v_b->>'base')::numeric <> v_start THEN
            v_items := v_items || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_correction'),
                'sub', NULL, 'value', core.fn_ui_money((v_b->>'base')::numeric - v_start, v_cur), 'gap', false,
                'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;
        IF (v_b->>'booked')::numeric <> 0 THEN
            v_items := v_items || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_booked',
                             jsonb_build_object('date', core.fn_ui_date((v_b->>'from')::date))),
                'sub', NULL, 'value', core.fn_ui_money((v_b->>'booked')::numeric, v_cur), 'gap', false,
                'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;

        -- feste Ab-/Eingaenge bis zum Tief (Einzelvorkommen = dieselbe Quelle wie die Reihe)
        FOR v_n IN 0..1 LOOP
            WITH f AS (
                SELECT pf.due_date, pf.amount, r.name AS rp_name,
                       (r.account_id = v_acc.id OR v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid) AS src_vis
                  FROM finance.fn_account_planned_flows(v_acc.id, (v_b->>'from')::date, (v_o->>'min_date')::date) pf
                  JOIN finance.recurring_payments r ON r.id = pf.recurring_payment_id
                  JOIN finance.accounts sa ON sa.id = r.account_id
                 WHERE CASE WHEN v_n = 0 THEN pf.amount < 0 ELSE pf.amount > 0 END
            )
            SELECT jsonb_agg(jsonb_build_object(
                       'label', CASE WHEN f.src_vis THEN to_jsonb(f.rp_name)
                                     ELSE core.fn_ui_tpl('finance.app.payments.from_household') END,
                       'value', core.fn_ui_tpl('finance.app.payments.d_payment', jsonb_build_object(
                                     'date', core.fn_ui_date(f.due_date), 'amount', core.fn_ui_money(f.amount, v_cur))))
                       ORDER BY f.due_date, f.rp_name),
                   count(*)
              INTO v_det, v_cnt
              FROM f;
            IF v_cnt > 0 THEN
                v_items := v_items || jsonb_build_object(
                    'label', core.fn_ui_tpl(CASE WHEN v_n = 0 THEN 'finance.app.payments.b_out' ELSE 'finance.app.payments.b_in' END,
                                 jsonb_build_object('date', v_low->'date')),
                    'sub', core.fn_ui_tpl('finance.app.payments.b_count', jsonb_build_object('count', core.fn_ui_num(v_cnt))),
                    'value', core.fn_ui_money((v_b->>CASE WHEN v_n = 0 THEN 'out' ELSE 'in' END)::numeric, v_cur), 'gap', false,
                    'pill', NULL, 'progress', NULL, 'target', NULL, 'details', v_det);
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
        v_items := v_items || jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_everyday'),
            'sub', core.fn_ui_tpl(CASE WHEN (v_o->>'provisional')::boolean THEN 'finance.app.payments.b_everyday_sub_provisional'
                                       ELSE 'finance.app.payments.b_everyday_sub' END,
                       jsonb_build_object('per_day', core.fn_ui_money(abs((v_o->>'everyday_per_day')::numeric), v_cur),
                                          'days', core.fn_ui_num((v_b->>'days')::numeric))),
            'value', core.fn_ui_money((v_b->>'everyday')::numeric, v_cur), 'gap', false,
            'pill', NULL, 'progress', NULL, 'target', NULL, 'details', COALESCE(v_det, '[]'::jsonb));

        -- tiefster Stand (Ampel) + Puffer
        v_items := v_items || jsonb_build_object(
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
        v_items := v_items || jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.payments.b_buffer'),
            'sub', core.fn_ui_tpl(CASE WHEN v_o->>'buffer_source' = 'account' THEN 'finance.app.payments.b_buffer_account'
                                       ELSE 'finance.app.payments.b_buffer_default' END,
                       jsonb_build_object('tight', core.fn_ui_money(v_factor * (v_o->>'buffer')::numeric, v_cur))),
            'value', core.fn_ui_money((v_o->>'buffer')::numeric, v_cur), 'gap', false,
            'pill', NULL, 'progress', NULL, 'target', NULL);

        -- naechster Geldeingang: Name nur, wenn die Quelle sichtbar ist (Haushalt oder eigenes Konto)
        IF v_o->>'next_income_date' IS NOT NULL THEN
            v_items := v_items || jsonb_build_object(
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
                              THEN core.fn_ui_money((v_o->>'next_income_amount')::numeric, v_cur) END,
                'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;

        -- Umbuchungs-Vorschlag (nennt ein Haushaltskonto -> nur Haushalts-Sicht; v_sugg oben)
        IF jsonb_typeof(v_sugg) = 'object' THEN
            v_items := v_items || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_suggest', jsonb_build_object(
                             'amount', core.fn_ui_money((v_sugg->>'amount')::numeric, v_cur),
                             'from', v_sugg->>'from_account', 'by', core.fn_ui_date((v_sugg->>'by_date')::date))),
                'sub', NULL, 'value', NULL, 'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL);
        END IF;

        -- weitere Zahlungen nach dem Tief bis zum Fensterende (Vollstaendigkeit: nichts verschwindet aus der Liste)
        WITH f AS (
            SELECT pf.due_date, pf.amount, r.name AS rp_name,
                   (r.account_id = v_acc.id OR v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid) AS src_vis
              FROM finance.fn_account_planned_flows(v_acc.id, GREATEST((v_o->>'min_date')::date + 1, v_today), v_until) pf
              JOIN finance.recurring_payments r ON r.id = pf.recurring_payment_id
              JOIN finance.accounts sa ON sa.id = r.account_id
        )
        SELECT jsonb_agg(jsonb_build_object(
                   'label', CASE WHEN f.src_vis THEN to_jsonb(f.rp_name)
                                 ELSE core.fn_ui_tpl('finance.app.payments.from_household') END,
                   'value', core.fn_ui_tpl('finance.app.payments.d_payment', jsonb_build_object(
                                 'date', core.fn_ui_date(f.due_date), 'amount', core.fn_ui_money(f.amount, v_cur))))
                   ORDER BY f.due_date, f.rp_name),
               count(*), sum(f.amount)
          INTO v_det, v_cnt, v_amt
          FROM f;
        IF v_cnt > 0 THEN
            v_items := v_items || jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.payments.b_later', jsonb_build_object('date', core.fn_ui_date(v_until))),
                'sub', core.fn_ui_tpl('finance.app.payments.b_count', jsonb_build_object('count', core.fn_ui_num(v_cnt))),
                'value', core.fn_ui_money(v_amt, v_cur), 'gap', false,
                'pill', NULL, 'progress', NULL, 'target', NULL, 'details', v_det);
        END IF;

        v_cov := v_cov || jsonb_build_object(
            'rank', CASE v_state WHEN 'alert' THEN 1 WHEN 'warn' THEN 2 WHEN 'ok' THEN 3 ELSE 4 END,
            'name', v_acc.name,
            'section', jsonb_build_object(
                'title', core.fn_ui_tpl('finance.app.payments.section_account', jsonb_build_object('account', v_acc.name)),
                'value', v_low->'amount',
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

    -- ===== Kommende Zahlungen im Fenster: Hero + Abschnitte der Konten OHNE Vorschau =====
    -- Abschnitts-Konto = sichtbare Quelle, sonst sichtbares Ziel (dann neutral „vom Haushalt“)
    WITH u AS (
        SELECT u.due_date, u.amount, u.planned_amount, u.target_account_id, r.name AS rp_name,
               -- IS NOT DISTINCT FROM: ein Haushaltskonto (owner NULL) waere mit "=" NULL statt false, NOT NULL faellt
               -- in einem CASE durch -> Name eines verborgenen Kontos (im Test gefangen)
               sa.id AS src_id, sa.name AS src_name, sa.currency AS src_cur, sa.account_type AS src_type,
               (v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid) AS src_vis,
               ta.id AS tgt_id, ta.name AS tgt_name, ta.currency AS tgt_cur, ta.account_type AS tgt_type,
               (ta.id IS NOT NULL AND (v_hh OR ta.owner_person_id IS NOT DISTINCT FROM v_pid)) AS tgt_vis
          FROM finance.fn_upcoming_payments(v_today, v_until) u
          JOIN finance.recurring_payments r ON r.id = u.recurring_payment_id
          JOIN finance.accounts sa ON sa.id = u.account_id
          LEFT JOIN finance.accounts ta ON ta.id = u.target_account_id
    ), shown AS (
        SELECT u.*,
               CASE WHEN u.src_vis THEN u.src_id ELSE u.tgt_id END AS sec_id,
               CASE WHEN u.src_vis THEN u.src_name ELSE u.tgt_name END AS sec_name,
               CASE WHEN u.src_vis THEN u.src_type ELSE u.tgt_type END AS sec_type,
               CASE WHEN u.src_vis AND u.target_account_id IS NULL AND u.amount < 0 THEN u.amount END AS out_native
          FROM u
         WHERE u.src_vis OR u.tgt_vis
    )
    SELECT COALESCE(sum(finance.fn_to_eur(s.out_native, s.src_cur)), 0),
           COALESCE(bool_or(s.out_native IS NOT NULL AND finance.fn_to_eur(s.out_native, s.src_cur) IS NULL), false),
           (SELECT COALESCE(jsonb_agg(x.sec ORDER BY x.sec_name), '[]'::jsonb) FROM (
                SELECT s2.sec_name,
                       jsonb_build_object(
                           'title', core.fn_ui_tpl('finance.app.payments.section_account', jsonb_build_object('account', s2.sec_name)),
                           -- Zeilenbetrag in Quellwaehrung (auch fuer die neutrale Ziel-Zeile); Summe nur bei einer Waehrung
                           'value', CASE WHEN count(DISTINCT s2.src_cur) = 1
                                         THEN core.fn_ui_money(sum(CASE WHEN s2.src_vis THEN s2.amount ELSE abs(s2.planned_amount) END),
                                                               min(s2.src_cur)) END,
                           'empty', core.fn_ui_tpl('finance.app.payments.empty'),
                           -- Grund: Vorschau gibt es nur fuer cash-Konten (fn_coverage_accounts); ein cash-Konto
                           -- ohne Vorschau hat noch keinen Kontoauszug (Live-Befund 2026-10-30: P2P mit Auszug)
                           'items', jsonb_build_array(jsonb_build_object(
                                        'label', core.fn_ui_tpl(CASE WHEN s2.sec_type::text = 'cash'
                                                                     THEN 'finance.app.payments.no_outlook'
                                                                     ELSE 'finance.app.payments.no_outlook_type' END),
                                        'sub', NULL, 'value', NULL,
                                        'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL))
                                    || jsonb_agg(jsonb_build_object(
                               'label', CASE WHEN s2.src_vis THEN to_jsonb(s2.rp_name)
                                             ELSE core.fn_ui_tpl('finance.app.payments.from_household') END,
                               'sub', CASE WHEN NOT s2.src_vis OR s2.target_account_id IS NULL
                                           THEN core.fn_ui_tpl('finance.app.payments.due_on',
                                                    jsonb_build_object('date', core.fn_ui_date(s2.due_date)))
                                           ELSE core.fn_ui_tpl('finance.app.payments.due_on_to', jsonb_build_object(
                                                    'date', core.fn_ui_date(s2.due_date),
                                                    'to', CASE WHEN s2.tgt_vis THEN to_jsonb(s2.tgt_name)
                                                               ELSE core.fn_ui_tpl('finance.app.payments.household') END)) END,
                               'value', CASE WHEN s2.src_vis THEN core.fn_ui_money(s2.amount, s2.src_cur)
                                             ELSE core.fn_ui_money(abs(s2.planned_amount), s2.src_cur) END,
                               'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL)
                               ORDER BY s2.due_date, s2.rp_name)) AS sec
                  FROM shown s2
                 WHERE s2.sec_id NOT IN (SELECT cc.id FROM finance.fn_coverage_accounts() cc(id))
                 GROUP BY s2.sec_id, s2.sec_name, s2.sec_type) x)
      INTO v_out, v_gap, v_other
      FROM shown s;

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
            'value', core.fn_ui_money(v_out, 'EUR'),
            'gap', v_gap,
            'note', NULL),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_payments(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
