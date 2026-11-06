-- ============================================================
-- fn_app_payment_rows (READ, IMMUTABLE) -- Zahlungs-Vorkommen fuer die Mini-App gruppieren (Aufklapp-Liste)
--   Die EINE Regel fuer die Einzelposten der Zeilen „Gehen ab“ / „Kommen rein“ und der Bruecke auf dem Tab „Konten“
--   (finance.fn_app_screen_accounts). Wiederholte Vorkommen derselben Zahlung mit gleichem Betrag (Schluessel =
--   Lineage-Kopf + Seite, vom Aufrufer als key; eine abweichende Kredit-Schlussrate hat einen anderen Betrag und bleibt
--   eigene Zeile) werden EINE Zeile. Rechnet nichts ausser Anzahl/Summe/erstes/letztes Datum der Gruppe.
--   DECKEL (§3.12 details <= 8 Zeilen, UX-Gesamtkonzept 2026-10-31): mehr als 8 Gruppen -> die ersten 7 + eine Zeile
--   „weitere n Zahlungen“ mit ihrer Summe (Waehrung der Zeilen).
--   EINGABE p = {rows: [{key, date, amount, cur, label}]} (label = Text oder ui-Wert)
--   RUECKGABE jsonb-Array, Reihenfolge erstes Datum, Label: 1 Vorkommen {label, value: d_payment} /
--   n {label, value: d_payment_n (n x Betrag · erstes - letztes)} / Rest {label: d_more, value: Summe}
--   Tests: tests/db/finance/test_fn_app_payment_rows.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_payment_rows(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    WITH r AS (
        SELECT x->>'key' AS k, (x->>'date')::date AS d, (x->>'amount')::numeric AS amt, x->>'cur' AS cur,
               x->'label' AS label
          FROM jsonb_array_elements(COALESCE(p->'rows', '[]'::jsonb)) x
    ), g AS (
        SELECT r.k, r.amt, r.cur, r.label, count(*) AS n, min(r.d) AS first_d, max(r.d) AS last_d, sum(r.amt) AS total
          FROM r
         GROUP BY r.k, r.amt, r.cur, r.label
    ), o AS (
        SELECT g.*, row_number() OVER (ORDER BY g.first_d, g.label::text, g.amt) AS pos, count(*) OVER () AS cnt FROM g
    )
    SELECT COALESCE(jsonb_agg(x.e ORDER BY x.pos), '[]'::jsonb)
      FROM (SELECT o.pos, CASE
                       WHEN o.n = 1 THEN jsonb_build_object(
                           'label', o.label,
                           'value', core.fn_ui_tpl('finance.app.accounts.d_payment', jsonb_build_object(
                                        'date', core.fn_ui_date(o.first_d), 'amount', core.fn_ui_money(o.amt, o.cur, o.amt > 0))))
                       ELSE jsonb_build_object(
                           'label', o.label,
                           'value', core.fn_ui_tpl('finance.app.accounts.d_payment_n', jsonb_build_object(
                                        'n', core.fn_ui_num(o.n), 'amount', core.fn_ui_money(o.amt, o.cur, o.amt > 0),
                                        'first', core.fn_ui_date(o.first_d), 'last', core.fn_ui_date(o.last_d)))) END AS e
              FROM o WHERE o.cnt <= 8 OR o.pos <= 7
            UNION ALL
            SELECT 8, jsonb_build_object(
                       'label', core.fn_ui_tpl('finance.app.accounts.d_more', jsonb_build_object('n', core.fn_ui_num(sum(o.n)))),
                       'value', core.fn_ui_money(sum(o.total), min(o.cur), sum(o.total) > 0))
              FROM o WHERE o.cnt > 8 AND o.pos > 7
            HAVING count(*) > 0) x;
$$;
