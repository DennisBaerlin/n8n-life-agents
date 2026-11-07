-- tests/db/finance/pending_drift_findings.sql
-- PENDING: Drift-Funde (Tool-Description/Golden-Case <-> fn-Vertrag), bewusst ROT und ausserhalb des Gates
-- (db_test sammelt nur test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_drift_*'
-- Fund-Nummern = Karten-IDs im Drift-Bericht (S<Stufe>.<n>, Stand main 8ff7de43). Jeder Fall ruft die fn mit dem
-- Payload, den das Modell laut Description/Golden-Case schickt (Werte erfunden), und prueft das KORREKTE Verhalten.
-- Nach dem Fix den Fall in eine test_*.sql verschieben (dann gruen und im Gate). Eine Transaktion je Fall: ein roter
-- Fall bricht die folgenden sonst ab.

-- (S1.1) Aktienkauf mit Fremdwaehrungs-Kurs. Golden tc46: "5 Apple zu 293 US-Dollar" -> price_per_share=293,
--   quote_currency=USD. fn_book_stock_buy bucht -(5 x 293) = -1465 vom EUR-Verrechnungskonto, ohne Umrechnung.
--   Korrekt: entweder {ok:false} (Kurswaehrung != Kontowaehrung, Nutzer nennt den abgebuchten Betrag) oder ein
--   umgerechneter Betrag (fn_fx_rate) -- jedenfalls NICHT -1465 EUR. Fix-Idee: Guard price_currency_mismatch
--   (Owner-Entscheid umrechnen vs. abgebuchten Betrag erfragen), danach tc46 neu fassen.
BEGIN;
DO $$
DECLARE r jsonb; v_settle int; v_depot int;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__drift_s11_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__drift_s11_depot__','account_type','stocks_depot',
                 'currency','EUR','settlement_id',v_settle))->>'account_id')::int;
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','5','price_per_share','293','order_fee','0','quote_currency','USD'));
  IF (r->>'ok')::boolean AND (r->>'settlement_change')::numeric = -1465 THEN
    RAISE EXCEPTION 'FAIL [S1.1] USD-Kurs ohne Umrechnung vom EUR-Konto abgebucht: settlement_change=% (erwartet ok:false oder umgerechnet), got %',
      r->>'settlement_change', r;
  END IF;
  RAISE NOTICE 'PASS [S1.1]';
END $$;
ROLLBACK;

-- (S1.2) "Wohnung verkauft" ueber tool_set_real_estate status=sold (Description bietet es an, delete_real_estate
--   verweist sogar darauf). fn_set_real_estate setzt nur den Status: kein Erloes, sale_tx_id NULL, Wert unveraendert.
--   Korrekt: {ok:false} mit Hinweis auf tool_sell_real_estate (dort Erloes + Rueckgaengig). Fix-Idee: Guard in
--   fn_set_real_estate fuer status=sold, Descriptions von set_/delete_real_estate auf das Verkaufs-Tool zeigen lassen.
BEGIN;
DO $$
DECLARE r jsonb; v_re int;
BEGIN
  v_re := (finance.fn_create_real_estate('{"name":"__drift_s12_whg__","current_value":"300000"}'::jsonb)->>'real_estate_id')::int;
  r := finance.fn_set_real_estate(jsonb_build_object('real_estate_id',v_re,'status','sold'));
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S1.2] status=sold ohne Verkaufsbuchung angenommen (status=%, sale_tx_id=%), erwartet ok:false -> tool_sell_real_estate, got %',
      (SELECT status FROM finance.real_estate WHERE id = v_re), (SELECT sale_tx_id FROM finance.real_estate WHERE id = v_re), r;
  END IF;
  RAISE NOTICE 'PASS [S1.2]';
END $$;
ROLLBACK;

-- (S1.3) Gesetzliche Rente schliessen loescht alle Standmitteilungen (pension_statements ON DELETE CASCADE).
--   fn_close_pension zaehlt nur Buchungen auf dem Beitrag; die gesetzliche Rente hat keinen -> Hard-DELETE.
--   Korrekt: Standmitteilungen bleiben (Soft-Close wie bei Buchungen) oder {ok:false} mit Rueckfrage.
--   Fix-Idee: Standmitteilungen in die "hat Historie"-Zaehlung aufnehmen; Card-Line mit ihrer Anzahl.
BEGIN;
DO $$
DECLARE r jsonb; v_p int; v_cnt int;
BEGIN
  v_p := (finance.fn_create_pension('{"name":"__drift_s13_drv__","pension_type":"statutory"}'::jsonb)->>'pension_id')::int;
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, projection)
  VALUES (v_p, core.fn_today() - 400, 900, 1800), (v_p, core.fn_today() - 30, 950, 1850);
  r := finance.fn_close_pension('{"pension_name":"__drift_s13_drv__"}'::jsonb);
  SELECT count(*) INTO v_cnt FROM finance.pension_statements WHERE pension_id = v_p;
  IF v_cnt <> 2 THEN
    RAISE EXCEPTION 'FAIL [S1.3] close_pension hat % von 2 Standmitteilungen mitgeloescht (action=%), erwartet Soft-Close oder ok:false, got %',
      2 - v_cnt, r->>'action', r;
  END IF;
  RAISE NOTICE 'PASS [S1.3]';
END $$;
ROLLBACK;

-- (S1.4) Kredit "abbezahlt" ueber tool_set_loan status=paid_off (Description nennt paid_off, kein Verweis auf
--   tool_settle_loan). fn_set_loan setzt nur den Status: Restschuld bleibt am Kreditkonto, keine Abloesebuchung.
--   Korrekt: {ok:false} solange Restschuld > 0, mit Hinweis auf tool_settle_loan. Fix-Idee: Guard in fn_set_loan,
--   paid_off aus der Description.
BEGIN;
DO $$
DECLARE r jsonb; v_debit int; v_loan int; v_acc int; v_bal numeric;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__drift_s14_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_loan(jsonb_build_object('name','__drift_s14_kredit__','lender','Beispielbank','original_amount',50000,
         'disbursement_date','2026-01-01','interest_rate',3.0,'monthly_annuity',900,'schedule_day_of_month',1,
         'first_payment_date','2026-02-01','debit_account_id',v_debit));
  v_loan := (r->>'loan_id')::int;
  r := finance.fn_set_loan(jsonb_build_object('loan_id',v_loan,'status','paid_off'));
  SELECT l.loan_account_id INTO v_acc FROM finance.loans l WHERE l.id = v_loan;
  SELECT balance INTO v_bal FROM finance.account_balances WHERE account_id = v_acc;
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S1.4] status=paid_off bei Restschuld % angenommen (keine Abloesung gebucht), erwartet ok:false -> tool_settle_loan, got %',
      v_bal, r;
  END IF;
  RAISE NOTICE 'PASS [S1.4]';
END $$;
ROLLBACK;

-- (S1.5) Vorsorge-Beitrag mit Jahres-Rhythmus ohne Startdatum (Description: first_payment_date "optional", ohne
--   Folge-Hinweis). fn_create_pension ankert die Beitragskette an CURRENT_DATE -> Tag und Monat von heute.
--   Korrekt: fuer Rhythmus != Monat ohne Datum {ok:false, code missing_required} (wie Versicherung/Kredit).
--   Fix-Idee: Guard + core.fn_today() statt CURRENT_DATE; Description "MUST" wie bei Versicherung.
BEGIN;
DO $$
DECLARE r jsonb; v_acct int; v_first date;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__drift_s15_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_pension(jsonb_build_object('name','__drift_s15_ruerup__','pension_type','ruerup',
         'contribution_amount','1200','schedule_unit','year','debit_account_id',v_acct));
  IF (r->>'ok')::boolean THEN
    SELECT first_payment_date INTO v_first FROM finance.recurring_payments WHERE id = (r->>'recurring_payment_id')::int;
    RAISE EXCEPTION 'FAIL [S1.5] Jahresbeitrag ohne Startdatum auf heute verankert (first_payment_date=%), erwartet ok:false missing_required, got %',
      v_first, r;
  END IF;
  RAISE NOTICE 'PASS [S1.5]';
END $$;
ROLLBACK;

-- (S1.6a) Geldfeld als deutscher Text: Immobilienwert "350.000" (string-typisiertes $fromAI-Feld ohne "plain number").
--   fn_create_real_estate castet NULLIF(...)::numeric -> 350 (Punkt = Dezimaltrenner), Faktor 1.000 zu klein.
--   Korrekt: 350000 (fn_parse_de_numeric) oder {ok:false}. Fix-Idee: ein gemeinsamer Parse-Helfer fuer alle
--   Geldfelder der Write-fns, unlesbar -> {ok:false}.
BEGIN;
DO $$
DECLARE r jsonb; v_cv numeric;
BEGIN
  r := finance.fn_create_real_estate('{"name":"__drift_s16_haus__","current_value":"350.000"}'::jsonb);
  SELECT current_value INTO v_cv FROM finance.real_estate WHERE id = (r->>'real_estate_id')::int;
  IF (r->>'ok')::boolean AND v_cv IS DISTINCT FROM 350000 THEN
    RAISE EXCEPTION 'FAIL [S1.6a] "350.000" als % gespeichert, erwartet 350000 oder ok:false, got %', v_cv, r;
  END IF;
  RAISE NOTICE 'PASS [S1.6a]';
END $$;
ROLLBACK;

-- (S1.6b) Umbuchung "1.234,56" (amount string): fn_book_transfer castet ::numeric -> RAISE (Owner-Alarm statt
--   Rueckfrage). Korrekt: 1234.56 gebucht oder {ok:false}. Fix-Idee wie S1.6a.
BEGIN;
DO $$
DECLARE r jsonb; v_a int; v_b int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__drift_s16_a__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__drift_s16_b__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  BEGIN
    r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_a,'to_account_id',v_b,'amount','1.234,56'));
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'FAIL [S1.6b] amount "1.234,56" -> RAISE (%), erwartet 1234.56 gebucht oder ok:false', SQLERRM;
  END;
  RAISE NOTICE 'PASS [S1.6b] %', r;
END $$;
ROLLBACK;

-- (S1.7) Sparziel schliessen mit unbekanntem outcome (Tippfehler "complete"): v_completed nur bei exakt
--   "completed", alles andere = cancelled (Zuordnungen frei, Rate endet). Korrekt: {ok:false} ueber
--   fn_enum_reason. Fix-Idee: outcome gegen {completed, cancelled} pruefen.
BEGIN;
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__drift_s17_pot__','cash','EUR','active');
DO $$
DECLARE r jsonb; v_acct int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__drift_s17_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_savings_goal(jsonb_build_object('name','__drift_s17_ziel__','target_amount',5000,
         'target_date',(CURRENT_DATE + 365)::text,'monthly_savings_rate',100,
         'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__drift_s17_pot__'),
         'account_id',v_acct,'first_payment_date',CURRENT_DATE::text));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [S1.7] %', r; END IF;
  r := finance.fn_close_savings_goal('{"savings_goal_name":"__drift_s17_ziel__","outcome":"complete"}'::jsonb);
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S1.7] outcome "complete" still als % geschlossen, erwartet ok:false (unbekanntes outcome), got %',
      r->>'status', r;
  END IF;
  RAISE NOTICE 'PASS [S1.7]';
END $$;
ROLLBACK;

-- (S2.2) Dauerueberweisung auf ein Depot ("between TWO of the user's OWN accounts", kein Typ-Ausschluss).
--   fn_create_recurring_transfer prueft fn_bookable_account_reason nicht (fn_create_recurring_payment tut es);
--   erst jede einzelne Ausfuehrung (fn_book_recurring_transfer) lehnt ab. Korrekt: {ok:false} schon beim Anlegen.
--   Fix-Idee: denselben Guard in fn_create_recurring_transfer.
BEGIN;
DO $$
DECLARE r jsonb; v_giro int; v_depot int;
BEGIN
  v_giro  := (finance.fn_create_account('{"name":"__drift_s22_giro__","account_type":"cash","opening_balance":3000}'::jsonb)->>'account_id')::int;
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__drift_s22_depot__','account_type','stocks_depot',
                'settlement_id',v_giro))->>'account_id')::int;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__drift_s22_dauer__','from_account_id',v_giro,
         'to_account_id',v_depot,'amount','100','schedule_unit','month','first_payment_date',(CURRENT_DATE + 3)::text));
  IF (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S2.2] Dauerueberweisung auf ein Depot angelegt, jede Ausfuehrung scheitert spaeter; erwartet ok:false, got %', r;
  END IF;
  RAISE NOTICE 'PASS [S2.2]';
END $$;
ROLLBACK;

-- (S2.6) Geplante Ueberweisung mit angepasstem Betrag buchen (tool_book_recurring_occurrence). Die DB nimmt den
--   Override auch bei Transfers (Gegenbeweis zur Description "ok:false if ... internal transfer", Absicherung in
--   test_drift_guard_finance.sql), liefert aber {debit_tx_id, credit_tx_id} statt des Vertrags-Kopfs
--   {transaction_id, amount, plan_amount}. Das Tool liest transaction_id/amount -> NULL auf der Erfolgsmeldung.
--   Korrekt: dieselben Post-State-Felder wie eine Zahlung (mindestens amount + plan_amount). Fix-Idee: Rueckgabe von
--   fn_book_recurring_transfer um amount/plan_amount ergaenzen (oder das Tool liest beide Formen); Description
--   korrigieren (Override geht, Betrag in Kontowaehrung).
BEGIN;
DO $$
DECLARE r jsonb; v_a int; v_b int; v_rp int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__drift_s26_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__drift_s26_tg__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__drift_s26_dauer__','from_account_id',v_a,
         'to_account_id',v_b,'amount','200','schedule_unit','month','first_payment_date',(CURRENT_DATE - 2)::text));
  v_rp := (r->>'recurring_payment_id')::int;
  IF v_rp IS NULL THEN RAISE EXCEPTION 'SETUP [S2.6] %', r; END IF;
  r := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,
         'due_date',(CURRENT_DATE - 2)::text,'amount','250'));
  IF NOT (r->>'ok')::boolean OR (r->>'amount') IS NULL OR (r->>'plan_amount') IS NULL THEN
    RAISE EXCEPTION 'FAIL [S2.6] Transfer-Rueckgabe ohne amount/plan_amount (Tool zeigt NULL), got %', r;
  END IF;
  RAISE NOTICE 'PASS [S2.6]';
END $$;
ROLLBACK;
