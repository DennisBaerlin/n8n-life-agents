-- tests/db/finance/test_fn_account_outlook.sql
-- Deckungs-Vorschau je Konto + Berater-Warnungen.
--   fn_account_outlook: Start = bestaetigter Stand, geplante Zahlungen ab dem Tag danach, Alltagsausgaben je Tag aus den
--     letzten Auszuegen (unmatched_out / Tage), Horizont = naechster Geldeingang auf dieses Konto; tiefster Stand + Tag,
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

  -- nur Skips aus einem Saldo-Abgleich per Chat (kein Auszug hat sie festgestellt) -> keine Warnung
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
  -- die Warnung nennt die Alltags-Schaetzung je Tag und dass der Puffer der Standard ist
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'account_coverage:' || v_giro
                   AND a->'msg'->0->'params'->'per_day' = core.fn_ui_money(10, 'EUR')
                   AND a->'msg' @> jsonb_build_array(core.fn_ui_tpl('finance.advisor.account_coverage_default_buffer'))) THEN
    RAISE EXCEPTION 'FAIL advisor account_coverage nennt Alltag je Tag + Standard-Puffer: %', v_alerts; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'account_coverage:' || v_tg) THEN
    RAISE EXCEPTION 'FAIL advisor: Konto ohne Auszug darf nicht gewarnt werden'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'recurring_missing:' || v_handy) THEN
    RAISE EXCEPTION 'FAIL advisor recurring_missing fehlt: %', v_alerts; END IF;
  RAISE NOTICE 'PASS advisor: account_coverage nur fuer Auszug-Konto, recurring_missing nur nach 2 vom Auszug festgestellten Skips';

  -- ein neuer Dauerauftrag, der nie lief und zweimal fehlte -> derselbe Key, aber der Satz "wurde noch nie ausgefuehrt"
  -- (Institut beim Namen, sonst _generic); die Lastschrift behaelt recurring_missing
  v_rp := finance.fn_add_recurring_payment(v_giro, -150, 'Tagesgeld-Sparen', 1::smallint, 'month'::finance.schedule_unit, NULL,
            (t - interval '2 months')::date, (t - interval '2 months')::date, NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_tg WHERE id = v_rp;
  INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date)
  VALUES (v_rp, (t - interval '2 months')::date), (v_rp, (t - interval '1 month')::date);
  UPDATE finance.bank_statements SET skipped = skipped || jsonb_build_array(jsonb_build_object('recurring_payment_id', v_rp,
           'due_date', CASE WHEN period_end = t - 35 THEN (t - interval '2 months')::date ELSE (t - interval '1 month')::date END))
  WHERE account_id = v_giro;
  v_alerts := finance.fn_advisor_review('finance')->'alerts';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'recurring_missing:' || v_rp
                   AND a->'msg'->0->>'value' = 'finance.advisor.recurring_never_started_standing_order_generic'
                   AND a->'msg'->0->'params'->>'name' = 'Tagesgeld-Sparen') THEN
    RAISE EXCEPTION 'FAIL advisor never_started (generic): %', v_alerts; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'recurring_missing:' || v_handy
                   AND a->'msg'->0->>'value' = 'finance.advisor.recurring_missing') THEN
    RAISE EXCEPTION 'FAIL advisor Lastschrift behaelt recurring_missing: %', v_alerts; END IF;
  UPDATE finance.accounts SET bank = 'Lindenbank' WHERE id = v_giro;
  v_alerts := finance.fn_advisor_review('finance')->'alerts';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'recurring_missing:' || v_rp
                   AND a->'msg'->0->>'value' = 'finance.advisor.recurring_never_started_standing_order'
                   AND a->'msg'->0->'params'->>'bank' = 'Lindenbank') THEN
    RAISE EXCEPTION 'FAIL advisor never_started mit Bank: %', v_alerts; END IF;
  RAISE NOTICE 'PASS advisor: nie gelaufener Dauerauftrag -> never_started mit Bank/_generic, Lastschrift recurring_missing';
END $$;

-- Puffer (250 EUR) wird in Kontowaehrung ungerundet umgerechnet; ueber fn_to_eur(1, 'CLP') =
-- round(1/1450, 2) = 0.00 bliebe der Puffer still 250 CLP; JPY (160) -> 0.01 -> 25000 statt 40000 JPY.
DO $$
DECLARE v_clp INT; v_jpy INT; v_res JSONB;
BEGIN
  PERFORM finance.fn_ensure_currency('CLP'); PERFORM finance.fn_ensure_currency('JPY');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR','CLP', 1450, CURRENT_DATE - 1),
                                                                                    ('EUR','JPY', 160, CURRENT_DATE - 1)
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
  v_clp := (finance.fn_create_account('{"name":"__t_ol_clp__","account_type":"cash","currency":"CLP","opening_balance":1000000}'::jsonb)->>'account_id')::int;
  v_jpy := (finance.fn_create_account('{"name":"__t_ol_jpy__","account_type":"cash","currency":"JPY","opening_balance":100000}'::jsonb)->>'account_id')::int;
  -- ein Abgang weit hinter dem Horizont: ohne ihn waere der Puffer 0 (buffer_source none) und die Umrechnung ungeprueft
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from)
  VALUES ('CLP Abo', v_clp, -1000, 1, 'year', CURRENT_DATE + 60, CURRENT_DATE + 60),
         ('JPY Abo', v_jpy, -1000, 1, 'year', CURRENT_DATE + 60, CURRENT_DATE + 60);
  v_res := finance.fn_account_outlook(v_clp);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 362500 THEN RAISE EXCEPTION 'FAIL outlook CLP-Puffer: %', v_res; END IF;
  v_res := finance.fn_account_outlook(v_jpy);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 40000 THEN RAISE EXCEPTION 'FAIL outlook JPY-Puffer: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook Puffer in Fremdwaehrung: 362500 CLP / 40000 JPY';
END $$;

-- Randfaelle der Dauerauftrags-Fluesse (kommen aus finance.fn_upcoming_payments):
--   * offenes Vorkommen zwischen bestaetigtem Stand und heute (d0 < heute) zaehlt in den Stand heute
--   * Uebertrag auf das Konto mit positivem Betrag in der Zeile (kein CHECK erzwingt das Minus) -> Ziel-Seite +abs()
--   * Uebertrag vom Konto -> Quell-Seite mit Vorzeichen; der Uebertrag aufs Konto ist zugleich der Horizont (Einnahme)
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

-- Rechenkern (fn_account_projection, geteilt mit fn_account_funding):
--   * Ein- und Ausgang am selben Tag zaehlen getrennt in planned_in / planned_out (nicht je Tag verrechnet)
--   * Ziel-Seite eines Uebertrags aus einer anderen Waehrung in Zielwaehrung (nicht der Quellbetrag roh)
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

-- Der Umbuchungs-Vorschlag nennt nie ein Kinderkonto als Quelle, auch
-- wenn es den groessten freien Saldo hat (der Vorschlag geht ohne LLM in die Karte/den Alert). Werte erfunden.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_kid INT; v_adult INT; v_res JSONB;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__t_ol_kid__', 'Kind Beispiel', 'child')
    ON CONFLICT (person_id) DO UPDATE SET role = 'child';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ol_short__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id) VALUES ('__t_ol_kid__', 'cash', 'EUR', 'active', '__t_ol_kid__') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ol_adult__', 'cash', 'EUR', 'active') RETURNING id INTO v_adult;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 100, t - 40, 'other'), (v_kid, 900000, t - 40, 'other'), (v_adult, 800000, t - 40, 'other');
  -- Abgang hinter dem Horizont (t+31): Standard-Puffer 250 bleibt, der tiefste Stand bleibt 100
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from)
  VALUES ('Short Abo', v_giro, -10, 1, 'year', t + 60, t + 60);

  v_res := finance.fn_account_outlook(v_giro);
  IF (v_res->>'shortfall')::numeric IS DISTINCT FROM 150 OR v_res->'suggestion'->>'from_account' IS DISTINCT FROM '__t_ol_adult__' THEN
    RAISE EXCEPTION 'FAIL outlook Vorschlag ohne Kinderkonto: %', v_res; END IF;

  UPDATE finance.accounts SET status = 'closed' WHERE id = v_adult;
  v_res := finance.fn_account_outlook(v_giro);
  IF v_res->'suggestion'->>'from_account' = '__t_ol_kid__' THEN
    RAISE EXCEPTION 'FAIL outlook: einziges Quellkonto ist ein Kinderkonto, trotzdem vorgeschlagen: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook: Umbuchungs-Vorschlag nie von einem Kinderkonto';
END $$;

-- Bruecke bis zum Tief summiert exakt auf min_projected (start = Saldo zum Vortag von d0, inkl.
-- einer rueckdatierten Buchung vor dem Abgleich -> Korrektur gegen den bestaetigten Stand), Puffer je Konto
-- (accounts.min_balance) vor dem Standard, buffer_source, provisional, naechster Geldeingang mit Betrag. Werte erfunden.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_res JSONB; v_b JSONB;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_ol_bridge__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 1000, t - 40, 'other');
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1000, 'reconciliation_date', (t - 5)::text));
  -- rueckdatiert (vor dem Abgleich, nachtraeglich erfasst) und eine Buchung nach dem Abgleich
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 30, t - 10, 'other'),
                                                                                         (v_a, -50, t - 2, 'other');
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_a, t - 64, t - 35, 1600, 1300, 'EUR', 5, 0, -900, 0, NULL),
         (v_a, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -300, 0, t - 35);
  PERFORM finance.fn_add_recurring_payment(v_a, -800, 'Miete', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 3, t + 3, NULL, NULL, NULL);
  PERFORM finance.fn_add_recurring_payment(v_a, 2000, 'Gehalt', 30::smallint, 'day'::finance.schedule_unit, NULL, t + 10, t + 10, NULL, NULL, NULL);

  v_res := finance.fn_account_outlook(v_a);
  v_b := v_res->'bridge';
  -- d0 = t-4; Basis 1030 (1000 + rueckdatierte 30); booked -50; Miete -800; Alltag 10/Tag x 14 Tage (t-4..t+9) = -140
  IF (v_b->>'base')::numeric IS DISTINCT FROM 1030 OR (v_b->>'confirmed')::numeric IS DISTINCT FROM 1000
     OR (v_b->>'booked')::numeric IS DISTINCT FROM -50 OR (v_b->>'out')::numeric IS DISTINCT FROM -800
     OR (v_b->>'in')::numeric IS DISTINCT FROM 0 OR (v_b->>'everyday')::numeric IS DISTINCT FROM -140
     OR (v_b->>'days')::int IS DISTINCT FROM 14 OR (v_b->>'from')::date IS DISTINCT FROM t - 4
     OR (v_res->>'min_projected')::numeric IS DISTINCT FROM 40 OR (v_res->>'min_date')::date IS DISTINCT FROM t + 9 THEN
    RAISE EXCEPTION 'FAIL [B1] Bruecke: %', v_res; END IF;
  IF (v_b->>'base')::numeric + (v_b->>'booked')::numeric + (v_b->>'out')::numeric + (v_b->>'in')::numeric
     + (v_b->>'everyday')::numeric <> (v_res->>'min_projected')::numeric THEN
    RAISE EXCEPTION 'FAIL [B2] Bruecke summiert nicht exakt auf das Tief: %', v_res; END IF;
  IF v_res->>'buffer_source' IS DISTINCT FROM 'default' OR (v_res->>'provisional')::boolean IS DISTINCT FROM false
     OR (v_res->>'next_income_amount')::numeric IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'FAIL [B3] buffer_source default / provisional false / Geldeingang 2000: %', v_res; END IF;

  -- eigener Puffer fuer dieses Konto: 30 statt 250 -> kein Fehlbetrag mehr
  UPDATE finance.accounts SET min_balance = 30 WHERE id = v_a;
  v_res := finance.fn_account_outlook(v_a);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 30 OR v_res->>'buffer_source' IS DISTINCT FROM 'account'
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [B4] Puffer je Konto: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook Bruecke: exakt bis zum Tief inkl. rueckdatierter Buchung; Puffer je Konto';
END $$;

-- Veralteter Kontoauszug: Alter > finance.statement_stale_days (Default 45) -> statt account_coverage der Hinweis
-- statement_stale:<konto> (die Vorschau zieht den Alltag ab dem Abgleich ohne Obergrenze ab -> sonst Fehlalarm je Woche).
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_old INT; v_new INT; v_res JSONB; v_alerts JSONB;
BEGIN
  v_old := (finance.fn_create_account('{"name":"__t_ol_alt__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_new := (finance.fn_create_account('{"name":"__t_ol_frisch__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_old, 500, t - 120, 'other'),
                                                                                         (v_new, 100, t - 120, 'other');
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_old, 'confirmed_balance', 500, 'reconciliation_date', (t - 60)::text));
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_new, 'confirmed_balance', 100, 'reconciliation_date', (t - 5)::text));
  -- je ein Auszug mit 10 Alltag je Tag: beide Konten unterschreiten den Puffer (alt: 500 - 60 x 10 - ..., frisch: 100)
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_old, t - 89, t - 60, 800, 500, 'EUR', 5, 0, -300, 0, NULL),
         (v_new, t - 34, t - 5, 400, 100, 'EUR', 5, 0, -300, 0, NULL);

  v_res := finance.fn_account_outlook(v_old);
  IF (v_res->>'statement_age_days')::int IS DISTINCT FROM 60 OR (v_res->>'shortfall')::numeric <= 0 THEN
    RAISE EXCEPTION 'FAIL outlook statement_age_days alt: erwartet 60 + Fehlbetrag, got %', v_res; END IF;
  IF (finance.fn_account_outlook(v_new)->>'statement_age_days')::int IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'FAIL outlook statement_age_days frisch: %', finance.fn_account_outlook(v_new); END IF;

  v_alerts := finance.fn_advisor_review('finance')->'alerts';
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'account_coverage:' || v_old) THEN
    RAISE EXCEPTION 'FAIL advisor: veralteter Auszug darf keine Deckungs-Warnung ausloesen: %', v_alerts; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a
                 WHERE a->>'metric_key' = 'statement_stale:' || v_old AND a->>'kind' = 'staleness'
                   AND (a->>'value')::numeric = 60 AND (a->>'target')::numeric = 45
                   AND a->'msg'->0->>'value' = 'finance.advisor.statement_stale'
                   AND a->'msg'->0->'params'->>'account' = '__t_ol_alt__') THEN
    RAISE EXCEPTION 'FAIL advisor statement_stale fehlt: %', v_alerts; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'account_coverage:' || v_new)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_alerts) a WHERE a->>'metric_key' = 'statement_stale:' || v_new) THEN
    RAISE EXCEPTION 'FAIL advisor: frischer Auszug warnt weiter mit account_coverage, ohne statement_stale: %', v_alerts; END IF;
  RAISE NOTICE 'PASS outlook/advisor: Auszug 60 Tage alt -> statement_stale statt account_coverage; frischer Auszug warnt normal';
END $$;

-- Puffer nur, wenn etwas abgeht: geplante Abbuchung (Dauerauftrag, Sparplan, Uebertrag weg) in 400 Tagen oder Alltag
-- aus Auszuegen. Sonst Puffer 0 (buffer_source none); ein Minus meldet weiter, ein eigener Puffer gilt weiter. Die
-- Abbuchung darf hinter dem Horizont liegen (Verrechnungskonto: Zubringer am Tag X, Sparplan am Tag X+1), sonst
-- spraenge der Puffer im Monat zwischen 0 und 250. N4/N5 haben keinen Auszug (Alltag unbekannt). Werte erfunden.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_zero INT; v_neg INT; v_own INT; v_src INT; v_vor INT; v_nach INT; v_alltag INT; v_res JSONB;
BEGIN
  v_zero := (finance.fn_create_account('{"name":"__t_ol_none_zero__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_neg  := (finance.fn_create_account('{"name":"__t_ol_none_neg__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_own  := (finance.fn_create_account('{"name":"__t_ol_none_own__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_src  := (finance.fn_create_account('{"name":"__t_ol_none_src__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_vor  := (finance.fn_create_account('{"name":"__t_ol_none_vor__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_nach := (finance.fn_create_account('{"name":"__t_ol_none_nach__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_alltag := (finance.fn_create_account('{"name":"__t_ol_none_alltag__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_neg, -40, t - 10, 'other'), (v_src, 5000, t - 40, 'other'), (v_alltag, 1000, t - 40, 'other');
  UPDATE finance.accounts SET min_balance = 20 WHERE id = v_own;

  v_res := finance.fn_account_outlook(v_zero);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 0 OR v_res->>'buffer_source' IS DISTINCT FROM 'none'
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 0 OR jsonb_typeof(v_res->'suggestion') <> 'null'
     OR (v_res->>'outflow_expected')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [N1] Saldo 0 ohne Abgang -> Puffer 0, none, kein Vorschlag: %', v_res; END IF;

  v_res := finance.fn_account_outlook(v_neg);
  IF v_res->>'buffer_source' IS DISTINCT FROM 'none' OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 40
     OR (v_res->'suggestion'->>'amount')::numeric IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'FAIL [N2] Minus ohne Abgang meldet weiter (shortfall 40, Vorschlag 50): %', v_res; END IF;

  v_res := finance.fn_account_outlook(v_own);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 20 OR v_res->>'buffer_source' IS DISTINCT FROM 'account'
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'FAIL [N3] eigener Puffer gilt auch ohne Abgang: %', v_res; END IF;

  -- Verrechnungskonto: Zubringer vom Girokonto, Sparplan-Abbuchung vor bzw. nach dem Zubringer
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('None Zubringer vor',  v_src, v_vor,  -100, 30, 'day', t + 5, t + 5),
         ('None Sparplan vor',   v_vor, NULL,   -100, 30, 'day', t + 3, t + 3),
         ('None Zubringer nach', v_src, v_nach, -100, 30, 'day', t + 2, t + 2),
         ('None Sparplan nach',  v_nach, NULL,  -100, 30, 'day', t + 3, t + 3);
  v_res := finance.fn_account_outlook(v_vor);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 250 OR v_res->>'buffer_source' IS DISTINCT FROM 'default'
     OR (v_res->>'outflow_expected')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [N4] Sparplan vor dem Zubringer -> Standard-Puffer: %', v_res; END IF;
  v_res := finance.fn_account_outlook(v_nach);
  IF (v_res->>'horizon_end')::date IS DISTINCT FROM t + 2 OR (v_res->>'planned_out')::numeric IS DISTINCT FROM 0
     OR (v_res->>'buffer')::numeric IS DISTINCT FROM 250 OR v_res->>'buffer_source' IS DISTINCT FROM 'default'
     OR (v_res->>'outflow_expected')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [N5] Sparplan hinter dem Horizont -> Standard-Puffer, kein Springen: %', v_res; END IF;
  -- die Zubringer-Quelle selbst hat einen Abgang (Uebertrag weg)
  IF finance.fn_account_outlook(v_src)->>'buffer_source' IS DISTINCT FROM 'default' THEN
    RAISE EXCEPTION 'FAIL [N6] Uebertrag weg zaehlt als Abgang: %', finance.fn_account_outlook(v_src); END IF;

  -- nur Alltag aus einem Auszug, kein Dauerauftrag
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', v_alltag, 'confirmed_balance', 1000, 'reconciliation_date', (t - 5)::text));
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_alltag, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -300, 0, NULL);
  v_res := finance.fn_account_outlook(v_alltag);
  IF (v_res->>'everyday_per_day')::numeric >= 0 OR v_res->>'buffer_source' IS DISTINCT FROM 'default'
     OR (v_res->>'outflow_expected')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [N7] Alltag aus dem Auszug zaehlt als Abgang: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook Puffer nur mit Abgang: 0 ohne (Minus meldet, eigener Puffer gilt), Sparplan vor/nach Horizont, Alltag';
END $$;

-- Alltag bekannt 0 (Auszug ohne freie Abgaenge): kein Standard-Puffer, auch wenn ein Sparplan abgeht; der Puffer
-- faengt nur die Schaetzung des Alltags ab. Alltag unbekannt (kein Auszug, N4/N5) behaelt den Standard; ein eigener
-- Puffer gilt; ein Tief unter 0 meldet weiter. Werte erfunden.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_plan INT; v_own INT; v_neg INT; v_res JSONB;
BEGIN
  v_plan := (finance.fn_create_account('{"name":"__t_ol_k0_plan__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_own  := (finance.fn_create_account('{"name":"__t_ol_k0_own__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_neg  := (finance.fn_create_account('{"name":"__t_ol_k0_neg__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_plan, 100, t - 40, 'other'), (v_own, 100, t - 40, 'other'), (v_neg, 30, t - 40, 'other');
  UPDATE finance.accounts SET min_balance = 80 WHERE id = v_own;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('K0 Sparplan',     v_plan, NULL, -50, 1, 'month', t + 3, t + 3),
         ('K0 Sparplan own', v_own,  NULL, -50, 1, 'month', t + 3, t + 3),
         ('K0 Sparplan neg', v_neg,  NULL, -50, 1, 'month', t + 3, t + 3);
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id', a, 'confirmed_balance', b, 'reconciliation_date', (t - 5)::text))
  FROM (VALUES (v_plan, 100), (v_own, 100), (v_neg, 30)) x(a, b);
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  SELECT a, t - 34, t - 5, b, b, 'EUR', 1, 1, 0, 0, NULL FROM (VALUES (v_plan, 100), (v_own, 100), (v_neg, 30)) x(a, b);

  v_res := finance.fn_account_outlook(v_plan);
  IF (v_res->>'has_history')::boolean IS DISTINCT FROM true OR (v_res->>'everyday_per_day')::numeric IS DISTINCT FROM 0
     OR (v_res->>'planned_out')::numeric IS DISTINCT FROM -50 OR (v_res->>'min_projected')::numeric IS DISTINCT FROM 50
     OR (v_res->>'buffer')::numeric IS DISTINCT FROM 0 OR v_res->>'buffer_source' IS DISTINCT FROM 'none'
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 0 OR (v_res->>'outflow_expected')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [K1] Alltag bekannt 0 + Sparplan -> Puffer 0 (none), Tief 50 reicht: %', v_res; END IF;

  v_res := finance.fn_account_outlook(v_own);
  IF (v_res->>'buffer')::numeric IS DISTINCT FROM 80 OR v_res->>'buffer_source' IS DISTINCT FROM 'account'
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 30 THEN
    RAISE EXCEPTION 'FAIL [K2] Alltag bekannt 0: eigener Puffer 80 gilt (Tief 50 -> 30 fehlen): %', v_res; END IF;

  v_res := finance.fn_account_outlook(v_neg);
  IF v_res->>'buffer_source' IS DISTINCT FROM 'none' OR (v_res->>'min_projected')::numeric IS DISTINCT FROM -20
     OR (v_res->>'shortfall')::numeric IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'FAIL [K3] Alltag bekannt 0: Tief unter 0 meldet weiter (shortfall 20): %', v_res; END IF;

  -- ein Auszug ohne neuen Tag (Schnitt = Auszugsende) misst keinen Alltag: unbekannt, nicht 0 -> Standard-Puffer
  v_plan := (finance.fn_create_account('{"name":"__t_ol_k0_nodays__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_plan, 100, t - 40, 'other');
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('K0 Sparplan nodays', v_plan, NULL, -50, 1, 'month', t + 3, t + 3);
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_plan, t - 34, t - 5, 100, 100, 'EUR', 1, 1, 0, 0, t - 5);
  v_res := finance.fn_account_outlook(v_plan);
  IF (v_res->>'has_history')::boolean IS DISTINCT FROM true OR v_res->>'buffer_source' IS DISTINCT FROM 'default' THEN
    RAISE EXCEPTION 'FAIL [K4] Auszug ohne gezaehlten Tag -> Alltag unbekannt, Standard-Puffer: %', v_res; END IF;
  RAISE NOTICE 'PASS outlook Alltag bekannt 0: Puffer 0 trotz Sparplan, eigener Puffer gilt, Minus meldet';
END $$;

ROLLBACK;
