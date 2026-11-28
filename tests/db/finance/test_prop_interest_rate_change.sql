-- tests/db/finance/test_prop_interest_rate_change.sql
-- Eigenschafts-Test: Zins-Konditionen eines Kontos aendern (fn_set_account_interest) gegen die Zins-Vorschau
-- (fn_interest_due_open, fn_interest_amount_due) und die Buchung.
--   I1 ein "Wechsel" auf denselben Satz mit derselben Kadenz mitten im Zeitraum aendert weder die offenen Perioden noch
--      ihre Betraege (Summe der Teile = Ganzes)
--   I2 ein hoeherer Satz ab einem Stichtag aendert keine Periode, die vor dem Stichtag endet, und senkt keine andere
--   I3 Karte = Buchung: jede offene Periode wird mit dem unmittelbar vorher genannten Betrag gebucht, danach ist sie
--      nicht mehr offen, und der Saldo steigt um genau die gebuchten Zinsen
-- Daten relativ zu heute (der Scheduler liest "bis heute"); Saetze, Kadenzen und Stichtage in Schleifen.
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_sav INT; r RECORD; o RECORD; v_cut INT; v_n INT := 0;
  v_sig0 TEXT; v_sig1 TEXT; v_due NUMERIC; v_bal0 NUMERIC; v_sum NUMERIC; v_cnt INT;
BEGIN
  FOR r IN SELECT * FROM (VALUES (3.00, 1, -1), (1.25, 1, 15), (2.40, 3, -1)) x(rate, intv, dom) LOOP
    FOREACH v_cut IN ARRAY ARRAY[20, 50, 85] LOOP
      BEGIN
        SELECT (finance.fn_create_account('{"name":"__prop_irc_tg__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_sav;
        INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_sav, 10000, v_t - 260, 'other');
        v_res := finance.fn_set_account_interest(jsonb_build_object('account_id',v_sav,'annual_rate',r.rate,'schedule_unit','month',
                   'schedule_interval',r.intv,'schedule_day_of_month',r.dom,'valid_from',v_t - 200));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL I setup %: %', r, v_res; END IF;
        SELECT string_agg(d.period_start || '..' || d.period_end || '=' || finance.fn_interest_amount_due(v_sav, d.period_end), '|' ORDER BY d.period_end)
          INTO v_sig0 FROM finance.fn_interest_due_open(v_t) d WHERE d.account_id = v_sav;
        IF v_sig0 IS NULL THEN RAISE EXCEPTION 'FAIL I setup %: keine offene Zins-Periode in 200 Tagen', r; END IF;
        -- I1
        v_res := finance.fn_set_account_interest(jsonb_build_object('account_id',v_sav,'annual_rate',r.rate,'schedule_unit','month',
                   'schedule_interval',r.intv,'schedule_day_of_month',r.dom,'valid_from',v_t - v_cut));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL I1 % stichtag -%: %', r, v_cut, v_res; END IF;
        SELECT string_agg(d.period_start || '..' || d.period_end || '=' || finance.fn_interest_amount_due(v_sav, d.period_end), '|' ORDER BY d.period_end)
          INTO v_sig1 FROM finance.fn_interest_due_open(v_t) d WHERE d.account_id = v_sav;
        IF v_sig1 IS DISTINCT FROM v_sig0 THEN
          RAISE EXCEPTION 'FAIL I1 % stichtag -%: gleicher Satz aendert die Vorschau: [%] -> [%]', r, v_cut, v_sig0, v_sig1; END IF;
        -- I2
        v_res := finance.fn_set_account_interest(jsonb_build_object('account_id',v_sav,'annual_rate',r.rate + 2,'schedule_unit','month',
                   'schedule_interval',r.intv,'schedule_day_of_month',r.dom,'valid_from',v_t - v_cut + 1));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL I2 % stichtag -%: %', r, v_cut, v_res; END IF;
        IF EXISTS (SELECT 1 FROM finance.fn_interest_due_open(v_t) d
                   JOIN LATERAL (SELECT split_part(e, '=', 2)::numeric AS amt0 FROM unnest(string_to_array(v_sig0, '|')) e
                                  WHERE e LIKE d.period_start || '..' || d.period_end || '=%') b ON true
                   WHERE d.account_id = v_sav
                     AND ((d.period_end <= v_t - v_cut AND finance.fn_interest_amount_due(v_sav, d.period_end) IS DISTINCT FROM b.amt0)
                          OR finance.fn_interest_amount_due(v_sav, d.period_end) < b.amt0)) THEN
          RAISE EXCEPTION 'FAIL I2 % stichtag -%: hoeherer Satz aendert eine fruehere Periode oder senkt eine spaetere', r, v_cut; END IF;
        -- I3
        SELECT balance INTO v_bal0 FROM finance.account_balances WHERE account_id = v_sav;
        v_sum := 0; v_cnt := 0;
        FOR o IN SELECT d.period_end FROM finance.fn_interest_due_open(v_t) d WHERE d.account_id = v_sav ORDER BY d.period_end LOOP
          v_due := finance.fn_interest_amount_due(v_sav, o.period_end);
          v_res := finance.fn_book_interest_occurrence(jsonb_build_object('account_id',v_sav,'period_end',o.period_end));
          IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'amount')::numeric IS DISTINCT FROM v_due
             OR EXISTS (SELECT 1 FROM finance.fn_interest_due_open(v_t) d WHERE d.account_id = v_sav AND d.period_end = o.period_end) THEN
            RAISE EXCEPTION 'FAIL I3 % Periode bis %: genannt %, Buchung %', r, o.period_end, v_due, v_res; END IF;
          v_sum := v_sum + v_due; v_cnt := v_cnt + 1;
        END LOOP;
        IF (SELECT balance FROM finance.account_balances WHERE account_id = v_sav) IS DISTINCT FROM v_bal0 + v_sum
           OR EXISTS (SELECT 1 FROM finance.fn_interest_due_open(v_t) d WHERE d.account_id = v_sav) THEN
          RAISE EXCEPTION 'FAIL I3 %: Saldo % statt % nach % gebuchten Perioden, oder noch offene Perioden', r,
            (SELECT balance FROM finance.account_balances WHERE account_id = v_sav), v_bal0 + v_sum, v_cnt; END IF;
        v_n := v_n + 1;
        RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
      EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
      END;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'PASS prop interest rate change [% Kombinationen Satz x Kadenz x Stichtag, I1-I3]', v_n;
END $$;

ROLLBACK;
