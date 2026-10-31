-- ============================================================
-- finance.fn_app_screen_goals(p jsonb) — Mini-App-Bildschirm „Ziele" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12, Design-Regeln dort), Muster
--   finance.fn_app_screen_overview. UX-Gesamtkonzept 2026-10-31 §5.3: „Kommen wir mit dem Sparen voran, und was laeuft
--   automatisch?" Je Abschnitt EINE Frage; eine Zeile gehoert nur hinein, wenn sie genau diese Frage beantwortet:
--   Abschnitt finance.app.goals.section_reserves: Frage: Sind die Ruecklagen voll, und wird genug zurueckgelegt?
--   Abschnitt finance.app.goals.section_goals: Frage: Wie weit ist jedes Sparziel, und woher kommt seine Rate?
--   Abschnitt finance.app.goals.section_plans: Frage: Was wird automatisch ins Depot gespart?
--   Kontostaende, „frei", Dauerauftraege und Konto-Hinweise haben ihre Heimat im Bildschirm Konten (ein Fakt, ein Platz).
--   Quellen: savings_goal_progress (Ziele; Ampel = finance.fn_savings_goal_pace, die EINE Regel, die auch der Berater
--   nutzt; Rueckstand behind_amount), savings_goal_account_share (wo liegt das Geld), finance.fn_depot_cover_state
--   (Kurswert eines Depots gegen das Ziel-Geld darin), finance.fn_savings_goal_sources (Quelle der Rate),
--   fn_emergency_reserve_status (Notreserve), maintenance_reserve_status (Instandhaltung + Richtwert nach II. BV),
--   savings_plan_overview (Sparplaene), fn_account_low_state (Zustand des Abbuchungskontos), fn_app_order_line
--   (Betrag · Rhythmus). Die Seite rechnet nichts.
--   PILLE = HANDLUNGSBEDARF (§3.12): nur warn/alert mit Betrag, Datum oder Monat; neutral nur „pausiert" bzw. „nicht
--   messbar: kein Konto zugeordnet" (sagt, was fehlt); NIE ok, auch kein ok-Balken (Balken auf Kurs = neutral/Akzent).
--   Hero „Zurueckgelegt" = Sparziele + Ruecklagen (Notreserve gedeckt + Instandhaltung), Note mit der Aufschluesselung
--     (entfaellt bei fx-Luecke, dann gap). Keine Abschnittssumme bei Ruecklagen/Sparzielen (= Note). Keine Doppelzaehlung:
--     Instandhaltung hat per Form-CHECK keinen Zielbetrag, die Notreserve ist aus der Ziel-Liste ausgeschlossen.
--   1 Ruecklagen (Notreserve nur fuer Haushalts-Betrachter, Zero-Trust; Reihenfolge gelb -> uebrige -> volle Notreserve):
--     Notreserve: Wert gedeckt, „Ziel x" + Balken + warn „fehlen x" solange unvollstaendig; voll -> „Ziel x erreicht",
--     keine Pille, kein Balken; neutral (Ausgaben unbekannt) ohne Pille. Aufklappen = Herleitung (nur Monats-Ziel) + Geld
--     je Konto. Instandhaltung: „x im Monat", warn „x im Monat unter Richtwert" (aktive Immobilie mit Richtwert), kein
--     Balken; Aufklappen = Rate wie bei den Sparzielen („Rate von <Konto>" = Betrag · Rhythmus des heute gueltigen
--     Glieds), „Richtwert nach II. BV" (Monat aus Flaeche x Satz) bzw. „fehlen Wohnflaeche oder Baujahr", Immobilie.
--   2 Sparziele (aktiv, mit Zielbetrag): alert -> warn -> uebrige nach Datum/Prioritaet/Name -> erreicht. Untertitel „von x
--     · bis <Monat>" bzw. „x erreicht · geplant fuer <Datum>". Pille nach Rang: alert „<Depot>: Kurswert x unter dem
--     Zurueckgelegten" (ein fuer den Betrachter SICHTBARES Depot mit Ziel-Geld im Zustand short; eine Delle (dip) zeigt
--     nichts; mehrere Ziele auf einem Depot tragen dieselbe Pille, der Depot-Name sagt, wen sie betrifft) > warn „hinter
--     Plan · fehlen x" (behind_amount > 0; bei fx-Luecke keine Pille, der Rueckstand waere zu hoch, nur gap — BACKLOG)
--     > neutral pausiert / nicht messbar. gap auch bei einem sichtbaren Depot ohne Kurs (unknown) und bei einer
--     Plan-Rate ohne Kurs. Aufklappen (<= 8 Zeilen): Rate je Quellen-Art (Sparplaene mit Namen — fuer das Kind nur die
--     sichtbaren, der Betrag zaehlt alle; Dauerauftrag „Rate von <Konto>" = Betrag · Rhythmus; sonst „keine laufende
--     Rate", nicht bei erreicht), „liegt auf <Konto>" je Anteil (groesste zuerst; mehr als vier -> „liegt auf n weiteren Konten" mit dem
--     Rest), Zieldatum (nicht bei erreicht).
--   3 Sparplaene: alert -> warn -> aktiv -> pausiert, je Name. Wert = Monatsbetrag; Untertitel aus dem HEUTE gueltigen
--     Glied: feste Tage „n× monatlich je x · naechste", eine Ausfuehrung je Monat „naechste", sonst Betrag · Rhythmus.
--     Summe der aktiven Plaene als section.value (der Renderer setzt „zusammen" davor) nur ab 2 aktiven Plaenen und ohne
--     gap an einer Zeile. Pille = Spiegel des sichtbaren Abbuchungskontos (fn_funding_accounts kind 'plan'): dasselbe
--     Urteil und dieselbe Pille wie die Konten-Zeile „Tiefster Stand" (fn_account_low_state + fn_app_low_state_pill:
--     knapp / unter dem Puffer / reicht bis / Luecke ab; Kurs fehlt -> gap); sonst neutral „pausiert".
--     Aufklappen: Wertpapier (Name), Depot,
--     Abbuchung von + Fuer (nur Haushalt), Sparziel, geplante Aenderung (Betrag · Rhythmus · ab).
--   ZERO-TRUST-SICHTBARKEIT (Rolle loest der Handler selbst auf, core.fn_app_sees_household): owner/partner sehen den
--     Haushalt, alle anderen nur Ziel/Ruecklage mit beneficiary_person_id = ich, Sparplaene mit beneficiary = ich UND
--     eigenem Depot, Konten/Depots mit owner_person_id = ich (IS NOT DISTINCT FROM: ein Haushaltskonto ohne Besitzer ist
--     verborgen). Ein fremdes Konto heisst neutral „Haushaltskonto"; ein fremdes Depot gibt keine Pille und keinen Betrag.
--   params.probe = true -> {ok, empty, banners}: Banner „hinter Plan" je sichtbarem Ziel mit Pille (behind ohne
--     fx-Luecke), target = goals. Kein Notreserve-Banner (Dauerzustand, Owner D3 2026-10-31). Konto-Hinweise kommen
--     vom probe des Bildschirms Konten — ausser fuer Deckungs-Konten (fn_funding_accounts), die der Konten-Tab dieser
--     Person nicht zeigt (finance.fn_app_accounts_listed; Kinder-Konten in der Haushalts-Sicht): fuer sie hier derselbe
--     Banner wie dort (fn_account_low_state mit p_alert_only, Satz + Umbuchungs-Vorschlag fn_app_low_state_banner),
--     target = goals. probe laeuft bei jedem App-Start -> nur Ziele + Ampel + dieses alert-Fenster, Rest per EXISTS.
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
    v_probe     boolean;
    v_hh_acct   jsonb := core.fn_ui_tpl('finance.app.common.household_account');
    v_goals     jsonb;
    v_total     numeric;
    v_gap       boolean;
    v_reserves  jsonb;
    v_res_total numeric;
    v_res_gap   boolean;
    v_res_warn  int;       -- Instandhaltungs-Zeilen mit gelber Pille (Reihenfolge der Notreserve)
    v_plans     jsonb;
    v_plans_sum numeric;
    v_sections  jsonb := '[]'::jsonb;
    v_es        jsonb;     -- finance.fn_emergency_reserve_status() (Notreserve, nur Haushalts-Sicht)
    v_emerg     jsonb;     -- Zeile Notreserve
    v_plan_accts int[];                 -- sichtbare Abbuchungskonten aktiver Sparplaene
    v_acc_ban   jsonb := '[]'::jsonb;   -- probe: alert-Banner der Kinder-Konten (nicht auf dem Konten-Tab)
    v_fund      jsonb := '{}'::jsonb;   -- je Abbuchungskonto {pill, fx_gap}
    v_dep       jsonb := '{}'::jsonb;   -- je sichtbarem Depot mit Ziel-Geld fn_depot_cover_state + name
    v_rates     jsonb := '{}'::jsonb;   -- je Ziel {lines, none, fx_gap} aus fn_savings_goal_sources
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

    -- Notreserve (2026-10-30): Ruecklage des HAUSHALTS -> nur fuer Haushalts-Betrachter (Zero-Trust); Rechnung allein in
    -- finance.fn_emergency_reserve_status (Ziel, Basis, Deckung je Konto)
    v_es := CASE WHEN v_hh THEN finance.fn_emergency_reserve_status() ELSE jsonb_build_object('exists', false) END;

    -- probe (jeder App-Start): „hinter Plan" (dieselbe Bedingung wie die Pille) + Konto-Banner fuer Deckungs-Konten
    -- (fn_funding_accounts, jede Art), die der Konten-Tab dieser Person NICHT zeigt (Kinder-Konten in der Haushalts-
    -- Sicht; alle anderen meldet sein probe). Derselbe Satz + Vorschlag wie dort (fn_app_low_state_banner); erst die
    -- billige Konten-Auswahl, die Deckungs-Regel laeuft nur, wenn es ein ungelistetes Geld-Konto gibt.
    IF v_probe THEN
        SELECT COALESCE(jsonb_agg(b.banner || jsonb_build_object('target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))
                                  ORDER BY b.banner ->> 'state' = 'alert' DESC, b.name, b.id), '[]'::jsonb)
          INTO v_acc_ban
          FROM (SELECT a.id, a.name, finance.fn_app_low_state_banner(l.ls, a.name,
                       CASE WHEN v_hh AND l.ls ->> 'state' = 'alert' AND l.ls ->> 'verdict' = 'buffer'
                            THEN finance.fn_account_outlook(a.id) -> 'suggestion' END) AS banner
                  FROM finance.accounts a
                  CROSS JOIN LATERAL (SELECT finance.fn_account_low_state(a.id, true) AS ls) l
                 WHERE a.status = 'active' AND a.account_type::text IN ('cash', 'fixed_deposit', 'p2p')
                   AND (v_hh OR a.owner_person_id IS NOT DISTINCT FROM v_pid)
                   AND a.id NOT IN (SELECT finance.fn_app_accounts_listed(v_pid))
                   AND a.id IN (SELECT fa.account_id FROM finance.fn_funding_accounts() fa)) b
         WHERE b.banner IS NOT NULL;
        RETURN (
            WITH g AS (
                SELECT sg.name, sg.target_date, sg.priority, sg.has_fx_gap, sg.behind_amount,
                       finance.fn_savings_goal_pace(sg.id) AS pace
                  FROM finance.savings_goal_progress sg
                 WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
                   AND sg.id NOT IN (SELECT e.id FROM finance.savings_goals e WHERE e.kind = 'emergency_reserve')
                   AND (v_hh OR sg.beneficiary_person_id = v_pid)
            )
            SELECT jsonb_build_object('ok', true,
                       'empty', count(*) = 0
                                AND NOT EXISTS (SELECT 1 FROM finance.savings_goals sg
                                                 WHERE sg.status = 'active' AND sg.kind = 'maintenance_reserve'
                                                   AND (v_hh OR sg.beneficiary_person_id = v_pid))
                                AND NOT COALESCE((v_es->>'exists')::boolean, false)
                                AND NOT EXISTS (SELECT 1 FROM finance.savings_plans s
                                                  JOIN finance.accounts d ON d.id = s.depot_id
                                                 WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid)),
                       'banners', COALESCE(jsonb_agg(jsonb_build_object(
                           'state', 'warn', 'icon', 'alert',
                           'text', core.fn_ui_tpl('finance.app.goals.banner_behind', jsonb_build_object('name', g.name)),
                           'target', jsonb_build_object('screen', 'goals', 'params', '{}'::jsonb))
                         ORDER BY g.target_date, g.priority NULLS LAST, g.name)
                         FILTER (WHERE g.pace = 'behind' AND NOT g.has_fx_gap AND g.behind_amount > 0), '[]'::jsonb)
                       || v_acc_ban)
              FROM g);
    END IF;

    -- Abbuchungskonten sichtbarer Sparplaene (die EINE Konten-Regel fn_funding_accounts, kind 'plan'), nur sichtbare Konten
    SELECT COALESCE(array_agg(DISTINCT fa.account_id), '{}')
      INTO v_plan_accts
      FROM finance.fn_funding_accounts() fa
      JOIN finance.accounts a ON a.id = fa.account_id
     WHERE fa.kind = 'plan'
       AND (v_hh OR (a.owner_person_id IS NOT DISTINCT FROM v_pid
                     AND fa.beneficiary_person_id = v_pid AND fa.depot_owner_person_id = v_pid));

    -- Spiegel-Pille der Sparplaene: dasselbe Urteil + dieselbe Pille wie die Konten-Zeile „Tiefster Stand"
    -- (finance.fn_account_low_state + finance.fn_app_low_state_pill); gap = Kurs der Kontowaehrung fehlt
    SELECT COALESCE(jsonb_object_agg(x.id::text, jsonb_build_object(
               'fx_gap', COALESCE((x.ls ->> 'gap')::boolean, false),
               'pill', finance.fn_app_low_state_pill(x.ls))), '{}'::jsonb)
      INTO v_fund
      FROM (SELECT u.id, finance.fn_account_low_state(u.id, false) AS ls FROM unnest(v_plan_accts) u(id)) x;

    -- Depot-Deckung je fuer den Betrachter sichtbarem Depot mit Ziel-Geld (ein fremdes Depot gibt nichts her)
    SELECT COALESCE(jsonb_object_agg(x.id::text, finance.fn_depot_cover_state(x.id) || jsonb_build_object('name', x.name)), '{}'::jsonb)
      INTO v_dep
      FROM (SELECT DISTINCT a.id, a.name
              FROM finance.savings_goal_account_share s
              JOIN finance.accounts a ON a.id = s.account_id
             WHERE s.goal_status = 'active' AND a.account_type IN ('stocks_depot', 'crypto_depot')
               AND (COALESCE(s.share_native, s.share_eur, 0) <> 0 OR s.has_fx_gap)
               AND (v_hh OR a.owner_person_id IS NOT DISTINCT FROM v_pid)) x;

    -- Quelle der Rate je sichtbarem Ziel/Ruecklage (eine Adresse: fn_savings_goal_sources): fertige Aufklapp-Zeilen
    WITH src AS (
        SELECT sg.id, finance.fn_savings_goal_sources(sg.id) AS s
          FROM finance.savings_goals sg
         WHERE sg.status = 'active' AND sg.kind <> 'emergency_reserve'
           AND (v_hh OR sg.beneficiary_person_id = v_pid)
    ), pl AS (
        SELECT src.id,
               jsonb_array_length(src.s -> 'plans') AS n,
               string_agg(e.pl ->> 'name', ', ' ORDER BY e.o)
                 FILTER (WHERE v_hh OR (e.pl ->> 'beneficiary_person_id' = v_pid AND e.pl ->> 'depot_owner_person_id' = v_pid)) AS names
          FROM src
          CROSS JOIN LATERAL jsonb_array_elements(src.s -> 'plans') WITH ORDINALITY AS e(pl, o)
         GROUP BY src.id, src.s
    ), l AS (
        SELECT src.id, (src.s ->> 'plans_fx_gap')::boolean AS fx_gap,
               -- Sparplaene
               CASE WHEN pl.n > 0 THEN jsonb_build_object(
                   'label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                   'value', CASE WHEN (src.s ->> 'plans_fx_gap')::boolean AND pl.names IS NULL
                                 THEN core.fn_ui_tpl('finance.app.goals.d_rate_plans_anon_nofx')
                                 WHEN (src.s ->> 'plans_fx_gap')::boolean
                                 THEN core.fn_ui_tpl('finance.app.goals.d_rate_plans_nofx', jsonb_build_object(
                                          'plans', pl.names))
                                 WHEN pl.names IS NULL
                                 THEN core.fn_ui_tpl('finance.app.goals.d_rate_plans_anon', jsonb_build_object(
                                          'rate', core.fn_ui_money((src.s ->> 'plans_monthly_eur')::numeric, 'EUR')))
                                 ELSE core.fn_ui_tpl(CASE WHEN pl.n = 1 THEN 'finance.app.goals.d_rate_plan'
                                                          ELSE 'finance.app.goals.d_rate_plans' END, jsonb_build_object(
                                          'rate', core.fn_ui_money((src.s ->> 'plans_monthly_eur')::numeric, 'EUR'),
                                          'plans', pl.names)) END) END AS plan_line,
               -- Dauerauftrag (Raten-Kette)
               CASE WHEN jsonb_typeof(src.s -> 'transfer') = 'object' THEN jsonb_build_object(
                   'label', core.fn_ui_tpl('finance.app.goals.d_rate_from', jsonb_build_object('account',
                                CASE WHEN v_hh OR src.s -> 'transfer' ->> 'account_owner_person_id' = v_pid
                                     THEN to_jsonb(src.s -> 'transfer' ->> 'account_name') ELSE v_hh_acct END)),
                   'value', finance.fn_app_order_line((src.s -> 'transfer' ->> 'rp_id')::int)) END AS transfer_line
          FROM src
          LEFT JOIN pl ON pl.id = src.id
    )
    SELECT COALESCE(jsonb_object_agg(l.id::text, jsonb_build_object(
               'fx_gap', COALESCE(l.fx_gap, false),
               'none', l.plan_line IS NULL AND l.transfer_line IS NULL,
               'lines', CASE WHEN l.plan_line IS NULL AND l.transfer_line IS NULL
                             THEN jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_rate'),
                                                                       'value', core.fn_ui_tpl('finance.app.goals.d_rate_none')))
                             ELSE (SELECT jsonb_agg(x ORDER BY o) FROM (VALUES (1, l.plan_line), (2, l.transfer_line)) v(o, x)
                                    WHERE x IS NOT NULL) END)), '{}'::jsonb)
      INTO v_rates
      FROM l;

    -- 2 Sparziele (aktiv, mit Zielbetrag)
    WITH g AS (
        SELECT sg.id, sg.name, sg.target_amount, sg.target_date, sg.current_amount, sg.progress_percent, sg.priority,
               sg.has_fx_gap, sg.behind_amount, finance.fn_savings_goal_pace(sg.id) AS pace,
               -- Einbruch: das sichtbare Depot des Ziels mit dem groessten Fehlbetrag im Zustand short
               (SELECT v_dep -> s.account_id::text
                  FROM finance.savings_goal_account_share s
                 WHERE s.goal_id = sg.id AND v_dep -> s.account_id::text ->> 'state' = 'short'
                   AND COALESCE(s.share_native, s.share_eur, 0) <> 0
                 ORDER BY (v_dep -> s.account_id::text ->> 'gap')::numeric DESC, s.account_id LIMIT 1) AS dep_short,
               EXISTS (SELECT 1 FROM finance.savings_goal_account_share s
                        WHERE s.goal_id = sg.id AND v_dep -> s.account_id::text ->> 'state' = 'unknown'
                          AND (COALESCE(s.share_native, s.share_eur, 0) <> 0 OR s.has_fx_gap)) AS dep_unknown
          FROM finance.savings_goal_progress sg
         WHERE sg.status = 'active' AND sg.target_amount IS NOT NULL
           AND sg.id NOT IN (SELECT e.id FROM finance.savings_goals e WHERE e.kind = 'emergency_reserve')
           AND (v_hh OR sg.beneficiary_person_id = v_pid)
    ), gp AS (
        SELECT g.*,
               CASE WHEN g.dep_short IS NOT NULL
                    THEN jsonb_build_object('state', 'alert', 'icon', 'alert',
                             'text', core.fn_ui_tpl('finance.app.goals.cover_short', jsonb_build_object(
                                         'depot', g.dep_short ->> 'name',
                                         'gap', core.fn_ui_money((g.dep_short ->> 'gap')::numeric, 'EUR'))))
                    WHEN g.pace = 'behind' AND NOT g.has_fx_gap AND g.behind_amount > 0
                    THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                             'text', core.fn_ui_tpl('finance.app.goals.pace.behind_gap', jsonb_build_object(
                                         'gap', core.fn_ui_money(g.behind_amount, 'EUR'))))
                    WHEN g.pace = 'paused'
                    THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                             'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))
                    WHEN g.pace = 'unmeasurable'
                    THEN jsonb_build_object('state', 'neutral', 'icon', 'info',
                             'text', core.fn_ui_tpl('finance.app.goals.pace.unmeasurable')) END AS pill,
               g.has_fx_gap OR g.dep_unknown OR COALESCE((v_rates -> g.id::text ->> 'fx_gap')::boolean, false) AS row_gap
          FROM g
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', gp.name,
               'sub', CASE WHEN gp.pace = 'reached'
                           THEN core.fn_ui_tpl('finance.app.goals.goal_sub_reached', jsonb_build_object(
                                    'target', core.fn_ui_money(gp.target_amount, 'EUR'), 'date', core.fn_ui_date(gp.target_date)))
                           ELSE core.fn_ui_tpl('finance.app.goals.goal_sub', jsonb_build_object(
                                    'target', core.fn_ui_money(gp.target_amount, 'EUR'), 'date', core.fn_ui_month(gp.target_date))) END,
               'value', core.fn_ui_money(gp.current_amount, 'EUR'),
               'gap', gp.row_gap,
               'pill', gp.pill,
               -- Balken = Fortschritt zum Zielbetrag: auf Kurs neutral (Akzent), sonst die Farbe der Pille; erreicht -> keiner
               'progress', CASE WHEN gp.progress_percent IS NOT NULL AND gp.pace IS DISTINCT FROM 'reached' THEN jsonb_build_object(
                               'pct', round(LEAST(GREATEST(gp.progress_percent, 0), 100), 1),
                               'state', CASE WHEN gp.pill ->> 'state' IN ('warn', 'alert') THEN gp.pill ->> 'state'
                                             ELSE 'neutral' END) END,
               'target', NULL,
               -- ein erreichtes Ziel ohne Rate braucht keine Zeile „keine laufende Rate" (weglassen vor erklaeren)
               'details', CASE WHEN gp.pace = 'reached' AND (v_rates -> gp.id::text ->> 'none')::boolean THEN '[]'::jsonb
                               ELSE COALESCE(v_rates -> gp.id::text -> 'lines', '[]'::jsonb) END
                          || (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o, x.k), '[]'::jsonb) FROM (
                   -- wo liegt das Geld: je Konto der Anteil, groesste zuerst; ab fuenf Konten die kleineren in einer Zeile
                   SELECT 1 AS o, s.rn AS k, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_on_account', jsonb_build_object(
                                  'account', CASE WHEN s.vis THEN to_jsonb(s.account_name) ELSE v_hh_acct END)),
                              'value', CASE WHEN s.share_native IS NOT NULL THEN core.fn_ui_money(s.share_native, s.account_currency)
                                            ELSE core.fn_ui_money(s.share_eur, 'EUR') END) AS d
                     FROM (SELECT sh.*, (v_hh OR sa.owner_person_id IS NOT DISTINCT FROM v_pid) AS vis,
                                  row_number() OVER (ORDER BY sh.share_eur DESC NULLS LAST, sh.account_name, sh.account_id) AS rn,
                                  count(*) OVER () AS cnt
                             FROM finance.savings_goal_account_share sh
                             JOIN finance.accounts sa ON sa.id = sh.account_id
                            WHERE sh.goal_id = gp.id AND COALESCE(sh.share_native, sh.share_eur, 0) <> 0) s
                    WHERE s.cnt <= 5 OR s.rn <= 4
                   UNION ALL
                   SELECT 1, 5, jsonb_build_object(
                              'label', core.fn_ui_tpl('finance.app.goals.d_on_more', jsonb_build_object('n', core.fn_ui_num(count(*)))),
                              'value', CASE WHEN bool_and(s.share_eur IS NOT NULL) THEN core.fn_ui_money(sum(s.share_eur), 'EUR') END)
                     FROM (SELECT sh.share_eur, count(*) OVER () AS cnt,
                                  row_number() OVER (ORDER BY sh.share_eur DESC NULLS LAST, sh.account_name, sh.account_id) AS rn
                             FROM finance.savings_goal_account_share sh
                            WHERE sh.goal_id = gp.id AND COALESCE(sh.share_native, sh.share_eur, 0) <> 0) s
                    WHERE s.cnt > 5 AND s.rn > 4
                   HAVING count(*) > 0
                   UNION ALL
                   SELECT 2, 0, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_target_date'),
                                                   'value', core.fn_ui_date(gp.target_date))
                    WHERE gp.pace IS DISTINCT FROM 'reached') x))
             ORDER BY CASE gp.pill ->> 'state' WHEN 'alert' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END,
                      (gp.pace = 'reached'), gp.target_date, gp.priority NULLS LAST, gp.name), '[]'::jsonb),
           COALESCE(sum(gp.current_amount), 0),
           COALESCE(bool_or(gp.has_fx_gap), false)
      INTO v_goals, v_total, v_gap
      FROM gp;

    -- 1 Ruecklagen: Notreserve (nur Haushalt) + Instandhaltung
    IF (v_es->>'exists')::boolean THEN
        v_emerg := jsonb_build_object(
            'label', v_es->>'name',
            'sub', CASE WHEN v_es->>'state' = 'ok'
                        THEN core.fn_ui_tpl('finance.app.goals.emergency_sub_reached', jsonb_build_object(
                                 'target', core.fn_ui_money((v_es->>'target_eur')::numeric, 'EUR')))
                        WHEN v_es->>'target_kind' = 'months' AND v_es->'target_eur' <> 'null'::jsonb
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
            'pill', CASE WHEN v_es->>'state' = 'warn' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                 'text', core.fn_ui_tpl('finance.app.goals.missing', jsonb_build_object(
                                     'gap', core.fn_ui_money((v_es->>'gap_eur')::numeric, 'EUR')))) END,
            -- Balken nur solange nicht voll (voll = erreicht, der Untertitel sagt es)
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
               'sub', CASE WHEN m.running_monthly_eur IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                    'rate', core.fn_ui_money(m.running_monthly_eur, 'EUR'))) END,
               'value', core.fn_ui_money(m.saved_eur, 'EUR'),
               'gap', COALESCE(sg.has_fx_gap, false),
               'pill', CASE WHEN m.property_status = 'active' AND m.gap_monthly_eur > 0
                            THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                     'text', core.fn_ui_tpl('finance.app.goals.reserve_low', jsonb_build_object(
                                                 'gap', core.fn_ui_money(m.gap_monthly_eur, 'EUR')))) END,
               -- kein Balken: eine Ruecklage hat kein Betragsziel (Owner-Entscheid 2026-10-30)
               'progress', NULL,
               'target', NULL,
               'details', COALESCE(v_rates -> m.goal_id::text -> 'lines', '[]'::jsonb)
                          || (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 1 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_guide'),
                              'value', core.fn_ui_tpl('finance.app.goals.d_guide_value', jsonb_build_object(
                                  'monthly', core.fn_ui_money(m.recommended_monthly, 'EUR'),
                                  'area', core.fn_ui_num(m.living_area_m2, scale(trim_scale(m.living_area_m2))),
                                  'rate', core.fn_ui_money(m.rate_eur_m2, 'EUR')))) AS d
                    WHERE m.recommended_monthly IS NOT NULL
                   UNION ALL
                   SELECT 1, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_missing'), 'value', NULL)
                    WHERE m.recommended_monthly IS NULL AND (m.living_area_m2 IS NULL OR m.year_built IS NULL)
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_property'),
                              'value', m.real_estate_name)) x))
             ORDER BY COALESCE(m.gap_monthly_eur > 0 AND m.property_status = 'active', false) DESC, m.goal_name), '[]'::jsonb),
           COALESCE(sum(m.saved_eur), 0),
           COALESCE(bool_or(sg.has_fx_gap), false),
           count(*) FILTER (WHERE m.gap_monthly_eur > 0 AND m.property_status = 'active')
      INTO v_reserves, v_res_total, v_res_gap, v_res_warn
      FROM finance.maintenance_reserve_status m
      JOIN finance.savings_goals g ON g.id = m.goal_id
      LEFT JOIN finance.savings_goal_progress sg ON sg.id = m.goal_id
     WHERE v_hh OR g.beneficiary_person_id = v_pid;

    -- Notreserve nach der Reihenfolge-Regel (Abweichung zuerst, Erledigtes zuletzt): gelb ganz oben, voll ganz unten,
    -- neutral nach den gelben Instandhaltungs-Zeilen
    IF v_emerg IS NOT NULL THEN
        v_reserves := CASE v_es->>'state'
            WHEN 'warn' THEN jsonb_build_array(v_emerg) || v_reserves
            WHEN 'ok'   THEN v_reserves || jsonb_build_array(v_emerg)
            ELSE COALESCE((SELECT jsonb_agg(x ORDER BY o) FROM jsonb_array_elements(v_reserves) WITH ORDINALITY t(x, o) WHERE o <= v_res_warn), '[]'::jsonb)
                 || jsonb_build_array(v_emerg)
                 || COALESCE((SELECT jsonb_agg(x ORDER BY o) FROM jsonb_array_elements(v_reserves) WITH ORDINALITY t(x, o) WHERE o > v_res_warn), '[]'::jsonb) END;
        v_res_total := v_res_total + COALESCE((v_es->>'covered_eur')::numeric, 0);
        v_res_gap := v_res_gap OR COALESCE((v_es->>'has_fx_gap')::boolean, false);
    END IF;

    -- 3 Sparplaene: Untertitel aus dem HEUTE gueltigen Glied (current_rp_id + days_of_month der View)
    WITH sp AS (
        SELECT s.*, bp.full_name AS beneficiary_name,
               CASE WHEN s.status = 'active' THEN v_fund -> s.settlement_account_id::text -> 'pill' END AS fund_pill,
               COALESCE(s.status = 'active' AND (v_fund -> s.settlement_account_id::text ->> 'fx_gap')::boolean, false) AS row_gap
          FROM finance.savings_plan_overview s
          JOIN finance.accounts d ON d.id = s.depot_id
          LEFT JOIN core.fn_household_persons() bp ON bp.person_id = s.beneficiary_person_id
         WHERE v_hh OR (s.beneficiary_person_id = v_pid AND d.owner_person_id = v_pid)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'label', sp.name,
               'sub', CASE WHEN sp.status <> 'active' THEN NULL
                           WHEN cardinality(sp.days_of_month) >= 2 AND sp.next_execution IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.plan_days_next', jsonb_build_object(
                                    'n', core.fn_ui_num(cardinality(sp.days_of_month)),
                                    'amount', core.fn_ui_money(sp.amount_per_execution, sp.currency),
                                    'date', core.fn_ui_date(sp.next_execution)))
                           WHEN sp.amount_per_execution = sp.monthly_amount AND sp.next_execution IS NOT NULL
                           THEN core.fn_ui_tpl('finance.app.goals.plan_next', jsonb_build_object(
                                    'date', core.fn_ui_date(sp.next_execution)))
                           ELSE finance.fn_app_order_line(sp.current_rp_id) END,
               'value', core.fn_ui_money(sp.monthly_amount, sp.currency),
               'gap', sp.row_gap,
               'pill', CASE WHEN sp.status = 'paused'
                            THEN jsonb_build_object('state', 'neutral', 'icon', 'pause',
                                     'text', core.fn_ui_tpl('finance.app.goals.pace.paused'))
                            ELSE sp.fund_pill END,
               'progress', NULL,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(x.d ORDER BY x.o), '[]'::jsonb) FROM (
                   SELECT 1 AS o, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_security'),
                              'value', COALESCE(sp.security_name, sp.symbol)) AS d
                    WHERE COALESCE(sp.security_name, sp.symbol) IS NOT NULL
                   UNION ALL
                   SELECT 2, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_depot'), 'value', sp.depot_name)
                   UNION ALL
                   SELECT 3, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_from'),
                              'value', sp.settlement_account_name)
                    WHERE v_hh
                   UNION ALL
                   SELECT 4, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_for'), 'value', sp.beneficiary_name)
                    WHERE v_hh AND sp.beneficiary_name IS NOT NULL
                   UNION ALL
                   SELECT 5, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_goal'),
                              'value', sp.savings_goal_name)
                    WHERE sp.savings_goal_name IS NOT NULL
                   UNION ALL
                   -- geplante Aenderung: das kuenftige Kopf-Glied als Betrag · Rhythmus · ab Datum
                   SELECT 6, jsonb_build_object('label', core.fn_ui_tpl('finance.app.goals.d_change'),
                              'value', finance.fn_app_order_line(sp.head_rp_id))
                    WHERE sp.change_from IS NOT NULL) x))
             ORDER BY CASE sp.fund_pill ->> 'state' WHEN 'alert' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END,
                      (sp.status = 'active') DESC, sp.name), '[]'::jsonb),
           -- Summe nur ab 2 aktiven Plaenen, ohne fehlenden Wechselkurs und ohne gap an einer Zeile (sonst NULL)
           CASE WHEN count(*) FILTER (WHERE sp.status = 'active') >= 2
                 AND NOT COALESCE(bool_or(finance.fn_to_eur(sp.monthly_amount, sp.currency) IS NULL)
                                  FILTER (WHERE sp.status = 'active'), false)
                 AND NOT COALESCE(bool_or(sp.row_gap), false)
                THEN sum(finance.fn_to_eur(sp.monthly_amount, sp.currency)) FILTER (WHERE sp.status = 'active') END
      INTO v_plans, v_plans_sum
      FROM sp;

    -- Sparziele immer (mit Leer-Text), alles Weitere nur mit Eintraegen; Summe nur bei den Sparplaenen
    IF jsonb_array_length(v_reserves) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_reserves'),
            'value', NULL,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_reserves);
    END IF;
    v_sections := v_sections || jsonb_build_object(
        'title', core.fn_ui_tpl('finance.app.goals.section_goals'),
        'value', NULL,
        'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_goals);
    IF jsonb_array_length(v_plans) > 0 THEN
        v_sections := v_sections || jsonb_build_object(
            'title', core.fn_ui_tpl('finance.app.goals.section_plans'),
            'value', CASE WHEN v_plans_sum > 0 THEN core.fn_ui_tpl('finance.app.goals.reserve_rate', jsonb_build_object(
                                                        'rate', core.fn_ui_money(v_plans_sum, 'EUR'))) END,
            'empty', core.fn_ui_tpl('finance.app.goals.empty'), 'items', v_plans);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.goals.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.goals.hero'),
            'value', core.fn_ui_money(v_total + v_res_total, 'EUR'),
            'gap', v_gap OR v_res_gap,
            -- Aufschluesselung nur mit beiden Teilen und ohne fx-Luecke (sonst waeren die Teile still zu niedrig)
            'note', CASE WHEN jsonb_array_length(v_reserves) > 0 AND jsonb_array_length(v_goals) > 0 AND NOT (v_gap OR v_res_gap)
                         THEN core.fn_ui_tpl('finance.app.goals.hero_note', jsonb_build_object(
                                  'goals', core.fn_ui_money(v_total, 'EUR'), 'reserves', core.fn_ui_money(v_res_total, 'EUR'))) END),
        'banners', '[]'::jsonb,
        'sections', v_sections);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_goals(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
