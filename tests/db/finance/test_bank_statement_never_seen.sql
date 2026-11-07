-- tests/db/finance/test_bank_statement_never_seen.sql
-- Monats-Check, erstes Fehlen: ein neuer Dauerauftrag/Sparplan, der noch nie lief und noch nie von einem Auszug
--   uebersprungen wurde, traegt in missing[] never_seen:true; die Karte fragt je Kette einmal, ob er bei der Bank
--   eingerichtet ist (Institut beim Namen, sonst _generic). Nicht bei Lastschriften, nicht bei einer Kette, die schon
--   gebucht wurde, nicht beim zweiten Auszug nach dem Skip. Das Ziel-Konto eines Uebertrags zeigt die Frage auch, wenn
--   sein Auszug zuerst kommt. Werte erfunden.
BEGIN;

DO $$
DECLARE
  ps DATE := date_trunc('month', CURRENT_DATE - 60)::date;
  pe DATE := (date_trunc('month', CURRENT_DATE - 60) + interval '1 month - 1 day')::date;
  ps2 DATE := date_trunc('month', CURRENT_DATE - 30)::date;
  pe2 DATE := (date_trunc('month', CURRENT_DATE - 30) + interval '1 month - 1 day')::date;
  v_giro INT; v_tg INT; v_tg2 INT; r_new INT; r_old INT; r_handy INT;
  v_res JSONB; v_prep JSONB; v_stmt JSONB; v_notes JSONB;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__t_ns_giro__","account_type":"cash","currency":"EUR","account_number":"DE11520513735120710131"}'::jsonb)->>'account_id')::int;
  v_tg   := (finance.fn_create_account('{"name":"__t_ns_tg__","account_type":"cash","currency":"EUR","account_number":"DE81520513735120710132"}'::jsonb)->>'account_id')::int;
  v_tg2  := (finance.fn_create_account('{"name":"__t_ns_tg2__","account_type":"cash","currency":"EUR","account_number":"DE81520513735120710133"}'::jsonb)->>'account_id')::int;
  UPDATE finance.accounts SET bank = 'Lindenbank' WHERE id = v_giro;

  -- neu: alle zwei Wochen ab ps+1 (zwei Termine im Zeitraum, beide fehlen), nie gelaufen
  r_new := finance.fn_add_recurring_payment(v_giro, -200, '__t_ns_neu__', 2::smallint, 'week'::finance.schedule_unit, NULL::smallint,
             ps + 1, ps + 1, NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_tg WHERE id = r_new;
  -- alt: lief im Vormonat schon (gebucht), fehlt jetzt
  r_old := finance.fn_add_recurring_payment(v_giro, -50, '__t_ns_alt__', 1::smallint, 'month'::finance.schedule_unit, 5::smallint,
             (ps - interval '1 month')::date, (ps - interval '1 month')::date, NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_tg2 WHERE id = r_old;
  -- Lastschrift: richtet der Glaeubiger ein
  r_handy := finance.fn_add_recurring_payment(v_giro, -25, '__t_ns_handy__', 1::smallint, 'month'::finance.schedule_unit, 12::smallint,
             ps, ps, NULL, NULL, NULL);
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', r_old,
             'due_date', (ps - interval '1 month' + interval '4 days')::date));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP alt gebucht: %', v_res; END IF;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 1050, ps - 40, 'other');
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_giro, 'confirmed_balance', 1000,
             'reconciliation_date', (ps - 1)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP reconcile: %', v_res; END IF;

  -- [1] Ziel-Konto zuerst: dessen Auszug ohne Zeilen fragt schon nach dem neuen Uebertrag
  v_prep := finance.fn_statement_prepare(jsonb_build_object('account_number', 'DE81520513735120710132', 'currency', 'EUR',
              'period_start', ps, 'period_end', pe, 'opening_balance', 0, 'closing_balance', 0, 'lines', '[]'::jsonb));
  IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1] prepare Ziel-Konto: %', v_prep; END IF;
  SELECT jsonb_agg(c) INTO v_notes FROM jsonb_array_elements(v_prep->'card_lines') c
   WHERE c->>'value' LIKE 'finance.note.statement_never_seen%';
  IF jsonb_array_length(COALESCE(v_notes, '[]')) <> 1
     OR v_notes->0->>'value' <> 'finance.note.statement_never_seen_standing_order' THEN
    RAISE EXCEPTION 'FAIL [1] Frage auf dem Ziel-Konto: %', v_prep->'card_lines'; END IF;
  RAISE NOTICE 'PASS [1] Auszug des Ziel-Kontos zuerst: Frage dort';

  -- [2] Quell-Konto: zwei fehlende Termine der neuen Kette -> beide never_seen, EINE Frage mit Bank und Name;
  --     die gelaufene Kette und die Lastschrift fehlen ohne never_seen
  v_stmt := jsonb_build_object('account_number', 'DE11520513735120710131', 'currency', 'EUR',
              'period_start', ps, 'period_end', pe, 'opening_balance', 1000, 'closing_balance', 1000, 'lines', '[]'::jsonb);
  v_prep := finance.fn_statement_prepare(v_stmt);
  IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2] prepare: %', v_prep; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_prep->'missing') x
       WHERE (x->>'recurring_payment_id')::int = r_new AND (x->>'never_seen')::boolean) <> 2 THEN
    RAISE EXCEPTION 'FAIL [2a] neue Kette nicht zweimal never_seen: %', v_prep->'missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r_old)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r_handy)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x
                 WHERE (x->>'recurring_payment_id')::int IN (r_old, r_handy) AND x ? 'never_seen') THEN
    RAISE EXCEPTION 'FAIL [2b] alt/Lastschrift: %', v_prep->'missing'; END IF;
  SELECT jsonb_agg(c) INTO v_notes FROM jsonb_array_elements(v_prep->'card_lines') c
   WHERE c->>'value' LIKE 'finance.note.statement_never_seen%';
  IF jsonb_array_length(COALESCE(v_notes, '[]')) <> 1
     OR v_notes->0->>'value' <> 'finance.note.statement_never_seen_standing_order'
     OR v_notes->0->'params'->>'bank' IS DISTINCT FROM 'Lindenbank'
     OR v_notes->0->'params'->>'name' IS DISTINCT FROM '__t_ns_neu__' THEN
    RAISE EXCEPTION 'FAIL [2c] eine Frage mit Bank und Name: %', v_notes; END IF;
  RAISE NOTICE 'PASS [2] erstes Fehlen: never_seen je Termin, eine Frage je Kette; gelaufen/Lastschrift ohne';

  -- [3] ohne Bankname -> _generic
  UPDATE finance.accounts SET bank = NULL WHERE id = v_giro;
  v_prep := finance.fn_statement_prepare(v_stmt);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c
                  WHERE c->>'value' = 'finance.note.statement_never_seen_standing_order_generic') THEN
    RAISE EXCEPTION 'FAIL [3] _generic: %', v_prep->'card_lines'; END IF;
  RAISE NOTICE 'PASS [3] ohne Bankname: _generic';

  -- [4] Auszug buchen (Skips), Folge-Auszug: die neue Kette fehlt wieder, aber ohne never_seen und ohne Frage
  v_res := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4] apply: %', v_res; END IF;
  v_prep := finance.fn_statement_prepare(jsonb_build_object('account_number', 'DE11520513735120710131', 'currency', 'EUR',
              'period_start', ps2, 'period_end', pe2, 'opening_balance', 1000, 'closing_balance', 1000, 'lines', '[]'::jsonb));
  IF (v_prep->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4] prepare 2: %', v_prep; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE (x->>'recurring_payment_id')::int = r_new)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'missing') x WHERE x ? 'never_seen')
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_prep->'card_lines') c WHERE c->>'value' LIKE 'finance.note.statement_never_seen%') THEN
    RAISE EXCEPTION 'FAIL [4] zweiter Auszug: %', v_prep->'missing'; END IF;
  RAISE NOTICE 'PASS [4] nach dem ersten Skip keine Frage mehr';
END $$;
ROLLBACK;
