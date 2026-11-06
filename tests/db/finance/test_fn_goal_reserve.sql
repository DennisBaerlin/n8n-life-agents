-- tests/db/finance/test_fn_goal_reserve.sql
-- Sparziel mit festem Reserve-Topf (Owner-Entscheid 2026-10-23, Paket DB-ist-das-Gesetz Nachtrag D):
--   Der Topf ist recurring_payments.target_account_id der Sparrate; die Reserve = Topf + jedes Konto, auf dem noch
--   getaggtes Geld des Ziels liegt (teilweises Umschichten). fn_book_savings_goal_transfer leitet Von/An ab und prueft:
--   (1) deposit ohne Konten -> An = Topf, Von = Abbuchungskonto der Rate; effective nennt beide Konten
--   (2) deposit auf ein fremdes Konto -> ok:false not_reserve
--   (3) withdrawal ohne Von -> Von = Topf; mehr als der Anteil dort -> ok:false insufficient_share
--   (4) relocate des ganzen Anteils -> ok, der Topf zieht um (alle laufenden Raten-Zeilen), deposit landet danach dort
--   (5) relocate auf das Abbuchungskonto -> ok:false (gleiche Regel wie Topf aendern), kein RAISE
--   (6) Kontonamen statt ids; Depot-Name -> ok:false mit Verweis auf die Depot-Reservierung
BEGIN;

DO $$
DECLARE
  v_giro int; v_pot int; v_pot2 int; v_goal int; v_rp int; v_r jsonb; v_t int; v_depot int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__gr_giro__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__gr_pot__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_pot2 := (finance.fn_create_account('{"name":"__gr_pot2__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__gr Ziel__','target_amount',3000,'target_date','2028-12-31',
           'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date','2026-11-01'));
  v_goal := (v_r->>'goal_id')::int; v_rp := (v_r->>'recurring_payment_id')::int;

  -- (1) deposit ohne Konten
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 500, 'direction', 'deposit'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->'effective'->>'to_account_id')::int IS DISTINCT FROM v_pot
     OR (v_r->'effective'->>'from_account_id')::int IS DISTINCT FROM v_giro OR v_r->'effective'->>'to_account_name' IS DISTINCT FROM '__gr_pot__' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [1 deposit ableiten]: %', v_r; END IF;

  -- (2) deposit auf fremdes Konto
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 10, 'direction', 'deposit',
           'to_account_id', v_pot2));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'not_reserve' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [2 deposit fremdes Konto]: %', v_r; END IF;

  -- (3) withdrawal ohne Von; mehr als der Anteil
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 100, 'direction', 'withdrawal',
           'to_account_name', '__gr_giro__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->'effective'->>'from_account_id')::int IS DISTINCT FROM v_pot THEN
    RAISE EXCEPTION 'FAIL goal_reserve [3 withdrawal ableiten]: %', v_r; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 9999, 'direction', 'withdrawal',
           'to_account_id', v_giro));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'insufficient_share' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [3 Anteil zu klein]: %', v_r; END IF;

  -- (5) relocate aufs Abbuchungskonto -> ok:false
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 400, 'direction', 'relocate',
           'to_account_id', v_giro));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL goal_reserve [5 relocate aufs Abbuchungskonto]: %', v_r; END IF;

  -- (4) relocate des ganzen Anteils (400 liegen noch auf dem Topf) -> Topf zieht um
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 400, 'direction', 'relocate',
           'to_account_name', '__gr_pot2__'));
  SELECT target_account_id INTO v_t FROM finance.recurring_payments WHERE id = v_rp;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_t IS DISTINCT FROM v_pot2 THEN
    RAISE EXCEPTION 'FAIL goal_reserve [4 relocate verlegt den Topf]: % / target=%', v_r, v_t; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 50, 'direction', 'deposit'));
  IF (v_r->'effective'->>'to_account_id')::int IS DISTINCT FROM v_pot2 THEN
    RAISE EXCEPTION 'FAIL goal_reserve [4 deposit landet im neuen Topf]: %', v_r; END IF;

  -- (6) Depot-Name -> ok:false mit Hinweis
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__gr Depot__','account_type','stocks_depot','settlement_id',v_giro))->>'account_id')::int;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 50, 'direction', 'deposit',
           'to_account_name', '__gr Depot__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT ILIKE '%reservation%' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [6 Depot-Name]: %', v_r; END IF;

  RAISE NOTICE 'PASS goal_reserve [Ableitung je Richtung, not_reserve, insufficient_share, relocate verlegt Topf, Depot-Hinweis]';
END $$;

-- Randfaelle (Code-Review 2026-10-23):
--   (7) Geld zwischen zwei Reserve-Konten desselben Ziels ist ein relocate: withdrawal/deposit -> ok:false use_relocate
--   (8) gleiche Einzahlung zweimal -> der Doppelbuchungs-Hinweis aus fn_book_transfer kommt auf die Karte (card_lines)
--   (9) beendete Rate: voller relocate verlegt den Topf trotzdem (naechste Einzahlung landet im neuen Topf)
--  (10) geschlossenes Ziel wieder aktiv + neuer Topf -> die neue Rate fliesst in den neuen Topf
--  (11) Altziel ohne Sparrate, Geld auf genau einem Konto: Einzahlung ohne Konto -> dorthin; fremdes Konto -> not_reserve
--       mit lesbarem Grund (nie NULL)
DO $$
DECLARE
  v_giro int; v_a int; v_b int; v_goal int; v_rp int; v_r jsonb; v_t int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__gr2_giro__","account_type":"cash","opening_balance":9000}'::jsonb)->>'account_id')::int;
  v_a    := (finance.fn_create_account('{"name":"__gr2_a__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_b    := (finance.fn_create_account('{"name":"__gr2_b__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__gr2 Ziel__','target_amount',5000,'target_date','2029-12-31',
           'account_id',v_giro,'reserve_account_id',v_a,'first_payment_date','2026-11-01'));
  v_goal := (v_r->>'goal_id')::int; v_rp := (v_r->>'recurring_payment_id')::int;

  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 600, 'direction', 'deposit'));
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 200, 'direction', 'relocate',
           'to_account_id', v_b));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL goal_reserve [7 Teil-relocate]: %', v_r; END IF;

  -- (7)
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 50, 'direction', 'withdrawal',
           'from_account_id', v_a, 'to_account_id', v_b));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'use_relocate' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [7 withdrawal zwischen Reserve-Konten]: %', v_r; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 50, 'direction', 'deposit',
           'from_account_id', v_b));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'use_relocate' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [7 deposit aus Reserve-Konto]: %', v_r; END IF;

  -- (8)
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 600, 'direction', 'deposit'));
  IF jsonb_array_length(COALESCE(v_r->'card_lines', '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'FAIL goal_reserve [8 Doppelbuchungs-Hinweis fehlt]: %', v_r; END IF;

  -- (9) Rate endet heute; voller relocate vom Topf A (1000 auf A) nach C=giro? nein: nach einem neuen Konto
  UPDATE finance.recurring_payments SET valid_to = core.fn_today() WHERE id = v_rp;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 1000, 'direction', 'relocate',
           'from_account_id', v_a, 'to_account_id', v_b));
  SELECT target_account_id INTO v_t FROM finance.recurring_payments WHERE id = v_rp;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_t IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'FAIL goal_reserve [9 beendete Rate: Topf zieht nicht um]: % / target=%', v_r, v_t; END IF;

  -- (10) geschlossen -> wieder aktiv mit neuem Topf A
  UPDATE finance.recurring_payments SET valid_to = core.fn_today() - 1 WHERE id = v_rp;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'status', 'active', 'reserve_account_id', v_a));
  SELECT rp.target_account_id INTO v_t FROM finance.savings_goals g JOIN finance.recurring_payments rp ON rp.id = g.recurring_payment_id
   WHERE g.id = v_goal;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_t IS DISTINCT FROM v_a THEN
    RAISE EXCEPTION 'FAIL goal_reserve [10 Wiedereroeffnen: neue Rate nicht im neuen Topf]: % / target=%', v_r, v_t; END IF;

  -- (11) Altziel ohne Rate: Geld liegt nur auf B
  UPDATE finance.savings_goals SET recurring_payment_id = NULL WHERE id = v_goal;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 30, 'direction', 'deposit',
           'from_account_id', v_giro));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->'effective'->>'to_account_id')::int IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'FAIL goal_reserve [11 Altziel: Einzahlung ohne Konto]: %', v_r; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal, 'amount', 30, 'direction', 'deposit',
           'from_account_id', v_giro, 'to_account_id', v_a));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'not_reserve' OR v_r->>'reason' IS NULL THEN
    RAISE EXCEPTION 'FAIL goal_reserve [11 Altziel: fremdes Konto ohne Grund]: %', v_r; END IF;

  RAISE NOTICE 'PASS goal_reserve [use_relocate, Doppelbuchungs-Hinweis, beendete Rate, Wiedereroeffnen, Altziel ohne Rate]';
END $$;

-- Saldo-basierte Topf-Typen + Zuordnung (Sparziel-Zweckbindung 2026-10-27):
--  (12) P2P ist ein erlaubter Topf (Anlegen mit Rate in den P2P-Topf); Namensaufloesung findet P2P-Konten
--  (13) nur zugeordnetes Geld (Journal, kein Transfer) auf einem P2P-Konto kann entnommen werden (Anteil = Tags + Journal)
--  (14) Depot-Zuordnungen sind kein Reserve-Konto fuer Geldbewegungen (fn_goal_reserve_accounts nur Topf-Typen)
--  (15) Kreditkonto bleibt als Topf verboten
DO $$
DECLARE
  v_giro int; v_p2p int; v_p2p2 int; v_depot int; v_loan int; v_goal int; v_goal2 int; v_r jsonb; v_cnt int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__gr3_giro__","account_type":"cash","opening_balance":9000}'::jsonb)->>'account_id')::int;
  v_p2p  := (finance.fn_create_account('{"name":"__gr3_p2p__","account_type":"p2p","opening_balance":4000}'::jsonb)->>'account_id')::int;

  -- (12)
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__gr3 Ziel__','target_amount',2000,'target_date','2029-12-31',
           'account_id',v_giro,'reserve_account_id',v_p2p,'first_payment_date','2026-11-01'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL goal_reserve [12 P2P-Topf]: %', v_r; END IF;
  v_r := finance.fn_resolve_cash_account('__gr3_p2p__');
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'id')::int IS DISTINCT FROM v_p2p THEN
    RAISE EXCEPTION 'FAIL goal_reserve [12 P2P aufloesen]: %', v_r; END IF;

  -- (13) Ziel ohne Rate, 1500 auf dem P2P-Konto zugeordnet -> 400 entnehmen aufs Giro
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__gr3 Reise__', 1500, current_date + 300, 'active') RETURNING id INTO v_goal2;
  v_r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal2, 'account_id', v_p2p, 'amount', 1500));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL goal_reserve [13 setup]: %', v_r; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal2, 'amount', 400, 'direction', 'withdrawal',
           'to_account_id', v_giro));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->'effective'->>'from_account_id')::int IS DISTINCT FROM v_p2p
     OR (v_r->>'current_amount')::numeric IS DISTINCT FROM 1100 THEN
    RAISE EXCEPTION 'FAIL goal_reserve [13 Entnahme aus Zuordnung]: %', v_r; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal2, 'amount', 1200, 'direction', 'withdrawal',
           'to_account_id', v_giro));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'insufficient_share' THEN
    RAISE EXCEPTION 'FAIL goal_reserve [13 Anteil 1100]: %', v_r; END IF;

  -- (14) Depot-Zuordnung zaehlt nicht als Reserve-Konto fuer Geldbewegungen
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__gr3 Depot__','account_type','stocks_depot','settlement_id',v_giro))->>'account_id')::int;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_goal2, v_depot, 5000, 'EUR', 'manual');
  SELECT count(*) INTO v_cnt FROM finance.fn_goal_reserve_accounts(v_goal2) r WHERE r.account_id = v_depot;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL goal_reserve [14 Depot in fn_goal_reserve_accounts]'; END IF;
  v_r := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id', v_goal2, 'amount', 100, 'direction', 'withdrawal',
           'to_account_id', v_giro));
  IF (v_r->'effective'->>'from_account_id')::int IS DISTINCT FROM v_p2p THEN
    RAISE EXCEPTION 'FAIL goal_reserve [14 Entnahme darf nicht aus dem Depot kommen]: %', v_r; END IF;

  -- (15)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__gr3_loan__','loan','EUR','active') RETURNING id INTO v_loan;
  IF finance.fn_goal_reserve_account_reason(v_loan, v_giro) IS NULL THEN
    RAISE EXCEPTION 'FAIL goal_reserve [15 Kreditkonto als Topf]'; END IF;

  RAISE NOTICE 'PASS goal_reserve [P2P-Topf, Entnahme aus Zuordnung, Depot kein Reserve-Konto, Kredit verboten]';
END $$;

ROLLBACK;
