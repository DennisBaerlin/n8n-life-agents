-- tests/db/finance/test_fn_recurring_lineage.sql
-- Audit Paket 2 (A0): Vorgaenger-Kette der recurring_payments.
--   * Split stempelt predecessor_id, Besitzer (Kredit) zeigen danach auf den KOPF (vorher blieb der Kredit auf der
--     alten rp -> die Erinnerung erkannte die neue Rate nicht als Kreditrate).
--   * fn_recurring_lineage liefert alle Glieder (beide Richtungen), fn_recurring_lineage_head den Kopf.
--   * ein altes Vorkommen der Vorgaengerin bucht weiter als Kreditrate (Tilgung) und stempelt SEINE rp.
--   * Resolver: ein abgeloestes Glied (mit Nachfolger) ist kein Kandidat mehr -> Name eindeutig.
--   * DB-Gesetz: hoechstens ein Nachfolger (partieller UNIQUE), kein Mittelglied loeschbar (FK).
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_giro  INT;
  v_loan  INT;
  v_lacc  INT;
  v_rp1   INT;
  v_rp2   INT;
  v_due   DATE := CURRENT_DATE + 3;
  v_ids   INT[];
  v_cnt   INT;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_lin_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_lin_kredit__','lender','B','borrower','T',
    'original_amount',200000,'current_balance',200000,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',3.6,
    'monthly_annuity',1000,'first_payment_date',v_due::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp1 FROM finance.loans WHERE id = v_loan;

  -- Split der Kreditrate ab +40 Tagen (Rate 1100) direkt ueber den gemeinsamen Split-Helfer (das standalone
  -- set-Tool lehnt entitaets-besessene rps ab; die Kopf-Regel gilt fuer jeden Split-Konsumenten generisch).
  SELECT finance.fn_split_recurring_payment(v_rp1, CURRENT_DATE + 40, -1100, NULL, NULL, NULL, NULL, NULL, NULL) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL split: %', v_res; END IF;
  v_rp2 := (v_res->>'recurring_payment_id')::int;

  -- 1. predecessor_id gestempelt
  IF (SELECT predecessor_id FROM finance.recurring_payments WHERE id = v_rp2) IS DISTINCT FROM v_rp1 THEN
    RAISE EXCEPTION 'FAIL lineage [predecessor_id]: erwartet %, got %', v_rp1,
      (SELECT predecessor_id FROM finance.recurring_payments WHERE id = v_rp2); END IF;
  RAISE NOTICE 'PASS lineage [Split stempelt predecessor_id]';

  -- 2. Kopf-Regel: der Kredit zeigt auf die neue rp
  IF (SELECT recurring_payment_id FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM v_rp2 THEN
    RAISE EXCEPTION 'FAIL lineage [Kopf-Regel Kredit]: loans.recurring_payment_id=% erwartet %',
      (SELECT recurring_payment_id FROM finance.loans WHERE id = v_loan), v_rp2; END IF;
  RAISE NOTICE 'PASS lineage [Kredit zeigt nach Split auf den Kopf]';

  -- 3. Kette lesen (beide Richtungen) + Kopf
  SELECT array_agg(x ORDER BY x) INTO v_ids FROM finance.fn_recurring_lineage(v_rp1) x;
  IF v_ids IS DISTINCT FROM ARRAY[LEAST(v_rp1, v_rp2), GREATEST(v_rp1, v_rp2)] THEN
    RAISE EXCEPTION 'FAIL lineage [fn_recurring_lineage(alt)]: got %', v_ids; END IF;
  SELECT array_agg(x ORDER BY x) INTO v_ids FROM finance.fn_recurring_lineage(v_rp2) x;
  IF v_ids IS DISTINCT FROM ARRAY[LEAST(v_rp1, v_rp2), GREATEST(v_rp1, v_rp2)] THEN
    RAISE EXCEPTION 'FAIL lineage [fn_recurring_lineage(neu)]: got %', v_ids; END IF;
  IF finance.fn_recurring_lineage_head(v_rp1) IS DISTINCT FROM v_rp2
     OR finance.fn_recurring_lineage_head(v_rp2) IS DISTINCT FROM v_rp2 THEN
    RAISE EXCEPTION 'FAIL lineage [head]: head(alt)=% head(neu)=%',
      finance.fn_recurring_lineage_head(v_rp1), finance.fn_recurring_lineage_head(v_rp2); END IF;
  IF finance.fn_recurring_lineage_head(-1) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL lineage [head unbekannt]: erwartet NULL'; END IF;
  RAISE NOTICE 'PASS lineage [Kette beide Richtungen + Kopf]';

  -- 4. Altes Vorkommen (+3, Rate 1000 auf rp1) bucht als Kreditrate: Restschuld sinkt, Stempel = rp1.
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp1,
    'due_date', v_due::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL lineage [altes Vorkommen buchen]: %', v_res; END IF;
  IF finance.fn_get_balance(v_lacc) IS DISTINCT FROM -199600.00 OR finance.fn_get_balance(v_giro) IS DISTINCT FROM -1000.00 THEN
    RAISE EXCEPTION 'FAIL lineage [altes Vorkommen = Kreditrate]: Kreditkonto=% Giro=% (erwartet -199600/-1000)',
      finance.fn_get_balance(v_lacc), finance.fn_get_balance(v_giro); END IF;
  IF (SELECT recurring_payment_id FROM finance.transactions WHERE id = (v_res->>'transaction_id')::int) IS DISTINCT FROM v_rp1 THEN
    RAISE EXCEPTION 'FAIL lineage [Stempel]: erwartet rp %', v_rp1; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_due) o WHERE o.recurring_payment_id = v_rp1 AND o.due_date = v_due) THEN
    RAISE EXCEPTION 'FAIL lineage [Vorkommen geschlossen]: % noch offen', v_due; END IF;
  -- Doppel-Pruefung ueber die Kette: dasselbe Vorkommen noch einmal -> ok:false
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp1,
    'due_date', v_due::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL lineage [doppelt]: %', v_res; END IF;
  RAISE NOTICE 'PASS lineage [altes Vorkommen bucht als Kreditrate, stempelt seine rp, kein Doppel]';

  -- 5. Resolver: das abgeloeste Glied ist kein Kandidat -> der Name ist eindeutig (der Kopf)
  SELECT hit_count INTO v_cnt FROM finance.fn_resolve_recurring_payment('__test_lin_kredit__', FALSE);
  IF (SELECT id FROM finance.fn_resolve_recurring_payment((SELECT name FROM finance.recurring_payments WHERE id = v_rp2), FALSE))
     IS DISTINCT FROM v_rp2 THEN
    RAISE EXCEPTION 'FAIL lineage [Resolver]: erwartet Kopf %, got %', v_rp2,
      (SELECT candidates FROM finance.fn_resolve_recurring_payment((SELECT name FROM finance.recurring_payments WHERE id = v_rp2), FALSE)); END IF;
  RAISE NOTICE 'PASS lineage [Resolver loest auf den Kopf auf]';

  -- 6. DB-Gesetz: zweiter Nachfolger derselben rp -> unique_violation; Mittelglied loeschen -> FK-Fehler
  BEGIN
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('__test_lin_dup__', v_giro, -1, 'month', CURRENT_DATE, CURRENT_DATE, v_rp1);
    RAISE EXCEPTION 'FAIL lineage [UNIQUE]: zweiter Nachfolger akzeptiert';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    DELETE FROM finance.recurring_payment_skips WHERE recurring_payment_id = v_rp1;
    DELETE FROM finance.transactions WHERE recurring_payment_id = v_rp1;
    DELETE FROM finance.recurring_payments WHERE id = v_rp1;
    RAISE EXCEPTION 'FAIL lineage [FK]: Mittelglied geloescht';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS lineage [UNIQUE ein Nachfolger + FK schuetzt die Kette]';
END $$;

ROLLBACK;
