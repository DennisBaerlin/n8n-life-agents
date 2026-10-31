-- tests/db/finance/test_fn_account_low_state.sql
-- finance.fn_account_low_state(acct, alert_only) — das EINE Urteil „Tiefster Stand“ (Konten-Tab, Konten-Banner,
--   Spiegel-Pille am Sparplan), auf dem Fixture-Haushalt tests/util/util_app_household.sql:
--   [1] Sparkonto P2P (Deckungs-Konto ohne Auszug): funding, Ziel-Geld ist nicht frei -> warn mit Datum/Monat, Wert =
--       tiefster freier Stand (negativ), Zahlen = fn_account_funding
--   [2] Broker-Cash (Sparplan, Notreserve darauf): funding, gedeckt -> ok
--   [3] Girokonto Jonas (Auszug + Absender von Dauerauftraegen): outlook; Urteil = das schlechtere aus Puffer und Ziel-Geld
--   [4] Tagesgeld Mira (Auszug, keine Bewegung): outlook ohne Abfluss (has_outflow false -> keine Zeile)
--   [5] Gemeinschaftskonto (Ausgaben, kein Auszug) / Verrechnungskonto: none, neutral
--   [6] Kontowaehrung ohne Kurs mit Auszug: neutral + gap; Depot/Kredit/unbekannt -> ok:false
--   [7] p_alert_only rechnet nur das alert-Fenster (gleiche Antwortform)
BEGIN;
\ir ../../util/util_app_household.sql

DO $$
DECLARE
  v jsonb; f jsonb; o jsonb; v_chf int;
BEGIN
  -- [1] Sparkonto
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_p2p'));
  f := finance.fn_account_funding((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_p2p'));
  IF v->>'source' <> 'funding' OR v->>'state' <> 'warn' OR v->>'verdict' <> 'goals'
     OR (v->>'on_date')::date IS DISTINCT FROM (f->>'runs_out_on')::date OR v->>'month' <> to_char((f->>'runs_out_on')::date, 'YYYY-MM')
     OR (v->>'amount')::numeric <> (f->>'min_free')::numeric OR (v->>'amount')::numeric >= 0
     OR NOT (v->>'has_outflow')::boolean OR (v->>'gap')::boolean OR (v->>'monthly_out')::numeric >= 0 THEN
    RAISE EXCEPTION 'FAIL [1] Sparkonto funding warn, got % / %', v, f; END IF;
  -- Ziel-Geld 26.800 von 40.000, -3.000/Monat raus, +220 Ziel-Raten rein (nicht frei): reicht hoechstens ~5 Monate
  IF (f->>'runs_out_on')::date > core.fn_today() + interval '6 months' THEN
    RAISE EXCEPTION 'FAIL [1b] reicht bis zu spaet (Ziel-Geld als frei gezaehlt?), got %', f; END IF;
  RAISE NOTICE 'PASS [1] Sparkonto: funding warn, freies Geld, Datum + Monat';

  -- [2] Broker-Cash
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_broker_cash'));
  IF v->>'source' <> 'funding' OR v->>'state' <> 'ok' OR NOT (v->>'has_outflow')::boolean THEN
    RAISE EXCEPTION 'FAIL [2] Broker-Cash funding ok, got %', v; END IF;
  RAISE NOTICE 'PASS [2] Broker-Cash gedeckt';

  -- [3] Girokonto: outlook; Urteil = schlechter aus outlook-Zustand und fn_account_funding
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas'));
  o := finance.fn_account_outlook((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas'));
  f := finance.fn_account_funding((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas'));
  IF v->>'source' <> 'outlook' OR (v->>'amount')::numeric <> (o->>'min_projected')::numeric
     OR (v->>'low_date')::date <> (o->>'min_date')::date OR (v->>'buffer')::numeric <> (o->>'buffer')::numeric
     OR NOT (v->>'has_outflow')::boolean THEN
    RAISE EXCEPTION 'FAIL [3] Giro outlook, got % / %', v, o; END IF;
  IF array_position(ARRAY['ok', 'warn', 'alert'], v->>'state') < array_position(ARRAY['ok', 'warn', 'alert'], f->>'state')
     OR (v->>'verdict' = 'goals' AND (v->>'on_date')::date IS DISTINCT FROM (f->>'runs_out_on')::date) THEN
    RAISE EXCEPTION 'FAIL [3b] Giro: schlechteres Urteil, got % / funding %', v, f; END IF;
  RAISE NOTICE 'PASS [3] Giro: outlook, schlechteres Urteil aus Puffer und Ziel-Geld';

  -- [4] Tagesgeld Mira: Auszug, aber nichts geht ab
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_savings_mira'));
  IF v->>'source' <> 'outlook' OR (v->>'has_outflow')::boolean THEN RAISE EXCEPTION 'FAIL [4] Tagesgeld ohne Abfluss, got %', v; END IF;
  RAISE NOTICE 'PASS [4] ohne Abfluss: keine Zeile noetig';

  -- [5] Gemeinschaftskonto (unbekannte Alltagsausgaben, kein Deckungs-Konto) und Verrechnungskonto: kein Urteil
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_joint'));
  IF v->>'source' <> 'none' OR v->>'state' <> 'neutral' OR jsonb_typeof(v->'amount') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [5] Gemeinschaftskonto none, got %', v; END IF;
  IF finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_clearing'))->>'source' <> 'none' THEN
    RAISE EXCEPTION 'FAIL [5b] Verrechnungskonto none'; END IF;
  RAISE NOTICE 'PASS [5] ohne Auszug / ohne Rolle: none';

  -- [6] CHF-Konto mit Auszug ohne Wechselkurs -> neutral + gap; Depot/Kredit/unbekannt -> ok:false
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ls_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_chf, 900, core.fn_today() - 40, 'other');
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
      line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_chf, core.fn_today() - 34, core.fn_today() - 5, 1000, 900, 'CHF', 3, 0, -100, 0, NULL);
  v := finance.fn_account_low_state(v_chf);
  IF v->>'state' <> 'neutral' OR NOT (v->>'gap')::boolean THEN RAISE EXCEPTION 'FAIL [6] ohne Kurs -> neutral + gap, got %', v; END IF;
  IF (finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_depot_jonas'))->>'ok')::boolean
     OR (finance.fn_account_low_state(-1)->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [6b] Depot/unbekannt -> ok:false'; END IF;
  RAISE NOTICE 'PASS [6] Kurs fehlt -> neutral + gap; Depot/unbekannt -> ok:false';

  -- [7] probe-Fenster: gleiche Form, Sparkonto bleibt Deckungs-Konto
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_p2p'), true);
  IF v->>'source' <> 'funding' OR NOT (v ? 'state' AND v ? 'on_date' AND v ? 'month') THEN
    RAISE EXCEPTION 'FAIL [7] p_alert_only, got %', v; END IF;
  RAISE NOTICE 'PASS [7] p_alert_only';
END $$;

ROLLBACK;
