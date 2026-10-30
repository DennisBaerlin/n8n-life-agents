-- ============================================================
-- finance.fn_app_screen_depot(p jsonb) — Mini-App-Bildschirm „Depot" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Muster finance.fn_app_screen_overview.
--   Quellen: depot_holdings_overview (Marktwert, Kurs, Kurs-Datum, price_status ok|stale|missing, Kaufwert, Gewinn),
--   networth_by_asset_class (Hero), transactions (Kauf/Verkauf/Dividende je Position, finance.fn_app_holding_transactions).
--   Die Seite rechnet nichts. Was im Depot fuer Ziele reserviert ist, zeigt EIN Ort: Bildschirm Ziele, Abschnitt
--   „Konten" (Uebersicht R3; vorher ein eigener Abschnitt hier).
--   HERO = Anlageart „depot" aus networth_by_asset_class mit derselben Personen-Auswahl wie die Vermoegen-Seite (Uebersicht
--     R3: Depotwert = „Wertpapiere & Krypto" dort, ohne Kurs zaehlt der Kaufwert); gap, wenn eine Position keinen Kurs
--     oder keinen Wechselkurs hat. Haushalts-Betrachter: ohne Kinder-Depots (role = 'child', T2-Muster), die stehen
--     als eigene Abschnitte „… · nicht im Depotwert" hinten. Note: Gewinn seit Kauf (nur Positionen mit aktuellem Kurs
--     und Kaufwert; veraltete Kurse nicht, wie die Pille) + juengstes Kurs-Datum.
--   Ein Abschnitt je Depot (Haushalt vor Kind, dann Wert absteigend, ohne Wert zuletzt) mit Depot-Summe (section.value;
--   entfaellt, wenn eine Position keinen EUR-Wert hat, statt still zu niedrig zu sein);
--   Positionen nach Wert. Wert IMMER in EUR (market_value_eur); nur ohne Wechselkurs der Kurs-Waehrungs-Wert + gap.
--   Untertitel: Stueck (mit den Nachkommastellen, die sie hat), bei Fremdwaehrung „Kurs 148,60 $", Kurs-Datum nur wenn
--   es vom Hero-Datum abweicht. Pille nur fuer Kurs veraltet/fehlt (warn); Gewinn/Verlust seit Kauf als trend unter dem
--   Wert („+x € · +y %", Pfeil up/down, keine Ampel-Farbe; 0 -> keiner; Mini-App UX 2026-10-30). Bekannte Grenze: book_value_eur rechnet eine Fremdwaehrungs-
--   Kostenbasis zum heutigen Kurs um -> der Waehrungseffekt fehlt im „seit Kauf" (EUR-Kaeufe nicht betroffen).
--   Aufklappen (details): Ø Kaufkurs, Kaufwert, Gewinn (aus den eigenen Zeilen), dann die letzten 12 Buchungen und
--   „n aeltere" (finance.fn_app_holding_transactions).
--   RENDITE JE DEPOT (vor den Depot-Abschnitten): ein Abschnitt aus finance.fn_depot_performance mit derselben Personen-
--     Sicht; je Depot mit Jahreswert (return_pa_pct) bzw. mit Kurs-/Wechselkurs-Luecke und Beginn vor >= 1 Jahr eine
--     Zeile (Kinder-Depot „… · nicht in Alle Depots"), „Alle Depots" zuletzt und nur, wenn alle (mindestens zwei)
--     Haushalts-Depots mit Einzahlung eine Zeile haben; keine Zeile -> kein Abschnitt. EIN Zeitraum auf der
--     Seite (Owner 2026-10-30): juengere Depots fehlen, statt „seit Beginn" (bei Uebernahme ab Uebernahme-Kurs) neben
--     „Seit Kauf" (Hero, Positionen) zu stellen; Fonds zeigen unter einem Jahr ebenfalls keine Wertentwicklung (ESMA
--     Q&A zu Art. 15(4) VO 583/2010). Wert rechts = Rendite pro Jahr (Messwert, ohne Ampel-Farbe); Pille nur warn/clock
--     bei veraltetem Kurs (Zahl bleibt), ohne Kurs/Wechselkurs warn + gap. Aufklappen: Wert heute, Hinweis veralteter Kurs,
--     ein Erklaer-Satz. Depot-Auswahl ueberall = finance.fn_visible_depots.
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alle aktiven Depots, alle anderen nur
--     Depots mit owner_person_id = ich (dann ohne Kinder-Trennung: der Hero ist die eigene Summe).
--   params.probe = true -> {ok, empty, banners}: je Depot mit Kurs veraltet/fehlt ein warn-Banner, target = depot.
--   Fehler als Daten, nie RAISE: Frei-SQL-Sitzung -> forbidden, kaputte Eingabe -> bad_request. Keine IDs in der Antwort.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC (EXECUTE nur finance_rw/Host, nie *_ro).
--   Tests: tests/db/finance/test_fn_app_screen_depot.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_screen_depot(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, finance, core, pg_temp
AS $$
DECLARE
    v_pid      text;
    v_hh       boolean;
    v_date     date;
    v_gain     numeric;
    v_book     numeric;
    v_pos_gap  boolean;
    v_total    numeric;
    v_gap      boolean;
    v_depots   jsonb;
    v_perf     jsonb;
    v_banners  jsonb;
BEGIN
    IF core.fn_is_free_sql_session() THEN
        RETURN jsonb_build_object('ok', false, 'code', 'forbidden');
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR jsonb_typeof(p -> 'person_id') IS DISTINCT FROM 'string' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_pid := p ->> 'person_id';
    v_hh  := core.fn_app_sees_household(v_pid);

    -- probe (jeder App-Start): nur Existenz + Kurs-Banner je Depot, ohne Positionen/Details zu bauen
    IF p -> 'params' -> 'probe' = 'true'::jsonb THEN
        WITH d AS (
            SELECT a.id, a.name,
                   EXISTS (SELECT 1 FROM finance.depot_holdings_overview o
                            WHERE o.account_id = a.id AND o.price_status IN ('stale', 'missing')) AS price_issue,
                   EXISTS (SELECT 1 FROM finance.depot_holdings_overview o WHERE o.account_id = a.id) AS has_pos
              FROM finance.fn_visible_depots(v_hh, v_pid) a
        )
        SELECT jsonb_build_object('ok', true, 'empty', NOT COALESCE(bool_or(d.has_pos), false),
                   'banners', COALESCE(jsonb_agg(jsonb_build_object(
                       'state', 'warn', 'icon', 'clock',
                       'text', core.fn_ui_tpl('finance.app.depot.banner_price', jsonb_build_object('depot', d.name)),
                       'target', jsonb_build_object('screen', 'depot', 'params', '{}'::jsonb))
                     ORDER BY d.name) FILTER (WHERE d.price_issue), '[]'::jsonb))
          INTO v_banners
          FROM d;
        RETURN v_banners;
    END IF;

    -- Kennzahlen der Hero-Auswahl (ohne Kinder-Depots): Kurs-Datum, Gewinn seit Kauf, Positionen ohne Wert
    SELECT COALESCE(max(o.price_as_of) FILTER (WHERE NOT d.kid), max(o.price_as_of)),
           sum(o.unrealized_gain_eur) FILTER (WHERE NOT d.kid AND o.price_status = 'ok' AND o.book_value_eur > 0
                                                AND o.unrealized_gain_eur IS NOT NULL),
           sum(o.book_value_eur) FILTER (WHERE NOT d.kid AND o.price_status = 'ok' AND o.book_value_eur > 0
                                           AND o.unrealized_gain_eur IS NOT NULL),
           COALESCE(bool_or(o.market_value_eur IS NULL) FILTER (WHERE NOT d.kid), false)
      INTO v_date, v_gain, v_book, v_pos_gap
      FROM finance.fn_visible_depots(v_hh, v_pid) d
      JOIN finance.depot_holdings_overview o ON o.account_id = d.id;

    -- je sichtbarem Depot: Positionen, Wert, Luecke, Kurs-Problem
    WITH d AS (
        SELECT v.id, v.name, v.kid FROM finance.fn_visible_depots(v_hh, v_pid) v
    ), h AS (
        SELECT d.id AS depot_id, d.name AS depot_name, d.kid,
               o.holding_id, o.name, o.shares, o.currency, o.average_purchase_price, o.book_value, o.book_value_eur,
               o.market_value, o.market_value_eur, o.unrealized_gain_eur, o.price_currency, o.latest_price,
               o.price_as_of, o.price_status,
               (o.price_status = 'ok' AND o.book_value_eur > 0 AND o.unrealized_gain_eur IS NOT NULL) AS has_gain,
               CASE WHEN o.book_value_eur > 0 THEN round(100 * o.unrealized_gain_eur / o.book_value_eur, 1) END AS gain_pct
          FROM d
          JOIN finance.depot_holdings_overview o ON o.account_id = d.id
    ), per AS (
        SELECT h.depot_name AS name, h.kid,
               sum(h.market_value_eur) AS val,
               jsonb_agg(jsonb_build_object(
                   'label', h.name,
                   'sub', core.fn_ui_tpl(
                       CASE WHEN fx.foreign AND dt.differs THEN 'finance.app.depot.shares_price_date'
                            WHEN fx.foreign THEN 'finance.app.depot.shares_price'
                            WHEN dt.differs THEN 'finance.app.depot.shares_date'
                            ELSE 'finance.app.depot.shares' END,
                       jsonb_build_object(
                           'shares', core.fn_ui_num(h.shares, scale(trim_scale(h.shares))),
                           'price', CASE WHEN fx.foreign THEN core.fn_ui_money(h.latest_price, h.price_currency) END,
                           'date', CASE WHEN dt.differs THEN core.fn_ui_date(h.price_as_of) END)),
                   'value', CASE WHEN h.market_value_eur IS NOT NULL THEN core.fn_ui_money(h.market_value_eur, 'EUR')
                                 WHEN h.market_value IS NOT NULL THEN core.fn_ui_money(h.market_value, h.price_currency) END,
                   'gap', h.market_value_eur IS NULL,
                   -- Pille nur fuer ein Kurs-Problem (Urteil); der Gewinn seit Kauf ist Information -> trend (Mini-App UX
                   -- 2026-10-30: ein Kursverlust ist kein roter Alarm)
                   'pill', CASE
                       WHEN h.price_status = 'stale' THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                                                 'text', core.fn_ui_tpl('finance.app.depot.price_stale'))
                       WHEN h.price_status = 'missing' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                                 'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
                   END,
                   'trend', CASE WHEN h.has_gain AND h.unrealized_gain_eur <> 0 THEN jsonb_build_object(
                                'direction', CASE WHEN h.unrealized_gain_eur > 0 THEN 'up' ELSE 'down' END,
                                'text', core.fn_ui_tpl('finance.app.depot.gain', jsonb_build_object(
                                            'amount', core.fn_ui_money(h.unrealized_gain_eur, 'EUR', true),
                                            'pct', core.fn_ui_num(h.gain_pct, 1, true)))) END,
                   'progress', NULL,
                   'target', NULL,
                   'details', (SELECT COALESCE(jsonb_agg(e ORDER BY n) FILTER (WHERE e IS NOT NULL), '[]'::jsonb)
                                 FROM unnest(ARRAY[
                                  CASE WHEN h.average_purchase_price IS NOT NULL THEN jsonb_build_object(
                                      'label', core.fn_ui_tpl('finance.app.depot.d_avg_price'),
                                      'value', core.fn_ui_money(h.average_purchase_price, h.currency)) END,
                                  CASE WHEN h.book_value IS NOT NULL THEN jsonb_build_object(
                                      'label', core.fn_ui_tpl('finance.app.depot.d_book_value'),
                                      'value', core.fn_ui_money(h.book_value, h.currency)) END,
                                  CASE WHEN h.has_gain THEN jsonb_build_object(
                                      'label', core.fn_ui_tpl('finance.app.depot.d_gain'),
                                      'value', core.fn_ui_tpl('finance.app.depot.gain', jsonb_build_object(
                                          'amount', core.fn_ui_money(h.unrealized_gain_eur, 'EUR', true),
                                          'pct', core.fn_ui_num(h.gain_pct, 1, true)))) END]) WITH ORDINALITY AS k(e, n))
                              || finance.fn_app_holding_transactions(h.holding_id))
                 ORDER BY h.market_value_eur DESC NULLS LAST, h.name) AS items,
               bool_or(h.market_value_eur IS NULL) AS val_gap
          FROM h
          CROSS JOIN LATERAL (SELECT h.latest_price IS NOT NULL AND h.price_currency IS DISTINCT FROM 'EUR' AS foreign) fx
          CROSS JOIN LATERAL (SELECT h.price_as_of IS NOT NULL AND h.price_as_of IS DISTINCT FROM v_date AS differs) dt
         GROUP BY h.depot_id, h.depot_name, h.kid
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'title', CASE WHEN per.kid
                             THEN core.fn_ui_tpl('finance.app.depot.section_child', jsonb_build_object('name', per.name))
                             ELSE core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', per.name)) END,
               -- Depot-Summe nur, wenn jede Position einen EUR-Wert hat (sonst waere sie still zu niedrig; die
               -- Positionen selbst tragen gap)
               'value', CASE WHEN per.val IS NOT NULL AND NOT per.val_gap THEN core.fn_ui_money(per.val, 'EUR') END,
               'empty', core.fn_ui_tpl('finance.app.depot.empty'),
               'items', per.items)
             ORDER BY per.kid, per.val DESC NULLS LAST, per.name), '[]'::jsonb)
      INTO v_depots
      FROM per;

    -- Rendite je Depot (finance.fn_depot_performance, dieselbe Sicht): EIN Abschnitt vor den Depots, nur Depots mit
    -- Jahreswert (die 365-Tage-Regel bleibt in der fn) bzw. mit Luecke und Beginn vor mindestens einem Jahr (ohne Kurs
    -- fehlt der Endwert-Fluss, period_days waere 0). EIN Zeitraum auf der Seite: darunter beantwortet „seit Kauf" die
    -- Gewinn-Frage. „Alle Depots" nur, wenn ALLE Haushalts-Depots mit Einzahlung stehen (mindestens zwei): sonst
    -- poolte die Summe versteckte junge Depots (bei Uebernahme ab Uebernahme-Kurs).
    WITH perf AS (
        SELECT finance.fn_depot_performance(jsonb_build_object('person_id', v_pid)) AS j
    ), a AS (
        SELECT t.x, t.o, (t.x ->> 'return_pa_pct')::numeric AS pct,
               NOT (t.x ->> 'is_total')::boolean AND NOT (t.x ->> 'is_child')::boolean AS hh,
               (t.x ->> 'return_pa_pct' IS NOT NULL
                OR (t.x ->> 'missing_reason' IS NOT NULL
                    AND (t.x ->> 'start_date')::date <= (perf.j ->> 'as_of')::date - 365)) AS shown
          FROM perf, jsonb_array_elements(perf.j -> 'rows') WITH ORDINALITY AS t(x, o)
         WHERE t.x ->> 'missing_reason' IS DISTINCT FROM 'no_flows'
    ), r AS (
        SELECT a.x, a.o, a.pct FROM a WHERE a.shown
    ), n AS (
        SELECT count(*) FILTER (WHERE a.hh AND a.shown) AS cnt, COALESCE(bool_and(a.shown) FILTER (WHERE a.hh), false) AS all_hh
          FROM a
    )
    SELECT jsonb_agg(jsonb_build_object(
               'label', CASE WHEN (r.x ->> 'is_total')::boolean THEN core.fn_ui_tpl('finance.app.depot.perf_total')
                             WHEN (r.x ->> 'is_child')::boolean
                             THEN core.fn_ui_tpl('finance.app.depot.perf_child', jsonb_build_object('name', r.x ->> 'depot_name'))
                             ELSE r.x -> 'depot_name' END,
               'sub', core.fn_ui_tpl('finance.app.depot.perf_since',
                          jsonb_build_object('date', core.fn_ui_date((r.x ->> 'start_date')::date))),
               -- Wert rechts = die Rendite pro Jahr (Messwert, keine Ampel-Farbe; Mini-App UX 2026-10-30)
               'value', CASE WHEN r.pct IS NOT NULL THEN core.fn_ui_tpl('finance.app.depot.perf_pa',
                                  jsonb_build_object('pct', core.fn_ui_num(round(r.pct, 1), 1, true))) END,
               'gap', r.x ->> 'missing_reason' IN ('no_price', 'no_fx'),
               'pill', CASE
                   -- veralteter Kurs: Zahl bleibt, Pille warnt wie an der Position
                   WHEN r.pct IS NOT NULL AND (r.x ->> 'price_stale')::boolean THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                       'text', core.fn_ui_tpl('finance.app.depot.price_stale'))
                   WHEN r.pct IS NOT NULL THEN NULL
                   WHEN r.x ->> 'missing_reason' = 'no_price' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                       'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
                   WHEN r.x ->> 'missing_reason' = 'no_fx' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                       'text', core.fn_ui_tpl('finance.app.depot.perf_fx_missing'))
                   ELSE jsonb_build_object('state', 'neutral', 'icon', 'info', 'text', core.fn_ui_tpl('finance.app.depot.perf_none'))
               END,
               'progress', NULL,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(e ORDER BY k) FILTER (WHERE e IS NOT NULL), '[]'::jsonb)
                             FROM unnest(ARRAY[
                              CASE WHEN r.x ->> 'value_eur' IS NOT NULL THEN jsonb_build_object(
                                  'label', core.fn_ui_tpl('finance.app.depot.d_perf_value'),
                                  'value', core.fn_ui_money((r.x ->> 'value_eur')::numeric, 'EUR')) END,
                              CASE WHEN (r.x ->> 'price_stale')::boolean AND r.pct IS NOT NULL THEN jsonb_build_object(
                                  'label', core.fn_ui_tpl('finance.app.depot.d_perf_stale'), 'value', NULL) END,
                              jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.d_perf_how'), 'value', NULL)])
                                  WITH ORDINALITY AS d(e, k)))
             ORDER BY r.o) FILTER (WHERE NOT (r.x ->> 'is_total')::boolean OR (n.cnt >= 2 AND n.all_hh))
      INTO v_perf
      FROM r CROSS JOIN n;
    IF v_perf IS NOT NULL THEN
        v_depots := jsonb_build_array(jsonb_build_object(
                        'title', core.fn_ui_tpl('finance.app.depot.section_perf'),
                        'value', NULL,
                        'empty', core.fn_ui_tpl('finance.app.depot.empty'),
                        'items', v_perf)) || v_depots;
    END IF;

    -- Hero: dieselbe Zahl wie „Wertpapiere & Krypto" auf der Vermoegen-Seite (gleiche Quelle, gleiche Auswahl)
    SELECT COALESCE(sum(n.value_eur), 0), COALESCE(bool_or(n.has_fx_gap), false)
      INTO v_total, v_gap
      FROM finance.networth_by_asset_class n
      LEFT JOIN core.fn_household_persons() hp ON hp.person_id = n.owner_person_id
     WHERE n.bucket = 'depot'
       AND ((v_hh AND hp.role IS DISTINCT FROM 'child') OR (NOT v_hh AND n.owner_person_id = v_pid));

    RETURN jsonb_build_object(
        'ok', true,
        'title', core.fn_ui_tpl('finance.app.depot.title'),
        'hero', jsonb_build_object(
            'label', core.fn_ui_tpl('finance.app.depot.hero'),
            'value', core.fn_ui_money(v_total, 'EUR'),
            'gap', v_gap OR v_pos_gap,
            'note', CASE
                WHEN v_book > 0 AND v_date IS NOT NULL
                THEN core.fn_ui_tpl('finance.app.depot.hero_note', jsonb_build_object(
                         'gain', core.fn_ui_money(v_gain, 'EUR', true),
                         'pct', core.fn_ui_num(round(100 * v_gain / v_book, 1), 1, true),
                         'date', core.fn_ui_date(v_date)))
                WHEN v_date IS NOT NULL
                THEN core.fn_ui_tpl('finance.app.depot.hero_note_date', jsonb_build_object('date', core.fn_ui_date(v_date)))
                END),
        'banners', '[]'::jsonb,
        'sections', v_depots);
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_app_screen_depot(jsonb) FROM public;
-- EXECUTE an finance_rw: core.fn_provision_package_roles (Bulk); finance_ro/core_ro bekommen ihn nicht (DEFINER).
