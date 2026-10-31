-- ============================================================
-- finance.fn_app_screen_depot(p jsonb) — Mini-App-Bildschirm „Depot" (READ, View-Modell v1)
--   Handler der Registry app_screens (docs/package-contract.md §3.12), Muster finance.fn_app_screen_overview.
--   Abschnitt finance.app.depot.section_perf: Frage: Wie viel hat jedes Depot im Jahr gebracht?
--   Abschnitt finance.app.depot.section: Frage: Was sind die Wertpapiere in diesem Depot heute wert, und wie stehen sie seit dem Kauf?
--   Abschnitt finance.app.depot.section_kids: Frage: Was liegt in den Depots der Kinder, und wie stehen sie?
--   Quellen: depot_holdings_overview (Marktwert, Kurs, Kurs-Datum, price_status ok|stale|missing, Kaufwert, Gewinn),
--   networth_by_asset_class (Hero), finance.fn_depot_performance (Rendite), transactions (Buchungen je Position,
--   finance.fn_app_holding_transactions). Die Seite rechnet nichts. Was im Depot fuer Ziele reserviert ist, zeigt der
--   Bildschirm Ziele.
--   HERO = Anlageart „depot" aus networth_by_asset_class mit derselben Personen-Auswahl wie die Vermoegen-Seite (Uebersicht
--     R3: Depotwert = „Wertpapiere & Krypto" dort, ohne Kurs zaehlt der Kaufwert); gap, wenn eine Position keinen Kurs
--     oder keinen Wechselkurs hat. Haushalts-Betrachter: ohne Kinder-Depots (role = 'child', T2-Muster), ohne Fussnote.
--     Note: Gewinn seit Kauf (nur Positionen mit aktuellem Kurs und Kaufwert; veraltete Kurse nicht, wie die Pille) +
--     juengstes Kurs-Datum.
--   RENDITE JE DEPOT (zuerst): ein Abschnitt aus finance.fn_depot_performance mit derselben Personen-Sicht; je Eltern-Depot
--     mit Jahreswert (return_pa_pct) bzw. mit Kurs-/Wechselkurs-Luecke und Beginn vor >= 1 Jahr eine Zeile, „Alle Depots"
--     zuletzt und nur, wenn alle (mindestens zwei) Haushalts-Depots mit Einzahlung eine Zeile haben; keine Zeile -> kein
--     Abschnitt. EIN Zeitraum auf der Seite (Owner 2026-10-30): juengere Depots fehlen, statt „seit Beginn" neben „Seit
--     Kauf" (Hero, Positionen) zu stellen; Fonds zeigen unter einem Jahr ebenfalls keine Wertentwicklung (ESMA Q&A zu
--     Art. 15(4) VO 583/2010). Wert rechts = Rendite pro Jahr (Messwert, ohne Ampel-Farbe); Pille nur warn: veralteter
--     Kurs mit dem aeltesten veralteten Kurs-Datum (Zahl bleibt; „Alle Depots" ueber alle Eltern-Depots), ohne Kurs bzw.
--     Wechselkurs + gap. Kinder-Depots stehen hier nicht (ihre Rendite steht an der Zeile in „Depots der Kinder"), Zeilen
--     ohne Ergebnis (no_result) entfallen (eine Pille muesste sagen, was fehlt); Aufklappen: Hinweis veralteter Kurs +
--     ein Erklaer-Satz (der Wert heute steht schon am Depot).
--   JE ELTERN-DEPOT ein Abschnitt (nach Wert, ohne Wert zuletzt), Positionen nach Wert. Wert IMMER in EUR
--     (market_value_eur); nur ohne Wechselkurs der Kurs-Waehrungs-Wert + gap. KEIN Untertitel (Stueck und Kurs stehen im
--     Aufklappen). Pille nur fuer ein Kurs-Problem: warn „Kurs fehlt" bzw. „Kurs veraltet ({Kurs-Datum})"; Gewinn/Verlust
--     seit Kauf als trend („+x € · +y %", Pfeil, keine Ampel-Farbe; 0 -> keiner). Bekannte Grenze: book_value_eur rechnet
--     eine Fremdwaehrungs-Kostenbasis zum heutigen Kurs um -> der Waehrungseffekt fehlt im „seit Kauf".
--     Depot-Summe (section.value) nur ab zwei Positionen, ohne Position ohne EUR-Wert (sonst still zu niedrig) und nur bei
--     mindestens zwei Eltern-Depots in der Sicht: mit einem Depot waere sie der Hero (bis auf Rundung; L4 sieht das nicht).
--     Aufklappen (hoechstens 8): Bestand „{Stueck} Stueck · Kurs {Kurs}" (Kurs in Kurs-Waehrung, „vom {Datum}" nur wenn es
--     vom Hero-Datum abweicht und der Kurs nicht veraltet ist, ohne Kurs nur die Stueck), Ø Kaufkurs, Kaufwert, dann
--     hoechstens 5 Buchungs-Zeilen (finance.fn_app_holding_transactions). Kein „Seit Kauf" (= trend).
--   DEPOTS DER KINDER (nur Haushalts-Sicht, nur Kind-Depots mit Positionen, zuletzt; Mini-App-UX-Gesamtkonzept P10, Owner-
--     Entscheid D2): eine Zeile je Kind-Depot: Wert nach der Regel der Vermoegen-Seite (ohne Kurs zaehlt der Kaufwert; gap,
--     wenn eine Position keinen EUR-Wert hat), Untertitel = Inhaber (full_name wie die Vermoegen-Seite), trend nach der
--     Regel der Hero-Note, Pille Kurs fehlt vor Kurs veraltet ({aeltestes Datum}); Zeilen mit Pille zuerst, dann nach Wert.
--     Aufklappen: „Rendite seit {Datum}" = Jahreswert aus fn_depot_performance (nur mit return_pa_pct; bei veraltetem Kurs
--     mit dem Hinweis „vorlaeufig" wie im Rendite-Abschnitt), dann je Position
--     „<Name>: Wert · Gewinn" (ohne EUR-Wert der native Wert, ohne Kurs „Kurs fehlt"), hoechstens 8 Zeilen (sonst
--     „und n weitere Positionen"). Abschnitts-Summe ab zwei Kind-Depots ohne gap.
--   Depot-Auswahl ueberall = finance.fn_visible_depots.
--   ZERO-TRUST-SICHTBARKEIT (core.fn_app_sees_household): owner/partner sehen alle aktiven Depots, alle anderen nur
--     Depots mit owner_person_id = ich (dann ohne Kinder-Trennung: der Hero ist die eigene Summe, kein Kinder-Abschnitt).
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
    v_parents  int;
    v_depots   jsonb;
    v_kids     jsonb;
    v_perf_j   jsonb;
    v_stale    jsonb;
    v_stale_hh date;
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

    -- Kennzahlen der Hero-Auswahl (ohne Kinder-Depots): Kurs-Datum, Gewinn seit Kauf, Positionen ohne Wert; Anzahl der
    -- Eltern-Depots mit Positionen (Regel der Depot-Summe)
    SELECT COALESCE(max(o.price_as_of) FILTER (WHERE NOT d.kid), max(o.price_as_of)),
           sum(o.unrealized_gain_eur) FILTER (WHERE NOT d.kid AND o.price_status = 'ok' AND o.book_value_eur > 0
                                                AND o.unrealized_gain_eur IS NOT NULL),
           sum(o.book_value_eur) FILTER (WHERE NOT d.kid AND o.price_status = 'ok' AND o.book_value_eur > 0
                                           AND o.unrealized_gain_eur IS NOT NULL),
           COALESCE(bool_or(o.market_value_eur IS NULL) FILTER (WHERE NOT d.kid), false),
           count(DISTINCT d.id) FILTER (WHERE NOT d.kid)
      INTO v_date, v_gain, v_book, v_pos_gap, v_parents
      FROM finance.fn_visible_depots(v_hh, v_pid) d
      JOIN finance.depot_holdings_overview o ON o.account_id = d.id;

    -- aeltestes veraltetes Kurs-Datum je Depot und ueber alle Eltern-Depots (Datum der „veraltet"-Pille im Rendite-
    -- Abschnitt; eine Abfrage statt einer je Rendite-Zeile)
    SELECT jsonb_object_agg(x.id::text, x.sd) FILTER (WHERE x.sd IS NOT NULL), min(x.sd) FILTER (WHERE NOT x.kid)
      INTO v_stale, v_stale_hh
      FROM (SELECT d.id, d.kid, min(o.price_as_of) FILTER (WHERE o.price_status = 'stale') AS sd
              FROM finance.fn_visible_depots(v_hh, v_pid) d
              JOIN finance.depot_holdings_overview o ON o.account_id = d.id
             GROUP BY d.id, d.kid) x;

    -- Rendite je Depot (dieselbe Sicht): einmal rechnen, fuer den Rendite-Abschnitt und die Kinder-Zeilen
    v_perf_j := finance.fn_depot_performance(jsonb_build_object('person_id', v_pid));

    -- je sichtbarem Depot: Positionen, Wert, Luecke, Kurs-Problem
    WITH d AS (
        SELECT v.id, v.name, v.kid, v.owner_person_id FROM finance.fn_visible_depots(v_hh, v_pid) v
    ), h AS (
        SELECT d.id AS depot_id, d.name AS depot_name, d.kid, d.owner_person_id,
               o.holding_id, o.name, o.shares, o.currency, o.average_purchase_price, o.book_value, o.book_value_eur,
               o.market_value, o.market_value_eur, o.unrealized_gain_eur, o.price_currency, o.latest_price,
               o.price_as_of, o.price_status,
               (o.price_status = 'ok' AND o.book_value_eur > 0 AND o.unrealized_gain_eur IS NOT NULL) AS has_gain,
               CASE WHEN o.book_value_eur > 0 THEN round(100 * o.unrealized_gain_eur / o.book_value_eur, 1) END AS gain_pct,
               row_number() OVER (PARTITION BY d.id ORDER BY o.market_value_eur DESC NULLS LAST, o.name) AS rn,
               count(*) OVER (PARTITION BY d.id) AS cnt
          FROM d
          JOIN finance.depot_holdings_overview o ON o.account_id = d.id
    ), per AS (
        -- Eltern-Depots (in der Kind-Sicht: die eigenen) als je ein Abschnitt
        SELECT h.depot_name AS name,
               sum(h.market_value_eur) AS val,
               count(*) AS n,
               jsonb_agg(jsonb_build_object(
                   'label', h.name,
                   'sub', NULL,
                   'value', CASE WHEN h.market_value_eur IS NOT NULL THEN core.fn_ui_money(h.market_value_eur, 'EUR')
                                 WHEN h.market_value IS NOT NULL THEN core.fn_ui_money(h.market_value, h.price_currency) END,
                   'gap', h.market_value_eur IS NULL,
                   -- Pille nur fuer ein Kurs-Problem (Handlungsbedarf); der Gewinn seit Kauf ist Information -> trend
                   'pill', CASE
                       WHEN h.price_status = 'missing' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                                 'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
                       WHEN h.price_status = 'stale' THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                                                 'text', core.fn_ui_tpl('finance.app.depot.price_stale_date', jsonb_build_object(
                                                     'date', core.fn_ui_date(h.price_as_of))))
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
                                  jsonb_build_object(
                                      'label', core.fn_ui_tpl('finance.app.depot.d_holding'),
                                      'value', CASE
                                          WHEN h.latest_price IS NULL
                                          THEN core.fn_ui_tpl('finance.app.depot.d_holding_shares', jsonb_build_object(
                                                   'shares', core.fn_ui_num(h.shares, scale(trim_scale(h.shares)))))
                                          WHEN h.price_status <> 'stale' AND h.price_as_of IS DISTINCT FROM v_date
                                          THEN core.fn_ui_tpl('finance.app.depot.d_holding_value_date', jsonb_build_object(
                                                   'shares', core.fn_ui_num(h.shares, scale(trim_scale(h.shares))),
                                                   'price', core.fn_ui_money(h.latest_price, h.price_currency),
                                                   'date', core.fn_ui_date(h.price_as_of)))
                                          ELSE core.fn_ui_tpl('finance.app.depot.d_holding_value', jsonb_build_object(
                                                   'shares', core.fn_ui_num(h.shares, scale(trim_scale(h.shares))),
                                                   'price', core.fn_ui_money(h.latest_price, h.price_currency))) END),
                                  CASE WHEN h.average_purchase_price IS NOT NULL THEN jsonb_build_object(
                                      'label', core.fn_ui_tpl('finance.app.depot.d_avg_price'),
                                      'value', core.fn_ui_money(h.average_purchase_price, h.currency)) END,
                                  CASE WHEN h.book_value IS NOT NULL THEN jsonb_build_object(
                                      'label', core.fn_ui_tpl('finance.app.depot.d_book_value'),
                                      'value', core.fn_ui_money(h.book_value, h.currency)) END]) WITH ORDINALITY AS k(e, n))
                              || finance.fn_app_holding_transactions(h.holding_id))
                 ORDER BY h.rn) AS items,
               bool_or(h.market_value_eur IS NULL) AS val_gap
          FROM h
         WHERE NOT h.kid
         GROUP BY h.depot_id, h.depot_name
    ), kd AS (
        -- Kind-Depots (nur Haushalts-Sicht): eine Zeile je Depot, Positionen im Aufklappen
        SELECT h.depot_id, h.depot_name, hp.full_name AS owner_name,
               sum(COALESCE(h.market_value_eur, h.book_value_eur)) AS val,
               bool_or(h.market_value_eur IS NULL) AS val_gap,
               sum(h.unrealized_gain_eur) FILTER (WHERE h.has_gain) AS gain,
               sum(h.book_value_eur) FILTER (WHERE h.has_gain) AS book,
               bool_or(h.price_status = 'missing') AS missing,
               min(h.price_as_of) FILTER (WHERE h.price_status = 'stale') AS stale_date,
               max(h.cnt) AS cnt,
               jsonb_agg(jsonb_build_object(
                   'label', h.name,
                   'value', CASE
                       WHEN h.market_value_eur IS NOT NULL AND h.has_gain AND h.unrealized_gain_eur <> 0
                       THEN core.fn_ui_tpl('finance.app.depot.kid_position', jsonb_build_object(
                                'value', core.fn_ui_money(h.market_value_eur, 'EUR'),
                                'gain', core.fn_ui_tpl('finance.app.depot.gain', jsonb_build_object(
                                            'amount', core.fn_ui_money(h.unrealized_gain_eur, 'EUR', true),
                                            'pct', core.fn_ui_num(h.gain_pct, 1, true)))))
                       WHEN h.market_value_eur IS NOT NULL THEN core.fn_ui_money(h.market_value_eur, 'EUR')
                       WHEN h.market_value IS NOT NULL THEN core.fn_ui_money(h.market_value, h.price_currency)
                       ELSE core.fn_ui_tpl('finance.app.depot.price_missing') END) ORDER BY h.rn) AS positions
          FROM h
          LEFT JOIN core.fn_household_persons() hp ON hp.person_id = h.owner_person_id
         WHERE h.kid
         GROUP BY h.depot_id, h.depot_name, hp.full_name
    ), kp AS (
        -- Jahres-Rendite der Kind-Depots (aus derselben fn_depot_performance wie der Rendite-Abschnitt)
        SELECT (r ->> 'account_id')::int AS depot_id, (r ->> 'return_pa_pct')::numeric AS pa_pct,
               (r ->> 'start_date')::date AS pa_since, COALESCE((r ->> 'price_stale')::boolean, false) AS pa_stale
          FROM jsonb_array_elements(v_perf_j -> 'rows') r
         WHERE (r ->> 'is_child')::boolean AND r ->> 'return_pa_pct' IS NOT NULL
    ), kr AS (
        SELECT kd.*, kp.pa_pct, kp.pa_since, COALESCE(kp.pa_stale, false) AS pa_stale,
               CASE WHEN kd.missing THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                                             'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
                    WHEN kd.stale_date IS NOT NULL THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                                             'text', core.fn_ui_tpl('finance.app.depot.price_stale_date', jsonb_build_object(
                                                 'date', core.fn_ui_date(kd.stale_date)))) END AS pill,
               -- hoechstens 8 Detail-Zeilen: Rendite (+ Hinweis bei veraltetem Kurs, wie im Rendite-Abschnitt), der Rest
               -- Positionen bzw. „weitere"
               8 - (kp.pa_pct IS NOT NULL)::int - (kp.pa_pct IS NOT NULL AND kp.pa_stale)::int AS room
          FROM kd
          LEFT JOIN kp ON kp.depot_id = kd.depot_id
    )
    SELECT (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'title', core.fn_ui_tpl('finance.app.depot.section', jsonb_build_object('name', per.name)),
                'value', CASE WHEN per.n >= 2 AND v_parents >= 2 AND per.val IS NOT NULL AND NOT per.val_gap
                              THEN core.fn_ui_money(per.val, 'EUR') END,
                'empty', core.fn_ui_tpl('finance.app.depot.empty'),
                'items', per.items)
              ORDER BY per.val DESC NULLS LAST, per.name), '[]'::jsonb) FROM per),
           (SELECT CASE WHEN count(*) > 0 THEN jsonb_build_object(
                'title', core.fn_ui_tpl('finance.app.depot.section_kids'),
                'value', CASE WHEN count(*) >= 2 AND NOT bool_or(kr.val_gap) THEN core.fn_ui_money(sum(kr.val), 'EUR') END,
                'empty', core.fn_ui_tpl('finance.app.depot.empty'),
                'items', jsonb_agg(jsonb_build_object(
                    'label', kr.depot_name,
                    'sub', CASE WHEN kr.owner_name IS NOT NULL
                                THEN core.fn_ui_tpl('finance.app.depot.kid_owner', jsonb_build_object('name', kr.owner_name)) END,
                    'value', core.fn_ui_money(kr.val, 'EUR'),
                    'gap', kr.val_gap,
                    'pill', kr.pill,
                    'trend', CASE WHEN kr.book > 0 AND kr.gain <> 0 THEN jsonb_build_object(
                                 'direction', CASE WHEN kr.gain > 0 THEN 'up' ELSE 'down' END,
                                 'text', core.fn_ui_tpl('finance.app.depot.gain', jsonb_build_object(
                                             'amount', core.fn_ui_money(kr.gain, 'EUR', true),
                                             'pct', core.fn_ui_num(round(100 * kr.gain / kr.book, 1), 1, true)))) END,
                    'progress', NULL,
                    'target', NULL,
                    'details',
                        CASE WHEN kr.pa_pct IS NOT NULL THEN jsonb_build_array(jsonb_build_object(
                            'label', core.fn_ui_tpl('finance.app.depot.kid_perf', jsonb_build_object(
                                         'date', core.fn_ui_date(kr.pa_since))),
                            'value', core.fn_ui_tpl('finance.app.depot.perf_pa', jsonb_build_object(
                                         'pct', core.fn_ui_num(round(kr.pa_pct, 1), 1, true))))) ELSE '[]'::jsonb END
                        || CASE WHEN kr.pa_pct IS NOT NULL AND kr.pa_stale THEN jsonb_build_array(jsonb_build_object(
                            'label', core.fn_ui_tpl('finance.app.depot.d_perf_stale'), 'value', NULL)) ELSE '[]'::jsonb END
                        || CASE WHEN kr.cnt <= kr.room THEN kr.positions
                                ELSE (SELECT jsonb_agg(x.e ORDER BY x.o) FROM jsonb_array_elements(kr.positions)
                                          WITH ORDINALITY AS x(e, o) WHERE x.o <= kr.room - 1)
                                     || jsonb_build_array(jsonb_build_object(
                                            'label', core.fn_ui_tpl('finance.app.depot.more_positions', jsonb_build_object(
                                                         'count', core.fn_ui_num(kr.cnt - (kr.room - 1), 0))),
                                            'value', NULL)) END)
                  ORDER BY (kr.pill IS NULL), kr.val DESC NULLS LAST, kr.depot_name)) END
              FROM kr)
      INTO v_depots, v_kids;

    -- Rendite je Depot: EIN Abschnitt vor den Depots, nur Eltern-Depots mit Jahreswert (die 365-Tage-Regel bleibt in der
    -- fn) bzw. mit Kurs-/Wechselkurs-Luecke und Beginn vor mindestens einem Jahr (ohne Kurs fehlt der Endwert-Fluss,
    -- period_days waere 0). EIN Zeitraum auf der Seite: darunter beantwortet „seit Kauf" die Gewinn-Frage. „Alle Depots"
    -- nur, wenn ALLE Haushalts-Depots mit Einzahlung stehen (mindestens zwei): sonst poolte die Summe versteckte junge
    -- Depots (bei Uebernahme ab Uebernahme-Kurs).
    WITH a AS (
        SELECT t.x, t.o, (t.x ->> 'return_pa_pct')::numeric AS pct,
               NOT (t.x ->> 'is_total')::boolean AS hh,
               (t.x ->> 'return_pa_pct' IS NOT NULL
                OR (t.x ->> 'missing_reason' IN ('no_price', 'no_fx')
                    AND (t.x ->> 'start_date')::date <= (v_perf_j ->> 'as_of')::date - 365)) AS shown,
               -- aeltestes veraltetes Kurs-Datum: je Depot bzw. fuer „Alle Depots" ueber alle Eltern-Depots der Sicht
               CASE WHEN (t.x ->> 'is_total')::boolean THEN v_stale_hh
                    ELSE (v_stale ->> (t.x ->> 'account_id'))::date END AS stale_date
          FROM jsonb_array_elements(v_perf_j -> 'rows') WITH ORDINALITY AS t(x, o)
         WHERE t.x ->> 'missing_reason' IS DISTINCT FROM 'no_flows'
           AND NOT (t.x ->> 'is_child')::boolean
    ), r AS (
        SELECT a.x, a.o, a.pct, a.stale_date FROM a WHERE a.shown
    ), n AS (
        SELECT count(*) FILTER (WHERE a.hh AND a.shown) AS cnt, COALESCE(bool_and(a.shown) FILTER (WHERE a.hh), false) AS all_hh
          FROM a
    )
    SELECT jsonb_agg(jsonb_build_object(
               'label', CASE WHEN (r.x ->> 'is_total')::boolean THEN core.fn_ui_tpl('finance.app.depot.perf_total')
                             ELSE r.x -> 'depot_name' END,
               'sub', core.fn_ui_tpl('finance.app.depot.perf_since',
                          jsonb_build_object('date', core.fn_ui_date((r.x ->> 'start_date')::date))),
               -- Wert rechts = die Rendite pro Jahr (Messwert, keine Ampel-Farbe; Mini-App UX 2026-10-30)
               'value', CASE WHEN r.pct IS NOT NULL THEN core.fn_ui_tpl('finance.app.depot.perf_pa',
                                  jsonb_build_object('pct', core.fn_ui_num(round(r.pct, 1), 1, true))) END,
               'gap', r.x ->> 'missing_reason' IN ('no_price', 'no_fx'),
               'pill', CASE
                   -- veralteter Kurs: Zahl bleibt, Pille warnt wie an der Position (mit dem Kurs-Datum)
                   WHEN r.pct IS NOT NULL AND (r.x ->> 'price_stale')::boolean
                   THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                            'text', core.fn_ui_tpl('finance.app.depot.price_stale_date', jsonb_build_object(
                                        'date', core.fn_ui_date(r.stale_date))))
                   WHEN r.pct IS NOT NULL THEN NULL
                   WHEN r.x ->> 'missing_reason' = 'no_price' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                       'text', core.fn_ui_tpl('finance.app.depot.price_missing'))
                   WHEN r.x ->> 'missing_reason' = 'no_fx' THEN jsonb_build_object('state', 'warn', 'icon', 'alert',
                       'text', core.fn_ui_tpl('finance.app.depot.perf_fx_missing'))
               END,
               'progress', NULL,
               'target', NULL,
               'details', (SELECT COALESCE(jsonb_agg(e ORDER BY k) FILTER (WHERE e IS NOT NULL), '[]'::jsonb)
                             FROM unnest(ARRAY[
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
    IF v_kids IS NOT NULL THEN
        v_depots := v_depots || jsonb_build_array(v_kids);
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
