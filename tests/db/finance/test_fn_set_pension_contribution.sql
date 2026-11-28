-- tests/db/finance/test_fn_set_pension_contribution.sql
-- fn_set_pension: Beitrag aendern (contribution_amount, effective_from, Rhythmus) und ersten Beitrag nachtragen.
-- Jeder Fall laeuft in einem eigenen Savepoint (RS000) und sieht nur das gemeinsame Konto.
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_giro INT; v_depot INT; v_pen INT; v_rp INT; v_head INT; v_n INT := 0;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__spc_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__spc_depot__','account_type','stocks_depot','currency','EUR',
            'settlement_id',v_giro))->>'account_id')::int INTO v_depot;
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id',v_giro,'amount',9000,'direction','inflow','transaction_date',v_t - 120));

  -- C1 Korrektur direkt nach dem Anlegen: in place, kein neues Glied
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t + 10));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',200));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM false
       OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_rp
       OR (v_res->>'contribution_amount')::numeric IS DISTINCT FROM 200
       OR (v_res->>'monthly_contribution')::numeric IS DISTINCT FROM 200
       OR (v_res->>'first_due')::date IS DISTINCT FROM v_t + 10
       OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -200
       OR (SELECT count(*) FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))) <> 1 THEN
      RAISE EXCEPTION 'FAIL C1 Korrektur in place: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C2 mit Historie: neues Glied ab dem naechsten offenen Termin, alter Beitrag bleibt stehen
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_t - 40));
    PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date))
      FROM finance.fn_recurring_due_open(v_t - 1) o WHERE o.recurring_payment_id = v_rp;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',220));
    v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true
       OR (v_res->>'previous_id')::int IS DISTINCT FROM v_rp OR v_head = v_rp
       OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_head
       OR (v_res->>'contribution_amount')::numeric IS DISTINCT FROM 220
       OR (v_res->>'monthly_contribution')::numeric IS DISTINCT FROM 220
       OR (v_res->>'first_due')::date IS DISTINCT FROM (SELECT valid_from FROM finance.recurring_payments WHERE id = v_head)
       OR (v_res->>'first_due')::date < v_t
       OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -150
       OR (SELECT amount FROM finance.recurring_payments WHERE id = v_head) IS DISTINCT FROM -220
       OR (SELECT name FROM finance.recurring_payments WHERE id = v_head) IS DISTINCT FROM 'AV-Beitrag __spc_pen__' THEN
      RAISE EXCEPTION 'FAIL C2 neues Glied: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C3 genannter Stichtag (auch relativ): der neue Beitrag gilt erst ab dort
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',100,'effective_from','in 3 months'));
    v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'first_due')::date < (v_t + interval '3 months')::date
       OR (v_res->>'first_due')::date > (v_t + interval '4 months')::date
       OR (v_res->'effective'->>'effective_from') IS NULL
       OR (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen) IS DISTINCT FROM 150
       OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t - 60, v_t + 200) u
                   WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head))
                     AND u.amount IS DISTINCT FROM (CASE WHEN u.due_date < (v_res->>'first_due')::date THEN -150 ELSE -100 END)) THEN
      RAISE EXCEPTION 'FAIL C3 Stichtag: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C4 gleicher Beitrag = keine Aenderung; C5 Beitrag 0/negativ; C6 Rhythmus ohne Betrag; C8 Konto an bestehender Kette
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',150));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res ? 'split' OR v_res ? 'contribution_amount'
       OR (SELECT count(*) FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))) <> 1 THEN
      RAISE EXCEPTION 'FAIL C4 gleicher Beitrag: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',0));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%paused%' THEN
      RAISE EXCEPTION 'FAIL C5 Beitrag 0: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',-5));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C5 Beitrag negativ: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'schedule_unit','year'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C6 Rhythmus ohne Betrag: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'schedule_unit','fortnight','contribution_amount',10));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C6 unbekannter Rhythmus: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',180,'debit_account_id',v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C8 Konto an bestehender Kette: %', v_res; END IF;
    IF (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -150 THEN
      RAISE EXCEPTION 'FAIL C5-C8: eine Ablehnung hat geschrieben'; END IF;
    -- C11 neuer Rhythmus mit Betrag: Monatswert rechnet die DB
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',1200,'schedule_unit','year'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'monthly_contribution')::numeric IS DISTINCT FROM 100
       OR (v_res->>'contribution_amount')::numeric IS DISTINCT FROM 1200 THEN
      RAISE EXCEPTION 'FAIL C11 Jahresbeitrag: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C7 erster Beitrag an einer Vorsorge ohne Beitrag
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private'));
    v_pen := (v_res->>'pension_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',90,'debit_account_id',v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%effective_from%' THEN
      RAISE EXCEPTION 'FAIL C7 ohne Datum: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',90,'effective_from',v_t + 20));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%account%' THEN
      RAISE EXCEPTION 'FAIL C7 ohne Konto: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',90,'effective_from',v_t + 20,'debit_account_id',v_depot));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C7 Depot als Konto: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'debit_account_id',v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C7 Konto ohne Beitrag: %', v_res; END IF;
    IF (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen) IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL C7: eine Ablehnung hat eine Zahlung angelegt'; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',90,'effective_from',v_t + 20,'debit_account_id',v_giro));
    v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_head IS NULL
       OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_head
       OR (v_res->>'first_due')::date IS DISTINCT FROM v_t + 20
       OR (v_res->>'contribution_amount')::numeric IS DISTINCT FROM 90
       OR (v_res->>'monthly_contribution')::numeric IS DISTINCT FROM 90
       OR (SELECT amount FROM finance.recurring_payments WHERE id = v_head) IS DISTINCT FROM -90
       OR (SELECT account_id FROM finance.recurring_payments WHERE id = v_head) IS DISTINCT FROM v_giro
       OR (SELECT name FROM finance.recurring_payments WHERE id = v_head) IS DISTINCT FROM 'AV-Beitrag __spc_pen__'
       OR (SELECT min(u.due_date) FROM finance.fn_upcoming_payments(v_t - 60, v_t + 200) u WHERE u.recurring_payment_id = v_head) IS DISTINCT FROM v_t + 20 THEN
      RAISE EXCEPTION 'FAIL C7 erster Beitrag: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C9 pausierte Vorsorge: Beitrag abgelehnt; status active + Beitrag im selben Aufruf: erst reaktivieren, dann Beitrag
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_t - 40));
    v_res := finance.fn_close_pension(jsonb_build_object('pension_name','__spc_pen__'));
    IF (v_res->>'action') IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'FAIL C9 setup: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',170));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%active%' THEN
      RAISE EXCEPTION 'FAIL C9 pausiert: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',170,'status','paid_out'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL C9 Beitrag + paid_out: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',170,'status','active'));
    v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_head
       OR (v_res->>'contribution_amount')::numeric IS DISTINCT FROM 170
       OR (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen) IS DISTINCT FROM 170
       OR (SELECT status FROM finance.pension WHERE id = v_pen) IS DISTINCT FROM 'active'
       OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t - 60, v_t + 200) u
                   WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head)) AND (u.due_date < v_t OR u.amount <> -170))
       OR (SELECT count(*) FROM finance.fn_upcoming_payments(v_t, v_t + 100) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head))) < 2 THEN
      RAISE EXCEPTION 'FAIL C9 reaktivieren + Beitrag: % / Glieder %', v_res,
        (SELECT string_agg(amount || ' ' || status || ' [' || valid_from || '..' || coalesce(valid_to::text, '-') || ')', ' | ' ORDER BY valid_from, id)
           FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_head))); END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C12 geplante Aenderung, dann pausieren: kein Glied bleibt faellig; C17 Stichtag vor der geplanten Aenderung abgelehnt;
  -- C13 schliessen nach einer Aenderung: Historie am Vorgaenger zaehlt (Soft-Close, nichts geloescht, nichts mehr faellig)
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_t - 40));
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',300,'effective_from',v_t + 100));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL C12 setup: %', v_res; END IF;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',250,'effective_from',v_t + 45));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'planned_from')::date IS NULL THEN
      RAISE EXCEPTION 'FAIL C17 Stichtag vor geplanter Aenderung: %', v_res; END IF;
    BEGIN
      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'status','paused'));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true
         OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))) THEN
        RAISE EXCEPTION 'FAIL C12 pausiert mit geplanter Aenderung: noch Termine faellig (%)', v_res; END IF;
      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'status','active'));
      IF (SELECT count(*) FROM finance.fn_upcoming_payments(v_t, v_t + 60) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)) AND u.amount = -150) < 1
         OR (SELECT count(*) FROM finance.fn_upcoming_payments(v_t + 100, v_t + 200) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)) AND u.amount = -300) < 2 THEN
        RAISE EXCEPTION 'FAIL C12 wieder aktiv: Termine fehlen (%)', v_res; END IF;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
    v_res := finance.fn_close_pension(jsonb_build_object('pension_name','__spc_pen__'));
    IF (v_res->>'action') IS DISTINCT FROM 'closed' OR (v_res->>'tx_count')::int IS DISTINCT FROM 1
       OR NOT EXISTS (SELECT 1 FROM finance.pension WHERE id = v_pen)
       OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))) THEN
      RAISE EXCEPTION 'FAIL C13 schliessen nach Aenderung: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C13b schliessen ohne jede Buchung nach einer geplanten Aenderung: Vorsorge und alle Glieder weg
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',300,'effective_from',v_t + 100));
    v_res := finance.fn_close_pension(jsonb_build_object('pension_name','__spc_pen__'));
    IF (v_res->>'action') IS DISTINCT FROM 'deleted' OR EXISTS (SELECT 1 FROM finance.pension WHERE id = v_pen)
       OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = 'AV-Beitrag __spc_pen__') THEN
      RAISE EXCEPTION 'FAIL C13b loeschen mit Kette: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C14 geschlossen + active + Beitrag am Abbuchungstag (woechentlich, heute faellig): der neue Beitrag gilt ab heute
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',40,
      'debit_account_id',v_giro,'first_payment_date',v_t - 28,'schedule_unit','week'));
    v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_t - 28));
    PERFORM finance.fn_close_pension(jsonb_build_object('pension_name','__spc_pen__'));
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',55,'status','active'));
    v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'first_due')::date IS DISTINCT FROM v_t
       OR EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t - 60, v_t + 60) u
                   WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_head)) AND (u.due_date < v_t OR u.amount <> -55)) THEN
      RAISE EXCEPTION 'FAIL C14 reaktivieren + Beitrag am Abbuchungstag: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  -- C15 gleicher Betrag, neuer Rhythmus: ist eine Aenderung; C16 erster Beitrag an der gesetzlichen Rente (freiwillig)
  BEGIN
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_pen__','pension_type','private','contribution_amount',150,
      'debit_account_id',v_giro,'first_payment_date',v_t - 40));
    v_pen := (v_res->>'pension_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',150,'schedule_unit','year'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true
       OR (v_res->>'monthly_contribution')::numeric IS DISTINCT FROM 12.5 OR (v_res->>'previous_contribution_amount')::numeric IS DISTINCT FROM 150 THEN
      RAISE EXCEPTION 'FAIL C15 neuer Rhythmus bei gleichem Betrag: %', v_res; END IF;
    v_res := finance.fn_create_pension(jsonb_build_object('name','__spc_stat__','pension_type','statutory'));
    v_pen := (v_res->>'pension_id')::int;
    v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',95,'effective_from',v_t + 15,'debit_account_id',v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'first_due')::date IS DISTINCT FROM v_t + 15 THEN
      RAISE EXCEPTION 'FAIL C16 gesetzliche Rente, erster Beitrag: %', v_res; END IF;
    v_n := v_n + 1;
    RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
  EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
  END;

  IF v_n <> 10 THEN RAISE EXCEPTION 'FAIL set_pension contribution: nur % von 10 Faellen gelaufen', v_n; END IF;
  RAISE NOTICE 'PASS set_pension contribution [% Faelle, C1-C17]', v_n;
END $$;

ROLLBACK;
