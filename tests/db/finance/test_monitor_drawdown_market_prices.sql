-- tests/db/finance/test_monitor_drawdown_market_prices.sql
-- Crash-Waechter auf einen gespeicherten Kurs (sql auf finance.market_prices), Weg wie im Tool agent.tool_create_monitor_trigger:
-- Probe (fn_monitor_probe) -> Probelauf vor der Karte (core.fn_dry_run) -> Write. Der Hoechststand ist das Maximum der
-- gespeicherten Kurse, nicht der heutige Kurs; Karte und Zeile tragen denselben Wert. Symbol und Kurse sind erfunden.
BEGIN;

DO $$
DECLARE
  c_sql  CONSTANT text := 'SELECT price FROM finance.market_prices WHERE symbol = ''ZZDDT1'' ORDER BY as_of DESC LIMIT 1';
  c_hist CONSTANT text := 'SELECT as_of, price FROM finance.market_prices WHERE symbol = ''ZZDDT1''';
  v_probe jsonb; v_args jsonb; v_dry jsonb; v jsonb; v_ref numeric; v_card numeric;
BEGIN
  INSERT INTO finance.market_prices (symbol, price, currency, as_of, source) VALUES
    ('ZZDDT1', 21.80, 'EUR', core.fn_today() - 41, 'test'),
    ('ZZDDT1', 23.47, 'EUR', core.fn_today() - 34, 'test'),
    ('ZZDDT1', 22.15, 'EUR', core.fn_today() - 9, 'test'),
    ('ZZDDT1', 20.95, 'EUR', core.fn_today(), 'test');

  v_probe := agent.fn_monitor_probe(jsonb_build_object('acquisition_method', 'sql', 'acquisition_sql', c_sql));
  IF (v_probe->>'ok')::boolean IS DISTINCT FROM true OR (v_probe->>'value')::numeric IS DISTINCT FROM 20.95 THEN
    RAISE EXCEPTION 'FAIL dd market [Probe]: got %', v_probe;
  END IF;

  v_args := jsonb_build_object('domain', '__t_ddmp__', 'package', 'finance', 'label', 'Beispiel-ETF 20 Prozent unter Hoechststand',
    'trigger_type', 'drawdown', 'acquisition_method', 'sql', 'acquisition_sql', c_sql, 'history_sql', c_hist,
    'drawdown_pct', '20', 'expected_unit', 'EUR', 'check_interval', '1 day', 'probe_observation', v_probe);

  v_dry := core.fn_dry_run('agent.fn_create_monitor_trigger(jsonb)'::regprocedure, v_args);
  SELECT (l#>>'{params,value,value}')::numeric INTO v_card
    FROM jsonb_array_elements(v_dry->'card_lines') l WHERE l->>'label' = 'core.label.peak';
  IF v_card IS DISTINCT FROM 23.47 THEN
    RAISE EXCEPTION 'FAIL dd market [Karte]: Hoechststand auf der Karte % (erwartet 23.47): %', v_card, v_dry;
  END IF;

  v := agent.fn_create_monitor_trigger(v_args);
  SELECT reference_value INTO v_ref FROM agent.monitor_triggers WHERE id = (v->>'trigger_id')::int;
  IF v_ref IS DISTINCT FROM 23.47 THEN
    RAISE EXCEPTION 'FAIL dd market [Write]: gespeicherter Hoechststand % (erwartet 23.47, heutiger Kurs 20.95 ist falsch)', v_ref;
  END IF;
  IF v_ref IS DISTINCT FROM v_card THEN
    RAISE EXCEPTION 'FAIL dd market: Karte % und Zeile % weichen ab', v_card, v_ref;
  END IF;
  RAISE NOTICE 'PASS dd market [Hoechststand aus den gespeicherten Kursen, Karte = Zeile]';
END $$;

ROLLBACK;
