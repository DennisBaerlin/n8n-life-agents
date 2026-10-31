-- ============================================================
-- fn_app_payment_rows (READ, IMMUTABLE) -- Zahlungs-Vorkommen fuer die Mini-App gruppieren (Mini-App UX 2026-10-30):
--   die EINE Regel, die fn_app_screen_payments an drei Stellen nutzt (Konten ohne Vorschau, Bruecken-Einzelposten,
--   Zahlungen bis Fensterende). Wiederholte Vorkommen derselben Zahlung mit gleichem Betrag (Schluessel = Lineage-Kopf +
--   Seite, vom Aufrufer als key; eine abweichende Kredit-Schlussrate hat einen anderen Betrag und bleibt eigene Zeile)
--   werden EINE Zeile; ein einzelnes Vorkommen bleibt im bisherigen Format. Rechnet nichts ausser Anzahl/Summe/erstes/
--   letztes Datum der Gruppe (Anzeige-Aggregat derselben DB-Betraege).
--   EINGABE p = {mode: 'items'|'details', rows: [{key, date, amount, cur, label, to?}]} (label/to = Text oder ui-Wert)
--   RUECKGABE jsonb-Array, Reihenfolge erstes Datum, Label:
--     items:   1 Vorkommen {label, sub: due_on | due_on_to, value} / n {label, sub: rows_n | rows_n_to, value = Summe,
--              details = je Termin (Datum, Betrag)} — Eingaenge mit Vorzeichen (+)
--     details: 1 Vorkommen {label, value: d_payment} / n {label, value: d_payment_n (n x Betrag · erstes - letztes)}
--   Tests: tests/db/finance/test_fn_app_payment_rows.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_payment_rows(p jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    WITH r AS (
        SELECT x->>'key' AS k, (x->>'date')::date AS d, (x->>'amount')::numeric AS amt, x->>'cur' AS cur,
               x->'label' AS label, NULLIF(x->'to', 'null'::jsonb) AS tgt
          FROM jsonb_array_elements(COALESCE(p->'rows', '[]'::jsonb)) x
    ), g AS (
        SELECT r.k, r.amt, r.cur, r.label, r.tgt, count(*) AS n, min(r.d) AS first_d, max(r.d) AS last_d,
               sum(r.amt) AS total,
               jsonb_agg(jsonb_build_object('label', core.fn_ui_date(r.d), 'value', core.fn_ui_money(r.amt, r.cur, r.amt > 0))
                         ORDER BY r.d) AS dates
          FROM r
         GROUP BY r.k, r.amt, r.cur, r.label, r.tgt
    )
    SELECT COALESCE(jsonb_agg(CASE
               WHEN p->>'mode' = 'details' AND g.n = 1 THEN jsonb_build_object(
                   'label', g.label,
                   'value', core.fn_ui_tpl('finance.app.payments.d_payment', jsonb_build_object(
                                'date', core.fn_ui_date(g.first_d), 'amount', core.fn_ui_money(g.amt, g.cur, g.amt > 0))))
               WHEN p->>'mode' = 'details' THEN jsonb_build_object(
                   'label', g.label,
                   'value', core.fn_ui_tpl('finance.app.payments.d_payment_n', jsonb_build_object(
                                'n', core.fn_ui_num(g.n), 'amount', core.fn_ui_money(g.amt, g.cur, g.amt > 0),
                                'first', core.fn_ui_date(g.first_d), 'last', core.fn_ui_date(g.last_d))))
               WHEN g.n = 1 THEN jsonb_build_object(
                   'label', g.label,
                   'sub', CASE WHEN g.tgt IS NULL
                               THEN core.fn_ui_tpl('finance.app.payments.due_on', jsonb_build_object('date', core.fn_ui_date(g.first_d)))
                               ELSE core.fn_ui_tpl('finance.app.payments.due_on_to', jsonb_build_object(
                                        'date', core.fn_ui_date(g.first_d), 'to', g.tgt)) END,
                   'value', core.fn_ui_money(g.amt, g.cur, g.amt > 0),
                   'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL)
               ELSE jsonb_build_object(
                   'label', g.label,
                   'sub', core.fn_ui_tpl(CASE WHEN g.tgt IS NULL THEN 'finance.app.payments.rows_n'
                                              ELSE 'finance.app.payments.rows_n_to' END, jsonb_build_object(
                              'n', core.fn_ui_num(g.n), 'first', core.fn_ui_date(g.first_d),
                              'last', core.fn_ui_date(g.last_d), 'to', g.tgt)),
                   'value', core.fn_ui_money(g.total, g.cur, g.total > 0),
                   'gap', false, 'pill', NULL, 'progress', NULL, 'target', NULL,
                   'details', g.dates) END
             ORDER BY g.first_d, g.label::text, g.amt), '[]'::jsonb)
      FROM g;
$$;
