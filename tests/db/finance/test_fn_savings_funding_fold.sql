-- tests/db/finance/test_fn_savings_funding_fold.sql
-- finance.fn_savings_funding_fold(accounts[], ask, state_only) — Event-Fold „Woher kommt das Geld?" der Sparplan- und
--   Zubringer-Writes. Je Deckungs-Konto (fn_funding_accounts) eine Kartenzeile aus fn_account_funding (ungelatcht) und
--   ein Note-Teil; ask=true fragt nur bei warn/alert und nur beim Latch-Uebergang (core.fn_should_notify
--   'savings_funding:<id>'), Re-Arm bei ok oder wenn das Konto kein Deckungs-Konto mehr ist. Fehlbetrag inkl.
--   geschaetzter Alltagsausgaben rechnet die fn; Fehlbetrag 0 bei warn/alert = Zeitpunkt-Variante. Werte erfunden.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_kid INT; v_drain INT; v_late INT; v_spend INT; v_chf INT; v_fut INT; v_depot INT; v_rp INT;
  v JSONB; a JSONB;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  DELETE FROM core.config WHERE package = 'finance' AND category = 'finance' AND key IN ('funding_horizon_months', 'funding_alert_months');
  DELETE FROM core.notification_state WHERE source = 'finance' AND key LIKE 'savings_funding:%';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_kid__', 'cash', 'EUR', 'active') RETURNING id INTO v_kid;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_drain__', 'cash', 'EUR', 'active') RETURNING id INTO v_drain;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_late__', 'cash', 'EUR', 'active') RETURNING id INTO v_late;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_spend__', 'cash', 'EUR', 'active') RETURNING id INTO v_spend;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_sf_fut__', 'cash', 'EUR', 'active') RETURNING id INTO v_fut;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__t_sf_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_depot;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 50000, t - 40, 'other'), (v_kid, 150, t - 40, 'other'), (v_drain, 3000, t - 40, 'other'),
    (v_late, 100, t - 40, 'other'), (v_spend, 1000, t - 40, 'other'), (v_fut, 1000, t - 40, 'other');

  -- Sparplaene (monatlich, Anker t+2) auf den Test-Konten
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('sf Plan Kind',  v_kid,   NULL, -200, 'month', t + 2, t + 2),
    ('sf Plan Abbau', v_drain, NULL, -240, 'month', t + 2, t + 2),
    ('sf Zubr Abbau', v_giro, v_drain, -200, 'month', t + 1, t + 1),
    ('sf Plan spaet', v_late,  NULL, -500, 'month', t + 2, t + 2),
    ('sf Zubr spaet', v_giro, v_late,  -500, 'month', t + 20, t + 20),
    ('sf Plan Spend', v_spend, NULL, -100, 'month', t + 2, t + 2),
    ('sf Miete',      v_spend, NULL, -200, 'month', t + 4, t + 4),
    ('sf CHF',        v_giro, v_chf,   -100, 'month', t + 5, t + 5);
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
  SELECT r.name, v_depot, 'SF' || r.id, 'Welt ETF', r.id FROM finance.recurring_payments r
   WHERE r.name LIKE 'sf Plan %';

  -- [a] Kind-Konto 150 gegen -200 ab t+2 -> alert; Kartenzeile gap mit rein 0 / raus 200; Frage-Note mit Fehlbetrag 200
  v := finance.fn_savings_funding_fold(ARRAY[v_kid], true);
  a := v->'savings_funding'->'accounts'->0;
  IF v->'card_lines'->0->>'value' <> 'finance.note.funding_gap'
     OR (v->'card_lines'->0->'params'->'in'->>'value')::numeric <> 0
     OR (v->'card_lines'->0->'params'->'out'->>'value')::numeric <> 200
     OR (v->'card_lines'->0->'params'->'date'->>'value')::date <> t + 2
     OR (a->>'account_id')::int <> v_kid OR a->>'state' <> 'alert' OR (a->>'monthly_gap')::numeric <> 200
     OR (a->>'runs_out_on')::date <> t + 2 OR NOT (a->>'asked')::boolean
     OR v->'savings_funding'->>'note' NOT LIKE '%ASK the user%' OR v->'savings_funding'->>'note' NOT LIKE '%200.00 EUR%' THEN
    RAISE EXCEPTION 'FAIL [a] Luecke -> Karte + Frage, got %', v; END IF;
  RAISE NOTICE 'PASS [a] Luecke: Kartenzeile + Frage mit Fehlbetrag';

  -- [b] zweiter Aufruf: Latch steht -> Kartenzeile ja, keine Frage mehr
  v := finance.fn_savings_funding_fold(ARRAY[v_kid], true);
  IF v->'card_lines'->0->>'value' <> 'finance.note.funding_gap' OR v ? 'savings_funding' THEN
    RAISE EXCEPTION 'FAIL [b] Latch: keine zweite Frage, got %', v; END IF;
  RAISE NOTICE 'PASS [b] Frage nur einmal je Konto';

  -- [c] Zubringer 200 vom Giro aufs Kind-Konto -> Bericht (ask=false): gedeckt; Giro ist kein Deckungs-Konto -> keine Zeile
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('sf Zubr Kind', v_giro, v_kid, -200, 'month', t + 1, t + 1);
  v := finance.fn_savings_funding_fold(ARRAY[v_giro, v_kid], false, false, ARRAY[v_kid]);
  a := v->'savings_funding'->'accounts'->0;
  IF jsonb_array_length(v->'card_lines') <> 1 OR v->'card_lines'->0->>'value' <> 'finance.note.funding_ok'
     OR (v->'card_lines'->0->'params'->'in'->>'value')::numeric <> 200
     OR (a->>'account_id')::int <> v_kid OR a->>'state' <> 'ok' OR (a->>'monthly_gap')::numeric <> 0 OR (a->>'asked')::boolean
     OR v->'savings_funding'->>'note' LIKE '%ASK%' OR v->'savings_funding'->>'note' NOT LIKE '%covered%' THEN
    RAISE EXCEPTION 'FAIL [c] Zubringer -> gedeckt, got %', v; END IF;
  RAISE NOTICE 'PASS [c] Zubringer-Bericht: gedeckt, Quellkonto ohne Zeile';
  -- [c2] „gedeckt" ohne p_report_ok (z. B. eine Abbuchung, die die Deckung nicht bricht) -> Kartenzeile, aber keine Note
  v := finance.fn_savings_funding_fold(ARRAY[v_kid], false);
  IF v->'card_lines'->0->>'value' <> 'finance.note.funding_ok' OR v ? 'savings_funding' THEN
    RAISE EXCEPTION 'FAIL [c2] gedeckt ohne Bericht, got %', v; END IF;
  RAISE NOTICE 'PASS [c2] gedeckt meldet nur fuer Geldeingaenge';

  -- [d] neue Lage: ein weiterer Plan verschiebt das „reicht bis"-Datum -> neuer Latch-Schluessel, fragt wieder
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('sf Plan Kind 2', v_kid, -100, 'month', t + 3, t + 3) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('sf Plan Kind 2', v_depot, 'SFK2', 'Welt ETF', v_rp);
  v := finance.fn_savings_funding_fold(ARRAY[v_kid], true);
  a := v->'savings_funding'->'accounts'->0;
  IF a->>'state' NOT IN ('warn', 'alert') OR (a->>'monthly_gap')::numeric <> 100 OR NOT (a->>'asked')::boolean THEN
    RAISE EXCEPTION 'FAIL [d] Re-Arm nach ok, got %', v; END IF;
  RAISE NOTICE 'PASS [d] nach „gedeckt" fragt ein neuer Plan wieder';

  -- [e] Abbau 40/Monat bei 3000 -> ok ueber den Horizont: Zeile ok_drain (baut 40 ab, Tief 2040), keine Frage
  v := finance.fn_savings_funding_fold(ARRAY[v_drain], true);
  IF v->'card_lines'->0->>'value' <> 'finance.note.funding_ok_drain'
     OR (v->'card_lines'->0->'params'->'drain'->>'value')::numeric <> 40
     OR (v->'card_lines'->0->'params'->'min'->>'value')::numeric <> 2040 OR v ? 'savings_funding' THEN
    RAISE EXCEPTION 'FAIL [e] Abbau ok, got %', v; END IF;
  RAISE NOTICE 'PASS [e] gewollter Abbau im Horizont: ok, keine Frage';

  -- [f] Zeitpunkt: rein = raus (500), Zubringer t+20 nach der Abbuchung t+2 bei 100 Stand -> alert, Fehlbetrag 0
  v := finance.fn_savings_funding_fold(ARRAY[v_late], true);
  a := v->'savings_funding'->'accounts'->0;
  IF v->'card_lines'->0->>'value' <> 'finance.note.funding_timing' OR a->>'state' <> 'alert'
     OR (a->>'monthly_gap')::numeric <> 0 OR (a->>'min_projected')::numeric <> -400
     OR v->'savings_funding'->>'note' NOT LIKE '%after the debits%' OR v->'savings_funding'->>'note' LIKE '%ASK the user where%' THEN
    RAISE EXCEPTION 'FAIL [f] Zeitpunkt-Variante, got %', v; END IF;
  RAISE NOTICE 'PASS [f] Zeitpunkt: Eingang nach der Abbuchung, kein Fehlbetrag';

  -- [g] Ausgabenkonto mit Auszug (netto -10 je Tag): Fehlbetrag = 300 + 10 * 30.4375 = 604.38, Note nennt Alltagsausgaben
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_spend, t - 64, t - 35, 1300, 1000, 'EUR', 5, 0, -400, 100, NULL);
  v := finance.fn_savings_funding_fold(ARRAY[v_spend], true);
  a := v->'savings_funding'->'accounts'->0;
  IF a->>'state' NOT IN ('warn', 'alert') OR (a->>'monthly_gap')::numeric <> 604.38
     OR v->'savings_funding'->>'note' NOT LIKE '%everyday%' THEN
    RAISE EXCEPTION 'FAIL [g] Fehlbetrag mit Alltagsausgaben, got %', v; END IF;
  RAISE NOTICE 'PASS [g] Alltagsausgaben im Fehlbetrag';

  -- [h] neutral (Ziel ohne Kurs) -> nichts; kein Deckungs-Konto (Giro) -> nichts
  IF finance.fn_savings_funding_fold(ARRAY[v_chf], true) <> '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [h] neutral'; END IF;
  v := finance.fn_savings_funding_fold(ARRAY[v_giro], true);
  IF v <> '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [h2] kein Deckungs-Konto -> {}, got %', v; END IF;
  RAISE NOTICE 'PASS [h] neutral / kein Deckungs-Konto -> nichts';

  -- [h3] Lage auf einem Weg ohne Fold geaendert (Einmal-Einzahlung, wie ein per set_recurring_payment erhoehter
  --      Zubringer): neues „reicht bis"-Datum -> der naechste Sparplan-Write fragt wieder, ohne Re-Arm-Pfad
  v := finance.fn_savings_funding_fold(ARRAY[v_kid], true);
  IF (v->'savings_funding'->'accounts'->0->>'asked')::boolean THEN
    RAISE EXCEPTION 'FAIL [h3] gleiche Lage fragt doppelt, got %', v; END IF;
  -- +100 bei 100/Monat Fehlbetrag: die Luecke kommt einen Monat spaeter
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_kid, 100, t, 'other');
  v := finance.fn_savings_funding_fold(ARRAY[v_kid], true);
  IF NOT (v->'savings_funding'->'accounts'->0->>'asked')::boolean THEN
    RAISE EXCEPTION 'FAIL [h3] neue Lage fragt nicht, got %', v; END IF;
  RAISE NOTICE 'PASS [h3] Latch je Lage: gleiche Lage still, geaenderte Lage fragt wieder';

  -- [i] state_only (kuenftige Ratenaenderung): Zeile ohne rein/raus, Frage ohne Betraege
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('sf Plan Zukunft', v_fut, -400, 'month', t + 2, t + 2) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('sf Plan Zukunft', v_depot, 'SFZ', 'Welt ETF', v_rp);
  v := finance.fn_savings_funding_fold(ARRAY[v_fut], true, true);
  IF v->'card_lines'->0->>'value' NOT IN ('finance.note.funding_until_date', 'finance.note.funding_gap_date')
     OR v->'card_lines'->0->'params' ? 'in' OR v->'savings_funding'->>'note' NOT LIKE '%ASK the user%'
     OR v->'savings_funding'->>'note' LIKE '%EUR a month%' THEN
    RAISE EXCEPTION 'FAIL [i] state_only, got %', v; END IF;
  RAISE NOTICE 'PASS [i] kuenftige Aenderung: nur Zustand + Datum';

  -- [j] Probelauf rollt den Latch mit zurueck (Savepoint wie core.fn_dry_run) -> der echte Write fragt
  DELETE FROM core.notification_state WHERE source = 'finance' AND key LIKE 'savings_funding:' || v_late || ':%';
  BEGIN
    PERFORM finance.fn_savings_funding_fold(ARRAY[v_late], true);
    RAISE EXCEPTION USING ERRCODE = 'LA001';
  EXCEPTION WHEN SQLSTATE 'LA001' THEN NULL;
  END;
  v := finance.fn_savings_funding_fold(ARRAY[v_late], true);
  IF NOT (v->'savings_funding'->'accounts'->0->>'asked')::boolean THEN
    RAISE EXCEPTION 'FAIL [j] Probelauf verbraucht den Latch, got %', v; END IF;
  RAISE NOTICE 'PASS [j] Probelauf verbraucht den Latch nicht';

  -- [m] fn_merge_fold: eigene Kartenzeilen bleiben vorn, Fold-Zeilen dahinter, uebrige Fold-Schluessel angehaengt;
  --     card_lines als JSON null / fehlend zaehlt als leer
  v := finance.fn_merge_fold('{"ok":true,"card_lines":[{"value":"own"}]}'::jsonb,
                             '{"card_lines":[{"value":"fold"}],"savings_funding":{"note":"n"}}'::jsonb);
  IF v->'card_lines' <> '[{"value":"own"},{"value":"fold"}]'::jsonb OR v->'savings_funding'->>'note' <> 'n'
     OR NOT (v->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [m] zusammenfuegen, got %', v; END IF;
  v := finance.fn_merge_fold('{"ok":true,"card_lines":null}'::jsonb, '{"card_lines":[{"value":"fold"}]}'::jsonb);
  IF v->'card_lines' <> '[{"value":"fold"}]'::jsonb THEN RAISE EXCEPTION 'FAIL [m2] null-Zeilen, got %', v; END IF;
  v := finance.fn_merge_fold('{"ok":true}'::jsonb, '{}'::jsonb);
  IF v <> '{"ok":true}'::jsonb THEN RAISE EXCEPTION 'FAIL [m3] leerer Fold, got %', v; END IF;
  RAISE NOTICE 'PASS [m] fn_merge_fold fuegt card_lines zusammen statt sie zu ersetzen';
END $$;
ROLLBACK;
