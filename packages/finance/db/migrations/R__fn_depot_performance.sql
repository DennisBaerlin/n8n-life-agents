-- ============================================================
-- finance.fn_depot_performance(p jsonb) — Depot-Rendite je Depot und gesamt (READ, STABLE)
--   Geldgewichtete Rendite (XIRR, Act/365, finance.fn_xirr) aus Sicht des Anlegers: sie beruecksichtigt, wann wie viel
--   eingezahlt wurde (wie Portfolio Performance „IZF"). Eingabe (alles optional): as_of (Stichtag, Standard und
--   Obergrenze core.fn_today()), person_id (Sicht wie die Mini-App: core.fn_app_sees_household; ohne = Haushalt; nur
--   aus dem DEFINER-Handler finance.fn_app_screen_depot nutzbar, unter *_ro fehlt das EXECUTE auf den Rollen-Helfer).
--   Depot-Auswahl = finance.fn_visible_depots (dieselbe wie der Depot-Hero).
--   Rueckgabe {ok, as_of, rows:[…]}: eine Zeile je aktivem Depot (stocks_depot/crypto_depot) + EINE Gesamt-Zeile
--   (is_total, account_id/depot_name NULL), sortiert: Haushalt nach Wert, Kinder-Depots, gesamt zuletzt. Felder:
--   account_id, depot_name, owner_person_id, is_child, is_total, value_eur (Wert am Stichtag), start_date (erster
--   Fluss), period_days (erster..letzter Fluss), return_pa_pct (ab 365 Tagen, sonst NULL), return_since_start_pct
--   (unter 365 Tagen, nicht annualisiert — GIPS; alles an einem Tag: Auszahlung / Einzahlung - 1), takeover_start_date,
--   price_stale (eine Position steht auf einem veralteten Kurs, Regel fn_price_status relativ zum Stichtag: die Zahl
--   gilt, ist aber mit Vorsicht zu lesen), missing_reason.
--   GELDFLUESSE in EUR zum Buchungstag (fn_to_eur(amount, Kontowaehrung, Datum)): jede Buchung mit holding_id einer
--     Position des Depots mit ihrem Vorzeichen (Kauf -, Verkauf/Dividende +, Positions-Gebuehr -); ausverkaufte
--     Positionen zaehlen mit. Endwert = Bestand am Stichtag (Summe shares bis as_of) x juengster Kurs <= as_of,
--     fn_to_eur zum Stichtag (wie depot_holdings_overview).
--   UEBERNAHME (Kauf mit position_takeover-Gegenbuchung derselben group_id; Paket A: mehrere Tranchen moeglich): der
--     Einstand ist kein echter Geldfluss (sonst verteilten sich Jahre an Gewinn auf Wochen). Start S = erster Kurs-Tag
--     >= juengster Uebernahme-Tag der Position; Startwert = Bestand nach allen Buchungen bis S x Kurs an S als
--     Einzahlung am Tag S; alle Buchungen der Position bis S fallen in den Startwert. Liegt S nach dem
--     Uebernahme-Tag (kein Kurs an dem Tag), traegt das Depot takeover_start_date = juengstes solches S (Hinweis
--     „ab <Datum>"). Kein Kurs ab dem Uebernahme-Tag -> no_price.
--   missing_reason (dann value_eur und/oder Rendite NULL, nie 0, nie Kaufwert-Fallback): no_price (Position mit Bestand
--     ohne Kurs, Uebernahme ohne Startkurs), no_fx (Wechselkurs fehlt fuer Endwert, Startwert oder einen Fluss),
--     no_flows (nichts eingezahlt, z. B. leeres Depot), no_result (XIRR ohne Loesung).
--   GESAMT = gepoolte Fluesse aller Nicht-Kinder-Depots der Sicht (wie der Depot-Hero): Kinder-Depots (role = 'child',
--     nur in der Haushalts-Sicht) stehen als eigene Zeilen, nicht in gesamt. Eine Luecke in einem Depot macht gesamt NULL.
--   Bekannte Grenzen: Depot-Gebuehren ohne holding_id (category fee am Verrechnungskonto) zaehlen nicht (kein Depot
--     zuordenbar); Fluesse einer Uebernahme-Position vor S (auch fruehere, ausverkaufte Zyklen) gehen im Startwert auf;
--     geschlossene Depots fehlen (wie in der App).
--   INVOKER: liest nur finance + core.fn_household_persons (publiziertes Fenster, via fn_visible_depots); die View finance.depot_performance
--   (R__v_depot_performance.sql) ruft sie fuer den Agent-Read (finance_ro), finance.fn_app_screen_depot fuer die App.
--   Fehler als Daten: p kein Objekt / person_id kein Text -> {ok:false, code:'bad_request'}; as_of laeuft ueber
--   core.fn_resolve_input_dates (auch relativ, z. B. "yesterday"; Unsinn -> {ok:false, code:'invalid_date'}).
--   Quellen (Verfahren): siehe finance.fn_xirr; GIPS-Annualisierung https://www.gipsstandards.org/standards/
--   Tests: tests/db/finance/test_fn_depot_performance.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_depot_performance(p jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_dates jsonb;
    v_as_of date;
    v_pid   text;
    v_hh    boolean := true;
    v_rows  jsonb;
BEGIN
    p := COALESCE(p, '{}'::jsonb);
    IF jsonb_typeof(p) <> 'object' OR (p ? 'person_id' AND jsonb_typeof(p -> 'person_id') NOT IN ('string', 'null')) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_request');
    END IF;
    v_dates := core.fn_resolve_input_dates(p, ARRAY['as_of']);
    IF NOT (v_dates ->> 'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates -> 'p';
    -- nie nach heute: ein kuenftiger Endwert zum heutigen Kurs verteilte den Gewinn auf eine zu lange Zeit
    v_as_of := least(COALESCE(NULLIF(p ->> 'as_of', '')::date, core.fn_today()), core.fn_today());
    v_pid := NULLIF(p ->> 'person_id', '');
    IF v_pid IS NOT NULL THEN
        v_hh := core.fn_app_sees_household(v_pid);
    END IF;

    WITH dep AS (
        SELECT * FROM finance.fn_visible_depots(v_hh, v_pid)
    ), hold AS (
        SELECT h.id, h.account_id, h.symbol
          FROM finance.depot_holdings h
          JOIN dep ON dep.id = h.account_id
    ), tx AS MATERIALIZED (
        SELECT t.holding_id, t.transaction_date AS d, t.shares,
               finance.fn_to_eur(t.amount, ac.currency, t.transaction_date) AS eur,
               (t.category = 'buy' AND t.group_id IS NOT NULL
                AND EXISTS (SELECT 1 FROM finance.transactions g
                             WHERE g.group_id = t.group_id AND g.category = 'position_takeover')) AS takeover
          FROM finance.transactions t
          JOIN hold ON hold.id = t.holding_id
          JOIN finance.accounts ac ON ac.id = t.account_id
         WHERE t.transaction_date <= v_as_of
    ), pos AS (
        -- je Position: Bestand am Stichtag + juengster Uebernahme-Tag
        SELECT hold.id, hold.account_id, hold.symbol,
               COALESCE(sum(tx.shares), 0) AS shares_now,
               max(tx.d) FILTER (WHERE tx.takeover) AS d_take
          FROM hold
          LEFT JOIN tx ON tx.holding_id = hold.id
         GROUP BY hold.id, hold.account_id, hold.symbol
    ), st AS (
        -- Start-Kurs-Tag einer Uebernahme (erster Kurs >= Uebernahme-Tag) + juengster Kurs am Stichtag
        SELECT pos.*, s.as_of AS s_day,
               finance.fn_to_eur(round((SELECT COALESCE(sum(tx.shares), 0) FROM tx
                                         WHERE tx.holding_id = pos.id AND tx.d <= s.as_of) * s.price, 2),
                                 s.currency, s.as_of) AS s_eur,
               lp.price AS lp_price,
               -- veraltet relativ zum Stichtag, mit DER Regel fn_price_status (die misst gegen heute: Datum verschieben)
               (finance.fn_price_status(lp.as_of + (current_date - v_as_of)) = 'stale') AS lp_stale,
               finance.fn_to_eur(round(pos.shares_now * lp.price, 2), lp.currency, v_as_of) AS value_eur
          FROM pos
          LEFT JOIN LATERAL (SELECT mp.as_of, mp.price, mp.currency
                               FROM finance.market_prices mp
                              WHERE mp.symbol = pos.symbol AND mp.as_of >= pos.d_take AND mp.as_of <= v_as_of
                              ORDER BY mp.as_of LIMIT 1) s ON pos.d_take IS NOT NULL
          LEFT JOIN LATERAL (SELECT mp.as_of, mp.price, mp.currency
                               FROM finance.market_prices mp
                              WHERE mp.symbol = pos.symbol AND mp.as_of <= v_as_of
                              ORDER BY mp.as_of DESC LIMIT 1) lp ON true
    ), flows AS (
        -- kind: flow (echte Buchung) | start (Startwert einer Uebernahme) | value (Endwert) | gap (Uebernahme ohne Kurs)
        SELECT st.account_id, 'flow' AS kind, tx.d, tx.eur, NULL::date AS shifted
          FROM st
          JOIN tx ON tx.holding_id = st.id
         WHERE st.d_take IS NULL OR tx.d > st.s_day
        UNION ALL
        SELECT st.account_id, 'start', st.s_day, -st.s_eur, CASE WHEN st.s_day > st.d_take THEN st.s_day END
          FROM st
         WHERE st.s_day IS NOT NULL
        UNION ALL
        SELECT st.account_id, 'gap', NULL, NULL, NULL
          FROM st
         WHERE st.d_take IS NOT NULL AND st.s_day IS NULL
        UNION ALL
        SELECT st.account_id, 'value', v_as_of, st.value_eur, NULL
          FROM st
         WHERE st.shares_now > 0
    ), keyed AS (
        -- jede Zeile zaehlt fuer ihr Depot und (ohne Kinder-Depot) fuer gesamt (key 0)
        SELECT k.key, f.*
          FROM flows f
          JOIN dep ON dep.id = f.account_id
          CROSS JOIN LATERAL (VALUES (f.account_id), (CASE WHEN NOT dep.kid THEN 0 END)) AS k(key)
         WHERE k.key IS NOT NULL
    ), keys AS (
        SELECT dep.id AS key, dep.id AS account_id, dep.name, dep.owner_person_id, dep.kid, false AS total FROM dep
        UNION ALL
        SELECT 0, NULL, NULL, NULL, false, true WHERE EXISTS (SELECT 1 FROM dep WHERE NOT dep.kid)
    ), pstat AS (
        -- je Depot: Position mit Bestand ohne Kurs bzw. mit veraltetem Kurs (Endwert)
        SELECT st.account_id, bool_or(st.lp_price IS NULL) AS no_price, COALESCE(bool_or(st.lp_stale), false) AS stale
          FROM st
         WHERE st.shares_now > 0
         GROUP BY st.account_id
    ), agg AS (
        SELECT keys.key, keys.account_id, keys.name, keys.owner_person_id, keys.kid, keys.total,
               COALESCE(bool_or(f.kind = 'gap'), false)
                 OR EXISTS (SELECT 1 FROM pstat ps JOIN dep ON dep.id = ps.account_id
                             WHERE ps.no_price AND (ps.account_id = keys.key OR (keys.key = 0 AND NOT dep.kid))) AS no_price,
               EXISTS (SELECT 1 FROM pstat ps JOIN dep ON dep.id = ps.account_id
                        WHERE ps.stale AND (ps.account_id = keys.key OR (keys.key = 0 AND NOT dep.kid))) AS price_stale,
               COALESCE(bool_or(f.kind <> 'gap' AND f.eur IS NULL), false) AS no_fx,
               COALESCE(bool_or(f.kind = 'value' AND f.eur IS NULL), false) AS value_gap,
               COALESCE(sum(f.eur) FILTER (WHERE f.kind = 'value'), 0) AS value_eur,
               COALESCE(bool_or(f.eur < 0), false) AS invested,
               min(f.d) FILTER (WHERE f.kind IN ('flow', 'start') AND f.eur <> 0) AS start_date,
               max(f.d) FILTER (WHERE f.eur <> 0) AS end_date,
               max(f.shifted) AS takeover_start_date,
               sum(f.eur) FILTER (WHERE f.eur > 0) AS paid_out,
               sum(f.eur) FILTER (WHERE f.eur < 0) AS paid_in,
               -- nur Fluesse <> 0: fn_xirr misst die Periode ueber genau die Tage, die auch period_days bestimmen
               array_agg(f.d) FILTER (WHERE f.eur <> 0) AS ds,
               array_agg(f.eur) FILTER (WHERE f.eur <> 0) AS es
          FROM keys
          LEFT JOIN keyed f ON f.key = keys.key
         GROUP BY keys.key, keys.account_id, keys.name, keys.owner_person_id, keys.kid, keys.total
    ), res AS (
        SELECT agg.*, r.reason, (agg.end_date - agg.start_date) AS days,
               CASE WHEN r.reason IS NOT NULL THEN NULL
                    -- alles an einem Tag (z. B. Uebernahme heute, Kurs von heute): Auszahlung / Einzahlung - 1
                    WHEN agg.end_date = agg.start_date THEN COALESCE(agg.paid_out, 0) / -agg.paid_in - 1
                    ELSE finance.fn_xirr(agg.ds, agg.es, (agg.end_date - agg.start_date) >= 365) END AS rate
          FROM agg
          CROSS JOIN LATERAL (SELECT CASE WHEN agg.no_price THEN 'no_price'
                                          WHEN agg.no_fx THEN 'no_fx'
                                          WHEN NOT agg.invested THEN 'no_flows' END AS reason) r
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_id', res.account_id,
               'depot_name', res.name,
               'owner_person_id', res.owner_person_id,
               'is_child', res.kid,
               'is_total', res.total,
               'value_eur', CASE WHEN NOT (res.no_price OR res.value_gap) THEN round(res.value_eur, 2) END,
               'start_date', CASE WHEN res.invested THEN res.start_date END,
               'period_days', CASE WHEN res.invested THEN res.days END,
               'return_pa_pct', CASE WHEN res.days >= 365 THEN round(100 * res.rate, 2) END,
               'return_since_start_pct', CASE WHEN res.days < 365 THEN round(100 * res.rate, 2) END,
               'takeover_start_date', res.takeover_start_date,
               'price_stale', res.price_stale,
               'missing_reason', COALESCE(res.reason, CASE WHEN res.rate IS NULL THEN 'no_result' END))
             ORDER BY res.total, res.kid,
                      CASE WHEN NOT (res.no_price OR res.value_gap) THEN res.value_eur END DESC NULLS LAST,
                      res.name), '[]'::jsonb)
      INTO v_rows
      FROM res;

    RETURN jsonb_build_object('ok', true, 'as_of', v_as_of, 'rows', v_rows);
END;
$$;
