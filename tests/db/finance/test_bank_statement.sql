-- tests/db/finance/test_bank_statement.sql
-- Monats-Check WP-C: Kontoauszug einspielen ohne Einzelumsaetze.
--   fn_statement_prepare: Konto per IBAN (mit Leerzeichen), Saldo-Probe, Zuordnung Stufe A (SEPA-Mandat / Gegen-IBAN
--     des Zielkontos) und B (Betrag + Datum [+ Name]), Sparplan mit geschaetzten Stueck, fehlende Zahlung, unbekanntes
--     Mandat, Plan-Anpassung beim 2. gleichen Ist-Betrag, Rest = DB-Differenz, Fingerprint.
--   fn_apply_bank_statement: veraltete Vorschau -> stale_preview ohne Write; echte Buchung (Ist-Datum/-Betrag, beide
--     Transfer-Beine, Sparplan-Kauf geschaetzt, Schluessel gelernt, Plan gesplittet, Fehlendes uebersprungen, Rest als
--     Abgleich, Aggregat gespeichert); zweites Einspielen -> already_covered.
--   fn_void_bank_statement: letzter Auszug zurueck (Buchungen, Skips, Schluessel, Abgleichsstand, Aggregat).
--   Fehlerpfade: Saldo-Probe, unbekannte IBAN (Kandidaten), Abweichung vor dem Zeitraum (drift) wird separat gebucht.
BEGIN;

DO $$
DECLARE
  ps DATE := date_trunc('month', CURRENT_DATE - 60)::date;      -- Auszugs-Zeitraum: ein voller, vergangener Monat
  pe DATE := (date_trunc('month', CURRENT_DATE - 60) + interval '1 month - 1 day')::date;
  v_giro INT; v_tg INT; v_depot INT; r_miete INT; r_strom INT; r_handy INT; r_gehalt INT; r_spar INT; r_plan INT;
  v_res JSONB; v_prep JSONB; v_stmt JSONB; v_lines JSONB; v_closing NUMERIC; v_m JSONB; v_cnt INT;
BEGIN
  -- ---------- Setup ----------
  v_giro := (finance.fn_create_account('{"name":"__t_bs_giro__","account_type":"cash","currency":"EUR","account_number":"DE11 5205 1373 5120 7101 31"}'::jsonb)->>'account_id')::int;
  v_tg   := (finance.fn_create_account('{"name":"__t_bs_tg__","account_type":"cash","currency":"EUR","account_number":"DE81520513735120710132"}'::jsonb)->>'account_id')::int;
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__t_bs_depot__','account_type','stocks_depot',
                'currency','EUR','settlement_id', v_giro))->>'account_id')::int;

  r_miete  := finance.fn_add_recurring_payment(v_giro, -850, 'Miete', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  r_strom  := finance.fn_add_recurring_payment(v_giro, -85, 'Strom Stadtwerke', 1::smallint, 'month'::finance.schedule_unit, 15::smallint,
                (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  r_handy  := finance.fn_add_recurring_payment(v_giro, -25, 'Handyvertrag', 1::smallint, 'month'::finance.schedule_unit, 12::smallint,
                (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  r_gehalt := finance.fn_add_recurring_payment(v_giro, 3000, 'Gehalt', 1::smallint, 'month'::finance.schedule_unit, 28::smallint,
                (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  r_spar   := finance.fn_add_recurring_payment(v_giro, -300, 'Sparrate', 1::smallint, 'month'::finance.schedule_unit, 10::smallint,
                (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_tg WHERE id = r_spar;
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__t_bs_etf__','depot_name','__t_bs_depot__',
             'isin','IE00BK5BQT80','symbol','VWCE','security_name','All-World','amount',100,'schedule_interval',1,
             'schedule_unit','month','schedule_day_of_month',5,'first_payment_date',(ps - interval '2 months')::date::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP plan: %', v_res; END IF;
  SELECT recurring_payment_id INTO r_plan FROM finance.savings_plans WHERE name = '__t_bs_etf__';
  INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of) VALUES ('VWCE', 'IE00BK5BQT80', 50, 'EUR', ps + 4);
  -- Strom ist per SEPA-Mandat bekannt; im Vormonat wurden schon 92 statt 85 abgebucht (-> Plan-Anpassung beim 2. Mal)
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (r_strom, 'sepa_mandate', 'DE98ZZZ09999999999|STROM-4711', 'user');
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_strom,
             'due_date', (ps - interval '1 month' + interval '14 days')::date, 'amount', 92));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP strom vormonat: %', v_res; END IF;
  -- Stand vor dem Zeitraum bestaetigt: 1000 EUR zum Vortag des Zeitraums
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 1092, ps - 40, 'other');
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_giro, 'confirmed_balance', 1000,
             'reconciliation_date', (ps - 1)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP reconcile: %', v_res; END IF;

  v_lines := jsonb_build_array(
    jsonb_build_object('date', ps + 2,  'amount', -850,   'counterparty', 'Hausverwaltung Mueller', 'purpose', 'Miete August'),
    jsonb_build_object('date', ps + 5,  'amount', -100,   'counterparty', 'Trade Republic', 'purpose', 'Sparplan __t_bs_etf__'),
    jsonb_build_object('date', ps + 10, 'amount', -300,   'counterparty', 'Ich', 'counterparty_iban', 'DE81 5205 1373 5120 7101 32', 'purpose', 'Umbuchung'),
    jsonb_build_object('date', ps + 15, 'amount', -92,    'counterparty', 'Stadtwerke', 'counterparty_iban', 'DE44500105175407324931',
                       'creditor_id', 'DE98ZZZ09999999999', 'mandate_ref', 'STROM-4711', 'purpose', 'Abschlag'),
    jsonb_build_object('date', ps + 16, 'amount', -29.99, 'counterparty', 'VODAFONE GMBH', 'creditor_id', 'DE21ZZZ00000012345',
                       'mandate_ref', 'VF-1', 'purpose', 'Rechnung'),
    jsonb_build_object('date', ps + 18, 'amount', -40.10, 'counterparty', 'REWE', 'purpose', 'Einkauf'),
    jsonb_build_object('date', ps + 22, 'amount', -60,    'counterparty', 'ARAL', 'purpose', 'Tanken'),
    jsonb_build_object('date', ps + 27, 'amount', 3000,   'counterparty', 'ACME GmbH', 'counterparty_iban', 'DE89370400440532013000', 'purpose', 'Lohn'));
  v_closing := 1000 - 850 - 100 - 300 - 92 - 29.99 - 40.10 - 60 + 3000;   -- 2527.91
  v_stmt := jsonb_build_object('account_number', 'de11 5205 1373 5120 7101 31', 'currency', 'EUR',
              'period_start', ps, 'period_end', pe, 'opening_balance', 1000, 'closing_balance', v_closing, 'lines', v_lines);

  -- ---------- Fehlerpfade ----------
  v_res := finance.fn_statement_prepare(v_stmt || jsonb_build_object('closing_balance', v_closing + 1));
  IF v_res->>'code' IS DISTINCT FROM 'balance_check_failed' OR (v_res->>'difference')::numeric IS DISTINCT FROM 1.00 THEN
    RAISE EXCEPTION 'FAIL Saldo-Probe: %', v_res; END IF;
  v_res := finance.fn_statement_prepare(v_stmt || jsonb_build_object('account_number', 'DE36000000000000000000'));
  IF v_res->>'code' IS DISTINCT FROM 'account_unknown' THEN RAISE EXCEPTION 'FAIL account_unknown: %', v_res; END IF;
  RAISE NOTICE 'PASS Fehlerpfade (Saldo-Probe 1,00 Differenz, unbekannte IBAN)';

  -- ---------- Vorschau ----------
  v_prep := finance.fn_statement_prepare(v_stmt);
  IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL prepare: %', v_prep; END IF;
  IF (v_prep->>'account_id')::int IS DISTINCT FROM v_giro OR (v_prep->>'drift')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL prepare Konto/drift: %', v_prep; END IF;
  IF jsonb_array_length(v_prep->'matched') <> 5 THEN RAISE EXCEPTION 'FAIL matched (erwartet 5): %', v_prep->'matched'; END IF;
  SELECT m INTO v_m FROM jsonb_array_elements(v_prep->'matched') m WHERE (m->>'recurring_payment_id')::int = r_strom;
  IF v_m->>'stage' IS DISTINCT FROM 'A' THEN RAISE EXCEPTION 'FAIL Strom Stufe A: %', v_m; END IF;
  SELECT m INTO v_m FROM jsonb_array_elements(v_prep->'matched') m WHERE (m->>'recurring_payment_id')::int = r_spar;
  IF v_m->>'stage' IS DISTINCT FROM 'A' THEN RAISE EXCEPTION 'FAIL Sparrate Stufe A (IBAN Zielkonto): %', v_m; END IF;
  SELECT m INTO v_m FROM jsonb_array_elements(v_prep->'matched') m WHERE (m->>'recurring_payment_id')::int = r_plan;
  IF v_m->>'kind' IS DISTINCT FROM 'savings_plan' OR (v_m->>'shares')::numeric IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL Sparplan geschaetzt: %', v_m; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r_handy) THEN
    RAISE EXCEPTION 'FAIL missing Handy: %', v_prep->'missing'; END IF;
  IF jsonb_array_length(v_prep->'unknown_mandates') <> 1 THEN RAISE EXCEPTION 'FAIL unknown_mandates: %', v_prep->'unknown_mandates'; END IF;
  IF jsonb_array_length(v_prep->'plan_adjustments') <> 1
     OR (v_prep->'plan_adjustments'->0->>'recurring_payment_id')::int IS DISTINCT FROM r_strom THEN
    RAISE EXCEPTION 'FAIL plan_adjustments: %', v_prep->'plan_adjustments'; END IF;
  IF (v_prep->>'lump')::numeric IS DISTINCT FROM -130.09 THEN RAISE EXCEPTION 'FAIL lump: %', v_prep->>'lump'; END IF;
  IF jsonb_array_length(v_prep->'card_lines') < 5 OR length(v_prep->>'fingerprint') <> 32 THEN
    RAISE EXCEPTION 'FAIL Karte/Fingerprint: %', v_prep; END IF;
  RAISE NOTICE 'PASS Vorschau: 5 Treffer (A: Mandat + Ziel-IBAN, B, Sparplan 2 Stueck), Handy fehlt, 1 Mandat unbekannt, Plan-Anpassung Strom, Rest -130,09';

  -- ---------- Buchung ----------
  v_res := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', 'veraltet'));
  IF v_res->>'code' IS DISTINCT FROM 'stale_preview' OR EXISTS (SELECT 1 FROM finance.bank_statements WHERE account_id = v_giro) THEN
    RAISE EXCEPTION 'FAIL stale_preview: %', v_res; END IF;
  v_res := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL apply: %', v_res; END IF;
  IF finance.fn_get_balance(v_giro) IS DISTINCT FROM v_closing OR finance.fn_get_balance(v_tg) IS DISTINCT FROM 300.00 THEN
    RAISE EXCEPTION 'FAIL Salden: giro=% tg=%', finance.fn_get_balance(v_giro), finance.fn_get_balance(v_tg); END IF;
  IF (v_res->>'lump_amount')::numeric IS DISTINCT FROM -130.09 OR (v_res->>'balance_after')::numeric IS DISTINCT FROM v_closing
     OR (v_res->>'booked_count')::int IS DISTINCT FROM 5 OR (v_res->>'skipped_occurrences')::int < 1
     OR (v_res->>'learned_keys')::int IS DISTINCT FROM 2 OR jsonb_array_length(v_res->'plan_adjusted') <> 1
     -- Rest getrennt nach Richtung (Live-Befund 2026-10-30): -130.09 = Ausgang, kein Eingang
     OR (v_res->>'rest_outflow')::numeric IS DISTINCT FROM 130.09 OR (v_res->>'rest_inflow')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL apply Rueckgabe: %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = r_miete AND recurring_due_date = ps
                 AND transaction_date = ps + 2 AND bank_statement_id IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL Miete am Ist-Datum mit Auszugs-Herkunft'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = r_plan AND category = 'buy' AND shares = 2
                 AND shares_estimated) THEN RAISE EXCEPTION 'FAIL Sparplan-Kauf geschaetzt'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payment_skips WHERE recurring_payment_id = r_handy AND due_date = ps + 11) THEN
    RAISE EXCEPTION 'FAIL Handy uebersprungen'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payment_keys WHERE recurring_payment_id = r_gehalt
                 AND key_type = 'counterparty_iban' AND key_value = 'DE89370400440532013000') THEN
    RAISE EXCEPTION 'FAIL Gehalt-IBAN gelernt'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE predecessor_id = r_strom AND amount = -92) THEN
    RAISE EXCEPTION 'FAIL Strom-Plan auf 92 gesplittet'; END IF;
  SELECT count(*) INTO v_cnt FROM finance.bank_statements
   WHERE account_id = v_giro AND unmatched_out = -130.09 AND unmatched_in = 0 AND line_count = 8 AND matched_count = 5;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL Aggregat: %', (SELECT jsonb_agg(b) FROM finance.bank_statements b); END IF;
  v_res := finance.fn_statement_prepare(v_stmt);
  IF v_res->>'code' IS DISTINCT FROM 'already_covered' THEN RAISE EXCEPTION 'FAIL zweites Einspielen: %', v_res; END IF;
  RAISE NOTICE 'PASS Buchung: Salden, Ist-Datum, Sparplan geschaetzt, Skip, Schluessel, Plan-Split, Aggregat; Doppel gesperrt';

  -- ---------- Ruecknahme ----------
  v_res := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_giro));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL void: %', v_res; END IF;
  IF finance.fn_get_balance(v_giro) IS DISTINCT FROM 1000.00 OR finance.fn_get_balance(v_tg) IS DISTINCT FROM 0.00
     OR (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_giro) IS DISTINCT FROM ps - 1
     OR EXISTS (SELECT 1 FROM finance.bank_statements WHERE account_id = v_giro)
     OR EXISTS (SELECT 1 FROM finance.recurring_payment_skips WHERE recurring_payment_id = r_handy AND due_date = ps + 11)
     OR EXISTS (SELECT 1 FROM finance.recurring_payment_keys WHERE recurring_payment_id = r_gehalt) THEN
    RAISE EXCEPTION 'FAIL void Zustand: giro=% tg=% res=%', finance.fn_get_balance(v_giro), finance.fn_get_balance(v_tg), v_res; END IF;
  RAISE NOTICE 'PASS Ruecknahme: Salden, Abgleichsstand, Skips, Schluessel, Aggregat zurueck';
END $$;

-- Abweichung vor dem Zeitraum (System kennt einen anderen Anfangsstand) -> separat gebuchte Korrektur am Vortag
DO $$
DECLARE
  ps DATE := date_trunc('month', CURRENT_DATE - 60)::date;
  pe DATE := (date_trunc('month', CURRENT_DATE - 60) + interval '1 month - 1 day')::date;
  v_a INT; v_res JSONB; v_stmt JSONB;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_bs_drift__","account_type":"cash","currency":"EUR","account_number":"DE54520513735120710133"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 500, ps - 20, 'other');
  v_stmt := jsonb_build_object('account_number', 'DE54520513735120710133', 'currency', 'EUR', 'period_start', ps,
              'period_end', pe, 'opening_balance', 450, 'closing_balance', 400,
              'lines', jsonb_build_array(jsonb_build_object('date', ps + 3, 'amount', -50, 'counterparty', 'REWE')));
  v_res := finance.fn_statement_prepare(v_stmt);
  IF (v_res->>'drift')::numeric IS DISTINCT FROM -50 OR (v_res->>'lump')::numeric IS DISTINCT FROM -50 THEN
    RAISE EXCEPTION 'FAIL drift-Vorschau: %', v_res; END IF;
  v_res := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_res->>'fingerprint'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'drift_amount')::numeric IS DISTINCT FROM -50
     OR finance.fn_get_balance(v_a) IS DISTINCT FROM 400.00
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_a AND category = 'reconciliation'
                    AND transaction_date = ps - 1 AND amount = -50) THEN
    RAISE EXCEPTION 'FAIL drift-Buchung: % saldo=%', v_res, finance.fn_get_balance(v_a); END IF;
  RAISE NOTICE 'PASS Abweichung vor dem Zeitraum: -50 am Vortag, Rest -50 im Zeitraum';
END $$;

-- Review-Befunde: (1) schon gebuchte Zahlung mit Buchungsdatum NACH dem Auszugsende wird aufs Ist-Datum verschoben
-- statt zusaetzlich im Rest zu landen; (3) dieselbe geaenderte Zahlung zweimal im Auszug -> EINE Plan-Anpassung, Buchung
-- gelingt; (5) "fehlt" zeigt auch offene Termine vor dem Zeitraum, die der Abgleich ueberspringt.
DO $$
DECLARE
  ps DATE := date_trunc('month', CURRENT_DATE - 100)::date;                       -- Zwei-Monats-Auszug
  pe DATE := (date_trunc('month', CURRENT_DATE - 100) + interval '2 months - 1 day')::date;
  m2 DATE := (date_trunc('month', CURRENT_DATE - 100) + interval '1 month')::date;
  v_a INT; r_fit INT; r_miete INT; r_zeit INT; v_res JSONB; v_prep JSONB; v_stmt JSONB;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_bs_review__","account_type":"cash","currency":"EUR","account_number":"DE48520513735120710144"}'::jsonb)->>'account_id')::int;
  r_fit   := finance.fn_add_recurring_payment(v_a, -30, 'Fitnessstudio', 1::smallint, 'month'::finance.schedule_unit, 5::smallint,
               (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  r_miete := finance.fn_add_recurring_payment(v_a, -500, 'Miete', 1::smallint, 'month'::finance.schedule_unit, (-1)::smallint,
               (ps - interval '2 months')::date, (ps - interval '2 months')::date, NULL, NULL, NULL);
  r_zeit  := finance.fn_add_recurring_payment(v_a, -10, 'Zeitung', 3::smallint, 'month'::finance.schedule_unit, NULL,
               ps - 5, ps - 5, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (r_fit, 'sepa_mandate', 'DE11ZZZ00000000001|FIT-1', 'user');
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_a, 2000, ps - 70, 'other');
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_fit,
             'due_date', (ps - interval '1 month' + interval '4 days')::date, 'amount', 35));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP fit vormonat: %', v_res; END IF;
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1965,
             'reconciliation_date', (ps - 1)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP reconcile: %', v_res; END IF;
  -- Miete fuer das Zeitraum-Ende schon im Chat bestaetigt, aber mit Buchungsdatum 2 Tage NACH dem Auszugsende
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_miete, 'due_date', pe,
             'amount', 500, 'transaction_date', pe + 2));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP miete nachher: %', v_res; END IF;

  v_stmt := jsonb_build_object('account_number', 'DE48520513735120710144', 'currency', 'EUR', 'period_start', ps,
    'period_end', pe, 'opening_balance', 1965, 'closing_balance', 1965 - 35 - 500 - 200 - 35 - 500,
    'lines', jsonb_build_array(
      jsonb_build_object('date', ps + 4,  'amount', -35,  'counterparty', 'FitX', 'creditor_id', 'DE11ZZZ00000000001', 'mandate_ref', 'FIT-1'),
      jsonb_build_object('date', m2 - 1,  'amount', -500, 'counterparty', 'Vermieter', 'purpose', 'Miete'),
      jsonb_build_object('date', ps + 10, 'amount', -200, 'counterparty', 'REWE'),
      jsonb_build_object('date', m2 + 4,  'amount', -35,  'counterparty', 'FitX', 'creditor_id', 'DE11ZZZ00000000001', 'mandate_ref', 'FIT-1'),
      jsonb_build_object('date', pe,      'amount', -500, 'counterparty', 'Vermieter', 'purpose', 'Miete')));

  v_prep := finance.fn_statement_prepare(v_stmt);
  IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL review prepare: %', v_prep; END IF;
  IF jsonb_array_length(v_prep->'plan_adjustments') <> 1
     OR (v_prep->'plan_adjustments'->0->>'eff_from')::date IS DISTINCT FROM m2 + 5 THEN
    RAISE EXCEPTION 'FAIL (3) eine Plan-Anpassung je Kette: %', v_prep->'plan_adjustments'; END IF;
  IF jsonb_array_length(v_prep->'already_booked') <> 1 OR (v_prep->>'lump')::numeric IS DISTINCT FROM -200 THEN
    RAISE EXCEPTION 'FAIL (1) nachher gebuchte Miete nicht im Rest: booked=% lump=%', v_prep->'already_booked', v_prep->>'lump'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r_zeit
                 AND (x->>'due_date')::date = ps - 5) THEN
    RAISE EXCEPTION 'FAIL (5) offener Termin vor dem Zeitraum fehlt auf der Karte: %', v_prep->'missing'; END IF;

  v_res := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'redated_count')::int IS DISTINCT FROM 1
     OR (v_res->>'lump_amount')::numeric IS DISTINCT FROM -200 OR jsonb_array_length(v_res->'plan_adjusted') <> 1 THEN
    RAISE EXCEPTION 'FAIL review apply: %', v_res; END IF;
  IF finance.fn_get_balance(v_a) IS DISTINCT FROM 695.00
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = r_miete AND recurring_due_date = pe
                    AND transaction_date = pe)
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE predecessor_id = r_fit AND amount = -35
                    AND valid_from = m2 + 5) THEN
    RAISE EXCEPTION 'FAIL review Zustand: saldo=%', finance.fn_get_balance(v_a); END IF;
  RAISE NOTICE 'PASS Review-Befunde: Miete aufs Ist-Datum verschoben (kein Doppel), eine Plan-Anpassung, Vorzeitraum-Termin auf der Karte';
END $$;

-- Owner-Befund 2026-10-23: Auszug eines NEUEN Kontos. account_unknown traegt den gepruefte Endsaldo + Stichtag (nur
-- wenn die Saldo-Probe stimmt); Anlegen mit diesem Saldo zum Stichtag -> derselbe Auszug = already_covered,
-- der Folgeauszug schliesst ohne Abweichung an.
DO $$
DECLARE
  ps DATE := date_trunc('month', CURRENT_DATE - 60)::date;
  pe DATE := (date_trunc('month', CURRENT_DATE - 60) + interval '1 month - 1 day')::date;
  v_iban TEXT := 'DE02100123450000000561';
  v_a INT; v_res JSONB; v_stmt JSONB; v_next JSONB;
BEGIN
  v_stmt := jsonb_build_object('account_number', v_iban, 'currency', 'EUR', 'period_start', ps,
              'period_end', pe, 'opening_balance', 100, 'closing_balance', 150,
              'lines', jsonb_build_array(jsonb_build_object('date', ps + 1, 'amount', 100, 'counterparty', 'Papa'),
                                         jsonb_build_object('date', ps + 2, 'amount', -50, 'counterparty', 'Vanguard')));
  v_res := finance.fn_statement_prepare(v_stmt);
  IF v_res->>'code' IS DISTINCT FROM 'account_unknown' OR (v_res->>'closing_balance')::numeric IS DISTINCT FROM 150
     OR (v_res->>'balance_date')::date IS DISTINCT FROM pe OR v_res->>'currency' IS DISTINCT FROM 'EUR'
     OR (v_res->>'balance_verified')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL account_unknown mit geprueftem Endsaldo: %', v_res; END IF;
  -- verlesener Auszug (Probe stimmt nicht): kein Endsaldo zum Uebernehmen
  v_res := finance.fn_statement_prepare(v_stmt || jsonb_build_object('closing_balance', 151));
  IF v_res->>'code' IS DISTINCT FROM 'account_unknown' OR v_res ? 'closing_balance'
     OR (v_res->>'balance_verified')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL account_unknown bei falscher Saldo-Probe: %', v_res; END IF;

  v_res := finance.fn_create_account(jsonb_build_object('name', '__t_bs_new__', 'account_type', 'cash',
             'account_number', v_iban, 'opening_balance', '150', 'opening_balance_date', to_char(pe, 'YYYY-MM-DD')));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP neues Konto: %', v_res; END IF;
  v_a := (v_res->>'account_id')::int;

  v_res := finance.fn_statement_prepare(v_stmt);
  IF v_res->>'code' IS DISTINCT FROM 'already_covered' THEN
    RAISE EXCEPTION 'FAIL gleicher Auszug nach Anlegen: %', v_res; END IF;
  v_next := jsonb_build_object('account_number', v_iban, 'currency', 'EUR', 'period_start', pe + 1,
              'period_end', pe + 20, 'opening_balance', 150, 'closing_balance', 130,
              'lines', jsonb_build_array(jsonb_build_object('date', pe + 5, 'amount', -20, 'counterparty', 'REWE')));
  v_res := finance.fn_statement_prepare(v_next);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'account_id')::int IS DISTINCT FROM v_a
     OR (v_res->>'drift')::numeric IS DISTINCT FROM 0 OR (v_res->>'lump')::numeric IS DISTINCT FROM -20 THEN
    RAISE EXCEPTION 'FAIL Folgeauszug: %', v_res; END IF;
  RAISE NOTICE 'PASS Neues Konto per Auszug: gepruefter Endsaldo, already_covered, Folgeauszug ohne Abweichung';
END $$;

ROLLBACK;
