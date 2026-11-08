-- tests/db/finance/test_holding_trigger_lock.sql
-- Bestands-Trigger update_holding_shares / update_holding_avg_price — Race Cron || Chat.
--   Ohne Sperre rechnet UPDATE ... SET shares = (SELECT SUM ...) mit dem Snapshot VOR dem Warten auf die Zeilensperre:
--   zwei parallele Buchungen auf dieselbe Position schreiben je eine Summe ohne die andere (Lost Update). Deshalb:
--   Holding-Zeile zuerst sperren (FOR UPDATE), DANN rechnen — Muster Saldo-Trigger (test_balance_trigger_lock.sql).
--   TESTGRENZE: keine zweite Verbindung im Framework -> struktureller Test (Sperre vor der Rechnung, in beiden Zweigen);
--   das funktionale Verhalten decken test_fn_book_stock_buy/_sell und test_holding_avg_precision ab.
BEGIN;

DO $$
DECLARE
  v_fn   TEXT;
  v_calc TEXT;
  v_def  TEXT;
  v_lock INT;
  v_pos  INT;
  v_rest TEXT;
BEGIN
  FOR v_fn, v_calc IN VALUES ('finance.update_holding_shares()', 'SUM(shares)'),
                              ('finance.update_holding_avg_price()', 'fn_holding_avg_cost(') LOOP
    v_def  := pg_get_functiondef(v_fn::regprocedure);
    v_lock := strpos(v_def, 'FOR UPDATE');
    v_pos  := strpos(v_def, v_calc);
    IF v_lock = 0 OR v_pos = 0 OR v_lock > v_pos THEN
      RAISE EXCEPTION 'FAIL holding-lock [% Sperre vor Rechnung]: FOR UPDATE an %, Rechnung an %', v_fn, v_lock, v_pos; END IF;
    v_rest := substr(v_def, v_pos + 1);
    IF strpos(v_rest, 'FOR UPDATE') = 0 OR strpos(v_rest, 'FOR UPDATE') > strpos(v_rest, v_calc) THEN
      RAISE EXCEPTION 'FAIL holding-lock [% OLD-Zweig]: keine Sperre vor der zweiten Rechnung', v_fn; END IF;
  END LOOP;
  RAISE NOTICE 'PASS holding-lock [shares + avg: Holding-Zeile wird in beiden Zweigen VOR dem Rechnen gesperrt]';
END $$;

ROLLBACK;
