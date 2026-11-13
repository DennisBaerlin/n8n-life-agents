-- tests/db/finance/test_fn_bank_setup_kind.sql
-- Bank-Hinweis: welche Kette muss der Nutzer selbst bei Bank/Broker einrichten (fn_bank_setup_kind), welcher Text-Key
--   und welcher Institutsname gehoeren zur Notiz (fn_bank_setup_note), und lief eine Kette noch nie (fn_recurring_never_ran).
--   Werte erfunden.
BEGIN;
DO $$
DECLARE
  v_cash INT; v_cash2 INT; v_nob INT; v_p2p INT; v_depot INT;
  v_rp_so INT; v_rp_man INT; v_rp_bank INT; v_rp_p2p INT; v_rp_debit INT; v_rp_in INT; v_rp_plan INT; v_rp_nob INT;
  v_rp_split INT; v_rp_route INT;
  v_n jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status, bank) VALUES ('__t_bs_cash__','cash','EUR','active','Lindenbank') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_bs_cash2__','cash','EUR','active') RETURNING id INTO v_cash2;
  INSERT INTO finance.accounts (name, account_type, currency, status, bank) VALUES ('__t_bs_nob__','cash','EUR','active','  ') RETURNING id INTO v_nob;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_bs_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, bank)
    VALUES ('__t_bs_depot__','stocks_depot','EUR','active', v_cash2, 'Testbroker') RETURNING id INTO v_depot;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_so__', v_cash, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_so;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, executed_by)
    VALUES ('__t_bs_man__', v_cash, v_cash2, -100, 'month', current_date + 1, current_date + 1, 'manual') RETURNING id INTO v_rp_man;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, executed_by)
    VALUES ('__t_bs_bank__', v_cash, v_cash2, -100, 'month', current_date + 1, current_date + 1, 'bank') RETURNING id INTO v_rp_bank;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_p2p__', v_p2p, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_p2p;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_debit__', v_cash, -30, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_debit;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_in__', v_cash, 2000, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_in;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_plan__', v_cash2, -50, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_plan;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__t_bs_plan__', v_depot, 'TST', 'Test ETF', v_rp_plan);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_nob__', v_nob, v_cash2, -100, 'month', current_date + 1, current_date + 1) RETURNING id INTO v_rp_nob;

  -- [1] Kind je Fall: Uebertrag vom Geld-Konto (unknown) -> standing_order; manual/bank/P2P -> NULL; Lastschrift,
  --     Eingang -> NULL; Sparplan -> savings_plan; unbekannte id -> NULL
  IF finance.fn_bank_setup_kind(v_rp_so)    IS DISTINCT FROM 'standing_order'
     OR finance.fn_bank_setup_kind(v_rp_man)   IS NOT NULL
     OR finance.fn_bank_setup_kind(v_rp_bank)  IS NOT NULL
     OR finance.fn_bank_setup_kind(v_rp_p2p)   IS NOT NULL
     OR finance.fn_bank_setup_kind(v_rp_debit) IS NOT NULL
     OR finance.fn_bank_setup_kind(v_rp_in)    IS NOT NULL
     OR finance.fn_bank_setup_kind(v_rp_plan)  IS DISTINCT FROM 'savings_plan'
     OR finance.fn_bank_setup_kind(-1)         IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1] kind: so=% man=% bank=% p2p=% debit=% in=% plan=% unbekannt=%',
      finance.fn_bank_setup_kind(v_rp_so), finance.fn_bank_setup_kind(v_rp_man), finance.fn_bank_setup_kind(v_rp_bank),
      finance.fn_bank_setup_kind(v_rp_p2p), finance.fn_bank_setup_kind(v_rp_debit), finance.fn_bank_setup_kind(v_rp_in),
      finance.fn_bank_setup_kind(v_rp_plan), finance.fn_bank_setup_kind(-1); END IF;
  RAISE NOTICE 'PASS [1] kind je Fall';

  -- [2] Split-Glied: der Vorgaenger antwortet wie der Kopf (Sparplan zeigt auf den Kopf)
  v_rp_split := (finance.fn_split_recurring_payment(v_rp_plan, current_date + 40, -60, NULL, NULL, NULL, NULL, NULL, NULL)
                 ->>'recurring_payment_id')::int;
  IF v_rp_split IS NULL THEN RAISE EXCEPTION 'FAIL [2] Split ohne neue Zeile'; END IF;
  IF finance.fn_bank_setup_kind(v_rp_plan) IS DISTINCT FROM 'savings_plan'
     OR finance.fn_bank_setup_kind(v_rp_split) IS DISTINCT FROM 'savings_plan' THEN
    RAISE EXCEPTION 'FAIL [2] Split: alt=% neu=%', finance.fn_bank_setup_kind(v_rp_plan), finance.fn_bank_setup_kind(v_rp_split); END IF;
  RAISE NOTICE 'PASS [2] Split-Glied antwortet wie der Kopf';

  -- [3] Notiz: Dauerauftrag mit Bank der Quelle, Sparplan mit Bank des Depots, leerer Name -> _generic ohne bank
  v_n := finance.fn_bank_setup_note(v_rp_so, 'statement_never_seen');
  IF jsonb_array_length(v_n) <> 1 OR v_n->0->>'kind' <> 'note'
     OR v_n->0->>'value' <> 'finance.note.statement_never_seen_standing_order'
     OR v_n->0->'params'->>'bank' IS DISTINCT FROM 'Lindenbank' THEN
    RAISE EXCEPTION 'FAIL [3a] Notiz Dauerauftrag: %', v_n; END IF;
  v_n := finance.fn_bank_setup_note(v_rp_plan, 'statement_never_seen');
  IF v_n->0->>'value' <> 'finance.note.statement_never_seen_savings_plan' OR v_n->0->'params'->>'bank' IS DISTINCT FROM 'Testbroker' THEN
    RAISE EXCEPTION 'FAIL [3b] Notiz Sparplan: %', v_n; END IF;
  v_n := finance.fn_bank_setup_note(v_rp_nob, 'statement_never_seen', '{"name":"X"}'::jsonb);
  IF v_n->0->>'value' <> 'finance.note.statement_never_seen_standing_order_generic' OR v_n->0->'params' ? 'bank'
     OR v_n->0->'params'->>'name' IS DISTINCT FROM 'X' THEN
    RAISE EXCEPTION 'FAIL [3c] Notiz ohne Bankname: %', v_n; END IF;
  IF finance.fn_bank_setup_note(v_rp_man, 'statement_never_seen') <> '[]'::jsonb
     OR finance.fn_bank_setup_note(v_rp_debit, 'statement_never_seen') <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3d] kein Hinweis bei manual/Lastschrift'; END IF;
  RAISE NOTICE 'PASS [3] Notiz: Institut beim Namen, sonst _generic, sonst keine';

  -- [4] never_ran: frisch -> true; eine Buchung an einem Glied der Kette -> false
  IF finance.fn_recurring_never_ran(v_rp_so) IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4a] frische Kette lief schon?'; END IF;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
    VALUES (v_cash2, -50, current_date, 'other', v_rp_plan, '__t_bs_tx__');
  IF finance.fn_recurring_never_ran(v_rp_split) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4b] Buchung am Vorgaenger zaehlt nicht'; END IF;
  RAISE NOTICE 'PASS [4] never_ran ueber die ganze Kette';

  -- [5] never_ran: eine andere Kette derselben Strecke (Quelle -> Ziel) lief schon -> false (Ersatz-Dauerauftrag)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_bs_route__', v_cash, v_cash2, -80, 'month', current_date - 60, current_date - 60) RETURNING id INTO v_rp_route;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
    VALUES (v_cash, -80, current_date - 30, 'other', v_rp_route, '__t_bs_tx2__');
  IF finance.fn_recurring_never_ran(v_rp_so) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5] gebuchte Strecke zaehlt nicht'; END IF;
  IF finance.fn_recurring_never_ran(v_rp_nob) IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5b] andere Quelle zaehlt mit'; END IF;
  RAISE NOTICE 'PASS [5] gebuchte Strecke gilt als gelaufen';

  -- [6] Mit Ende nennt die Notiz die letzte Ausfuehrung (_until + typisiertes Datum); bank_stop nur, solange sie kommt
  UPDATE finance.recurring_payments SET valid_to = current_date + 40 WHERE id IN (v_rp_so, v_rp_nob, v_rp_plan);
  UPDATE finance.recurring_payments SET valid_to = current_date + 80 WHERE id = v_rp_split;
  v_n := finance.fn_bank_setup_note(v_rp_so, 'bank_setup');
  IF v_n->0->>'value' <> 'finance.note.bank_setup_standing_order_until' OR v_n->0->'params'->>'bank' <> 'Lindenbank'
     OR v_n->0->'params'->'date'->>'kind' <> 'date'
     OR (v_n->0->'params'->'date'->>'value')::date <> finance.fn_recurring_last_due(v_rp_so) THEN
    RAISE EXCEPTION 'FAIL [6] bank_setup mit Ende: %', v_n; END IF;
  v_n := finance.fn_bank_setup_note(v_rp_nob, 'bank_stop');
  IF v_n->0->>'value' <> 'finance.note.bank_stop_standing_order_until_generic' THEN RAISE EXCEPTION 'FAIL [6] bank_stop kuenftig: %', v_n; END IF;
  v_n := finance.fn_bank_setup_note(v_rp_plan, 'bank_setup');
  IF v_n->0->>'value' <> 'finance.note.bank_setup_savings_plan_until' THEN RAISE EXCEPTION 'FAIL [6] Sparplan: %', v_n; END IF;
  UPDATE finance.recurring_payments SET valid_from = current_date - 40, first_payment_date = current_date - 40, valid_to = current_date WHERE id = v_rp_nob;
  v_n := finance.fn_bank_setup_note(v_rp_nob, 'bank_stop');
  IF v_n->0->>'value' <> 'finance.note.bank_stop_standing_order_generic' OR v_n->0->'params' ? 'date' THEN
    RAISE EXCEPTION 'FAIL [6] bank_stop vergangen: %', v_n; END IF;
  -- Pausieren mit kuenftigem Ende: Der Auftrag soll jetzt stoppen, nicht bis zum alten Ende laufen -> kein _until
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_rp_so;
  v_n := finance.fn_bank_setup_note(v_rp_so, 'bank_stop');
  IF v_n->0->>'value' <> 'finance.note.bank_stop_standing_order' OR v_n->0->'params' ? 'date' THEN
    RAISE EXCEPTION 'FAIL [6] bank_stop pausiert: %', v_n; END IF;
  RAISE NOTICE 'PASS [6] letzte Ausfuehrung in der Notiz';
END $$;
ROLLBACK;
