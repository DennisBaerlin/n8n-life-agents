-- tests/db/finance/test_fn_account_outlook.sql
-- Monats-Check WP-E: Deckungs-Vorschau je Konto + Berater-Warnungen.
--   fn_account_outlook: Start = bestaetigter Stand, geplante Zahlungen ab dem Tag danach, Alltagsausgaben je Tag aus den
--     letzten Auszuegen (unmatched_out / Tage), Horizont = naechster Geldeingang auf DIESES Konto; tiefster Stand + Tag,
--     Puffer, Fehlbetrag und Vorschlag (Umbuchung von einem anderen Konto, auf 50 aufgerundet, 2 Tage vor dem Tief).
--   fn_advisor_review: account_coverage:<konto> bei Unterschreitung; recurring_missing:<kette> nach zwei uebersprungenen
--     Terminen in Folge.
BEGIN;

DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_tg INT; v_rp INT; v_handy INT; v_res JSONB; v_alerts JSONB;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__t_ol_giro__","account_type":"cash","currency":"EUR","account_number":"DE36520513735120710166"}'::jsonb)->>'account_id')::int;
  v_tg   := (finance.fn_create_account('{"name":"__t_ol_tg__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 1000, t - 40, 'other'),
                                                                                         (v_tg, 5000, t - 40, 'other');
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_giro, 'confirmed_balance', 1000, 'reconciliation_date', (t - 5)::text));
  -- zwei Auszuege je 30 Tage: 300 Alltagsausgaben -> 10 je Tag. Der juengere ueberlappt 10 bestaetigte Tage
  -- (prev_last_reconciled_at = t-25): nur 20 neue Tage, 200 Alltag -> ebenfalls 10 je Tag (Nenner = neue Tage).
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_giro, t - 64, t - 35, 1600, 1300, 'EUR', 5, 0, -300, 0, NULL),
         (v_giro, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -200, 0, t - 25);
  v_rp := finance.fn_add_recurring_payment(v_giro, -800, 'Miete', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 3, t + 3, NULL, NULL, NULL);
  v_rp := finance.fn_add_recurring_payment(v_giro, 2000, 'Gehalt', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 10, t + 10, NULL, NULL, NULL);

  v_res := finance.fn_account_outlook(v_giro);
  IF (v_res->>'next_income_date')::date IS DISTINCT FROM t + 10 OR (v_res->>'everyday_per_day')::numeric IS DISTINCT FROM -10
     OR (v_res->>'estimated_today')::numeric IS DISTINCT FROM 950
     OR (v_res->>'min_projected')::numeric IS DISTINCT FROM 60 OR (v_res->>'min_date')::date IS DISTINCT FROM t + 9
     OR (v_res->>'buffer')::numeric IS DISTINCT FROM 250 OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 190 THEN
    RAISE EXCEPTION 'FAIL outlook Werte: %', v_res; END IF;
  IF (v_res->'suggestion'->>'amount')::numeric IS DISTINCT FROM 200 OR (v_res->'suggestion'->>'by_date')::date IS DISTINCT FROM t + 7
     OR v_res->'suggestion'->>'from_account' IS DISTINCT FROM '__t_ol_tg__' THEN
    RAISE EXCEPTION 'FAIL outlook Vorschlag: %', v_res->'suggestion'; END IF;
  RAISE NOTICE 'PASS outlook: heute ~950, Tief 60 am Tag vor dem Gehalt, 190 unter Puffer -> 200 vom Tagesgeld bis t+7';

  -- zwei Termine in Folge uebersprungen (nach einer Buchung) -> recurring_missing
  v_handy := finance.fn_add_recurring_payment(v_giro, -25, 'Handyvertrag', 1::smallint, 'month'::finance.schedule_unit, NULL,
               (t - interval '3 months')::date, (t - interval '3 months')::date, NULL, NULL, NULL);
  PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_handy,
            'due_date', (t - interval '3 months')::date, 'transaction_date', (t - interval '3 months')::date));
  INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date)
  VALUES (v_handy, (t - interval '2 months')::date), (v_handy, (t - interval '1 month')::date);

  -- nur Skips aus einem Saldo-Abgleich per Chat (kein Auszug hat sie festgestellt) -> KEINE Warnung
  v_alerts := finance.fn_advisor_review('finance')->'alerts';
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'recurring_missing:' || v_handy) THEN
    RAISE EXCEPTION 'FAIL advisor recurring_missing aus Chat-Abgleich-Skips: %', v_alerts; END IF;

  -- dieselben Skips von den Auszuegen festgestellt -> Warnung
  UPDATE finance.bank_statements SET skipped = jsonb_build_array(jsonb_build_object('recurring_payment_id', v_handy,
           'due_date', CASE WHEN period_end = t - 35 THEN (t - interval '2 months')::date ELSE (t - interval '1 month')::date END))
  WHERE account_id = v_giro;

  v_alerts := finance.fn_advisor_review('finance')->'alerts';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'account_coverage:' || v_giro) THEN
    RAISE EXCEPTION 'FAIL advisor account_coverage fehlt: %', v_alerts; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'account_coverage:' || v_tg) THEN
    RAISE EXCEPTION 'FAIL advisor: Konto ohne Auszug darf nicht gewarnt werden'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'recurring_missing:' || v_handy) THEN
    RAISE EXCEPTION 'FAIL advisor recurring_missing fehlt: %', v_alerts; END IF;
  RAISE NOTICE 'PASS advisor: account_coverage nur fuer Auszug-Konto, recurring_missing nur nach 2 vom Auszug festgestellten Skips';
END $$;

-- Rundungs-Paket 2026-10-23: Puffer (250 EUR) in Kontowaehrung ungerundet umgerechnet. Vorher: fn_to_eur(1, 'KRW') =
-- round(1/1450, 2) = 0.00 -> Puffer blieb still 250 KRW; JPY (160) -> 0.01 -> 25000 statt 40000 JPY.
DO $$
DECLARE v_krw INT; v_jpy INT; v_res JSONB;
BEGIN
  PERFORM finance.fn_ensure_currency('KRW'); PERFORM finance.fn_ensure_currency('JPY');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR','KRW', 1450, CURRENT_DATE - 1),
                                                                                    ('EUR','JPY', 160, CURRENT_DATE - 1)
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
  v_krw := (finance.fn_create_account('{"name":"__t_ol_krw__","account_type":"cash","currency":"KRW","opening_balance":1000000}'::jsonb)->>'account_id')::int;
  v_jpy := (finance.fn_create_account('{"name":"__t_ol_jpy__","account_type":"cash","currency":"JPY","opening_balance":100000}'::jsonb)->>'account_id')::int;
  v_res := finance.fn_account_outlook(v_krw);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 362500 THEN RAISE EXCEPTION 'FAIL outlook KRW-Puffer: %', v_res; END IF;
  v_res := finance.fn_account_outlook(v_jpy);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 40000 THEN RAISE EXCEPTION 'FAIL outlook JPY-Puffer: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook Puffer in Fremdwaehrung: 362500 KRW / 40000 JPY';
END $$;

-- Ueberbrueckung 2026-10-28 (Dauerauftrags-Fluesse kommen aus finance.fn_upcoming_payments): Randfaelle, die VOR dem
-- Umbau so gerechnet wurden und danach identisch bleiben muessen.
--   * offenes Vorkommen zwischen bestaetigtem Stand und heute (d0 < heute) zaehlt in den Stand heute
--   * Uebertrag AUF das Konto mit POSITIVEM Betrag in der Zeile (kein CHECK erzwingt das Minus) -> Ziel-Seite +abs()
--   * Uebertrag VOM Konto -> Quell-Seite mit Vorzeichen; der Uebertrag aufs Konto ist zugleich der Horizont (Einnahme)
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_b INT; v_res JSONB;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_ol_edge_a__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__t_ol_edge_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 1000, t - 40, 'other'),
                                                                                         (v_b, 100, t - 40, 'other');
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1000, 'reconciliation_date', (t - 5)::text));
  PERFORM finance.fn_add_recurring_payment(v_a, -100, 'Edge Abo', 30::smallint, 'day'::finance.schedule_unit, NULL, t - 2, t - 2, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('Edge rein positiv', v_b, v_a, 50, 30, 'day', t + 1, t + 1),
         ('Edge raus', v_a, v_b, -30, 30, 'day', t, t);

  v_res := finance.fn_account_outlook(v_a);
  -- Stand: 1000 bis t-3, t-2 -100, t -30 = 870 (heute = Tief), t+1 +50 (Horizont = naechster Eingang)
  IF (v_res->>'estimated_today')::numeric IS DISTINCT FROM 870 OR (v_res->>'min_projected')::numeric IS DISTINCT FROM 870
     OR (v_res->>'min_date')::date IS DISTINCT FROM t OR (v_res->>'horizon_end')::date IS DISTINCT FROM t + 1
     OR (v_res->>'next_income_name') IS DISTINCT FROM 'Edge rein positiv'
     OR (v_res->>'planned_out')::numeric IS DISTINCT FROM -130 OR (v_res->>'planned_in')::numeric IS DISTINCT FROM 50
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 0 OR jsonb_typeof(v_res->'suggestion') <> 'null' THEN
    RAISE EXCEPTION 'FAIL outlook Randfaelle: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook Randfaelle: Vorkommen vor heute, positiver Uebertrag aufs Konto, Uebertrag vom Konto';
END $$;

-- Rechenkern-Umbau 2026-10-29 (fn_account_projection, geteilt mit fn_account_funding):
--   * Ein- und Ausgang am SELBEN Tag zaehlen getrennt in planned_in / planned_out (nicht je Tag verrechnet)
--   * Bugfix: Ziel-Seite eines Uebertrags aus einer anderen Waehrung in ZIELwaehrung (vorher Quellbetrag roh)
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_usd INT; v_res JSONB;
BEGIN
  PERFORM finance.fn_ensure_currency('USD');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'USD', 1.10, t - 1)
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
  v_a   := (finance.fn_create_account('{"name":"__t_ol_same__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_usd := (finance.fn_create_account('{"name":"__t_ol_usd__","account_type":"cash","currency":"USD"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 1000, t - 40, 'other');
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('Same rein', v_a, NULL,   200, 30, 'day', t + 3, t + 3),
         ('Same raus', v_a, NULL,   -80, 30, 'day', t + 3, t + 3),
         ('Same usd',  v_a, v_usd, -100, 30, 'day', t + 1, t + 1);

  v_res := finance.fn_account_outlook(v_a);
  IF (v_res->>'planned_in')::numeric IS DISTINCT FROM 200 OR (v_res->>'planned_out')::numeric IS DISTINCT FROM -180
     OR (v_res->>'horizon_end')::date IS DISTINCT FROM t + 3 OR (v_res->>'min_projected')::numeric IS DISTINCT FROM 900 THEN
    RAISE EXCEPTION 'FAIL outlook selber Tag: %', v_res; END IF;
  v_res := finance.fn_account_outlook(v_usd);
  IF (v_res->>'planned_in')::numeric IS DISTINCT FROM 110.00 OR (v_res->>'horizon_end')::date IS DISTINCT FROM t + 1 THEN
    RAISE EXCEPTION 'FAIL outlook Uebertrag in Zielwaehrung: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook: Zu-/Abgang am selben Tag getrennt, Uebertrag EUR -> USD als 110 USD';
END $$;

ROLLBACK;
