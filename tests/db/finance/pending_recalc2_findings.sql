-- tests/db/finance/pending_recalc2_findings.sql
-- PENDING: Abweichungen der Zweitrechnung Runde 2 (finance), bewusst ROT und ausserhalb des Gates (db_test sammelt nur
-- test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_recalc2_*'
-- Jeder Fall nennt die unabhaengige Erwartung; die fn bleibt unveraendert (fn-Dateien gehoerten in dieser Nacht der
-- Mutations-Session), bis der Owner entschieden bzw. jemand den Fix gebaut hat. Nach dem Fix den Fall in die passende
-- test_recalc2_*.sql verschieben (dann gruen und im Gate).
-- (F2) Anzeige: Puffer-Hinweis knapp unter der Grenze nennt den Zielwert als Ist-Wert (Text widerspricht sich).
--      fn_advisor_review rundet den Anteil "frei / Einnahmen" kaufmaennisch auf eine Stelle: Einnahmen 3.000, frei 299,99
--      -> 9,9997 % -> "nur 299,99 EUR frei (10,0 % der Einnahmen, Ziel 10 %)". Der Hinweis feuert zu Recht (299,99 < 300),
--      der Satz liest sich aber wie "Ziel erreicht". Betroffen: frei zwischen 9,95 % und 10 % der Einnahmen.
--      Erwartung: unter dem Ziel nie >= Ziel anzeigen -> abrunden auf eine Stelle: 9,9.
--      Fix-Vorschlag: 'pct' = trunc(v_free / income * 100, 1) im Zweig cashflow_buffer (Zeile mit fn_ui_num(... , 1)).
--      Nebenbefund gleiche Stelle: 'target' wird ohne Nachkommastelle gezeigt (Config 0,125 -> "Ziel 13 %").
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.account_balances SET balance = 0;
DO $$
DECLARE
  v_giro int; r jsonb; a jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f2_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__r2f2_gehalt__', v_giro, 3000, 'month', current_date, current_date),
    ('__r2f2_miete__', v_giro, -2700.01, 'month', current_date, current_date);
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage';
  IF (a->'msg'->0->'params'->'pct'->>'value')::numeric IS DISTINCT FROM 9.9 THEN
    RAISE EXCEPTION 'FAIL [F2] Puffer-Anteil unter dem Ziel: erwartet 9.9 (abgerundet), got % (Ziel %)',
      a->'msg'->0->'params'->'pct'->>'value', a->'msg'->0->'params'->'target'->>'value'; END IF;
END $$;
ROLLBACK;
