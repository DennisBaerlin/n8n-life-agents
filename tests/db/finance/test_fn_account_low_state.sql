-- tests/db/finance/test_fn_account_low_state.sql
-- finance.fn_account_low_state(acct, alert_only) — das EINE Urteil „Tiefster Stand“ (Konten-Tab, Konten-Banner,
--   Spiegel-Pille am Sparplan), auf dem Fixture-Haushalt tests/util/util_app_household.sql:
--   [1] Sparkonto Zins (Deckungs-Konto ohne Auszug): funding, Ziel-Geld ist nicht frei -> warn mit Datum/Monat, Wert =
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
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_sparkonto'));
  f := finance.fn_account_funding((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_sparkonto'));
  IF v->>'source' <> 'funding' OR v->>'state' <> 'warn' OR v->>'verdict' <> 'goals'
     OR (v->>'on_date')::date IS DISTINCT FROM (f->>'runs_out_on')::date OR v->>'month' <> to_char((f->>'runs_out_on')::date, 'YYYY-MM')
     OR (v->>'amount')::numeric <> (f->>'min_free')::numeric OR (v->>'amount')::numeric >= 0
     OR NOT (v->>'has_outflow')::boolean OR (v->>'gap')::boolean OR (v->>'monthly_out')::numeric >= 0
     OR jsonb_typeof(v->'short_by') <> 'null'
     OR (v->>'horizon_end')::date IS DISTINCT FROM (f->>'horizon_end')::date OR v->>'horizon_end' IS NULL THEN
    RAISE EXCEPTION 'FAIL [1] Sparkonto funding warn (short_by null ohne Puffer-Urteil, horizon_end aus fn_account_funding), got % / %', v, f; END IF;
  -- Ziel-Geld 16.850 von 28.000, -2.400/Monat raus, +185 Ziel-Raten rein (nicht frei): reicht hoechstens ~5 Monate
  IF (f->>'runs_out_on')::date > core.fn_today() + interval '6 months' THEN
    RAISE EXCEPTION 'FAIL [1b] reicht bis zu spaet (Ziel-Geld als frei gezaehlt?), got %', f; END IF;
  RAISE NOTICE 'PASS [1] Sparkonto: funding warn, freies Geld, Datum + Monat';

  -- [2] Broker-Cash
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_broker_cash'));
  IF v->>'source' <> 'funding' OR v->>'state' <> 'ok' OR NOT (v->>'has_outflow')::boolean
     OR v->>'on_date' IS NOT NULL OR v->>'horizon_end' IS NULL THEN
    RAISE EXCEPTION 'FAIL [2] Broker-Cash funding ok (kein Lauf-Ende, horizon_end fuer „ueber <Monat> hinaus“), got %', v; END IF;
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
  -- short_by = Fehlbetrag zum Puffer aus fn_account_outlook (eine Adresse fuer „x unter dem Puffer"), nur bei verdict buffer
  IF (v->>'verdict' = 'buffer' AND (v->>'short_by')::numeric IS DISTINCT FROM (o->>'shortfall')::numeric)
     OR (v->>'verdict' IS DISTINCT FROM 'buffer' AND jsonb_typeof(v->'short_by') <> 'null') THEN
    RAISE EXCEPTION 'FAIL [3c] Giro short_by = outlook.shortfall bei verdict buffer, got % / %', v, o; END IF;
  RAISE NOTICE 'PASS [3] Giro: outlook, schlechteres Urteil aus Puffer und Ziel-Geld, short_by';

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
  -- mit Wechselkurs ist dasselbe Konto beurteilbar (kein gap)
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'CHF', 0.95, core.fn_today() - 1)
    ON CONFLICT DO NOTHING;
  IF (finance.fn_account_low_state(v_chf)->>'gap')::boolean THEN
    RAISE EXCEPTION 'FAIL [6c] mit Kurs kein gap, got %', finance.fn_account_low_state(v_chf); END IF;
  RAISE NOTICE 'PASS [6] Kurs fehlt -> neutral + gap; mit Kurs kein gap; Depot/unbekannt -> ok:false';

  -- [7] probe-Fenster: gleiche Form, Sparkonto bleibt Deckungs-Konto
  v := finance.fn_account_low_state((SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_sparkonto'), true);
  IF v->>'source' <> 'funding' OR NOT (v ? 'state' AND v ? 'on_date' AND v ? 'month') THEN
    RAISE EXCEPTION 'FAIL [7] p_alert_only, got %', v; END IF;
  RAISE NOTICE 'PASS [7] p_alert_only';
END $$;

-- [8] Schwelle warn = coverage_warn_factor x Puffer, Grenze exklusiv: ein Puffer-Urteil ohne Fehlbetrag mit Faktor genau
--     tiefster Stand / Puffer ist noch ok, ein Faktor darueber macht es knapp (warn).
DO $$
DECLARE
  v jsonb; v_id int; v_amt numeric; v_buf numeric;
BEGIN
  SELECT x.id INTO v_id FROM (SELECT id::int AS id FROM pg_temp.app_fx WHERE key LIKE 'acc\_%') x
   WHERE finance.fn_account_low_state(x.id)->>'verdict' = 'buffer'
     AND (finance.fn_account_low_state(x.id)->>'short_by')::numeric = 0
     AND (finance.fn_account_low_state(x.id)->>'buffer')::numeric > 0
     AND (finance.fn_account_low_state(x.id)->>'amount')::numeric > 0
   ORDER BY x.id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'SETUP [8] kein Fixture-Konto mit Puffer-Urteil ohne Fehlbetrag'; END IF;
  v := finance.fn_account_low_state(v_id);
  v_amt := (v->>'amount')::numeric; v_buf := (v->>'buffer')::numeric;
  IF trim_scale(v_amt / v_buf) * v_buf <> v_amt THEN RAISE EXCEPTION 'SETUP [8] Verhaeltnis nicht exakt: % / %', v_amt, v_buf; END IF;

  INSERT INTO core.config (category, key, value, package) VALUES ('finance', 'coverage_warn_factor', trim_scale(v_amt / v_buf)::text, 'finance')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;
  IF finance.fn_account_low_state(v_id)->>'state' IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'FAIL [8a] tiefster Stand = Faktor x Puffer -> ok, got %', finance.fn_account_low_state(v_id); END IF;
  UPDATE core.config SET value = trim_scale(v_amt / v_buf + 1)::text WHERE category = 'finance' AND key = 'coverage_warn_factor';
  IF finance.fn_account_low_state(v_id)->>'state' IS DISTINCT FROM 'warn' THEN
    RAISE EXCEPTION 'FAIL [8b] tiefster Stand unter Faktor x Puffer -> warn, got %', finance.fn_account_low_state(v_id); END IF;
  RAISE NOTICE 'PASS [8] warn-Schwelle Faktor x Puffer, Grenze exklusiv';
END $$;

-- [9] Auszug aelter als statement_stale_days: die Vorschau ist nicht verlaesslich -> warn, verdict stale, Auszug-Datum;
--     genau am Grenztag gilt noch das normale Urteil
DO $$
DECLARE
  v jsonb; v_id int := (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas');
BEGIN
  INSERT INTO core.config (category, key, value, package) VALUES ('finance', 'statement_stale_days', '45', 'finance')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;
  UPDATE finance.accounts SET last_reconciled_at = core.fn_today() - 46 WHERE id = v_id;
  v := finance.fn_account_low_state(v_id);
  IF v->>'source' <> 'outlook' OR v->>'state' <> 'warn' OR v->>'verdict' <> 'stale'
     OR (v->>'statement_date')::date <> core.fn_today() - 46 THEN
    RAISE EXCEPTION 'FAIL [9a] alter Auszug -> warn stale mit Datum, got %', v; END IF;
  UPDATE finance.accounts SET last_reconciled_at = core.fn_today() - 45 WHERE id = v_id;
  v := finance.fn_account_low_state(v_id);
  IF v->>'verdict' = 'stale' THEN RAISE EXCEPTION 'FAIL [9b] Grenztag ist noch nicht alt, got %', v; END IF;
  RAISE NOTICE 'PASS [9] alter Auszug';
END $$;

ROLLBACK;
