-- tests/db/finance/test_fn_app_payment_rows.sql
-- finance.fn_app_payment_rows(p) — Zahlungs-Vorkommen der Mini-App gruppieren (Mini-App UX 2026-10-30):
--   gleiche Zahlung (key) + gleicher Betrag -> eine Zeile (n x, erstes - letztes, Summe, Termine im Aufklappen);
--   ein Vorkommen bleibt einzeln; abweichender Betrag (Schlussrate) = eigene Zeile; Eingaenge mit Vorzeichen;
--   details-Modus fuer Aufklapp-Listen (nicht verschachtelbar). Erfundene Werte.
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
    jsonb_build_object('key', '9:out', 'date', d1, 'amount', -200, 'cur', 'EUR', 'label', 'Kredit', 'to', 'Darlehen'),
    jsonb_build_object('key', '9:out', 'date', d3, 'amount', -80, 'cur', 'EUR', 'label', 'Kredit', 'to', 'Darlehen'));

  v := finance.fn_app_payment_rows(jsonb_build_object('mode', 'items', 'rows', v_rows));
  IF jsonb_array_length(v) <> 4 THEN RAISE EXCEPTION 'FAIL [1] 4 Zeilen (3x ETF gruppiert, Kredit + Schlussrate getrennt), got %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object(
            'label', 'Welt ETF',
            'sub', core.fn_ui_tpl('finance.app.payments.rows_n', jsonb_build_object('n', core.fn_ui_num(3),
                       'first', core.fn_ui_date(d1), 'last', core.fn_ui_date(d3), 'to', NULL)),
            'value', core.fn_ui_money(-150, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [2] ETF 3x, Summe -150, got %', v; END IF;
  IF (SELECT jsonb_array_length(i->'details') FROM jsonb_array_elements(v) i WHERE i->>'label' = 'Welt ETF') <> 3 THEN
    RAISE EXCEPTION 'FAIL [3] Termine im Aufklappen'; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('label', 'Taschengeld', 'value', core.fn_ui_money(30, 'EUR', true),
            'sub', core.fn_ui_tpl('finance.app.payments.due_on', jsonb_build_object('date', core.fn_ui_date(d2)))))) THEN
    RAISE EXCEPTION 'FAIL [4] Eingang einzeln mit Vorzeichen, got %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('label', 'Kredit', 'value', core.fn_ui_money(-80, 'EUR'),
            'sub', core.fn_ui_tpl('finance.app.payments.due_on_to', jsonb_build_object('date', core.fn_ui_date(d3), 'to', 'Darlehen'))))) THEN
    RAISE EXCEPTION 'FAIL [5] Schlussrate eigene Zeile mit Ziel, got %', v; END IF;
  IF v->0->>'label' NOT IN ('Kredit', 'Welt ETF') OR v->-1->>'label' <> 'Kredit' THEN
    RAISE EXCEPTION 'FAIL [6] Reihenfolge erstes Datum, got %', v; END IF;

  v := finance.fn_app_payment_rows(jsonb_build_object('mode', 'details', 'rows', v_rows));
  IF NOT (v @> jsonb_build_array(jsonb_build_object('label', 'Welt ETF',
            'value', core.fn_ui_tpl('finance.app.payments.d_payment_n', jsonb_build_object('n', core.fn_ui_num(3),
                         'amount', core.fn_ui_money(-50, 'EUR'), 'first', core.fn_ui_date(d1), 'last', core.fn_ui_date(d3)))))) THEN
    RAISE EXCEPTION 'FAIL [7] details: 3x -50 erstes-letztes, got %', v; END IF;
  IF NOT (v @> jsonb_build_array(jsonb_build_object('label', 'Taschengeld',
            'value', core.fn_ui_tpl('finance.app.payments.d_payment', jsonb_build_object(
                         'date', core.fn_ui_date(d2), 'amount', core.fn_ui_money(30, 'EUR', true)))))) THEN
    RAISE EXCEPTION 'FAIL [8] details: Einzelzeile wie bisher, got %', v; END IF;
  IF finance.fn_app_payment_rows('{"mode":"items","rows":[]}') <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [9] leer'; END IF;
  RAISE NOTICE 'PASS [1-9] Gruppierung, Schlussrate getrennt, Vorzeichen, details-Modus';
END $$;
ROLLBACK;
