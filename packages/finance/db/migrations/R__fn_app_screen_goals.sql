-- ============================================================
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12, Design-Regeln dort), Muster
--   finance.fn_app_screen_overview. Quellen: savings_goal_progress (Ziele mit Zielbetrag; Ampel = finance.fn_savings_goal_pace,
--   die EINE Regel, die auch der Berater nutzt; Rueckstand behind_amount), savings_goal_account_share (wo liegt das Geld),
--   account_reserve_status + finance.fn_depot_cover_state (Deckung je Konto/Depot), fn_emergency_reserve_status
--   (Notreserve), maintenance_reserve_status (Instandhaltung + Herleitung nach II. BV), savings_plan_overview
--   (Sparplaene), fn_account_funding (Spar-Deckung der Konten), fn_account_flows (Zufluesse), fn_standing_orders +
--   fn_app_order_line (Dauerauftraege). Die Seite rechnet nichts.
--   Deckungs-Konten = finance.fn_funding_accounts (die eine Regel: Abbuchungskonto eines aktiven Sparplans oder Ziel
--   eines Dauerauftrags, aktive Nicht-Kredit-Konten), gefiltert auf sichtbare Konten und sichtbare Sparplaene.
--   Pille der Spar-Deckung = fn_account_funding, NUR bei Abweichung (Mini-App UX 2026-10-30: gruen nur fuer die
--   Hauptaussage einer Zeile): warn „reicht bis", alert „Luecke ab", neutral „nicht ermittelbar" (ohne Kurs -> + gap;
--   Alltagsausgaben eines Ausgabenkontos ohne Auszug unbekannt -> Hinweis in den Konto-Details, kein gap); ok = keine Pille.
--   Die Dauerauftraege (fn_standing_orders) liest die Seite einmal je Aufruf (v_so, Abschnitt Konten + probe-empty);
--   fn_funding_accounts liest sie fuer die Deckungs-Konten ein zweites Mal (bewusst: die Konten-Regel hat eine Adresse).
--   Abschnitte (Mini-App UX 2026-10-30; Reihenfolge in jedem Abschnitt: Abweichung zuerst):
--   Hero „Zurueckgelegt" = Sparziele + Ruecklagen (Notreserve gedeckt + Instandhaltung), Note mit der Aufschluesselung
--     (entfaellt bei fx-Luecke, dann gap). Keine Doppelzaehlung: Instandhaltung hat per Form-CHECK keinen Zielbetrag, die
--     Notreserve ist aus der Ziel-Liste ausgeschlossen.
--   1 Ruecklagen (Notreserve nur fuer Haushalts-Betrachter, Zero-Trust; dann Instandhaltung): Summe neben dem Titel
--     (NULL bei fx-Luecke). Notreserve: „Ziel …", Pille vollstaendig / „fehlen {gap}" / nicht ermittelbar, Balken nur
--     solange nicht vollstaendig; Aufklappen = Ziel-Herleitung + Geld je Konto. Instandhaltung: Untertitel „{rate} im
--     Monat · wie empfohlen" bzw. „· empfohlen {rec}", Pille (nur aktive Immobilie mit bekannter Empfehlung) ausreichend /
--     „{gap} im Monat unter Empfehlung", KEIN Balken (kein Betragsziel); Aufklappen = Herleitung oder „fehlt".
--   2 Sparziele (aktiv, mit Zielbetrag): Summe neben dem Titel (NULL bei fx-Luecke); hinter Plan -> uebrige nach Datum ->
--     erreicht. Untertitel „Ziel x bis Datum · noch 16 J. 5 Mon." (Restzeit aus age(); nicht bei erreicht/ueberfaellig).
--     Pille „hinter Plan · fehlen {behind}" (behind_amount; ohne Betrag bei fx-Luecke), kein Balken bei erreicht.
--     Aufklappen: Sparrate des heute gueltigen Glieds + Abbuchungskonto, dann je Konto der Anteil (Summe = Zielstand).
--   3 Sparplaene: Wert = Monatsbetrag, Untertitel „Betrag je Ausfuehrung · naechste Datum", Summe der aktiven Plaene im
--     Titel (entfaellt ohne Wechselkurs); Pille pausiert bzw. abweichende Deckung des Verrechnungskontos. Aufklappen:
--     Wertpapier, Depot, Abbuchungskonto + Beguenstigter (nur Haushalt), Sparziel, geplante Aenderung, Position heute.
--     Zufluesse und Konto-Stand stehen unter 4 (ein Fakt, eine Adresse).
--   4 Konten (ersetzt „Fuer Ziele verplant" + „Dauerauftraege je Konto"): je sichtbarem Konto mit Ziel-Geld (Konto oder
--     Depot, Depot auch bei Ziel-Anteil ohne Kurs), Dauerauftraegen als Quelle oder Spar-Deckung eine Zeile. Wert =
--     Kontostand (account_balances, nativ) bzw. Depot-Marktwert (EUR). Untertitel „fuer Ziele X · frei Y" („frei"
--     entfaellt bei Fehlbetrag) bzw. „Dauerauftraege X im Monat". Pille nur bei Abweichung, Rang alert > warn > neutral:
--     Luecke ab / fehlen {gap} (Saldo bzw. Depot ab der Schwelle) / reicht bis / „Kurswert {gap} darunter" (Kursdelle,
--     fn_depot_cover_state) / nicht ermittelbar. Aufklappen = Bank-To-do je Auftrag „→ Ziel" = Betrag · Rhythmus · ab Datum
--     + geplante Aenderungen (Spar-Lastschriften ohne Ziel mit ihrem Namen), „Geld kommt von" je Zufluss (Quellkonto bzw.
--     Name eines externen Eingangs), zuletzt „Konto" (rein · raus im Monat · tiefster Stand) und die Alltags-Schaetzung.
--     Die Deckungsluecke ist KEIN Banner auf diesem Bildschirm (Berater unterdrueckt sie, wenn das Ziel im Plan ist).
--   Bekannt: "hinter Plan" bei einem Ziel mit has_fx_gap ist zu hoch gerechnet -> Item traegt gap, kein Banner (BACKLOG).
--   ZERO-TRUST-SICHTBARKEIT (Rolle loest der Handler selbst auf, core.fn_app_sees_household): owner/partner sehen den
--     Haushalt, alle anderen nur Ziel/Ruecklage mit beneficiary_person_id = ich, Sparplaene mit beneficiary = ich UND
--     eigenem Depot, Konten/Depots/Abbuchungen/Deckungs-Pills mit owner_person_id = ich (IS NOT DISTINCT FROM: ein
--     Haushaltskonto ohne Besitzer ist fuer sie verborgen). Ein fremdes Konto in Details heisst neutral „Haushaltskonto"
--     (Ziel-Anteile, Zubringer „Geld kommt von", Auftrag „→" an ein verborgenes Konto, ohne dessen Stand).
--   params.probe = true -> {ok, empty, banners}: Banner "hinter Plan" je sichtbarem Ziel (pace = behind) ohne fx-Luecke
--     (sonst waere der Rueckstand zu hoch gerechnet) + Banner je sichtbarem Deckungs-Konto im Zustand alert (nur alert:
--     ein gelbes „reicht bis" stuende bei 24 Monaten Horizont monatelang da) + Notreserve unvollstaendig, target = goals.
--     Der Bildschirm selbst traegt keine Banner (Pills). probe laeuft bei jedem App-Start -> nur Ziele + Ampel, Deckung nur
--     ueber das alert-Fenster, Ruecklagen/Sparplaene/Dauerauftraege/verplantes Geld per EXISTS, keine Details.
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request. Keine IDs in der Antwort.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (EXECUTE nur finance_rw/Host, nie *_ro).
--   Tests: tests/db/finance/test_fn_app_screen_goals.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_goals(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid       text;
    v_hh        boolean;
    v_goals     jsonb;
    v_total     numeric;
    v_gap       boolean;
    v_banners   jsonb;
    v_reserves  jsonb;
    v_res_total numeric;
    v_res_gap   boolean;
    v_plans     jsonb;
    v_plans_sum numeric;
    v_orders    jsonb;     -- je Quellkonto {monthly, cur, details} der Dauerauftraege
    v_accts     jsonb := '[]'::jsonb;
    v_sections  jsonb := '[]'::jsonb;
    v_hh_acct   jsonb := core.fn_ui_tpl('finance.app.common.household_account');
    v_probe     boolean;
    v_so        jsonb;
    v_cov       record;
    v_f         jsonb;
    v_fund      jsonb := '{}'::jsonb;
    v_fund_ban  jsonb := '[]'::jsonb;
    v_es        jsonb;     -- finance.fn_emergency_reserve_status() (Notreserve, nur Haushalts-Sicht)
    v_emerg     jsonb;     -- Zeile Notreserve
    v_a         record;
    v_dc        jsonb;     -- fn_depot_cover_state eines Depots
    v_pill      jsonb;
    v_rank      int;
    v_sub       jsonb;
    v_det       jsonb;
    v_val       jsonb;
    v_agap      boolean;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid   := p ->> 'person_id';
    v_hh    := core.fn_app_sees_household(v_pid);
    v_probe := COALESCE(p -> 'params' -> 'probe' = 'true'::jsonb, false);

    -- Dauerauftraege einmal je Aufruf (Deckungs-Konten, probe-empty, Abschnitt Konten lesen dieselbe Menge)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('rp_id', so.rp_id, 'head_id', so.head_id, 'kind', so.kind)), '[]'::jsonb)
      INTO v_so FROM finance.fn_standing_orders() so;

    -- Deckungs-Konten: Spar-Deckung je sichtbarem Konto (Pill + Details in 3/4, alert-Banner). probe rechnet nur das
    -- alert-Fenster (billig, App-Start); die Karte haelt je Konto die fertige Pill (keine IDs verlassen die DB).
    FOR v_cov IN
        SELECT a.id, a.name
          FROM finance.accounts a
         WHERE (v_hh OR a.owner_person_id IS NOT DISTINCT FROM v_pid)
           -- die EINE Konten-Regel (auch Karten-Hinweis savings_funding); die Seite filtert nur ihre Sichtbarkeit
           AND a.id IN (SELECT fa.account_id
                          FROM finance.fn_funding_accounts() fa
                         WHERE fa.kind = 'transfer' OR v_hh
                            OR (fa.beneficiary_person_id = v_pid AND fa.depot_owner_person_id = v_pid))
         ORDER BY a.name, a.id
    LOOP
        v_f := finance.fn_account_funding(v_cov.id, v_probe);
        CONTINUE WHEN (v_f ->> 'ok') IS DISTINCT FROM 'true';
        -- ok traegt keine Pille (gruen nur fuer die Hauptaussage einer Zeile)
        v_fund := v_fund || jsonb_build_object(v_cov.id::text, v_f || jsonb_build_object('pill', CASE v_f ->> 'state'
            WHEN 'ok'    THEN NULL
            WHEN 'warn'  THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                                  'text', core.fn_ui_tpl('finance.app.goals.fund_until', jsonb_build_object(
                                              'date', core.fn_ui_date((v_f ->> 'runs_out_on')::date))))
            WHEN 'alert' THEN jsonb_build_object('state', 'alert', 'icon', 'alert',
                                  'text', core.fn_ui_tpl('finance.app.goals.fund_gap', jsonb_build_object(
                                              'date', core.fn_ui_date((v_f ->> 'runs_out_on')::date))))
            ELSE jsonb_build_object('state', 'neutral', 'icon', 'info',
                                  'text', core.fn_ui_tpl('finance.app.goals.fund_unknown')) END));
        IF v_f ->> 'state' = 'alert' THEN
            v_fund_ban := v_fund_ban || jsonb_build_array(jsonb_build_object(
                'state', 'alert', 'icon', 'alert',
                'text', core.fn_ui_tpl('finance.app.goals.banner_fund_gap', jsonb_build_object(
                            'account', v_cov.name, 'date', core.fn_ui_date((v_f ->> 'runs_out_on')::date))),
                'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb)));
        END IF;
    END LOOP;

    -- Notreserve (2026-10-30): Ruecklage des HAUSHALTS -> nur fuer Haushalts-Betrachter (Zero-Trust); Rechnung allein in
    -- finance.fn_emergency_reserve_status (Ziel, Basis, Deckung je Konto)
    v_es := CASE WHEN v_hh THEN finance.fn_emergency_reserve_status() ELSE jsonb_build_object('exists', false) END;
    IF v_probe AND (v_es->>'exists')::boolean AND v_es->>'state' = 'warn' THEN
        v_fund_ban := jsonb_build_array(jsonb_build_object('state', 'warn', 'icon', 'alert',
            'text', core.fn_ui_tpl('finance.app.goals.banner_emergency', jsonb_build_object(
                        'covered', core.fn_ui_money((v_es->>'covered_eur')::numeric, 'EUR'),
                        'target', core.fn_ui_money((v_es->>'target_eur')::numeric, 'EUR'))),
            'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))) || v_fund_ban;
    END IF;

    -- probe (jeder App-Start): Ziele + Ampel fuer Banner, Ruecklagen/Sparplaene nur per EXISTS, keine Details
    IF v_probe THEN
        WITH g AS (
            SELECT sg.name, sg.target_date, sg.priority, sg.has_fx_gap, finance.fn_savings_goal_pace(sg.id) AS pace
              FROM finance.savings_goal_progress sg
             WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
               AND sg.id NOT IN (SELECT e.id FROM finance.savings_goals e WHERE e.kind = 'emergency_reserve')
               AND (v_hh OR sg.beneficiary_person_id = v_pid)
        )
        SELECT jsonb_build_object('ok', true,
                   'empty', count(*) = 0
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_goals sg
                                             WHERE sg.status = 'active' AND sg.real_estate_id IS NOT NULL
                                               AND (v_hh OR sg.beneficiary_person_id = v_pid))
                            AND NOT COALESCE((v_es->>'exists')::boolean, false)
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_plans s
                                              JOIN finance.accounts d ON d.id = s.depot_id
                                             WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid))
                            -- Dauerauftraege ohne Ziel/Plan (z. B. nur ein Vorsorge-Beitrag) halten den Bildschirm sichtbar
                            AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_so) AS so(rp_id int, head_id int, kind text)
                                              JOIN finance.recurring_payments r ON r.id = so.rp_id
                                              JOIN finance.accounts sa ON sa.id = r.account_id
                                             WHERE v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid)
                            -- verplantes Geld eines Ziels ohne Zielbetrag haelt ihn ebenso sichtbar
                            AND NOT EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                                              JOIN finance.accounts a ON a.id = s.account_id
                                             WHERE s.goal_status = 'active' AND (v_hh OR a.owner_person_id = v_pid)),
                   'banners', COALESCE(jsonb_agg(jsonb_build_object(
                       'state', 'warn', 'icon', 'alert',
                       'text', core.fn_ui_tpl('finance.app.goals.banner_behind', jsonb_build_object('name', g.name)),
                       'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))
                     ORDER BY g.target_date, g.priority NULLS LAST, g.name)
                     FILTER (WHERE g.pace = 'behind' AND NOT g.has_fx_gap), '[]'::jsonb))
          INTO v_banners
          FROM g;
        RETURN jsonb_set(v_banners, '{banners}', (v_banners -> 'banners') || v_fund_ban);
    END IF;

    -- 2 Sparziele (aktiv, mit Zielbetrag): hinter Plan zuerst, erreicht zuletzt; Ampel aus fn_savings_goal_pace
    WITH g AS (
        SELECT sg.id, sg.name, sg.target_amount, sg.target_date, sg.current_amount, sg.progress_percent, sg.priority,
               sg.has_fx_gap, sg.recurring_payment_id, sg.behind_amount, finance.fn_savings_goal_pace(sg.id) AS pace,
               age(sg.target_date, current_date) AS left_age
          FROM finance.savings_goal_progress sg
         WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
               AND sg.id NOT IN (SELECT e.id FROM finance.savings_goals e WHERE e.kind = 'emergency_reserve')
           AND (v_hh OR sg.beneficiary_person_id = v_pid)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', g.name,
               'sub', CASE WHEN g.pace IS DISTINCT FROM 'reached' AND g.target_date > current_date
                           THEN core.fn_ui_tpl('finance.app.goals.target_left', jsonb_build_object(
                                    'target', core.fn_ui_money(g.target_amount, 'EUR'),
                                    'left', CASE
                                        WHEN extract(year FROM g.left_age) > 0 AND extract(month FROM g.left_age) > 0
                                        THEN core.fn_ui_tpl('finance.app.goals.left_ym', jsonb_build_object(
                                                 'years', core.fn_ui_num(extract(year FROM g.left_age)),
                                                 'months', core.fn_ui_num(extract(month FROM g.left_age))))
                                        WHEN extract(year FROM g.left_age) > 0
                                        THEN core.fn_ui_tpl('finance.app.goals.left_y', jsonb_build_object(
                                                 'years', core.fn_ui_num(extract(year FROM g.left_age))))
                                        WHEN extract(month FROM g.left_age) > 0
                                        THEN core.fn_ui_tpl('finance.app.goals.left_m', jsonb_build_object(
                                                 'months', core.fn_ui_num(extract(month FROM g.left_age))))
                                        ELSE core.fn_ui_tpl('finance.app.goals.left_lt_month') END))
                           ELSE core.fn_ui_tpl('finance.app.goals.target_by', jsonb_build_object(
                                    'target', core.fn_ui_money(g.target_amount, 'EUR'), 'date', core.fn_ui_date(g.target_date)))
                      END,
               'value', core.fn_ui_money(g.current_amount, 'EUR'),
               'gap', g.has_fx_gap,
               'pill', CASE g.pace
                           WHEN 'on_track' THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.on_track'))
                           WHEN 'behind' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                                    'text', CASE WHEN g.behind_amount > 0
                                                                 THEN core.fn_ui_tpl('finance.app.goals.pace.behind_gap', jsonb_build_object(
                                                                          'gap', core.fn_ui_money(g.behind_amount, 'EUR')))
                                                                 ELSE core.fn_ui_tpl('finance.app.goals.pace.behind') END)
                           WHEN 'reached' THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.reached'))
                           WHEN 'paused' THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))
                           WHEN 'unmeasurable' THEN jsonb_build_object('state', 'neutral', 'icon', 'info',
                                                    'text', core.fn_ui_tpl('finance.app.goals.pace.unmeasurable'))
                       END,
               -- Balken = Fortschritt zum Zielbetrag; erreicht -> kein Balken (die Pille sagt es)
               'progress', CASE WHEN g.progress_percent IS NOT NULL AND g.pace IS DISTINCT FROM 'reached' THEN jsonb_build_object(
                               'pct', round(LEAST(GREATEST(g.progress_percent, 0), 100), 1),
                               'state', CASE g.pace WHEN 'behind' THEN 'warn'
                                                    WHEN 'on_track' THEN 'ok'
                                                    ELSE 'neutral' END) END,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o, x.k), '[]'::jsonb) FROM (
                   -- Zieldatum (der Untertitel nennt die Restzeit; ein Untertitel bleibt einzeilig)
                   SELECT 0 AS o, ''::text AS k, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_target_date'),
                              'value', core.fn_ui_date(g.target_date)) AS d
                    WHERE g.pace IS DISTINCT FROM 'reached' AND g.target_date > current_date
                   UNION ALL
                   -- Sparrate des heute gueltigen Glieds (laufend), Abbuchungskonto nur wenn sichtbar
                   SELECT 1, '', jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object(
                                  'rate', core.fn_ui_money(abs(rp.monthly_equivalent), ra.currency),
                                  'account', CASE WHEN v_hh OR ra.owner_person_id = v_pid THEN to_jsonb(ra.name)
                                                  ELSE v_hh_acct END)))
                     FROM finance.recurring_payments rp
                     JOIN finance.accounts ra ON ra.id = rp.account_id
                    -- „laeuft gerade" = exakt das Praedikat von finance.active_recurring_payments
                    WHERE rp.id = finance.fn_recurring_current(g.recurring_payment_id, current_date)
                      AND rp.status = 'active' AND rp.valid_from <= current_date
                      AND (rp.valid_to IS NULL OR rp.valid_to > current_date)
                   UNION ALL
                   -- wo liegt das Geld: je Konto der Anteil (Summe = Zielstand)
                   SELECT 2, s.account_name, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object(
                                  'account', CASE WHEN v_hh OR sa.owner_person_id = v_pid THEN to_jsonb(s.account_name)
                                                  ELSE v_hh_acct END)),
                              'value', CASE WHEN s.share_native IS NOT NULL THEN core.fn_ui_money(s.share_native, s.account_currency)
                                            ELSE core.fn_ui_money(s.share_eur, 'EUR') END)
                     FROM finance.savings_goal_account_share s
                     JOIN finance.accounts sa ON sa.id = s.account_id
                    WHERE s.goal_id = g.id AND COALESCE(s.share_native, s.share_eur, 0) <> 0) x))
             ORDER BY CASE g.pace WHEN 'behind' THEN 0 WHEN 'reached' THEN 2 ELSE 1 END,
                      g.target_date, g.priority NULLS LAST, g.name), '[]'::jsonb),
           COALESCE(sum(g.current_amount), 0),
           COALESCE(bool_or(g.has_fx_gap), false)
      INTO v_goals, v_total, v_gap
      FROM g;

    -- 1 Ruecklagen: Notreserve (nur Haushalt) + Instandhaltung (Stand, Rate, Empfehlung + Herleitung zum Aufklappen)
    IF (v_es->>'exists')::boolean THEN
        v_emerg := jsonb_build_object(
            'label', v_es->>'name',
            'sub', CASE WHEN v_es->>'target_kind' = 'months' AND v_es->'target_eur' <> 'null'::jsonb
                        THEN core.fn_ui_tpl('finance.app.goals.emergency_sub_months', jsonb_build_object(
                                 'target', core.fn_ui_money((v_es->>'target_eur')::numeric, 'EUR'),
                                 'months', core.fn_ui_num((v_es->>'months')::numeric, 1)))
                        WHEN v_es->>'target_kind' = 'months'
                        THEN core.fn_ui_tpl('finance.app.goals.emergency_sub_unknown', jsonb_build_object(
                                 'months', core.fn_ui_num((v_es->>'months')::numeric, 1)))
                        ELSE core.fn_ui_tpl('finance.app.goals.emergency_sub_amount', jsonb_build_object(
                                 'target', core.fn_ui_money((v_es->>'target_eur')::numeric, 'EUR'))) END,
            'value', core.fn_ui_money((v_es->>'covered_eur')::numeric, 'EUR'),
            'gap', (v_es->>'has_fx_gap')::boolean,
            'pill', CASE v_es->>'state'
                        WHEN 'ok' THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                          'text', core.fn_ui_tpl('finance.app.goals.emergency_ok'))
                        WHEN 'warn' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                          'text', core.fn_ui_tpl('finance.app.goals.missing', jsonb_build_object(
                                              'gap', core.fn_ui_money((v_es->>'gap_eur')::numeric, 'EUR'))))
                        ELSE jsonb_build_object('state', 'neutral', 'icon', 'info',
                                          'text', core.fn_ui_tpl('finance.app.goals.emergency_unknown')) END,
            -- Balken nur solange nicht vollstaendig (vollstaendig = erreicht, die Pille sagt es)
            'progress', CASE WHEN (v_es->>'target_eur')::numeric > 0 AND v_es->>'state' IS DISTINCT FROM 'ok' THEN jsonb_build_object(
                            'pct', round(LEAST(100 * (v_es->>'covered_eur')::numeric / (v_es->>'target_eur')::numeric, 100), 1),
                            'state', CASE WHEN v_es->>'state' = 'warn' THEN 'warn' ELSE 'neutral' END) END,
            'target', NULL,
            'details', CASE WHEN v_es->>'target_kind' = 'months' THEN jsonb_build_array(
                           jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_emergency_fixed'),
                                              'value', core.fn_ui_money((v_es->'basis'->>'fixed_eur')::numeric, 'EUR')),
                           jsonb_build_object('label', core.fn_ui_tpl(CASE WHEN (v_es->'basis'->>'everyday_provisional')::boolean
                                                                           THEN 'finance.app.goals.d_emergency_everyday_provisional'
                                                                           ELSE 'finance.app.goals.d_emergency_everyday' END),
                                              'value', core.fn_ui_money((v_es->'basis'->>'everyday_eur')::numeric, 'EUR')),
                           jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_emergency_monthly',
                                                  jsonb_build_object('months', core.fn_ui_num((v_es->>'months')::numeric, 1))),
                                              'value', core.fn_ui_money((v_es->'basis'->>'monthly_eur')::numeric, 'EUR')))
                           ELSE '[]'::jsonb END
                       || COALESCE((SELECT jsonb_agg(jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object('account', a->>'name')),
                              'value', core.fn_ui_money((a->>'eur')::numeric, 'EUR')))
                            FROM jsonb_array_elements(v_es->'accounts') a), '[]'::jsonb));
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', m.goal_name,
               'sub', CASE WHEN m.running_monthly_eur IS NOT NULL AND m.gap_monthly_eur = 0
                           THEN core.fn_ui_tpl('finance.app.goals.reserve_rate_as_rec', jsonb_build_object(
                                    'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR')))
                           WHEN m.running_monthly_eur IS NOT NULL AND m.recommended_monthly IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.reserve_rate_rec', jsonb_build_object(
                                    'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'),
                                    'recommended', core.fn_ui_money(m.recommended_monthly, 'EUR')))
                           WHEN m.running_monthly_eur IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                    'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'))) END,
               'value', core.fn_ui_money(m.saved_eur, 'EUR'),
               'gap', COALESCE(sg.has_fx_gap, false),
               'pill', CASE WHEN m.property_status <> 'active' THEN NULL
                            WHEN m.gap_monthly_eur > 0
                            THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                     'text', core.fn_ui_tpl('finance.app.goals.reserve_low', jsonb_build_object(
                                                 'gap', core.fn_ui_money(m.gap_monthly_eur, 'EUR'))))
                            WHEN m.gap_monthly_eur <= 0
                            THEN jsonb_build_object('state', 'ok', 'icon', 'check',
                                     'text', core.fn_ui_tpl('finance.app.goals.reserve_ok')) END,
               -- kein Balken: eine Ruecklage hat kein Betragsziel (Owner-Entscheid 2026-10-30)
               'progress', NULL,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 1 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_property'),
                              'value', m.real_estate_name) AS d
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_area'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_area_value', jsonb_build_object(
                                  'area', core.fn_ui_num(m.living_area_m2, scale(trim_scale(m.living_area_m2))))))
                    WHERE m.living_area_m2 IS NOT NULL
                   UNION ALL
                   SELECT 3, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_built'),
                              'value', CASE WHEN m.age_years IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.goals.d_built_value', jsonb_build_object(
                                                     'year', m.year_built::text, 'age', core.fn_ui_num(m.age_years)))
                                            ELSE to_jsonb(m.year_built::text) END)
                    WHERE m.year_built IS NOT NULL
                   UNION ALL
                   SELECT 4, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate_m2'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_rate_m2_value', jsonb_build_object(
                                  'rate', core.fn_ui_money(m.rate_eur_m2, 'EUR'))))
                    WHERE m.rate_eur_m2 IS NOT NULL
                   UNION ALL
                   SELECT 5, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_recommended'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_recommended_value', jsonb_build_object(
                                  'annual', core.fn_ui_money(m.recommended_annual, 'EUR'),
                                  'monthly', core.fn_ui_money(m.recommended_monthly, 'EUR'))))
                    WHERE m.recommended_monthly IS NOT NULL
                   UNION ALL
                   SELECT 6, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_missing'), 'value', NULL)
                    WHERE m.recommended_monthly IS NULL AND (m.living_area_m2 IS NULL OR m.year_built IS NULL)
                   UNION ALL
                   SELECT 7, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_running'),
                              'value', core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                  'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'))))
                    WHERE m.running_monthly_eur IS NOT NULL) x))
             ORDER BY COALESCE(m.gap_monthly_eur > 0 AND m.property_status = 'active', false) DESC, m.goal_name), '[]'::jsonb),
           COALESCE(sum(m.saved_eur), 0),
           COALESCE(bool_or(sg.has_fx_gap), false)
      INTO v_reserves, v_res_total, v_res_gap
      FROM finance.maintenance_reserve_status m
      JOIN finance.savings_goals g ON g.id = m.goal_id
      LEFT JOIN finance.savings_goal_progress sg ON sg.id = m.goal_id
     WHERE v_hh OR g.beneficiary_person_id = v_pid;

    IF v_emerg IS NOT NULL THEN
        v_reserves := jsonb_build_array(v_emerg) || v_reserves;
        v_res_total := v_res_total + COALESCE((v_es->>'covered_eur')::numeric, 0);
        v_res_gap := v_res_gap OR COALESCE((v_es->>'has_fx_gap')::boolean, false);
    END IF;

    -- 3 Sparplaene: aktiv vor pausiert, Wert = Monatsbetrag, Details (Zufluesse/Konto stehen unter 4)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', s.name,
               -- „je Ausfuehrung" nur, wenn es vom Monatsbetrag (Wert rechts) abweicht (kein Fakt doppelt)
               'sub', CASE WHEN s.status = 'active' AND s.next_execution IS NOT NULL AND s.amount_per_execution = s.monthly_amount
                           THEN core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object(
                                    'date', core.fn_ui_date(s.next_execution)))
                           WHEN s.status = 'active' AND s.next_execution IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.plan_exec_next', jsonb_build_object(
                                    'amount', core.fn_ui_money(s.amount_per_execution, s.currency),
                                    'date', core.fn_ui_date(s.next_execution)))
                           WHEN s.status = 'active'
                           THEN core.fn_ui_tpl('finance.app.goals.plan_exec', jsonb_build_object(
                                    'amount', core.fn_ui_money(s.amount_per_execution, s.currency))) END,
               'value', core.fn_ui_money(s.monthly_amount, s.currency),
               'gap', COALESCE(s.status = 'active' AND (v_fund -> s.settlement_account_id::text ->> 'fx_gap')::boolean, false),
               'pill', CASE WHEN s.status = 'paused'
                            THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                     'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))
                            -- nur eine abweichende Deckung (ok = keine Pille, s. Deckungs-Konten oben)
                            WHEN s.status = 'active' THEN v_fund -> s.settlement_account_id::text -> 'pill' END,
               'progress', NULL,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 1 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_security'),
                              'value', CASE WHEN s.isin IS NOT NULL
                                            THEN core.fn_ui_tpl('finance.app.goals.d_security_value', jsonb_build_object(
                                                     'name', COALESCE(s.security_name, s.symbol), 'isin', s.isin))
                                            ELSE to_jsonb(COALESCE(s.security_name, s.symbol)) END) AS d
                    WHERE COALESCE(s.security_name, s.symbol) IS NOT NULL
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_depot'), 'value', s.depot_name)
                   UNION ALL
                   SELECT 3, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_from'),
                              'value', s.settlement_account_name)
                    WHERE v_hh
                   UNION ALL
                   SELECT 4, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_for'), 'value', bp.full_name)
                    WHERE v_hh AND bp.full_name IS NOT NULL
                   UNION ALL
                   SELECT 5, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_goal'),
                              'value', s.savings_goal_name)
                    WHERE s.savings_goal_name IS NOT NULL
                   UNION ALL
                   SELECT 6, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_change', jsonb_build_object(
                                           'date', core.fn_ui_date(s.change_from))),
                              'value', core.fn_ui_tpl('finance.app.goals.plan_exec', jsonb_build_object(
                                           'amount', core.fn_ui_money(s.new_amount_per_execution, s.currency))))
                    WHERE s.change_from IS NOT NULL AND s.new_amount_per_execution IS NOT NULL
                   UNION ALL
                   SELECT 7, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_position'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_position_value', jsonb_build_object(
                                  'value', CASE WHEN o.market_value_eur IS NOT NULL
                                                THEN core.fn_ui_money(o.market_value_eur, 'EUR') END,
                                  'book', core.fn_ui_money(o.book_value, o.currency))))
                     FROM (SELECT ho.market_value_eur, ho.book_value, ho.currency
                             FROM finance.depot_holdings_overview ho
                            WHERE ho.account_id = s.depot_id
                              AND ((s.isin IS NOT NULL AND ho.isin = s.isin) OR ho.symbol = s.symbol)
                            ORDER BY (ho.isin IS NOT DISTINCT FROM s.isin) DESC, ho.holding_id
                            LIMIT 1) o) x))
             ORDER BY (s.status = 'active') DESC, s.name), '[]'::jsonb),
           -- Summe nur ohne fehlenden Wechselkurs (sonst still zu niedrig): NULL -> entfaellt
           CASE WHEN NOT COALESCE(bool_or(finance.fn_to_eur(s.monthly_amount, s.currency) IS NULL)
                                  FILTER (WHERE s.status = 'active'), false)
                THEN sum(finance.fn_to_eur(s.monthly_amount, s.currency)) FILTER (WHERE s.status = 'active') END
      INTO v_plans, v_plans_sum
      FROM finance.savings_plan_overview s
      JOIN finance.accounts d ON d.id = s.depot_id
      LEFT JOIN core.fn_household_persons() bp ON bp.person_id = s.beneficiary_person_id
     WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid);

    -- 4a Dauerauftraege je sichtbarem Quellkonto: Monatssumme + Bank-To-do (Auftraege + geplante Aenderungen)
    WITH o AS (
        SELECT so.rp_id, so.head_id, so.kind, r.name, r.account_id, r.valid_from AS cur_from,
               abs(r.monthly_equivalent) AS monthly,
               sa.currency AS src_cur, ta.name AS tgt_name,
               (ta.id IS NOT NULL AND (v_hh OR ta.owner_person_id IS NOT DISTINCT FROM v_pid)) AS tgt_vis
          FROM jsonb_to_recordset(v_so) AS so(rp_id int, head_id int, kind text)
          JOIN finance.recurring_payments r ON r.id = so.rp_id
          JOIN finance.accounts sa ON sa.id = r.account_id
          LEFT JOIN finance.accounts ta ON ta.id = r.target_account_id
         WHERE v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid
    ), l AS (
        SELECT o.account_id, o.monthly, o.rp_id, 0 AS k, NULL::date AS kd, jsonb_build_object(
                   'label', CASE WHEN o.kind = 'transfer'
                                 THEN core.fn_ui_tpl('finance.app.goals.d_order_to', jsonb_build_object('account',
                                          CASE WHEN o.tgt_vis THEN to_jsonb(o.tgt_name) ELSE v_hh_acct END))
                                 ELSE to_jsonb(o.name) END,
                   'value', finance.fn_app_order_line(o.rp_id)) AS d
          FROM o
        UNION ALL
        -- geplante Aenderungen der Kette (jedes spaeter startende Glied, nicht nur der Kopf): je eine Zeile darunter
        SELECT o.account_id, o.monthly, o.rp_id, 1, h.valid_from, jsonb_build_object(
                   'label', core.fn_ui_tpl('finance.app.goals.d_order_change', jsonb_build_object(
                                'date', core.fn_ui_date(h.valid_from))),
                   'value', finance.fn_app_order_line(h.id))
          FROM o
          JOIN finance.recurring_payments h ON h.id IN (SELECT finance.fn_recurring_lineage(o.rp_id))
         WHERE h.valid_from > GREATEST(current_date, o.cur_from)
    ), a AS (
        SELECT l.account_id, jsonb_agg(l.d ORDER BY l.monthly DESC, l.rp_id, l.k, l.kd) AS details
          FROM l GROUP BY l.account_id
    ), m AS (
        SELECT o.account_id, min(o.src_cur) AS src_cur, sum(o.monthly) AS monthly
          FROM o GROUP BY o.account_id
    )
    SELECT COALESCE(jsonb_object_agg(m.account_id::text, jsonb_build_object(
               'monthly', m.monthly, 'cur', m.src_cur, 'details', a.details)), '{}'::jsonb)
      INTO v_orders
      FROM m JOIN a ON a.account_id = m.account_id;

    -- 4 Konten: je sichtbarem Konto mit Ziel-Geld, Dauerauftraegen als Quelle oder Spar-Deckung eine Zeile
    FOR v_a IN
        SELECT a.id, a.name, a.currency, a.account_type, a.owner_person_id,
               COALESCE(ab.balance, 0) AS balance,
               COALESCE(rs.reserved, 0) AS reserved, COALESCE(rs.shortfall, 0) AS shortfall
          FROM finance.accounts a
          LEFT JOIN finance.account_balances ab ON ab.account_id = a.id
          LEFT JOIN finance.account_reserve_status rs ON rs.account_id = a.id
         WHERE a.status = 'active'
           AND (v_hh OR a.owner_person_id IS NOT DISTINCT FROM v_pid)
           AND (COALESCE(rs.reserved, 0) > 0
                OR v_orders ? a.id::text
                OR v_fund ? a.id::text
                OR (a.account_type IN ('stocks_depot', 'crypto_depot') AND (
                        EXISTS (SELECT 1 FROM finance.depot_reserve_status d WHERE d.account_id = a.id AND d.reserved > 0)
                     OR EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                                 WHERE s.account_id = a.id AND s.goal_status = 'active' AND s.has_fx_gap))))
    LOOP
        v_f := v_fund -> v_a.id::text;
        v_dc := CASE WHEN v_a.account_type IN ('stocks_depot', 'crypto_depot') THEN finance.fn_depot_cover_state(v_a.id) END;
        v_agap := COALESCE((v_f ->> 'fx_gap')::boolean, false) OR COALESCE(v_dc ->> 'state' = 'unknown', false);

        -- Pille nur bei Abweichung, Rang alert > warn > neutral
        v_pill := NULL; v_rank := 3;
        IF v_f ->> 'state' = 'alert' THEN
            v_pill := v_f -> 'pill'; v_rank := 0;
        ELSIF v_a.shortfall > 0 OR v_dc ->> 'state' = 'short' THEN
            v_pill := jsonb_build_object('state', 'warn', 'icon', 'alert',
                          'text', core.fn_ui_tpl('finance.app.goals.missing', jsonb_build_object('gap',
                                      CASE WHEN v_dc IS NOT NULL THEN core.fn_ui_money((v_dc ->> 'gap')::numeric, 'EUR')
                                           ELSE core.fn_ui_money(v_a.shortfall, v_a.currency) END)));
            v_rank := 1;
        ELSIF v_f ->> 'state' = 'warn' THEN
            v_pill := v_f -> 'pill'; v_rank := 1;
        ELSIF v_dc ->> 'state' = 'dip' THEN
            v_pill := jsonb_build_object('state', 'neutral', 'icon', 'info',
                          'text', core.fn_ui_tpl('finance.app.goals.cover_dip', jsonb_build_object(
                                      'gap', core.fn_ui_money((v_dc ->> 'gap')::numeric, 'EUR'))));
            v_rank := 2;
        ELSIF v_dc ->> 'state' = 'unknown' THEN
            v_pill := jsonb_build_object('state', 'neutral', 'icon', 'info',
                          'text', core.fn_ui_tpl('finance.app.goals.cover_unknown'));
            v_rank := 2;
        ELSIF v_f IS NOT NULL AND v_f -> 'pill' IS NOT NULL AND jsonb_typeof(v_f -> 'pill') = 'object' THEN
            v_pill := v_f -> 'pill'; v_rank := 2;
        END IF;

        -- Wert = Kontostand (nativ) bzw. Depot-Marktwert (EUR); Untertitel = Ziel-Geld oder Auftrags-Summe
        IF v_dc IS NOT NULL THEN
            v_val := core.fn_ui_money((v_dc ->> 'market_value')::numeric, 'EUR');
            v_sub := CASE WHEN (v_dc ->> 'reserved')::numeric > 0 AND v_dc ->> 'state' = 'ok'
                          THEN core.fn_ui_tpl('finance.app.goals.accounts_reserved_free', jsonb_build_object(
                                   'reserved', core.fn_ui_money((v_dc ->> 'reserved')::numeric, 'EUR'),
                                   'free', core.fn_ui_money((v_dc ->> 'market_value')::numeric - (v_dc ->> 'reserved')::numeric, 'EUR')))
                          WHEN (v_dc ->> 'reserved')::numeric > 0
                          THEN core.fn_ui_tpl('finance.app.goals.accounts_reserved', jsonb_build_object(
                                   'reserved', core.fn_ui_money((v_dc ->> 'reserved')::numeric, 'EUR'))) END;
        ELSE
            v_val := core.fn_ui_money(v_a.balance, v_a.currency);
            v_sub := CASE WHEN v_a.reserved > 0 AND v_a.shortfall = 0
                          THEN core.fn_ui_tpl('finance.app.goals.accounts_reserved_free', jsonb_build_object(
                                   'reserved', core.fn_ui_money(v_a.reserved, v_a.currency),
                                   'free', core.fn_ui_money(v_a.balance - v_a.reserved, v_a.currency)))
                          WHEN v_a.reserved > 0
                          THEN core.fn_ui_tpl('finance.app.goals.accounts_reserved', jsonb_build_object(
                                   'reserved', core.fn_ui_money(v_a.reserved, v_a.currency))) END;
        END IF;
        IF v_sub IS NULL AND v_orders ? v_a.id::text THEN
            v_sub := core.fn_ui_tpl('finance.app.goals.accounts_orders', jsonb_build_object(
                         'monthly', core.fn_ui_money((v_orders -> v_a.id::text ->> 'monthly')::numeric,
                                                     v_orders -> v_a.id::text ->> 'cur')));
        END IF;

        -- Details: Bank-To-do, Zufluesse („Geld kommt von", groesster zuerst), Konto (rein · raus · tiefster Stand), Alltag
        v_det := COALESCE(v_orders -> v_a.id::text -> 'details', '[]'::jsonb);
        IF v_f IS NOT NULL THEN
            v_det := v_det || COALESCE((SELECT jsonb_agg(x.d ORDER BY x.k, x.n) FROM (
                SELECT -COALESCE(af.monthly, 0) AS k, fl.id AS n, jsonb_build_object(
                           'label', core.fn_ui_tpl('finance.app.goals.d_money_from', jsonb_build_object('source',
                                        CASE WHEN fl.target_account_id IS NULL THEN to_jsonb(fl.name)
                                             WHEN v_hh OR fa.owner_person_id IS NOT DISTINCT FROM v_pid THEN to_jsonb(fa.name)
                                             ELSE v_hh_acct END)),
                           'value', finance.fn_app_order_line(fl.id)) AS d
                  FROM finance.fn_account_flows(v_a.id) af
                  JOIN finance.recurring_payments fl ON fl.id = af.rp_id
                  JOIN finance.accounts fa ON fa.id = fl.account_id
                 WHERE af.side = 'in') x), '[]'::jsonb);
            v_det := v_det || jsonb_build_array(jsonb_build_object(
                'label', core.fn_ui_tpl('finance.app.goals.d_fund_account', jsonb_build_object('account', v_a.name)),
                'value', CASE WHEN v_f ->> 'everyday' = 'unknown'
                              THEN core.fn_ui_tpl('finance.app.goals.d_fund_everyday_unknown')
                              ELSE core.fn_ui_tpl('finance.app.goals.d_fund_summary', jsonb_build_object(
                                       'in', core.fn_ui_money((v_f ->> 'monthly_in')::numeric, v_a.currency),
                                       'out', core.fn_ui_money(-(v_f ->> 'monthly_out')::numeric, v_a.currency),
                                       'min', core.fn_ui_money((v_f ->> 'min_projected')::numeric, v_a.currency),
                                       'date', core.fn_ui_date((v_f ->> 'min_date')::date))) END));
            -- Transparenz 2026-10-30: die Deckung rechnet mit der Netto-Alltags-Schaetzung aus den Kontoauszuegen
            IF v_f ->> 'everyday' = 'estimated' THEN
                v_det := v_det || jsonb_build_array(jsonb_build_object(
                    'label', core.fn_ui_tpl('finance.app.goals.d_fund_everyday'),
                    'value', core.fn_ui_tpl('finance.app.goals.d_fund_everyday_value', jsonb_build_object('per_day',
                        core.fn_ui_money(abs((v_f ->> 'everyday_per_day')::numeric), v_a.currency)))));
            END IF;
        END IF;

        v_accts := v_accts || jsonb_build_array(jsonb_build_object('rank', v_rank, 'name', v_a.name, 'item', jsonb_build_object(
            'label', v_a.name, 'sub', v_sub, 'value', v_val, 'gap', v_agap, 'pill', v_pill,
            'progress', NULL, 'target', NULL, 'details', v_det)));
    END LOOP;
    SELECT COALESCE(jsonb_agg(x -> 'item' ORDER BY (x ->> 'rank')::int, x ->> 'name'), '[]'::jsonb)
      INTO v_accts FROM jsonb_array_elements(v_accts) x;

    -- Sparziele immer (mit Leer-Text), alles Weitere nur mit Eintraegen
    IF jsonb_array_length(v_reserves) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_reserves'),
            'value', CASE WHEN NOT v_res_gap THEN core.fn_ui_money(v_res_total, 'EUR') END,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_reserves);
    END IF;
    v_sections := v_sections || jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.goals.section_goals'),
        'value', CASE WHEN jsonb_array_length(v_goals) > 0 AND NOT v_gap THEN core.fn_ui_money(v_total, 'EUR') END,
        'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_goals);
    IF jsonb_array_length(v_plans) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_plans'),
            'value', CASE WHEN v_plans_sum > 0 THEN core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                                        'rate', core.fn_ui_money(v_plans_sum, 'EUR'))) END,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_plans);
    END IF;
    IF jsonb_array_length(v_accts) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_accounts'),
            'value', NULL,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_accts);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.goals.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.goals.hero'),
            'value', core.fn_ui_money(v_total + v_res_total, 'EUR'),
            'gap', v_gap OR v_res_gap,
            -- Aufschluesselung nur mit Ruecklagen und ohne fx-Luecke (sonst waeren die Teile still zu niedrig)
            'note', CASE WHEN jsonb_array_length(v_reserves) > 0 AND NOT (v_gap OR v_res_gap)
                         THEN core.fn_ui_tpl('finance.app.goals.hero_note', jsonb_build_object(
                                  'goals', core.fn_ui_money(v_total, 'EUR'), 'reserves', core.fn_ui_money(v_res_total, 'EUR'))) END),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_goals(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
