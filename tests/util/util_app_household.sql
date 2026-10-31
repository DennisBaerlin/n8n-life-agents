-- tests/util/util_app_household.sql
-- Gemeinsamer Fixture-Haushalt der Mini-App-Tests (UX-Gesamtkonzept 2026-10-31, Abschnitt 10; EINE Adresse fuer alle
-- tests/db/finance/test_fn_app_screen_* und core.fn_app_view_lint). ALLE Namen und Zahlen sind erfunden (Repo oeffentlich).
--
-- EINBINDEN (Muster tests/util/util_cron_cases.sql):
--     BEGIN;
--     \ir ../../util/util_app_household.sql
--     DO $$ ... (SELECT id::int FROM pg_temp.app_fx WHERE key = 'acc_giro_jonas') ... $$;
--     ROLLBACK;
--   db_test faehrt jede Testdatei per \i <absoluter Pfad> (Batch) bzw. psql -f (-Sequential); \ir loest in beiden
--   Faellen relativ zur Testdatei auf. Die Datei beginnt selbst mit BEGIN (innerhalb der Test-Transaktion nur eine
--   WARNING) und hat kein COMMIT: vergisst ein Test sein BEGIN, bleibt trotzdem nichts in der Test-DB liegen (der
--   Guard-ROLLBACK des Treibers raeumt). Kein Seed-fn im Produktiv-Schema (Test-Code gehoert nicht in die Installation).
--   Schluessel -> id in pg_temp.app_fx(key, id text) (ON COMMIT DROP, SELECT fuer PUBLIC = auch unter SET LOCAL ROLE
--   lesbar); der Test castet selbst (::int). Personen-IDs = Text (fxh_*).
--
-- BAU-REGELN: alle Daten relativ zu core.fn_today(); jede Rate beginnt mit dem naechsten Termin AB heute
--   (first_payment_date >= heute, valid_from = heute - 30 -> „laeuft“, aber kein offener Altposten), nie am Monatstag
--   haengend (feste Tage <= 28 bzw. -1 = Monatsletzter); Salden der Konten ueber finance.transactions (der Saldo-Trigger
--   ueberschreibt ein UPDATE account_balances); Kredite ueber finance.fn_create_loan (Konto + Rate + Kredit atomar wie
--   produktiv); Depots ohne Buchungen (depot_holdings + market_prices direkt); CHF ohne fx_rates = Wechselkurs fehlt.
--
-- HAUSHALT (Rolle, was daran haengt):
--   fxh_jonas owner · fxh_mira partner · fxh_lea child (14) · fxh_tom child (9) · fxh_gast grandparent (keine Daten)
--   acc_giro_jonas   Girokonto Jonas (cash, Jonas) mit ZWEI Auszuegen: Gehalt zum Monatsletzten, Dauerauftraege an
--                    Gemeinschaftskonto / Lea / Tom / Sparkonto (Hausruecklage, Fahrrad-Rate), Handy, Autokredit-Rate
--   acc_joint        Gemeinschaftskonto (cash, Haushalt) OHNE Auszug: eingehender Dauerauftrag, Kreditraten, Strom,
--                    Abos, eine Erstattung, ein Vertrag mit valid_from in der Zukunft
--   acc_p2p          Sparkonto P2P (p2p, Jonas) mit Ziel-Geld (3 erreichte Ziele + Fahrrad + Hausruecklage); fuellt per
--                    Dauerauftrag acc_broker_cash -> frei < 6 Monatsraten: Regression B1 (Schwelle = Ziel-Geld) + B2
--                    (Absender des Dauerauftrags ist das gefaehrdete Konto, nicht der Empfaenger)
--   acc_broker_cash  Broker-Cash Jonas (cash) mit Notreserve-Geld; von hier bucht plan_jonas an 4 festen Tagen ab (freies
--                    Geld 5.000 > eine Monatsrate 3.000 -> Ergebnis unabhaengig davon, ob der Zubringer am 1. schon kam)
--   acc_depot_jonas  Depot Jonas (EINE Position: Summenregel B5) · acc_crypto Krypto-Depot Jonas (ZWEI Positionen, ETH-Kurs
--                    veraltet) · acc_clearing Verrechnungskonto Krypto 0 EUR ohne Bewegung (B10)
--   acc_cash_lea / acc_depot_lea   Lea: Eingang Eltern + externe Zuwendung, Depot mit genau einem Ziel, 2 Sparplaene,
--                    Kurswert knapp unter dem Ziel-Geld (Delle unter der Schwelle depot_cover_warn_pct)
--   acc_cash_tom / acc_depot_tom   Tom: Eingang Eltern, 1 Sparplan, Kurswert deutlich unter dem Ziel-Geld (ab Schwelle)
--   acc_savings_mira Tagesgeld Mira (cash, Mira) mit Auszug, ohne Ziel-Geld, ohne Bewegung
--   acc_depot_mira   Depot Mira mit einer CHF-Position ohne Wechselkurs (gap)
--   loan_house (Zinsbindung endet in 8 Monaten = im Warnfenster) · loan_modern (Zinsbindung 5 Jahre) · loan_car
--                    (Schlussrate zum Laufzeitende in 19 Monaten; Ziel goal_car in gleicher Hoehe erreicht: B4)
--   goal_vacation / goal_car / goal_washer erreicht · goal_bike mit Dauerauftrags-Rate, noch offen · goal_maint
--   Hausruecklage (Instandhaltung) · goal_emergency Notreserve (fehlen 5.000) · goal_lea / goal_tom Kinder-Depots
--   plan_jonas (4x monatlich) · plan_lea_world (4x) + plan_lea_share (1x) -> goal_lea · plan_tom (1x) -> goal_tom
--   house  Haus (Immobilie der Hausruecklage)
BEGIN;

CREATE TEMP TABLE IF NOT EXISTS app_fx (key text PRIMARY KEY, id text NOT NULL) ON COMMIT DROP;
GRANT SELECT ON pg_temp.app_fx TO public;

INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';

DO $fx$
DECLARE
  t date := core.fn_today();
  v_giro int; v_joint int; v_p2p int; v_bcash int; v_depot int; v_crypto int; v_clear int;
  v_lea int; v_dlea int; v_tom int; v_dtom int; v_mira int; v_dmira int; v_house int;
  v_rp int; v_g int; v_r jsonb;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('fxh_jonas', 'Jonas Beispiel', 'owner'), ('fxh_mira', 'Mira Beispiel', 'partner'),
    ('fxh_lea', 'Lea Beispiel', 'child'), ('fxh_tom', 'Tom Beispiel', 'child'), ('fxh_gast', 'Gast Beispiel', 'grandparent')
  ON CONFLICT (person_id) DO UPDATE SET full_name = excluded.full_name, role = excluded.role;
  INSERT INTO pg_temp.app_fx VALUES ('p_owner', 'fxh_jonas'), ('p_partner', 'fxh_mira'), ('p_lea', 'fxh_lea'),
    ('p_tom', 'fxh_tom'), ('p_guest', 'fxh_gast');

  -- ---------- Konten (Saldo ueber eine Eroeffnungsbuchung) ----------
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id, bank)
    VALUES ('Girokonto Jonas', 'cash', 'EUR', 'active', 'fxh_jonas', 'Beispielbank') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id, bank)
    VALUES ('Gemeinschaftskonto', 'cash', 'EUR', 'active', NULL, 'Beispielbank') RETURNING id INTO v_joint;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Sparkonto P2P', 'p2p', 'EUR', 'active', 'fxh_jonas') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Broker-Cash Jonas', 'cash', 'EUR', 'active', 'fxh_jonas') RETURNING id INTO v_bcash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Verrechnungskonto Krypto', 'cash', 'EUR', 'active', 'fxh_jonas') RETURNING id INTO v_clear;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Depot Jonas', 'stocks_depot', 'EUR', 'active', v_bcash, 'fxh_jonas') RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Krypto-Depot Jonas', 'crypto_depot', 'EUR', 'active', v_clear, 'fxh_jonas') RETURNING id INTO v_crypto;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Taschengeld Lea', 'cash', 'EUR', 'active', 'fxh_lea') RETURNING id INTO v_lea;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Depot Lea', 'stocks_depot', 'EUR', 'active', v_lea, 'fxh_lea') RETURNING id INTO v_dlea;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('Taschengeld Tom', 'cash', 'EUR', 'active', 'fxh_tom') RETURNING id INTO v_tom;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Depot Tom', 'stocks_depot', 'EUR', 'active', v_tom, 'fxh_tom') RETURNING id INTO v_dtom;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id, bank)
    VALUES ('Tagesgeld Mira', 'cash', 'EUR', 'active', 'fxh_mira', 'Beispielbank') RETURNING id INTO v_mira;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('Depot Mira', 'stocks_depot', 'EUR', 'active', v_mira, 'fxh_mira') RETURNING id INTO v_dmira;

  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_giro, 2800, t - 40, 'other'), (v_joint, 4100, t - 40, 'other'), (v_p2p, 40000, t - 40, 'other'),
    (v_bcash, 15000, t - 40, 'other'), (v_lea, 400, t - 40, 'other'), (v_tom, 150, t - 40, 'other'),
    (v_mira, 8000, t - 40, 'other');

  -- Auszuege: Giro Jonas zwei (Alltag geschaetzt aus dem juengeren), Tagesgeld Mira zwei ohne offene Zeilen
  UPDATE finance.accounts SET last_reconciled_at = t - 5 WHERE id IN (v_giro, v_mira);
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
      line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at, oneoff_out, oneoff_threshold)
  VALUES (v_giro, t - 64, t - 35, 3100, 2900, 'EUR', 30, 8, -900, 0, NULL, 0, NULL),
         (v_giro, t - 34, t - 5, 2900, 2800, 'EUR', 34, 8, -1300, 0, t - 35, -400, 250),
         (v_mira, t - 64, t - 35, 8000, 8000, 'EUR', 0, 0, 0, 0, NULL, 0, NULL),
         (v_mira, t - 34, t - 5, 8000, 8000, 'EUR', 0, 0, 0, 0, t - 35, 0, NULL);

  -- ---------- Dauerauftraege und Zahlungen (naechster Termin ab heute) ----------
  -- Giro Jonas
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Gehalt Jonas', v_giro, 3300, 'month', -1, (date_trunc('month', t) + interval '1 month - 1 day')::date, t - 30),
         ('Handyvertrag Jonas', v_giro, -25, 'month', 12,
            CASE WHEN extract(day FROM t) <= 12 THEN date_trunc('month', t)::date + 11 ELSE (date_trunc('month', t) + interval '1 month')::date + 11 END, t - 30);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Haushaltsgeld', v_giro, v_joint, -2000, 'month', 1, (date_trunc('month', t) + interval '1 month')::date, t - 30),
         ('Taschengeld Lea', v_giro, v_lea, -200, 'month', 1, (date_trunc('month', t) + interval '1 month')::date, t - 30),
         ('Taschengeld Tom', v_giro, v_tom, -30, 'month', 1, (date_trunc('month', t) + interval '1 month')::date, t - 30);
  -- Gemeinschaftskonto (ohne Auszug): Abos, Strom, Kita, Erstattung, ein Vertrag ab naechstem Monat
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  SELECT n, v_joint, a, 'month', d,
         CASE WHEN extract(day FROM t) <= d THEN date_trunc('month', t)::date + d - 1 ELSE (date_trunc('month', t) + interval '1 month')::date + d - 1 END,
         t - 30
    FROM (VALUES ('Strom', -95::numeric, 15), ('Internet', -40, 3), ('Hausratversicherung', -18, 1), ('Streaming', -13, 20),
                 ('Kita', -230, 5), ('Gas', -110, 15), ('Musikschule', -60, 10), ('Erstattung Krankenkasse', 30, 25)) x(n, a, d);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Zeitschrift (neu)', v_joint, -9, 'month', 8, (date_trunc('month', t) + interval '1 month')::date + 7,
          (date_trunc('month', t) + interval '1 month')::date + 7);
  -- Kinder: externe Zuwendung
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Zuwendung Oma', v_lea, 20, 'month', 5,
          CASE WHEN extract(day FROM t) <= 5 THEN date_trunc('month', t)::date + 4 ELSE (date_trunc('month', t) + interval '1 month')::date + 4 END, t - 30);
  -- Sparkonto -> Broker-Cash (B1/B2: der ABSENDER ist das gefaehrdete Konto)
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Übertrag Broker', v_p2p, v_bcash, -3000, 'month', 1, (date_trunc('month', t) + interval '1 month')::date, t - 30);

  -- ---------- Immobilie + Ziele + Ziel-Geld ----------
  INSERT INTO finance.real_estate (name, current_value, living_area_m2, year_built) VALUES ('Haus', 520000, 98, 1996)
    RETURNING id INTO v_house;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Hausrücklage', v_giro, v_p2p, -120, 'month', 1, (date_trunc('month', t) + interval '1 month')::date, t - 30)
    RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, recurring_payment_id) VALUES ('Hausrücklage', 'maintenance_reserve', v_house, v_rp)
    RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_p2p, 3000, 'manual');
  INSERT INTO pg_temp.app_fx VALUES ('goal_maint', v_g::text), ('house', v_house::text);

  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('Urlaub', 2500, t + 60) RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_p2p, 2500, 'manual');
  INSERT INTO pg_temp.app_fx VALUES ('goal_vacation', v_g::text);
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('Auto-Schlussrate', 18000, (t + interval '19 months')::date)
    RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_p2p, 18000, 'manual');
  INSERT INTO pg_temp.app_fx VALUES ('goal_car', v_g::text);
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('Waschmaschine', 800, t + 150) RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_p2p, 800, 'manual');
  INSERT INTO pg_temp.app_fx VALUES ('goal_washer', v_g::text);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Sparrate Fahrrad', v_giro, v_p2p, -100, 'month', 1, (date_trunc('month', t) + interval '1 month')::date, t - 30)
    RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id, beneficiary_person_id)
    VALUES ('Fahrrad Mira', 3000, (t + interval '6 months')::date, v_rp, 'fxh_mira') RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_p2p, 2500, 'manual');
  INSERT INTO pg_temp.app_fx VALUES ('goal_bike', v_g::text);
  INSERT INTO finance.savings_goals (name, kind, target_amount, status) VALUES ('Notreserve', 'emergency_reserve', 15000, 'active')
    RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_bcash, 10000, 'manual');
  INSERT INTO pg_temp.app_fx VALUES ('goal_emergency', v_g::text);

  -- ---------- Depots, Positionen, Kurse ----------
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency) VALUES
    (v_depot, 'FXH00000001', 'FXHW1', 'ETF World', 200, 100, 'EUR'),
    (v_crypto, NULL, 'FXHBTC', 'Bitcoin', 0.04, 60000, 'EUR'),
    (v_crypto, NULL, 'FXHETH', 'Ether', 0.5, 2400, 'EUR'),
    (v_dlea, 'FXH00000002', 'FXHWL', 'ETF World Lea', 20, 100, 'EUR'),
    (v_dlea, 'FXH00000003', 'FXHAL', 'Einzelaktie Lea', 3, 100, 'EUR'),
    (v_dtom, 'FXH00000004', 'FXHWT', 'ETF World Tom', 10, 120, 'EUR'),
    (v_dmira, 'FXH00000005', 'FXHCH', 'Schweizer Aktie', 10, 85, 'CHF');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('FXHW1', 106, 'EUR', t), ('FXHBTC', 65000, 'EUR', t), ('FXHETH', 2600, 'EUR', t - 30),
    ('FXHWL', 105, 'EUR', t), ('FXHAL', 50, 'EUR', t), ('FXHWT', 100, 'EUR', t), ('FXHCH', 90, 'CHF', t)
  ON CONFLICT (symbol, as_of) DO UPDATE SET price = excluded.price, currency = excluded.currency;

  -- ---------- Sparplaene (Abbuchungskonto = Konto der Raten-rp) + Kinder-Ziele ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
  VALUES ('Sparplan ETF World', v_bcash, -750, 1, 'month', '{2,9,16,23}', t, t - 30) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, isin, security_name, recurring_payment_id, beneficiary_person_id)
    VALUES ('ETF World Jonas', v_depot, 'FXHW1', 'FXH00000001', 'ETF World', v_rp, 'fxh_jonas') RETURNING id INTO v_g;
  INSERT INTO pg_temp.app_fx VALUES ('plan_jonas', v_g::text);

  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id)
    VALUES ('Depot Lea', 40000, (t + interval '13 years 5 months')::date, 'fxh_lea') RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_dlea, 2300, 'sparplan_buy');
  INSERT INTO pg_temp.app_fx VALUES ('goal_lea', v_g::text);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
  VALUES ('Sparplan ETF World Lea', v_lea, -40, 1, 'month', '{2,9,16,23}', t, t - 30) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, isin, security_name, recurring_payment_id, savings_goal_id, beneficiary_person_id)
    VALUES ('ETF World Lea', v_dlea, 'FXHWL', 'FXH00000002', 'ETF World', v_rp, v_g, 'fxh_lea');
  INSERT INTO pg_temp.app_fx SELECT 'plan_lea_world', id::text FROM finance.savings_plans WHERE recurring_payment_id = v_rp;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Sparplan Einzelaktie Lea', v_lea, -40, 'month', 9,
          CASE WHEN extract(day FROM t) <= 9 THEN date_trunc('month', t)::date + 8 ELSE (date_trunc('month', t) + interval '1 month')::date + 8 END, t - 30)
    RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, isin, security_name, recurring_payment_id, savings_goal_id, beneficiary_person_id)
    VALUES ('Einzelaktie Lea', v_dlea, 'FXHAL', 'FXH00000003', 'Einzelaktie', v_rp, v_g, 'fxh_lea');
  INSERT INTO pg_temp.app_fx SELECT 'plan_lea_share', id::text FROM finance.savings_plans WHERE recurring_payment_id = v_rp;

  INSERT INTO finance.savings_goals (name, target_amount, target_date, beneficiary_person_id)
    VALUES ('Depot Tom', 20000, (t + interval '9 years')::date, 'fxh_tom') RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES (v_g, v_dtom, 1200, 'sparplan_buy');
  INSERT INTO pg_temp.app_fx VALUES ('goal_tom', v_g::text);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
  VALUES ('Sparplan ETF World Tom', v_tom, -30, 'month', 2,
          CASE WHEN extract(day FROM t) <= 2 THEN date_trunc('month', t)::date + 1 ELSE (date_trunc('month', t) + interval '1 month')::date + 1 END, t - 30)
    RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, isin, security_name, recurring_payment_id, savings_goal_id, beneficiary_person_id)
    VALUES ('ETF World Tom', v_dtom, 'FXHWT', 'FXH00000004', 'ETF World', v_rp, v_g, 'fxh_tom');
  INSERT INTO pg_temp.app_fx SELECT 'plan_tom', id::text FROM finance.savings_plans WHERE recurring_payment_id = v_rp;

  -- ---------- Kredite (fn_create_loan: Konto + Rate + Kredit atomar) ----------
  v_r := finance.fn_create_loan(jsonb_build_object('name', 'Hauskredit', 'lender', 'Beispielbank', 'current_balance', 180000,
           'interest_rate', 3.1, 'monthly_annuity', 950, 'schedule_day_of_month', 15, 'debit_account_id', v_joint,
           'first_payment_date', (CASE WHEN extract(day FROM t) <= 15 THEN date_trunc('month', t)::date + 14
                                       ELSE (date_trunc('month', t) + interval '1 month')::date + 14 END)::text,
           'interest_rate_fixed_until', ((t + interval '8 months')::date)::text));
  IF (v_r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'app_household: Hauskredit %', v_r; END IF;
  INSERT INTO pg_temp.app_fx VALUES ('loan_house', v_r->>'loan_id');
  v_r := finance.fn_create_loan(jsonb_build_object('name', 'Modernisierungskredit', 'lender', 'Beispielbank', 'current_balance', 25000,
           'interest_rate', 4.2, 'monthly_annuity', 400, 'schedule_day_of_month', 15, 'debit_account_id', v_joint,
           'first_payment_date', (CASE WHEN extract(day FROM t) <= 15 THEN date_trunc('month', t)::date + 14
                                       ELSE (date_trunc('month', t) + interval '1 month')::date + 14 END)::text,
           'interest_rate_fixed_until', ((t + interval '5 years')::date)::text));
  IF (v_r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'app_household: Modernisierungskredit %', v_r; END IF;
  INSERT INTO pg_temp.app_fx VALUES ('loan_modern', v_r->>'loan_id');
  v_r := finance.fn_create_loan(jsonb_build_object('name', 'Autokredit', 'lender', 'Autobank', 'current_balance', 24000,
           'interest_rate', 2.4, 'monthly_annuity', 310, 'schedule_day_of_month', 1, 'debit_account_id', v_giro,
           'first_payment_date', ((date_trunc('month', t) + interval '1 month')::date)::text,
           'interest_rate_fixed_until', ((t + interval '19 months')::date)::text,
           'term_end_date', ((t + interval '19 months')::date)::text, 'notes', 'Schlussrate 18000'));
  IF (v_r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'app_household: Autokredit %', v_r; END IF;
  INSERT INTO pg_temp.app_fx VALUES ('loan_car', v_r->>'loan_id');

  INSERT INTO pg_temp.app_fx VALUES
    ('acc_giro_jonas', v_giro::text), ('acc_joint', v_joint::text), ('acc_p2p', v_p2p::text), ('acc_broker_cash', v_bcash::text),
    ('acc_clearing', v_clear::text), ('acc_depot_jonas', v_depot::text), ('acc_crypto', v_crypto::text),
    ('acc_cash_lea', v_lea::text), ('acc_depot_lea', v_dlea::text), ('acc_cash_tom', v_tom::text), ('acc_depot_tom', v_dtom::text),
    ('acc_savings_mira', v_mira::text), ('acc_depot_mira', v_dmira::text);
END
$fx$;
