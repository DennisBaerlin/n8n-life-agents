-- tests/db/finance/test_fn_app_payment_rows.sql
-- finance.fn_app_payment_rows(p) — Zahlungs-Vorkommen der Mini-App als Aufklapp-Liste gruppieren:
--   gleiche Zahlung (key) + gleicher Betrag -> eine Zeile (n x Betrag · erstes - letztes); ein Vorkommen bleibt einzeln;
--   abweichender Betrag (Schlussrate) = eigene Zeile; Eingaenge mit Vorzeichen; mehr als 8 Gruppen -> 7 + „weitere n
--   Zahlungen“ mit Summe (§3.12 details <= 8). Erfundene Werte.
BEGIN;
DO $$
DECLARE
  d1 date := current_date + 2; d2 date := current_date + 9; d3 date := current_date + 16;
  v jsonb; v_rows jsonb;
BEGIN
  v_rows := jsonb_build_array(
    jsonb_build_object('key', '7:out', 'date', d1, 'amount', -50, 'cur', 'EUR', 'label', 'Welt ETF'),
    jsonb_build_object('key', '7:out', 'date', d2, 'amount', -50, 'cur', 'EUR', 'label', 'Welt ETF'),
    jsonb_build_object('key', '7:out', 'date', d3, 'amount', -50, 'cur', 'EUR', 'label', 'Welt ETF'),
    jsonb_build_object('key', '8:in',  'date', d2, 'amount', 30,  'cur', 'EUR', 'label', 'Taschengeld'),
    jsonb_build_object('key', '9:out', 'date', d1, 'amount', -200, 'cur', 'EUR', 'label', 'Kredit'),
    jsonb_build_object('key', '9:out', 'date', d3, 'amount', -80, 'cur', 'EUR', 'label', 'Kredit'));

  v := finance.fn_app_payment_rows(jsonb_build_object('rows', v_rows));
  IF jsonb_array_length(v) <> 4 THEN RAISE EXCEPTION 'FAIL [1] 4 Zeilen (3x ETF gruppiert, Kredit + Schlussrate getrennt), got %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('label', 'Welt ETF',
            'value', core.fn_ui_tpl('finance.app.accounts.d_payment_n', jsonb_build_object('n', core.fn_ui_num(3),
                         'amount', core.fn_ui_money(-50, 'EUR'), 'first', core.fn_ui_date(d1), 'last', core.fn_ui_date(d3)))))) THEN
    RAISE EXCEPTION 'FAIL [2] 3x -50 erstes-letztes, got %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('label', 'Taschengeld',
            'value', core.fn_ui_tpl('finance.app.accounts.d_payment', jsonb_build_object(
                         'date', core.fn_ui_date(d2), 'amount', core.fn_ui_money(30, 'EUR', true)))))) THEN
    RAISE EXCEPTION 'FAIL [3] Eingang einzeln mit Vorzeichen, got %', v; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v) i WHERE i->>'label' = 'Kredit') <> 2 THEN
    RAISE EXCEPTION 'FAIL [4] Schlussrate eigene Zeile, got %', v; END IF;
  IF v->-1->>'label' <> 'Kredit' THEN RAISE EXCEPTION 'FAIL [5] Reihenfolge erstes Datum, got %', v; END IF;
  IF finance.fn_app_payment_rows('{"rows":[]}') <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [6] leer'; END IF;
  RAISE NOTICE 'PASS [1-6] Gruppierung, Schlussrate getrennt, Vorzeichen';

  -- [7] Deckel: 10 verschiedene Zahlungen -> 7 Einzelzeilen + „weitere 3 Zahlungen“ mit deren Summe
  SELECT jsonb_agg(jsonb_build_object('key', g || ':out', 'date', current_date + g, 'amount', -10 * g, 'cur', 'EUR',
                                      'label', 'Zahlung ' || g) ORDER BY g)
    INTO v_rows FROM generate_series(1, 10) g;
  v := finance.fn_app_payment_rows(jsonb_build_object('rows', v_rows));
  IF jsonb_array_length(v) <> 8 OR v->7->'label' <> core.fn_ui_tpl('finance.app.accounts.d_more', jsonb_build_object('n', core.fn_ui_num(3)))
     OR v->7->'value' <> core.fn_ui_money(-270, 'EUR') OR v->6->>'label' <> 'Zahlung 7' THEN
    RAISE EXCEPTION 'FAIL [7] Deckel 7 + Rest (-80-90-100 = -270), got %', v; END IF;
  -- genau 8 Gruppen bleiben vollstaendig
  v := finance.fn_app_payment_rows(jsonb_build_object('rows', (SELECT jsonb_agg(e) FROM jsonb_array_elements(v_rows) WITH ORDINALITY x(e, o) WHERE o <= 8)));
  IF jsonb_array_length(v) <> 8 OR v->7->>'label' <> 'Zahlung 8' THEN RAISE EXCEPTION 'FAIL [7b] 8 Gruppen ungekuerzt, got %', v; END IF;
  RAISE NOTICE 'PASS [7] Deckel bei mehr als 8 Zahlungen';
END $$;
ROLLBACK;
