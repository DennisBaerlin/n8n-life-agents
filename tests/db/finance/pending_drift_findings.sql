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
