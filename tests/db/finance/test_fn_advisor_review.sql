-- tests/db/finance/test_fn_advisor_review.sql
-- WS2 (Core-Advisor-Engine): finance.fn_advisor_review — die paket-besessene Soll-Ist-Drift + der
-- Quartals-Digest. WS2a-Stand = buchwert-immune Metriken (Sparziel-Pace, Notreserve, Staleness).
--   (1) Notreserve-Unterdeckung (Cash < target_eur) -> emergency_reserve-Alert
--   (2) Sparziel hinter Pace (10% Ist vs ~50% erwartet) -> savings_pace-Alert
--   (3) Plan ueberfaellig (_meta.last_confirmed_at alt) -> staleness-Alert
--   (4) Digest traegt alle 12 Felder (Regressionsnetz: plan_version/armed/fired ueber DEFINER-Fenster)
--       + den paket-gerenderten digest.text (Generik-Vertrag: der generische Cron sendet nur 'text')
--   (5) partial-tolerant: ohne emergency_reserve-Fakt KEIN emergency-Alert (kein Crash)
BEGIN;

-- ---------- Fixtures ----------
-- Cash-Konto mit niedrigem Saldo (Trigger legt account_balances=0 an, dann hochsetzen)
INSERT INTO finance.accounts (id, name, account_type, currency, status)
VALUES (910001, '__test_cash__', 'cash', 'EUR', 'active');
UPDATE finance.account_balances SET balance = 1000 WHERE account_id = 910001;

-- Sparziel hinter Pace: created vor 365 T, target in 365 T -> erwartet ~50%; WS-A: Fortschritt = aktuelle
-- RESERVE = markierte Bewegungen (savings_goal_id). 10% Deckung = +1000 markierter Reserve-Zufluss +
-- -1000 Abbuchung (Giro-Soll, untagged) -> 910001 netto 0 (Drift-Block 2 unberuehrt), progress 1000.
INSERT INTO finance.savings_goals (id, name, target_amount, target_date, status, created_at)
VALUES (910002, '__test_goal__', 10000, current_date + 365, 'active', (now() - interval '365 days'));
INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
VALUES (910001, -1000, current_date - 31, 'transfer', NULL, gen_random_uuid()),       -- Abbuchung (Giro-Soll, untagged)
       (910001,  1000, current_date - 30, 'transfer', 910002, gen_random_uuid());     -- Reserve-Zufluss (markiert) -> progress 1000

-- Soll-Plan: Notreserve 20000 (Cash 1000 < 20000) + alter Stempel (Staleness)
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('financial_planning', 'test', NULL, 'lazy', 'x', 'agent', 'finance',
        jsonb_build_object('facts', jsonb_build_object(
            'emergency_reserve', jsonb_build_object('target_eur', 20000),
            '_meta', jsonb_build_object('last_confirmed_at', '2023-01-01'))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, managed_by = 'agent', package = 'finance';

DO $$
DECLARE
  r        jsonb;
  v_em     int;
  v_pace   int;
  v_stale  int;
  v_dig    jsonb;
BEGIN
  r := finance.fn_advisor_review('finance');

  SELECT count(*) INTO v_em    FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'emergency_reserve';
  SELECT count(*) INTO v_pace  FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'savings_pace';
  SELECT count(*) INTO v_stale FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'staleness';

  IF v_em < 1 THEN RAISE EXCEPTION 'FAIL [1]: kein emergency_reserve-Alert (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [Notreserve-Unterdeckung -> emergency_reserve-Alert]';

  -- Generik-Vertrag: JEDER alert traegt ein paket-gerendertes, nicht-leeres 'text'-Feld (der generische
  -- Cron joint nur diese Texte). Beweis am emergency-Alert: enthaelt den Soll-Betrag.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'kind' = 'emergency_reserve'
                   AND COALESCE((a->'msg')::text,'') <> '' AND (a->'msg')::text LIKE '%20000%') THEN
    RAISE EXCEPTION 'FAIL [1b]: emergency-Alert ohne gerenderten text mit Soll-Betrag (alerts=%)', r->'alerts';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE COALESCE((a->'msg')::text,'') = '') THEN
    RAISE EXCEPTION 'FAIL [1b]: ein alert ohne text-Feld (alerts=%)', r->'alerts';
  END IF;
  RAISE NOTICE 'PASS [jeder alert trägt paket-gerenderten text]';

  IF v_pace < 1 THEN RAISE EXCEPTION 'FAIL [2]: kein savings_pace-Alert (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [Sparziel hinter Pace -> savings_pace-Alert]';

  -- (2b) WS-1: der Pace-Alert traegt die angereicherte Meldung (Nachhol-Rate, da Zieldatum in der Zukunft
  -- + ungedeckt -> required_catchup_rate non-NULL). Deckt die CASE-Anreicherung im fn-Text ab.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'kind' = 'savings_pace' AND (a->'msg')::text LIKE '%finance.advisor.savings_pace_catchup%') THEN
    RAISE EXCEPTION 'FAIL [2b]: savings_pace-Alert ohne Nachhol-Rate-Anreicherung (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [savings_pace-Alert trägt Nachhol-Rate-Anreicherung]';

  IF v_stale < 1 THEN RAISE EXCEPTION 'FAIL [3]: kein staleness-Alert (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [Plan überfällig -> staleness-Alert]';

  -- (4) Digest 12-Feld-Regression (Textkatalog Phase C: Rohwerte + 'lines'-Struktur statt vorformatierter Strings)
  v_dig := r->'digest';
  -- Audit Paket 3 (bewusste Vertragsaenderung): expenses/net -> consumption/obligations/free/saving/account_change
  IF NOT (v_dig ? 'plan_count' AND v_dig ? 'plan_version' AND v_dig ? 'plan_published'
          AND v_dig ? 'income' AND v_dig ? 'consumption' AND v_dig ? 'obligations' AND v_dig ? 'free'
          AND v_dig ? 'saving' AND v_dig ? 'account_change' AND v_dig ? 'lines'
          AND v_dig ? 'cash_total' AND v_dig ? 'depot_book_value' AND v_dig ? 'debt_total'
          AND v_dig ? 'triggers_armed' AND v_dig ? 'triggers_fired') THEN
    RAISE EXCEPTION 'FAIL [4]: Digest unvollständig (%)', v_dig;
  END IF;
  IF v_dig ? 'expenses' OR v_dig ? 'net' THEN
    RAISE EXCEPTION 'FAIL [4]: Digest traegt noch die Alt-Felder expenses/net (%)', v_dig; END IF;
  RAISE NOTICE 'PASS [Digest trägt alle 15 Felder]';

  -- (4b) Digest traegt den paket-gerenderten 'text' (der generische Cron sendet ihn); Zahlen 1:1 enthalten.
  IF COALESCE((v_dig->'lines')::text,'') = '' OR (v_dig->'lines')::text NOT LIKE '%finance.advisor.digest_title%' THEN
    RAISE EXCEPTION 'FAIL [4b]: Digest ohne gerenderten text (%)', v_dig;
  END IF;
  RAISE NOTICE 'PASS [Digest trägt paket-gerenderten text]';

  -- (4c) Textkatalog Phase C: Struktur statt deutschem Text — kein alert traegt 'text'; jedes msg-Element ist
  -- null (entfallener Teilsatz) oder ein tpl mit finance.advisor-Key; Betraege sind typisierte Zahlen (kein to_char).
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a ? 'text') THEN
    RAISE EXCEPTION 'FAIL [4c]: alert mit altem text-Feld (%)', r->'alerts'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a, jsonb_array_elements(a->'msg') m
              WHERE jsonb_typeof(m) <> 'null'
                AND (m->>'kind' IS DISTINCT FROM 'tpl' OR m->>'value' NOT LIKE 'finance.advisor.%')) THEN
    RAISE EXCEPTION 'FAIL [4c]: msg-Element ohne tpl/finance.advisor-Key (%)', r->'alerts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a, jsonb_array_elements(a->'msg') m
                  WHERE a->>'kind' = 'emergency_reserve' AND m->'params'->'target'->>'kind' = 'money'
                    AND jsonb_typeof(m->'params'->'target'->'value') = 'number') THEN
    RAISE EXCEPTION 'FAIL [4c]: emergency_reserve-Betrag nicht als typisierte Zahl (%)', r->'alerts'; END IF;
  IF jsonb_typeof(v_dig->'lines') <> 'array' OR jsonb_typeof(v_dig->'income') <> 'number' THEN
    RAISE EXCEPTION 'FAIL [4c]: Digest-lines/Rohwerte (%)', v_dig; END IF;
  RAISE NOTICE 'PASS [4c: Alerts/Digest als tpl-Struktur mit typisierten Werten]';

  -- (5) partial-tolerant: emergency_reserve-Fakt entfernen -> kein emergency-Alert, kein Crash
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date, 'YYYY-MM-DD'))))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_em FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'emergency_reserve';
  IF v_em <> 0 THEN RAISE EXCEPTION 'FAIL [5]: emergency-Alert trotz fehlendem Fakt'; END IF;
  RAISE NOTICE 'PASS [partial-tolerant: ohne Fakt kein Alert, kein Crash]';
END $$;

-- ============================================================
-- WS2b: Marktwert-Metriken (Allokations-Drift, Zielportfolio, Pflicht-Advisory-Sektionen)
-- ============================================================
DO $$
DECLARE
  r        jsonb;
  v_cash   INT; v_depot INT;
  v_cnt    int;
  v_blk    jsonb;
  v_breach boolean;
BEGIN
  -- Depot + Holdings (shares direkt; Marktpreise selektiv -> null_price testbar)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ar_cash__','cash','EUR','active') RETURNING id INTO v_cash;  -- netto 0 (kein Saldo)
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__ar_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;

  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class) VALUES
    (v_depot,'IE00BK5BQT80','VWCE','S&P500 ETF', 80, 100,'EUR','sp500'),   -- 80*100 = 8000
    (v_depot,'KR0000000001','KOR','Korea', 5, 100,'EUR','korea'),          -- 5*100 = 500
    (v_depot,'XX0000000001','GLD','Gold', 10, 100,'EUR','gold'),           -- 10*100 = 1000
    (v_depot,'XX0000000002','NOP','Gold2 (kein Kurs)', 1, 100,'EUR','gold'),-- Fallback 100, null_price
    (v_depot,'XX0000000003','ALT','Altcoin (unmapped)', 1, 100,'EUR','altcoin'), -- 100, unmapped Tag
    (v_depot, NULL,'UNT','Ungetaggt', 1, 100,'EUR', NULL),                 -- 100, null_tag
    (v_depot,'XX0000000004','OUT','Kinder-Depot-Position', 1, 100,'EUR','outside_plan'); -- bewusst ausserhalb: kein unmapped
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('VWCE',100,'EUR',current_date), ('KOR',100,'EUR',current_date),
    ('GLD',100,'EUR',current_date), ('ALT',100,'EUR',current_date), ('UNT',100,'EUR',current_date);
  -- NOP bewusst OHNE market_prices-Zeile -> null_price + Buchwert-Fallback

  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__ar_re__', 250000, 'active');

  -- Plan: Ziel-Allokation mit STABILEN keys + ein nicht-handelbarer Ziel-Block (real_estate) + Zielportfolio.
  -- (Validator-Registry hier NICHT geseedet -> der finance-Block-Validator laeuft nicht; Core-Trigger ok.)
  -- Audit Paket 3: echte Gesamtplan-Anteile statt target_pct 0 fuer die Immobilie (20 %). Die handelbaren Bloecke
  -- (Summe 80) normiert der Advisor auf ihre Summe -> sp500 68 -> 85 % [64,72] -> [80,90], korea 8,8 -> 11 %
  -- [4,8,12,8] -> [6,16], gold 3,2 -> 4 % (dieselben Erwartungen wie vorher).
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'goal', jsonb_build_object('target_portfolio_eur', jsonb_build_array(900000, 1000000)),
      'target_allocation', jsonb_build_object('rebalance_drift_pp', 5, 'blocks', jsonb_build_array(
          jsonb_build_object('key','sp500','name','S&P 500 ETF','target_pct',68,'corridor', jsonb_build_array(64,72)),
          jsonb_build_object('key','korea','name','Korea Depot','target_pct',8.8,'corridor', jsonb_build_array(4.8,12.8)),
          jsonb_build_object('key','gold','name','Physical Gold','target_pct',3.2),
          jsonb_build_object('key','real_estate','name','Immobilie','target_pct',20))),
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date,'YYYY-MM-DD'))))
  WHERE name = 'financial_planning';

  r := finance.fn_advisor_review('finance');

  -- (6) rebalanceable_drift: 3 handelbare Bloecke; sp500 IN Korridor (kein breach), korea + gold breach
  IF jsonb_array_length(r->'rebalanceable_drift') <> 3 THEN
    RAISE EXCEPTION 'FAIL [6]: erwartet 3 handelbare Drift-Blöcke, got %', r->'rebalanceable_drift'; END IF;
  SELECT (b->>'breach')::boolean INTO v_breach FROM jsonb_array_elements(r->'rebalanceable_drift') b WHERE b->>'key'='sp500';
  IF v_breach IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6]: sp500 sollte IM Korridor sein (kein breach), got %', r->'rebalanceable_drift'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='alloc:korea') THEN
    RAISE EXCEPTION 'FAIL [6]: kein korea-Allokations-Alert (unter Korridor)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='alloc:gold') THEN
    RAISE EXCEPTION 'FAIL [6]: kein gold-Allokations-Alert (pp-Fallback ausserhalb)'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='alloc:sp500') THEN
    RAISE EXCEPTION 'FAIL [6]: sp500 darf KEINEN Alert haben (im Korridor)'; END IF;
  RAISE NOTICE 'PASS [rebalanceable_drift: sp500 im Korridor still, korea+gold breach]';

  -- (7) non_rebalanceable_targets: der real_estate-Ziel-Block (nicht handelbar) -> gelistet, KEIN Alert
  IF jsonb_array_length(r->'non_rebalanceable_targets') <> 1
     OR (r->'non_rebalanceable_targets'->0->>'key') <> 'real_estate' THEN
    RAISE EXCEPTION 'FAIL [7]: real_estate sollte non_rebalanceable_target sein, got %', r->'non_rebalanceable_targets'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='alloc:real_estate') THEN
    RAISE EXCEPTION 'FAIL [7]: nicht-handelbarer Block darf NIE Drift-Alarm geben'; END IF;
  RAISE NOTICE 'PASS [non_rebalanceable_targets: real_estate gelistet, kein Drift-Alarm]';

  -- (8) net_worth_by_class deckt ALLE Klassen ab (inkl. real_estate abgeleitet)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'net_worth_by_class') c WHERE c->>'class'='real_estate') THEN
    RAISE EXCEPTION 'FAIL [8]: net_worth_by_class enthält real_estate nicht, got %', r->'net_worth_by_class'; END IF;
  RAISE NOTICE 'PASS [net_worth_by_class deckt alle Klassen ab]';

  -- (9) Pflicht-Advisory: unmapped (altcoin), null_tag (UNT), null_price (NOP)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advisories'->'unmapped') u WHERE u->>'asset_class'='altcoin') THEN
    RAISE EXCEPTION 'FAIL [9]: altcoin-Tag nicht als unmapped gemeldet, got %', r->'advisories'->'unmapped'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advisories'->'null_tag') t WHERE t->>'symbol'='UNT') THEN
    RAISE EXCEPTION 'FAIL [9]: UNT nicht als null_tag gemeldet, got %', r->'advisories'->'null_tag'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advisories'->'null_price') p WHERE p->>'symbol'='NOP') THEN
    RAISE EXCEPTION 'FAIL [9]: NOP nicht als null_price gemeldet, got %', r->'advisories'->'null_price'; END IF;
  -- Kurs-Luecken 2026-10-27: null_price kommt aus fn_holding_price_status (Name + Status je Position), der
  -- Datenqualitaets-Text nennt die Namen, und es gibt KEINEN null_price-latch_key (melden tut der Kurs-Luecken-Cron)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advisories'->'null_price') p
                 WHERE p->>'name' = 'Gold2 (kein Kurs)' AND p->>'status' = 'missing') THEN
    RAISE EXCEPTION 'FAIL [9 null_price name/status]: got %', r->'advisories'->'null_price'; END IF;
  IF position('Gold2 (kein Kurs)' IN (SELECT (a->'msg')::text FROM jsonb_array_elements(r->'alerts') a
                                      WHERE a->>'kind' = 'data_quality' LIMIT 1)) = 0 THEN
    RAISE EXCEPTION 'FAIL [9 dq names]: Datenqualitaets-Text nennt die kurslose Position nicht'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a, jsonb_array_elements_text(COALESCE(a->'latch_keys', '[]'::jsonb)) k
             WHERE k LIKE 'null_price%') THEN
    RAISE EXCEPTION 'FAIL [9 latch]: null_price darf keinen latch_key tragen (Doppel-Meldung)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='data_quality') THEN
    RAISE EXCEPTION 'FAIL [9]: kein data_quality-Sammelalert'; END IF;
  RAISE NOTICE 'PASS [Pflicht-Advisory: unmapped/null_tag/null_price + data_quality-Alert]';

  -- (9b) 2026-10-23: outside_plan ist weder unmapped noch null_tag; der Alarm nennt die Namen und latcht je Position
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'advisories'->'unmapped') u WHERE u->>'asset_class'='outside_plan') THEN
    RAISE EXCEPTION 'FAIL [9b]: outside_plan als unmapped gemeldet: %', r->'advisories'->'unmapped'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a, jsonb_array_elements(a->'msg') m
                 WHERE a->>'kind'='data_quality' AND m->>'value'='finance.advisor.dq_null_tag'
                   AND m->'params'->>'names' LIKE '%Ungetaggt%') THEN
    RAISE EXCEPTION 'FAIL [9b]: dq_null_tag ohne Namen: %', (SELECT a FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='data_quality'); END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a, jsonb_array_elements_text(a->'latch_keys') k
                 WHERE a->>'kind'='data_quality' AND k LIKE 'null_tag:%') THEN
    RAISE EXCEPTION 'FAIL [9b]: latch_keys fehlen'; END IF;
  RAISE NOTICE 'PASS [outside_plan kein Datenhinweis; dq_null_tag mit Namen + latch_keys]';

  -- (10) price_as_of gesetzt, NICHT stale (Kurse von heute)
  IF (r->'advisories'->>'price_stale')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [10]: price_stale sollte false sein (heutige Kurse), got %', r->'advisories'; END IF;
  IF (r->'advisories'->>'price_as_of') IS NULL THEN
    RAISE EXCEPTION 'FAIL [10]: price_as_of nicht gesetzt'; END IF;
  RAISE NOTICE 'PASS [price_as_of gesetzt, nicht stale]';

  -- (11) Zielportfolio-Drift: Marktwert << 900000 -> target_portfolio-Alert
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio') THEN
    RAISE EXCEPTION 'FAIL [11]: kein target_portfolio-Alert (Marktwert unter Zielspanne)'; END IF;
  RAISE NOTICE 'PASS [Zielportfolio-Drift: Marktwert unter Soll -> Alert]';

  -- (12) partial-tolerant: target_allocation entfernen -> rebalanceable_drift leer, kein Crash
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date,'YYYY-MM-DD'))))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  IF jsonb_array_length(r->'rebalanceable_drift') <> 0 THEN
    RAISE EXCEPTION 'FAIL [12]: ohne Plan-Allokation sollte rebalanceable_drift leer sein, got %', r->'rebalanceable_drift'; END IF;
  RAISE NOTICE 'PASS [partial-tolerant: ohne target_allocation kein Drift, kein Crash]';
END $$;

-- ============================================================
-- WS3 — FIRE-Topf-Semantik: target_portfolio_basis (investment default), Depot-Earmark im Pot,
--   fixed_deposit non-rebalanceable-Guard, ELSE-Fail-Safe. Differenz-basierte Assertions (robust gegen
--   die Bestands-Fixtures der vorigen Bloecke: nur der jeweils variierte Posten zaehlt in die Differenz).
-- ============================================================
DO $$
DECLARE
  r jsonb;
  v_inv numeric; v_net numeric; v_e0 numeric; v_e1 numeric; v_unk numeric;
  v_loan int; v_settle int; v_dep int; v_goal int;
BEGIN
  -- Loan-Konto (Hypothek): Restschuld -200000
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ws3_loan__','loan','EUR','active') RETURNING id INTO v_loan;
  UPDATE finance.account_balances SET balance = -200000 WHERE account_id = v_loan;

  -- Plan: sehr hohes Zielportfolio -> der target_portfolio-Alert feuert sicher (Pot << Ziel); Basis variieren wir.
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'goal', jsonb_build_object('target_portfolio_eur', 100000000),
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date,'YYYY-MM-DD'))))
  WHERE name = 'financial_planning';

  -- (W1) investment (default, kein basis-key): Hypothek wird NICHT abgezogen
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_inv FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';

  -- net_worth: Hypothek abgezogen
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,goal,target_portfolio_basis}', '"net_worth"') WHERE name='financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_net FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';

  IF v_inv IS NULL OR v_net IS NULL THEN RAISE EXCEPTION 'FAIL [W1]: target_portfolio-Alert fehlt (inv=%, net=%)', v_inv, v_net; END IF;
  -- Audit Paket 3 (bewusste Vertragsaenderung): net_worth = investment + Immobilien + Kredite. Der Kredit hier haengt
  -- an keiner Immobilie -> Diff = Immobilienwerte der Vor-Bloecke (__ar_re__ 250.000) - 200.000.
  IF round(v_net - v_inv, 2) <> (SELECT sum(current_value) FROM finance.real_estate WHERE status = 'active' AND current_value IS NOT NULL) - 200000 THEN
    RAISE EXCEPTION 'FAIL [W1]: net_worth - investment = Immobilien - 200000 erwartet, got % - % = %', v_net, v_inv, v_net - v_inv; END IF;
  RAISE NOTICE 'PASS [W1: investment zieht die Hypothek NICHT ab; net_worth zaehlt Immobilien + Kredite]';

  -- (W2) Depot fliesst VOLL in den FIRE-Pot (WS-B: Earmark-Netting entfallen): zurueck auf investment,
  --   Pot messen, dann Depot anlegen -> Pot waechst um den vollen Depot-Wert (kein Earmark-Abzug mehr).
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,goal,target_portfolio_basis}', '"investment"') WHERE name='financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_e0 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ws3_settle__','cash','EUR','active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__ws3_depot__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_dep,'WS300000001','WS3','WS3 ETF',100,100,'EUR','sp500');   -- Buchwert-Fallback 100*100 = 10000

  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_e1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';
  IF round(v_e1 - v_e0, 2) <> 10000 THEN
    RAISE EXCEPTION 'FAIL [W2]: Delta erwartet +10000 (voller Depot-Wert, kein Earmark-Netting), got % - % = %', v_e1, v_e0, v_e1 - v_e0; END IF;
  RAISE NOTICE 'PASS [W2: Depot fliesst voll in den FIRE-Pot (+10000, WS-B kein Earmark-Abzug)]';

  -- (W3) fixed_deposit als Plan-Block -> non_rebalanceable, KEIN Drift-Alarm (sonst Dauer-Fehlalarm)
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_allocation}',
    jsonb_build_object('rebalance_drift_pp',5,'blocks', jsonb_build_array(
      jsonb_build_object('key','sp500','name','S&P','target_pct',80),
      jsonb_build_object('key','fixed_deposit','name','Festgeld','target_pct',20)))) WHERE name='financial_planning';
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='alloc:fixed_deposit') THEN
    RAISE EXCEPTION 'FAIL [W3]: fixed_deposit-Plan-Block darf KEINEN Drift-Alarm geben'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'non_rebalanceable_targets') n WHERE n->>'key'='fixed_deposit') THEN
    RAISE EXCEPTION 'FAIL [W3]: fixed_deposit-Plan-Block sollte non_rebalanceable_target sein, got %', r->'non_rebalanceable_targets'; END IF;
  -- Audit Paket 3: sp500 = einziger handelbarer Block -> normiert 100 % (Plan-Roh-Anteil 80 bleibt als plan_pct sichtbar)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rebalanceable_drift') b
                 WHERE b->>'key'='sp500' AND (b->>'target_pct')::numeric = 100 AND (b->>'plan_pct')::numeric = 80) THEN
    RAISE EXCEPTION 'FAIL [W3]: sp500 erwartet target_pct 100 (normiert) + plan_pct 80, got %', r->'rebalanceable_drift'; END IF;
  RAISE NOTICE 'PASS [W3: fixed_deposit-Plan-Block = non_rebalanceable, kein Drift-Alarm]';

  -- (W4) unbekannte Basis -> ELSE-Fail-Safe = wie investment (gleicher Pot wie v_e1)
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,goal,target_portfolio_basis}', '"bogus"') WHERE name='financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_unk FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';
  IF v_unk IS DISTINCT FROM v_e1 THEN
    RAISE EXCEPTION 'FAIL [W4]: unbekannte Basis muss wie investment rechnen, got % vs % (v_e1)', v_unk, v_e1; END IF;
  RAISE NOTICE 'PASS [W4: unbekannte target_portfolio_basis degradiert als investment (ELSE-Fail-Safe)]';
END $$;

-- ============================================================
-- WS-3a — Custodial-Scope: Kind-Vermoegen (role='child') faellt aus dem FIRE-Pool (T2), bleibt aber
--   im Gesamt-Vermoegen (T1, net_worth_by_class). Erkennung rollen-basiert ueber core.fn_household_persons().
--   Differenz-basiert (robust gegen die Bestands-Fixtures): Kind-Depot erhoeht den FIRE-Pool NICHT,
--   ein Haushalts-Depot gleichen Werts schon -> die ROLLE entscheidet, nicht die Existenz.
-- ============================================================
DO $$
DECLARE
  r jsonb;
  v_p0 numeric; v_p1 numeric; v_p2 numeric; v_sp_before numeric; v_sp_after numeric;
  v_kid_cash int; v_kid_depot int; v_hh_cash int; v_hh_depot int;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('rev_kid','Kind Beispiel','child');
  -- sauberer Plan: sehr hohes Zielportfolio (Alert feuert sicher), investment-Basis (kein loan-Abzug)
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'goal', jsonb_build_object('target_portfolio_eur', 100000000),
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date,'YYYY-MM-DD'))))
    WHERE name = 'financial_planning';

  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_p0 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';
  SELECT COALESCE((SELECT (c->>'value_eur')::numeric FROM jsonb_array_elements(r->'net_worth_by_class') c WHERE c->>'class'='sp500'),0) INTO v_sp_before;

  -- KIND-Custodial-Depot 10000 (owner child)
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__rev_kid_cash__','cash','EUR','active','rev_kid') RETURNING id INTO v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__rev_kid_depot__','stocks_depot','EUR','active', v_kid_cash, 'rev_kid') RETURNING id INTO v_kid_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_kid_depot,'REV0000001','REVK','Kind ETF',100,100,'EUR','sp500');   -- Buchwert-Fallback 10000

  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_p1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';
  SELECT COALESCE((SELECT (c->>'value_eur')::numeric FROM jsonb_array_elements(r->'net_worth_by_class') c WHERE c->>'class'='sp500'),0) INTO v_sp_after;

  IF round(v_p1 - v_p0, 2) <> 0 THEN
    RAISE EXCEPTION 'FAIL [WS3a-1]: Kind-Depot darf den FIRE-Pool NICHT erhöhen (T2), Delta %', v_p1 - v_p0; END IF;
  IF round(v_sp_after - v_sp_before, 2) <> 10000 THEN
    RAISE EXCEPTION 'FAIL [WS3a-1]: net_worth_by_class sp500 sollte +10000 (Kind IM Gesamt-Vermögen T1), Delta %', v_sp_after - v_sp_before; END IF;
  RAISE NOTICE 'PASS [WS3a: Kind-Depot RAUS aus FIRE-Pool (T2), DRIN im Gesamt-Vermögen (T1)]';

  -- Kontrast: HAUSHALTS-Depot (owner NULL) gleicher Wert -> FIRE-Pool STEIGT um 10000 (Rolle, nicht Existenz)
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rev_hh_cash__','cash','EUR','active') RETURNING id INTO v_hh_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__rev_hh_depot__','stocks_depot','EUR','active', v_hh_cash) RETURNING id INTO v_hh_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_hh_depot,'REV0000002','REVH','HH ETF',100,100,'EUR','sp500');

  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_p2 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key'='target_portfolio';
  IF round(v_p2 - v_p1, 2) <> 10000 THEN
    RAISE EXCEPTION 'FAIL [WS3a-2]: Haushalts-Depot sollte den FIRE-Pool um 10000 erhöhen, Delta %', v_p2 - v_p1; END IF;
  RAISE NOTICE 'PASS [WS3a: Haushalts-Depot (owner NULL) IM FIRE-Pool — die Rolle entscheidet]';
END $$;

-- ============================================================
-- Phase-0 Item-4 — die tunbaren Schwellen werden ueber core.fn_config_get('core','advisor',...) gelesen
--   (vorher inline core.config). Regression: ein NICHT-Default plan_stale_days wird geehrt (nicht der
--   COALESCE-Default 365). Faengt zugleich einen falschen Paket-Parameter ab (falsches Paket -> NULL ->
--   COALESCE-Default 365 -> kein Alert), der sonst still drueber liefe.
-- ============================================================
DO $$
DECLARE
  r        jsonb;
  v_target numeric;
  v_cnt    int;
BEGIN
  -- Nicht-Default-Schwelle 30 Tage (Default waere 365), Paket 'core' (= wo die Advisor-Config wohnt).
  INSERT INTO core.config (package, category, key, value)
  VALUES ('core', 'advisor', 'plan_stale_days', '30')
  ON CONFLICT (category, key) DO UPDATE SET value = '30', package = 'core';

  -- Plan-Stempel exakt 100 Tage alt: unter Default 365 NICHT stale, unter konfigurierten 30 stale.
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date - 100, 'YYYY-MM-DD'))))
  WHERE name = 'financial_planning';

  r := finance.fn_advisor_review('finance');

  -- (a) Staleness-Alert MUSS feuern (100 > konfigurierte 30) -> Config wurde gelesen, nicht der Default.
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'staleness';
  IF v_cnt < 1 THEN
    RAISE EXCEPTION 'FAIL [Item4]: kein staleness-Alert bei plan_stale_days=30 + 100 Tage alt -> Config nicht gelesen (alerts=%)', r->'alerts'; END IF;
  -- (b) sein target == die KONFIGURIERTEN 30 (nicht 365): beweist den Config-Read-Pfad exakt.
  SELECT (a->>'target')::numeric INTO v_target FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'staleness';
  IF v_target IS DISTINCT FROM 30 THEN
    RAISE EXCEPTION 'FAIL [Item4]: staleness target=% erwartet 30 (konfigurierter Wert nicht geehrt -> falsches Paket/Default-Fallback)', v_target; END IF;
  RAISE NOTICE 'PASS [Item4: fn_advisor_review ehrt NICHT-Default core.config plan_stale_days über fn_config_get]';
END $$;

-- ============================================================
-- Phase A — Staleness-Nudges: tax_year_staleness (Vorjahr-Stempel, Bool-Toggle) + risk_profile_staleness
--   (as_of-Alter, day-Schwelle). Beide additive Alerts in fn_advisor_review; nur die rohen Alerts werden
--   geprueft (Latch sitzt im Core-Wrapper). Prueft NUR die jeweiligen metric_keys -> plan_staleness daneben
--   ist egal.
-- ============================================================
DO $$
DECLARE
  r       jsonb;
  v_cnt   int;
  v_prior text := to_char(date_trunc('year', current_date) - interval '1 day', 'YYYY-MM-DD'); -- 31.12. Vorjahr
  v_curr  text := to_char(date_trunc('year', current_date), 'YYYY-MM-DD');                     -- 01.01. lfd. Jahr
BEGIN
  -- (A1) UNSEEDED default-ON (M2): kein tax_year_nudge-Config-Eintrag -> Vorjahr-Stempel feuert den Nudge.
  DELETE FROM core.config WHERE category = 'advisor' AND key = 'tax_year_nudge';
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      '_meta', jsonb_build_object('last_confirmed_at', v_prior)))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'tax_year_staleness';
  IF v_cnt < 1 THEN RAISE EXCEPTION 'FAIL [PA-tax1]: kein tax_year_staleness bei Vorjahr-Stempel + unseeded (default-ON) (alerts=%)', r->'alerts'; END IF;
  -- der Alert traegt einen nicht-leeren paket-gerenderten text (Generik-Vertrag)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'tax_year_staleness' AND COALESCE((a->'msg')::text,'') <> '') THEN
    RAISE EXCEPTION 'FAIL [PA-tax1]: tax_year_staleness ohne gerenderten text'; END IF;
  RAISE NOTICE 'PASS [PA-tax1: Vorjahr-Stempel + unseeded -> tax_year_staleness (default-ON via COALESCE)]';

  -- (A2) tax_year_nudge='false' -> trotz Vorjahr-Stempel KEIN Alert.
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'tax_year_nudge', 'false')
    ON CONFLICT (category, key) DO UPDATE SET value = 'false', package = 'core';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'tax_year_staleness';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [PA-tax2]: tax_year_staleness trotz Toggle=false (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [PA-tax2: tax_year_nudge=false -> kein Alert]';

  -- (A3) Stempel im laufenden Jahr -> kein Alert (Toggle wieder true).
  UPDATE core.config SET value = 'true' WHERE category = 'advisor' AND key = 'tax_year_nudge';
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      '_meta', jsonb_build_object('last_confirmed_at', v_curr)))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'tax_year_staleness';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [PA-tax3]: tax_year_staleness im selben Jahr (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [PA-tax3: Stempel im laufenden Jahr -> kein tax_year-Alert]';

  -- (B1) risk_profile_staleness: altes as_of (vor 800 T) -> Alert.
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'risk_profile', jsonb_build_object('risk_tolerance', 'medium', 'as_of', to_char(current_date - 800, 'YYYY-MM-DD')),
      '_meta', jsonb_build_object('last_confirmed_at', v_curr)))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'risk_profile_staleness';
  IF v_cnt < 1 THEN RAISE EXCEPTION 'FAIL [PA-rp1]: kein risk_profile_staleness bei as_of vor 800 T (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [PA-rp1: altes risk_profile.as_of -> risk_profile_staleness]';

  -- (B2) frisches as_of -> kein Alert.
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,risk_profile,as_of}', to_jsonb(v_curr))
   WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'risk_profile_staleness';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [PA-rp2]: risk_profile_staleness bei frischem as_of (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [PA-rp2: frisches as_of -> kein Alert]';

  -- (B3) risk_profile ohne as_of -> kein Alert, kein Crash (partial-tolerant).
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'risk_profile', jsonb_build_object('risk_tolerance', 'high'),
      '_meta', jsonb_build_object('last_confirmed_at', v_curr)))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cnt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'risk_profile_staleness';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [PA-rp3]: risk_profile_staleness ohne as_of (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [PA-rp3: risk_profile ohne as_of -> kein Alert, kein Crash]';
END $$;

-- ============================================================
-- WS-C3 — Reserve-Coverage-Alert + Engpass-Reihung im Digest.
--   (RC1) ein Konto, dessen Saldo die getaggte Sparziel-Reserve nicht deckt (account_reserve_status.breach)
--         -> reserve_coverage-Alert (nennt das Konto). completed-Ziel gibt die Reserve frei -> Alert weg.
--   (RC2) Digest-goals-Ordering deterministisch: gleiches target_date -> priority ASC NULLS LAST, dann name.
-- ============================================================
DO $$
DECLARE
  r jsonb; v_acct INT; v_goal INT; v_txt text;
  v_d date := current_date + 400;   -- gemeinsames Zieldatum fuer die Ordering-Probe
BEGIN
  -- KONTO-skopiert (robust): die Bestands-Fixtures dieses Tests breachen u. U. eigene Konten -> wir pruefen
  -- NICHT die globale Alert-Zahl, sondern ob GENAU UNSER Konto im reserve_coverage-Text auftaucht/verschwindet.
  -- Breach erzeugen: Reserve +800 (getaggt) + un-getaggte Ausgabe -500 -> Saldo 300 < reserviert 800.
  SELECT finance.fn_create_account('{"name":"__rc_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO r; v_acct := (r->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rc_goal__', 9000, current_date + 365, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_acct, 800, current_date - 10, 'transfer', v_goal, gen_random_uuid()),
    (v_acct, -500, current_date - 5, 'other', NULL, NULL);

  r := finance.fn_advisor_review('finance');
  SELECT (a->'msg')::text INTO v_txt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'reserve_coverage' LIMIT 1;
  IF COALESCE(v_txt, '') NOT LIKE '%__rc_acct__%' THEN
    RAISE EXCEPTION 'FAIL [RC1]: reserve_coverage-Text nennt unser breach-Konto nicht: %', v_txt; END IF;
  RAISE NOTICE 'PASS [RC1: Konto unter Reserve -> reserve_coverage-Alert nennt das Konto]';

  -- completed-Ziel gibt die Reserve frei -> UNSER Konto ent-breacht -> faellt aus dem Text (andere Konten egal).
  UPDATE finance.savings_goals SET status = 'completed' WHERE id = v_goal;
  r := finance.fn_advisor_review('finance');
  SELECT (a->'msg')::text INTO v_txt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'reserve_coverage' LIMIT 1;
  IF COALESCE(v_txt, '') LIKE '%__rc_acct__%' THEN
    RAISE EXCEPTION 'FAIL [RC1-clear]: unser Konto trotz completed-Ziel noch im reserve_coverage-Text: %', v_txt; END IF;
  RAISE NOTICE 'PASS [RC1-clear: completed-Ziel gibt Reserve frei -> unser Konto fällt aus dem Alert]';

  -- (RC2) Digest-Ordering: drei Ziele gleichen Zieldatums, priority 1 / 2 / NULL -> Reihenfolge a, b, c.
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, priority) VALUES
    ('__rc_ord_a__', 1000, v_d, 'active', 1),
    ('__rc_ord_b__', 1000, v_d, 'active', 2),
    ('__rc_ord_c__', 1000, v_d, 'active', NULL);
  r := finance.fn_advisor_review('finance');
  v_txt := (r->'digest'->'lines')::text;   -- Sparziel-Zeilen in Digest-Reihenfolge
  IF NOT (position('__rc_ord_a__' IN v_txt) > 0 AND position('__rc_ord_b__' IN v_txt) > 0 AND position('__rc_ord_c__' IN v_txt) > 0) THEN
    RAISE EXCEPTION 'FAIL [RC2]: nicht alle drei Ordering-Ziele im Digest: %', v_txt; END IF;
  IF NOT (position('__rc_ord_a__' IN v_txt) < position('__rc_ord_b__' IN v_txt)
          AND position('__rc_ord_b__' IN v_txt) < position('__rc_ord_c__' IN v_txt)) THEN
    RAISE EXCEPTION 'FAIL [RC2]: Digest-Ordering falsch (erwartet a<b<c bei gleichem Datum: prio 1<2<NULL-LAST), got Positionen %/%/%',
      position('__rc_ord_a__' IN v_txt), position('__rc_ord_b__' IN v_txt), position('__rc_ord_c__' IN v_txt); END IF;
  RAISE NOTICE 'PASS [RC2: Digest-goals geordnet target_date->priority NULLS LAST->name (a<b<c)]';
END $$;

-- ============================================================
-- WS-B Stufe 3 — Lebenszyklus + Deckungs-Dialog (Berater-Zusaetze).
--   (S1) Uebererfuellt-Zweig: aktives Ziel mit current_amount >= target -> savings_goal_reached-Alert
--        (feuert NUR bei erreicht/uebertroffen, NICHT bei "hinter Plan").
--   (S2) Depot-Deckungs-Dialog: breach (depot_reserve_status) + Ziel HINTER Plan -> reserve_coverage_depot-Alert
--        (nennt Depot + Lever) + (S2-tax) Steuer-Hinweis (Abgeltungssteuer) beim Absichern.
--   (S3) Smart-Unterdrueckung: identischer breach, aber Ziel ON PACE (hohe laufende Rate = rp.monthly_equivalent)
--        -> KEIN reserve_coverage_depot-Alert fuer dieses Depot. Beweist laufende Rate != observed (gleicher
--        observed-Pace in S2/S3; nur die konfigurierte Vorwaerts-Rate unterscheidet).
--   (S4) Fremdwaehrungs-Caveat: breached Depot mit non-EUR-Holding -> FX-Hinweis im Alert-Text.
--   (S5) Reserve-Aufschluesselung Cash/Depot im Digest.
-- ============================================================
DO $$
DECLARE
  r jsonb; v_txt text;
  v_fund INT; v_p1 INT; v_p2 INT; v_p3 INT;
  v_rp_b INT;
  v_gh INT; v_ga INT; v_gb INT; v_gc INT;
  v_old timestamptz := now() - interval '24 months';
  v_td  date := current_date + 30;
BEGIN
  -- gemeinsames Funding-/Cash-Konto
  SELECT finance.fn_create_account('{"name":"__s3_fund__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO r;
  v_fund := (r->>'account_id')::int;

  -- ---------- (S1) Uebererfuellt ----------
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
  VALUES ('__s3_over__', 1000, current_date + 60, 'active', now() - interval '10 days') RETURNING id INTO v_gh;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
  VALUES (v_fund, 1200, current_date - 5, 'transfer', v_gh, gen_random_uuid());   -- current_amount 1200 >= target 1000

  r := finance.fn_advisor_review('finance');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'kind' = 'savings_goal_reached' AND (a->'msg')::text LIKE '%__s3_over__%') THEN
    RAISE EXCEPTION 'FAIL [S1]: kein savings_goal_reached-Alert für uebererfuelltes Ziel (alerts=%)', r->'alerts'; END IF;
  -- darf NICHT als savings_pace (hinter Plan) erscheinen
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
             WHERE a->>'kind' = 'savings_pace' AND (a->'msg')::text LIKE '%__s3_over__%') THEN
    RAISE EXCEPTION 'FAIL [S1]: uebererfuelltes Ziel fälschlich als savings_pace (hinter Plan) gemeldet'; END IF;
  RAISE NOTICE 'PASS [S1: current >= target -> savings_goal_reached, nicht savings_pace]';

  -- (S1b) nur durch Zuordnung gedeckt (Sparziel-Zweckbindung 2026-10-27): die Karte der Zuordnung/Anlage meldete die
  -- Deckung schon -> kein periodischer savings_goal_reached-Alert (Rauschen fuer "Geld liegt schon da").
  DECLARE v_p2p int; v_ge int; BEGIN
    v_p2p := (finance.fn_create_account('{"name":"__s3_p2p__","account_type":"p2p","opening_balance":5000}'::jsonb)->>'account_id')::int;
    INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__s3_earmarked__', 3000, current_date + 60, 'active') RETURNING id INTO v_ge;
    PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_ge, 'account_id', v_p2p, 'amount', 3000));
    r := finance.fn_advisor_review('finance');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
               WHERE a->>'kind' = 'savings_goal_reached' AND (a->'msg')::text LIKE '%__s3_earmarked__%') THEN
      RAISE EXCEPTION 'FAIL [S1b]: nur zugeordnet gedecktes Ziel darf keinen savings_goal_reached-Alert ausloesen'; END IF;
    IF (SELECT earmarked_amount FROM finance.savings_goal_progress WHERE id = v_ge) IS DISTINCT FROM 3000 THEN
      RAISE EXCEPTION 'FAIL [S1b earmarked_amount]'; END IF;
    UPDATE finance.savings_goals SET status = 'cancelled' WHERE id = v_ge;   -- stoert die folgenden Bloecke nicht
  END;
  RAISE NOTICE 'PASS [S1b: nur durch Zuordnung gedeckt -> kein erreicht-Alert]';

  -- ---------- (S2) Depot-Deckungs-Dialog: breach + hinter Plan -> Alert + Steuer-Hinweis ----------
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__s3_depot1__','stocks_depot','EUR','active', v_fund) RETURNING id INTO v_p1;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_p1,'S300000001','S3A','S3 EUR ETF', 10, 100, 'EUR', 'sp500');   -- Buchwert ~1000
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
  VALUES ('__s3_behind__', 10000, v_td, 'active', v_old) RETURNING id INTO v_ga;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
  VALUES (v_ga, v_p1, 1500, 'manual');   -- reserved 1500 > market ~1000 -> breach; current_amount 1500 << 10000 -> hinter Plan

  r := finance.fn_advisor_review('finance');
  SELECT (a->'msg')::text INTO v_txt FROM jsonb_array_elements(r->'alerts') a
   WHERE a->>'kind' = 'reserve_coverage_depot' AND (a->'msg')::text LIKE '%__s3_depot1__%' LIMIT 1;
  IF COALESCE(v_txt,'') = '' THEN
    RAISE EXCEPTION 'FAIL [S2]: kein reserve_coverage_depot-Alert für breached+hinter-Plan-Depot (alerts=%)', r->'alerts'; END IF;
  IF v_txt NOT LIKE '%finance.advisor.depot_reserve"%' THEN
    RAISE EXCEPTION 'FAIL [S2-tax]: Deckungs-Alert ohne Abgeltungssteuer-Hinweis beim Absichern: %', v_txt; END IF;
  RAISE NOTICE 'PASS [S2: breach + hinter Plan -> reserve_coverage_depot + Steuer-Hinweis]';

  -- ---------- (S3) Smart-Unterdrueckung: identischer breach, aber ON PACE (hohe laufende Rate) ----------
  -- Audit Paket 3: die laufende Rate fliesst in einen Topf (sonst ist das Ziel "nicht messbar" und nie on-pace)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__s3_pot__','cash','EUR','active') RETURNING id INTO v_p3;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__s3_rp_b__', v_fund, v_p3, -10000, 'month', current_date, current_date) RETURNING id INTO v_rp_b;  -- monthly_equivalent -10000
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__s3_depot2__','stocks_depot','EUR','active', v_fund) RETURNING id INTO v_p2;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_p2,'S300000002','S3B','S3 EUR ETF 2', 10, 100, 'EUR', 'sp500');   -- Buchwert ~1000
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at, recurring_payment_id)
  VALUES ('__s3_onpace__', 10000, v_td, 'active', v_old, v_rp_b) RETURNING id INTO v_gb;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
  VALUES (v_gb, v_p2, 1500, 'manual');   -- gleicher breach wie S2, aber laufende Rate 10000 >= catchup -> on pace

  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
             WHERE a->>'kind' = 'reserve_coverage_depot' AND (a->'msg')::text LIKE '%__s3_depot2__%') THEN
    RAISE EXCEPTION 'FAIL [S3]: reserve_coverage_depot trotz on-pace (laufende Rate schliesst die Lücke) -> Smart-Unterdrückung griff nicht'; END IF;
  RAISE NOTICE 'PASS [S3: identischer breach, aber laufende Rate >= Nachhol-Rate -> unterdrückt (laufende != observed)]';

  -- ---------- (S4) Fremdwaehrungs-Caveat ----------
  PERFORM finance.fn_ensure_currency('GBP');   -- non-EUR-Code registrieren (FK currencies)
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__s3_depot3__','stocks_depot','EUR','active', v_fund) RETURNING id INTO v_p3;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_p3,'S300000003','S3C','S3 GBP ETF', 10, 100, 'GBP', 'sp500');   -- non-EUR -> FX-Caveat
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, created_at)
  VALUES ('__s3_fx__', 10000, v_td, 'active', v_old) RETURNING id INTO v_gc;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
  VALUES (v_gc, v_p3, 1500, 'manual');   -- reserved 1500 > Marktwert (kein Kurs -> 0) -> breach; current 1500 << 10000 -> hinter Plan

  r := finance.fn_advisor_review('finance');
  SELECT (a->'msg')::text INTO v_txt FROM jsonb_array_elements(r->'alerts') a
   WHERE a->>'kind' = 'reserve_coverage_depot' AND (a->'msg')::text LIKE '%__s3_depot3__%' LIMIT 1;
  IF COALESCE(v_txt,'') = '' THEN
    RAISE EXCEPTION 'FAIL [S4]: kein Deckungs-Alert für das FX-Depot (alerts=%)', r->'alerts'; END IF;
  IF v_txt NOT LIKE '%finance.advisor.depot_reserve_fx_%' THEN
    RAISE EXCEPTION 'FAIL [S4]: Deckungs-Alert ohne Fremdwährungs-Caveat: %', v_txt; END IF;
  RAISE NOTICE 'PASS [S4: non-EUR-Holding im breached Depot -> FX-Caveat im Alert]';

  -- ---------- (S4b) WP-3c: null_rate-Advisory + data_quality-Alert nennen die kurslose Fremdwaehrung ----------
  -- GBP ist in Nutzung (Holding-Waehrung, s. S4) aber hat KEINE fx_rate-Zeile -> fn_to_eur=NULL -> die Roll-ups
  -- wuerden es still als 0 zaehlen. Der neue null_rate-Marker macht die Luecke sichtbar (Zwilling zu null_price).
  IF NOT (r->'advisories'->'null_rate' @> '[{"currency":"GBP"}]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [S4b null_rate]: GBP (in Nutzung, kein FX-Kurs) fehlt in advisories.null_rate (%)', r->'advisories'->'null_rate'; END IF;
  SELECT (a->'msg')::text INTO v_txt FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'data_quality' LIMIT 1;
  IF COALESCE(v_txt,'') NOT LIKE '%finance.advisor.dq_null_rate%' THEN
    RAISE EXCEPTION 'FAIL [S4b data_quality]: null_rate nicht im Daten-Hinweis (text=%)', v_txt; END IF;
  RAISE NOTICE 'PASS [S4b WP-3c: null_rate-Advisory + Daten-Hinweis melden GBP ohne Kurs (sichtbar statt still 0)]';

  -- ---------- (S5) Reserve-Aufschluesselung im Digest ----------
  v_txt := (r->'digest'->'lines')::text;
  IF COALESCE(v_txt,'') NOT LIKE '%finance.advisor.digest_reserve_heading%' THEN
    RAISE EXCEPTION 'FAIL [S5]: Digest ohne Reserve-Aufschlüsselung (text=%)', left(v_txt, 400); END IF;
  IF v_txt NOT LIKE '%__s3_behind__%' THEN
    RAISE EXCEPTION 'FAIL [S5]: Reserve-Aufschlüsselung nennt das getaggte Ziel nicht'; END IF;
  RAISE NOTICE 'PASS [S5: Digest trägt Reserve-Aufschlüsselung Cash/Depot je Konto]';
END $$;

-- ============================================================
-- Phase L — cashflow_coverage (WS-1) + savings_squeeze (WS-2).
--   monthly_cashflow_summary/monthly_liquidity_summary sind GLOBALE Single-Row-Views; die Geschwister-Bloecke
--   dieser Datei legen recurring_payments an (akkumulieren in der EINEN Transaktion). Daher in einem SAVEPOINT
--   alle bestehenden rp neutralisieren (status='paused', FK-frei, kein DELETE) + den financial_planning-Fakt
--   entfernen, kontrollierte Fixtures setzen, danach ROLLBACK TO SAVEPOINT -> Neutralisierung + Fixtures weg,
--   alle vorher gelaufenen Bloecke unberuehrt. Robust gegen Block-Reihenfolge (Reviewer m4).
--   (L1) net<0 -> cashflow_coverage (hart) + text; KEIN savings_squeeze (M5-Guard monthly_net>=0).
--   (L2) gesundes Plus -> kein Alert.   (L3) Plus < 10%-Puffer + Toggle an -> sanfter Alert.
--   (L4) Toggle aus -> kein Puffer-Alert.   (L5) Config-Schwelle (buffer_pct=0.50) geehrt (target=1000).
--   (L6) leer / income=0 -> KEIN Alert (NULL-Guard).
--   (L7) net>=0 aber net - signierte Sparziel-Foerderrate < 0 -> savings_squeeze + text, KEIN cashflow_coverage.
-- ============================================================
SAVEPOINT phase_l_cf;
UPDATE finance.recurring_payments SET status = 'paused';        -- nur im Savepoint; FK-frei
-- Plan-Fakten strippen (statt DELETE: der protected-contexts-Trigger koennte financial_planning gegen DELETE
-- sperren) -> v_facts NULL -> plan-getriebene Zweige still; cashflow/squeeze lesen nur die Cashflow-Views.
UPDATE agent.core_contexts SET metadata = metadata - 'facts' WHERE name = 'financial_planning';

DO $$
DECLARE
  r jsonb; v_cf int; v_sq int;
  v_acct int; v_res int; v_rp int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__pl_acct__','cash','EUR','active') RETURNING id INTO v_acct;

  -- (L1) Defizit: +2000 Einnahme, -3000 Ausgabe -> monthly_net -1000
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__pl_inc__', v_acct, 2000, 'month', current_date, current_date),
         ('__pl_exp__', v_acct, -3000, 'month', current_date, current_date);
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cf FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='cashflow_coverage';
  IF v_cf < 1 THEN RAISE EXCEPTION 'FAIL [L1]: kein cashflow_coverage bei net<0 (alerts=%)', r->'alerts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'kind'='cashflow_coverage' AND COALESCE((a->'msg')::text,'')<>'') THEN
    RAISE EXCEPTION 'FAIL [L1b]: cashflow_coverage ohne gerenderten text'; END IF;
  SELECT count(*) INTO v_sq FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='savings_squeeze';
  IF v_sq <> 0 THEN RAISE EXCEPTION 'FAIL [L1c]: savings_squeeze trotz reinem Defizit (M5-Guard verletzt)'; END IF;
  RAISE NOTICE 'PASS [L1: net<0 -> cashflow_coverage + text, KEIN savings_squeeze (M5)]';

  -- (L2) gesundes Plus: Ausgabe -500 -> net +1500 (>= 10% von 2000 = 200) -> kein Alert
  UPDATE finance.recurring_payments SET amount = -500 WHERE name = '__pl_exp__';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cf FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='cashflow_coverage';
  IF v_cf <> 0 THEN RAISE EXCEPTION 'FAIL [L2]: cashflow_coverage bei gesundem Plus (net 1500)'; END IF;
  RAISE NOTICE 'PASS [L2: gesundes Plus -> kein Alert]';

  -- (L3) knapper Puffer: Ausgabe -1900 -> net +100 (< 10% von 2000 = 200) -> sanfter Alert
  UPDATE finance.recurring_payments SET amount = -1900 WHERE name = '__pl_exp__';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cf FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='cashflow_coverage';
  IF v_cf < 1 THEN RAISE EXCEPTION 'FAIL [L3]: kein sanfter cashflow_coverage bei net 100 < Puffer 200'; END IF;
  RAISE NOTICE 'PASS [L3: Plus unter 10%%-Puffer -> sanfter Alert]';

  -- (L4) Toggle aus -> kein sanfter Alert (net +100)
  INSERT INTO core.config (package, category, key, value) VALUES ('core','advisor','cashflow_buffer_nudge','false')
    ON CONFLICT (category, key) DO UPDATE SET value='false', package='core';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cf FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='cashflow_coverage';
  IF v_cf <> 0 THEN RAISE EXCEPTION 'FAIL [L4]: sanfter Alert trotz cashflow_buffer_nudge=false'; END IF;
  RAISE NOTICE 'PASS [L4: Toggle aus -> kein Puffer-Alert]';

  -- (L5) Config-Schwelle geehrt: buffer_pct=0.50 + Toggle an -> net +100 < 0.5*2000=1000 -> Alert, target=1000
  UPDATE core.config SET value='true' WHERE category='advisor' AND key='cashflow_buffer_nudge';
  INSERT INTO core.config (package, category, key, value) VALUES ('core','advisor','cashflow_buffer_pct','0.50')
    ON CONFLICT (category, key) DO UPDATE SET value='0.50', package='core';
  r := finance.fn_advisor_review('finance');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'kind'='cashflow_coverage' AND (a->>'target')::numeric = 1000) THEN
    RAISE EXCEPTION 'FAIL [L5]: cashflow_buffer_pct=0.50 nicht geehrt (target!=1000), alerts=%', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [L5: cashflow_buffer_pct=0.50 geehrt (target=1000)]';
  DELETE FROM core.config WHERE category='advisor' AND key IN ('cashflow_buffer_pct','cashflow_buffer_nudge');

  -- (L6) leer / income=0: alle rp pausieren -> income NULL -> KEIN Alert, kein Crash
  UPDATE finance.recurring_payments SET status='paused';
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_cf FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='cashflow_coverage';
  IF v_cf <> 0 THEN RAISE EXCEPTION 'FAIL [L6]: cashflow_coverage bei leerem Cashflow (NULL-Guard verletzt)'; END IF;
  RAISE NOTICE 'PASS [L6: income=0/leer -> kein Alert (NULL-Guard)]';

  -- (L7) savings_squeeze: nur Einkommen __pl_inc__ +2000 aktiv + eine Sparziel-Foerderrate -2500 (Transfer auf
  --      Reservekonto, > Einkommen) -> monthly_net=+2000 (Transfer ausgeschlossen), liquidity_net=-500.
  --      M1: Rate signiert NEGATIV eingefuegt.
  UPDATE finance.recurring_payments SET status='active' WHERE name='__pl_inc__';   -- +2000 (aus L1)
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__pl_res__','cash','EUR','active') RETURNING id INTO v_res;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, target_account_id)
  VALUES ('__pl_sav__', v_acct, -2500, 'month', current_date, current_date, v_res) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id)
  VALUES ('__pl_goal__', 50000, current_date + 1000, 'active', v_rp);
  r := finance.fn_advisor_review('finance');
  SELECT count(*) INTO v_sq FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='savings_squeeze';
  IF v_sq < 1 THEN RAISE EXCEPTION 'FAIL [L7]: kein savings_squeeze (net +2000>=0, liquidity_net -500<0) (alerts=%)', r->'alerts'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'kind'='savings_squeeze' AND COALESCE((a->'msg')::text,'')<>'') THEN
    RAISE EXCEPTION 'FAIL [L7b]: savings_squeeze ohne gerenderten text'; END IF;
  SELECT count(*) INTO v_cf FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind'='cashflow_coverage';
  IF v_cf <> 0 THEN RAISE EXCEPTION 'FAIL [L7c]: cashflow_coverage trotz gesundem monthly_net (+1000)'; END IF;
  RAISE NOTICE 'PASS [L7: net>=0 + liquidity_net<0 -> savings_squeeze (signierte Rate), KEIN cashflow_coverage]';
END $$;

ROLLBACK TO SAVEPOINT phase_l_cf;

-- ============================================================
-- Audit Paket 3 — die drei Abwaegungen mit den Zahlen-Beispielen aus dem Auftrag.
--   Wie Phase L in einem SAVEPOINT: alle Bestands-rps pausieren, Salden/Bestaende/Immobilien/Vorsorge der
--   Geschwister-Bloecke neutralisieren -> kontrollierte, absolute Erwartungen; danach ROLLBACK TO SAVEPOINT.
--   (C1) 3000 / Konsum 2500 / ETF 600 -> kein cashflow_coverage, savings_squeeze gap 100.
--   (C2) 3000 / Konsum 2200 + Kreditrate 1000 (Zins 400, Tilgung 600) -> frei -200 -> cashflow_coverage, kein squeeze.
--   (M1) Zielmix Welt 50 / Anleihen 20 / Cash 10 / Festgeld 20 genau gehalten -> kein alloc-Alert, Welt-Soll 62,5.
--   (M2) Reviewer #6: kein cash-Block + 10.000 Giro -> Giro faellt aus dem Nenner (kein Dauer-Drift).
--   (M3) Reviewer #6: zurueckgelegtes Sparziel-Geld blaeht "Cash uebergewichtet" nicht auf.
--   (N1) net_worth: Haus 300.000 + Hypothek -200.000 -> Topf +100.000 gegenueber investment.
--   (N2) Haus ohne Wert bzw. kind-besessen -> Haus UND sein Kredit fallen beide heraus (symmetrisch).
--   (G1) Sparziel mit laufender Rate ohne Topf -> savings_goal_unmeasurable, KEIN savings_pace.
--   (E1) Notreserve liest das freie Cash aus fn_liquidity_snapshot (eine Adresse).
-- ============================================================
SAVEPOINT paket3;
UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.account_balances SET balance = 0;
UPDATE finance.depot_holdings SET shares = 0;
UPDATE finance.real_estate SET current_value = NULL;
UPDATE finance.pension SET current_value = NULL;
DELETE FROM finance.savings_goal_reserve_entries;
UPDATE finance.savings_goals SET status = 'completed';
UPDATE agent.core_contexts SET metadata = metadata - 'facts' WHERE name = 'financial_planning';

DO $$
DECLARE
  r jsonb; v_cnt int; v_val numeric; v_inv numeric; v_nw numeric;
  v_giro int; v_depot int; v_fd int; v_loan int; v_rp int; v_re int; v_goal int; v_pot int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__p3_giro__','cash','EUR','active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__p3_depot__','stocks_depot','EUR','active', v_giro) RETURNING id INTO v_depot;

  -- ---------- (C1) Auftrags-Beispiel Monatsueberschuss ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__p3_salary__', v_giro, 3000, 'month', current_date, current_date),
    ('__p3_rent__',   v_giro, -2500, 'month', current_date, current_date);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__p3_etf__', v_giro, -600, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__p3_etf_plan__', v_depot, 'P3W', 'World', v_rp);
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'cashflow_coverage') THEN
    RAISE EXCEPTION 'FAIL [C1]: ETF-Sparplan darf keinen Fixkosten-Alarm ausloesen (alerts=%)', r->'alerts'; END IF;
  SELECT (a->>'drift')::numeric INTO v_val FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'savings_squeeze';
  IF v_val IS DISTINCT FROM 100.00 THEN
    RAISE EXCEPTION 'FAIL [C1]: savings_squeeze mit gap 100 erwartet (frei 500, Sparen 600), got % (alerts=%)', v_val, r->'alerts'; END IF;
  IF (r->'digest'->>'free')::numeric IS DISTINCT FROM 500.00 OR (r->'digest'->>'account_change')::numeric IS DISTINCT FROM -100.00 THEN
    RAISE EXCEPTION 'FAIL [C1 digest]: frei 500 / Konto -100 erwartet, got %', r->'digest'; END IF;
  RAISE NOTICE 'PASS [C1: 3000/2500/ETF 600 -> kein Fixkosten-Alarm, savings_squeeze 100]';

  -- ---------- (C2) Reviewer #1: Tilgung ist Pflicht, kein "Sparrate senken" ----------
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name = '__p3_etf__';
  UPDATE finance.recurring_payments SET amount = -2200 WHERE name = '__p3_rent__';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__p3_loan__','loan','EUR','active') RETURNING id INTO v_loan;
  UPDATE finance.account_balances SET balance = -80000 WHERE account_id = v_loan;    -- 80.000 @ 6 % = Zins 400
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__p3_loan_rate__', v_giro, -1000, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate,
                             loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__p3_loan__', 100000, current_date - 365, 6, v_loan, v_giro, v_rp);
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_val FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'cashflow_coverage';
  IF v_val IS DISTINCT FROM -200.00 THEN
    RAISE EXCEPTION 'FAIL [C2]: cashflow_coverage mit frei -200 erwartet (Pflicht 3200 > Einnahmen 3000), got % (alerts=%)', v_val, r->'alerts'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'savings_squeeze') THEN
    RAISE EXCEPTION 'FAIL [C2]: savings_squeeze bei reinem Pflicht-Defizit (nichts wird gespart)'; END IF;
  RAISE NOTICE 'PASS [C2: Kreditrate inkl. Tilgung uebersteigt die Einnahmen -> cashflow_coverage, kein squeeze]';
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name IN ('__p3_loan_rate__', '__p3_rent__', '__p3_salary__');
  UPDATE finance.account_balances SET balance = 0 WHERE account_id = v_loan;

  -- ---------- (M1) Zielmix genau gehalten -> kein Drift ----------
  INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__p3_fd__','fixed_deposit','EUR','active','2030-12-31') RETURNING id INTO v_fd;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class) VALUES
    (v_depot, 'P3000000001', 'P3W', 'World', 500, 100, 'EUR', 'world'),   -- 50.000 (Buchwert-Fallback)
    (v_depot, 'P3000000002', 'P3B', 'Bonds', 200, 100, 'EUR', 'bonds');  -- 20.000
  UPDATE finance.account_balances SET balance = 10000 WHERE account_id = v_giro;
  UPDATE finance.account_balances SET balance = 20000 WHERE account_id = v_fd;
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'target_allocation', jsonb_build_object('rebalance_drift_pp', 5, 'blocks', jsonb_build_array(
          jsonb_build_object('key','world','name','Welt','target_pct',50),
          jsonb_build_object('key','bonds','name','Anleihen','target_pct',20),
          jsonb_build_object('key','cash','name','Cash','target_pct',10),
          jsonb_build_object('key','fixed_deposit','name','Festgeld','target_pct',20))),
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date,'YYYY-MM-DD'))))
  WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'allocation_drift') THEN
    RAISE EXCEPTION 'FAIL [M1]: exakt gehaltener Plan darf keinen Drift-Alarm geben (alerts=%, drift=%)', r->'alerts', r->'rebalanceable_drift'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rebalanceable_drift') b
                 WHERE b->>'key' = 'world' AND (b->>'target_pct')::numeric = 62.5 AND (b->>'actual_pct')::numeric = 62.5
                   AND (b->>'plan_pct')::numeric = 50) THEN
    RAISE EXCEPTION 'FAIL [M1]: Welt erwartet Soll 62,5 = Ist 62,5 (Plan 50), got %', r->'rebalanceable_drift'; END IF;
  RAISE NOTICE 'PASS [M1: Welt 50/Anleihen 20/Cash 10/Festgeld 20 genau gehalten -> kein Drift, Welt 62,5 = 62,5]';

  -- ---------- (M2) kein cash-Block: Giro faellt aus dem Nenner ----------
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_allocation,blocks}', jsonb_build_array(
      jsonb_build_object('key','world','name','Welt','target_pct',70),
      jsonb_build_object('key','bonds','name','Anleihen','target_pct',10),
      jsonb_build_object('key','fixed_deposit','name','Festgeld','target_pct',20))) WHERE name = 'financial_planning';
  UPDATE finance.depot_holdings SET shares = 700 WHERE symbol = 'P3W' AND account_id = v_depot;   -- 70.000
  UPDATE finance.depot_holdings SET shares = 100 WHERE symbol = 'P3B' AND account_id = v_depot;   -- 10.000
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'allocation_drift') THEN
    RAISE EXCEPTION 'FAIL [M2]: Giro ohne cash-Block erzeugt Dauer-Drift (drift=%)', r->'rebalanceable_drift'; END IF;
  IF (r->'digest'->'lines')::text NOT LIKE '%finance.advisor.digest_alloc_outside%' THEN
    RAISE EXCEPTION 'FAIL [M2]: Digest nennt den Betrag ausserhalb des Plans nicht'; END IF;
  RAISE NOTICE 'PASS [M2: handelbarer Wert ohne Plan-Block faellt aus dem Nenner, Digest nennt ihn]';

  -- ---------- (M3) Sparziel-Ruecklage blaeht Cash nicht auf ----------
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_allocation,blocks}', jsonb_build_array(
      jsonb_build_object('key','world','name','Welt','target_pct',50),
      jsonb_build_object('key','bonds','name','Anleihen','target_pct',20),
      jsonb_build_object('key','cash','name','Cash','target_pct',10),
      jsonb_build_object('key','fixed_deposit','name','Festgeld','target_pct',20))) WHERE name = 'financial_planning';
  UPDATE finance.depot_holdings SET shares = 500 WHERE symbol = 'P3W' AND account_id = v_depot;
  UPDATE finance.depot_holdings SET shares = 200 WHERE symbol = 'P3B' AND account_id = v_depot;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__p3_car__', 20000, current_date + 365, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__p3_pot__','cash','EUR','active') RETURNING id INTO v_pot;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_pot, 10000, current_date, 'transfer', v_goal, gen_random_uuid());   -- 10.000 im Topf, voll reserviert
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'alloc:cash') THEN
    RAISE EXCEPTION 'FAIL [M3]: reserviertes Sparziel-Geld blaeht Cash auf (drift=%)', r->'rebalanceable_drift'; END IF;
  RAISE NOTICE 'PASS [M3: Sparziel-Ruecklage zaehlt nicht als Cash-Uebergewicht]';

  -- ---------- (N1) net_worth zaehlt die Immobilie: Haus 300.000 + Hypothek -200.000 ----------
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,goal}',
      jsonb_build_object('target_portfolio_eur', 100000000)) WHERE name = 'financial_planning';
  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__p3_house__', 300000, 'active') RETURNING id INTO v_re;
  UPDATE finance.account_balances SET balance = -200000 WHERE account_id = v_loan;
  UPDATE finance.loans SET real_estate_id = v_re WHERE id = (SELECT id FROM finance.loans WHERE name = '__p3_loan__');
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_inv FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio';
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,goal,target_portfolio_basis}', '"net_worth"') WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_nw FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio';
  IF round(v_nw - v_inv, 2) IS DISTINCT FROM 100000.00 THEN
    RAISE EXCEPTION 'FAIL [N1]: net_worth = investment + Haus 300.000 - Hypothek 200.000 = +100.000 erwartet, got % - % = %', v_nw, v_inv, v_nw - v_inv; END IF;
  RAISE NOTICE 'PASS [N1: net_worth zaehlt Haus und Hypothek (+100.000)]';

  -- ---------- (N2) Haus ohne Wert -> Haus UND Hypothek fallen heraus (= investment) + Digest-Hinweis ----------
  UPDATE finance.real_estate SET current_value = NULL WHERE id = v_re;
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_nw FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio';
  IF round(v_nw - v_inv, 2) IS DISTINCT FROM 0.00 THEN
    RAISE EXCEPTION 'FAIL [N2]: Haus ohne Wert -> auch seine Hypothek raus (net_worth = investment), got Diff %', v_nw - v_inv; END IF;
  IF (r->'digest'->'lines')::text NOT LIKE '%finance.advisor.digest_real_estate_value_missing%' THEN
    RAISE EXCEPTION 'FAIL [N2]: Digest-Hinweis auf fehlenden Immobilienwert fehlt'; END IF;
  -- kind-besessenes Haus mit Wert -> ebenfalls beides raus
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('p3_kid', 'Kind', 'child');
  UPDATE finance.real_estate SET current_value = 300000, owner_person_id = 'p3_kid' WHERE id = v_re;
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_nw FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio';
  IF round(v_nw - v_inv, 2) IS DISTINCT FROM 0.00 THEN
    RAISE EXCEPTION 'FAIL [N2 kid]: Kind-Haus + seine Hypothek muessen beide raus, got Diff %', v_nw - v_inv; END IF;
  RAISE NOTICE 'PASS [N2: Haus ohne Wert / Kind-Haus -> Haus und Kredit symmetrisch raus]';

  -- (N3, Review) Haus VERKAUFT, Hypothek noch offen -> das Haus zaehlt nicht mehr, die Schuld schon (-200.000)
  UPDATE finance.real_estate SET owner_person_id = NULL, status = 'sold' WHERE id = v_re;
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_nw FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio';
  IF round(v_nw - v_inv, 2) IS DISTINCT FROM -200000.00 THEN
    RAISE EXCEPTION 'FAIL [N3]: verkauftes Haus mit offener Hypothek -> net_worth = investment - 200.000, got Diff %', v_nw - v_inv; END IF;
  RAISE NOTICE 'PASS [N3: Kredit einer verkauften Immobilie bleibt Schuld]';

  -- (FX, Paket-2-Punkt 11b) Wert DER Zielportfolio-Basis ohne Wechselkurs -> Alert sagt "unvollstaendig";
  -- eine Luecke ausserhalb der Basis (Kind-Konto) loest keinen Hinweis aus. Danach aufraeumen (Saldo 0).
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,goal,target_portfolio_basis}', '"investment"') WHERE name = 'financial_planning';
  PERFORM finance.fn_ensure_currency('CHF');
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF';
  DECLARE v_chf int; v_kid_chf int; BEGIN
    r := finance.fn_advisor_review('finance');
    IF (SELECT (a->'msg')::text FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio') LIKE '%target_portfolio_fx_gap%' THEN
      RAISE EXCEPTION 'FAIL [FX0]: ohne Luecke kein Wechselkurs-Hinweis'; END IF;
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('__p3_kid_chf__','cash','CHF','active','p3_kid') RETURNING id INTO v_kid_chf;
    UPDATE finance.account_balances SET balance = 5000 WHERE account_id = v_kid_chf;
    r := finance.fn_advisor_review('finance');
    IF (SELECT (a->'msg')::text FROM jsonb_array_elements(r->'alerts') a WHERE a->>'metric_key' = 'target_portfolio') LIKE '%target_portfolio_fx_gap%' THEN
      RAISE EXCEPTION 'FAIL [FX1]: Luecke nur im Kind-Konto (nicht im FIRE-Topf) darf keinen Hinweis geben'; END IF;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__p3_chf__','cash','CHF','active') RETURNING id INTO v_chf;
    UPDATE finance.account_balances SET balance = 5000 WHERE account_id = v_chf;
    r := finance.fn_advisor_review('finance');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                   WHERE a->>'metric_key' = 'target_portfolio' AND (a->'msg')::text LIKE '%finance.advisor.target_portfolio_fx_gap%') THEN
      RAISE EXCEPTION 'FAIL [FX2]: target_portfolio ohne Hinweis auf fehlenden Wechselkurs (alerts=%)', r->'alerts'; END IF;
    UPDATE finance.account_balances SET balance = 0 WHERE account_id IN (v_chf, v_kid_chf);
  END;
  RAISE NOTICE 'PASS [FX: Wechselkurs-Luecke im Zielportfolio wird gemeldet, ausserhalb der Basis nicht]';

  -- ---------- (G1) Sparziel mit laufender Rate OHNE Topf -> nicht messbar statt "hinter Plan" ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__p3_old_rate__', v_giro, -100, 'month', current_date - 300, current_date - 300) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id, created_at)
    VALUES ('__p3_old_goal__', 2400, current_date + 400, 'active', v_rp, now() - interval '300 days');
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
             WHERE a->>'kind' = 'savings_pace' AND a->>'label' = '__p3_old_goal__') THEN
    RAISE EXCEPTION 'FAIL [G1]: Ziel ohne Topf darf nicht "hinter Plan" melden'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'savings_goal_unmeasurable:__p3_old_goal__'
                   AND (a->'msg')::text LIKE '%finance.advisor.savings_goal_unmeasurable%') THEN
    RAISE EXCEPTION 'FAIL [G1]: savings_goal_unmeasurable-Alert fehlt (alerts=%)', r->'alerts'; END IF;
  IF (r->'digest'->'lines')::text NOT LIKE '%finance.advisor.digest_goal_line_unmeasurable%' THEN
    RAISE EXCEPTION 'FAIL [G1]: Digest zeigt das Ziel nicht als "nicht messbar"'; END IF;
  RAISE NOTICE 'PASS [G1: Ziel ohne Topf -> nicht messbar (Alert + Digest), kein savings_pace]';

  -- (G2, Review) Depot-Unterdeckung eines NICHT messbaren Ziels wird nicht als "on pace" verschluckt
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
    VALUES ((SELECT id FROM finance.savings_goals WHERE name = '__p3_old_goal__'), v_depot, 500, 'manual');   -- kein Live-Kurs -> Deckung 0
  r := finance.fn_advisor_review('finance');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a
                 WHERE a->>'metric_key' = 'depot_reserve_coverage:' || v_depot) THEN
    RAISE EXCEPTION 'FAIL [G2]: Depot-Unterdeckung eines nicht messbaren Ziels fehlt (alerts=%)', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [G2: nicht messbares Ziel gilt nie als on-pace -> Depot-Deckung meldet sich]';

  -- ---------- (E1) Notreserve = freies Cash aus fn_liquidity_snapshot ----------
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,emergency_reserve}',
      jsonb_build_object('target_eur', 99999999)) WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  SELECT (a->>'value')::numeric INTO v_val FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'emergency_reserve';
  IF v_val IS DISTINCT FROM round((finance.fn_liquidity_snapshot()->>'cash_eur')::numeric, 2) THEN
    RAISE EXCEPTION 'FAIL [E1]: Notreserve-Cash % <> freies Cash aus fn_liquidity_snapshot %', v_val, finance.fn_liquidity_snapshot()->>'cash_eur'; END IF;
  -- Topf (10.000, voll reserviert) zaehlt nicht: freies Cash = Giro 10.000
  IF v_val IS DISTINCT FROM 10000.00 THEN
    RAISE EXCEPTION 'FAIL [E1]: freies Cash 10.000 erwartet (Giro; Sparziel-Topf reserviert), got %', v_val; END IF;
  RAISE NOTICE 'PASS [E1: Notreserve liest das freie Cash aus fn_liquidity_snapshot]';
END $$;

ROLLBACK TO SAVEPOINT paket3;

-- ============================================================
-- Umschicht-Hilfe (Glide Path, Sparziel-Zweckbindung 2026-10-27; Owner: Fenster 60 Monate, Toleranz 10 pp):
--   erlaubt im Depot = Ziel * Restmonate / Fenster; mehr als erlaubt + Toleranz -> savings_goal_derisk mit
--   Vorschlagsbetrag (drift) und latch_keys je Restjahr; mit aktivem Sparplan zusaetzlich der Pausieren-Satz.
--   (D1) 12 Monate vor dem Ziel, 10000 im Depot -> Alert, drift = excess aus der View, latch y1, Plan-Satz
--   (D2) Ziel in 7 Jahren -> ausserhalb des Fensters, kein Alert
--   (D3) nur knapp ueber erlaubt (unter Toleranz) -> kein Alert
--   (D4) Fenster per Config 12 Monate -> erlaubt = Ziel, kein Alert fuer D1
-- ============================================================
SAVEPOINT derisk;
DO $$
DECLARE r jsonb; a jsonb; v_settle int; v_depot int; v_g1 int; v_g2 int; v_g3 int; v_months int; v_allowed numeric; v_excess numeric;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__dr_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__dr_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__dr_reise__', 10000, current_date + 365, 'active') RETURNING id INTO v_g1;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__dr_rente__', 10000, current_date + 2600, 'active') RETURNING id INTO v_g2;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__dr_knapp__', 10000, current_date + 365, 'active') RETURNING id INTO v_g3;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g1, 'account_id', v_depot, 'amount', 10000));
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g2, 'account_id', v_depot, 'amount', 10000));
  SELECT months_left, allowed_depot_eur INTO v_months, v_allowed FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g3;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_g3, 'account_id', v_depot, 'amount', v_allowed + 500));
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name','__dr_plan__','depot_name','__dr_depot__','isin','IE00B4L5Y983',
            'symbol','IUSQ','security_name','iShares MSCI World','amount',100,'schedule_interval',1,'schedule_unit','month',
            'first_payment_date',CURRENT_DATE::text));
  PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g1, 'link_savings_plan_name', '__dr_plan__'));

  -- View-Mathematik
  SELECT months_left, allowed_depot_eur, excess_eur INTO v_months, v_allowed, v_excess FROM finance.fn_savings_goal_derisk_status() WHERE goal_id = v_g1;
  IF v_allowed IS DISTINCT FROM round(10000.0 * v_months / 60, 2) OR v_excess IS DISTINCT FROM 10000 - v_allowed THEN
    RAISE EXCEPTION 'FAIL [D view]: months % allowed % excess %', v_months, v_allowed, v_excess; END IF;

  r := finance.fn_advisor_review('finance');
  -- (D1)
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'savings_goal_derisk:' || v_g1;
  IF a IS NULL OR a->>'kind' IS DISTINCT FROM 'savings_goal_derisk' OR (a->>'drift')::numeric IS DISTINCT FROM v_excess
     OR (a->>'value')::numeric IS DISTINCT FROM 10000 OR (a->>'target')::numeric IS DISTINCT FROM v_allowed
     OR a->'latch_keys' IS DISTINCT FROM jsonb_build_array('y' || ceil(v_months / 12.0)::int)
     OR (a->'msg')::text NOT LIKE '%finance.advisor.goal_derisk"%' OR (a->'msg')::text NOT LIKE '%finance.advisor.goal_derisk_plan%'
     OR (a->'msg')::text NOT LIKE '%finance.advisor.goal_derisk_tax%' THEN
    RAISE EXCEPTION 'FAIL [D1 derisk-Alert]: %', a; END IF;
  -- (D2)/(D3)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' IN ('savings_goal_derisk:' || v_g2, 'savings_goal_derisk:' || v_g3)) THEN
    RAISE EXCEPTION 'FAIL [D2/D3]: Alert ausserhalb des Fensters bzw. unter der Toleranz'; END IF;
  -- (D4)
  INSERT INTO core.config (package, category, key, value) VALUES ('core','advisor','derisk_window_months','12')
    ON CONFLICT (category, key) DO UPDATE SET value = '12', package = 'core';
  r := finance.fn_advisor_review('finance');
  -- 12-Monats-Fenster: bei 12 Restmonaten darf alles im Depot liegen, bei 13 liegt das Ziel ausserhalb -> kein Alert
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'savings_goal_derisk:' || v_g1) THEN
    RAISE EXCEPTION 'FAIL [D4 Config-Fenster]: %', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [D1-D4: Umschicht-Alert im Fenster mit Vorschlag + Plan-Satz; ausserhalb/unter Toleranz still; Fenster per Config]';
END $$;
ROLLBACK TO SAVEPOINT derisk;

-- ============================================================
-- Instandhaltungsruecklage (2026-10-27): Rate unter der Empfehlung nach II. BV -> maintenance_reserve_low:<id>
-- (latch_keys = Stufe + Satz, damit ein Stufen-/Satzwechsel erneut meldet); aktive Immobilie ohne Ruecklage ->
-- maintenance_reserve_missing:<id>; Digest-Zeile digest_maintenance_line statt "0 % (x / —)".
-- ============================================================
SAVEPOINT maintenance;
DO $$
DECLARE
  y      INT := EXTRACT(YEAR FROM core.fn_today())::int;
  r      jsonb;
  a      jsonb;
  v_giro INT; v_pot INT; v_haus INT; v_grund INT;
BEGIN
  INSERT INTO core.config (package, category, key, value) VALUES
      ('finance','finance','maintenance_rate_under22_eur_m2','11.50'),
      ('finance','finance','maintenance_rate_from22_eur_m2','14.58'),
      ('finance','finance','maintenance_rate_from32_eur_m2','18.62')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value, package = 'finance';
  v_giro := (finance.fn_create_account('{"name":"__adv_mr_giro__","account_type":"cash","opening_balance":9000}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__adv_mr_topf__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_haus := (finance.fn_create_real_estate(jsonb_build_object('name','__adv_mr_haus__','living_area_m2','110','year_built',y - 40))->>'real_estate_id')::int;
  v_grund := (finance.fn_create_real_estate('{"name":"__adv_mr_grund__"}'::jsonb)->>'real_estate_id')::int;
  -- Rate 100 < Empfehlung 171 (110 m2, Alter 40)
  PERFORM finance.fn_create_savings_goal(jsonb_build_object('real_estate_name','__adv_mr_haus__','reserve_account_id',v_pot,
            'account_id',v_giro,'monthly_savings_rate',100));
  r := finance.fn_advisor_review('finance');

  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'maintenance_reserve_low:' || v_haus;
  IF a IS NULL OR (a->>'value')::numeric IS DISTINCT FROM 100 OR (a->>'target')::numeric IS DISTINCT FROM 171
     OR (a->>'drift')::numeric IS DISTINCT FROM 71 OR a->'latch_keys'->>0 IS DISTINCT FROM 'from32:18.62'
     OR (a->'msg')::text NOT LIKE '%finance.advisor.maintenance_reserve_low%' THEN
    RAISE EXCEPTION 'FAIL [MR1 Rate unter Empfehlung]: %', a; END IF;
  -- Immobilie ohne Daten und ohne Ruecklage -> Hinweis (Variante ohne Empfehlung)
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'maintenance_reserve_missing:' || v_grund;
  IF a IS NULL OR (a->'msg')::text NOT LIKE '%finance.advisor.maintenance_reserve_missing_data%' THEN
    RAISE EXCEPTION 'FAIL [MR2 fehlende Ruecklage]: %', r->'alerts'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'maintenance_reserve_missing:' || v_haus) THEN
    RAISE EXCEPTION 'FAIL [MR2 Haus hat eine Ruecklage]'; END IF;
  -- Digest: eigene Zeile, kein savings_pace/goal_reached fuer die Ruecklage
  IF (r->'digest'->'lines')::text NOT LIKE '%finance.advisor.digest_maintenance_line%' THEN
    RAISE EXCEPTION 'FAIL [MR3 Digest-Zeile]: %', r->'digest'->'lines'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x
             WHERE x->>'metric_key' LIKE 'savings_goal%:Instandhaltungsrücklage __adv_mr_haus__') THEN
    RAISE EXCEPTION 'FAIL [MR3 Sparziel-Alert fuer Ruecklage]: %', r->'alerts'; END IF;

  -- Rate auf Empfehlung -> kein low-Alert mehr
  PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id',
            (SELECT id FROM finance.savings_goals WHERE real_estate_id = v_haus), 'monthly_savings_rate', '171'));
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'maintenance_reserve_low:' || v_haus) THEN
    RAISE EXCEPTION 'FAIL [MR4 Rate = Empfehlung still]'; END IF;
  RAISE NOTICE 'PASS [MR1-MR4: Ruecklage unter Empfehlung, fehlende Ruecklage, Digest-Zeile, still bei Empfehlung]';
END $$;
ROLLBACK TO SAVEPOINT maintenance;

ROLLBACK;
