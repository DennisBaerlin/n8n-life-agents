-- tests/db/finance/test_fn_validate_financial_planning.sql
-- WS1a (Core-Advisor-Engine): Plan-Fakten-Validator (partial-tolerant + rekursiver Derived-Guard),
-- paket-besessen in finance.fn_validate_financial_planning(jsonb), via core.context_validators-Registry
-- vom Core-Trigger generisch dispatcht. db_test seedet die Registry NICHT -> der Test seedet die Zeile
-- selbst (self-seedend, BEGIN..ROLLBACK), wie seed_data.sh es aus dem Manifest tut.
BEGIN;

DO $$
DECLARE
  v_err  TEXT;
  v_full JSONB := jsonb_build_object(
    -- Phase A: risk_tolerance ist aus dem goal-Block in risk_profile UMGEZOGEN (one-fact-one-home);
    -- der goal-Block traegt es nicht mehr (n4).
    'goal', jsonb_build_object('target_income_eur_month',3000,'horizon_years',25,'withdrawal_rate_pct',4),
    'risk_profile', jsonb_build_object('risk_tolerance','medium','risk_capacity','high','as_of','2026-06-01'),
    'target_allocation', jsonb_build_object(
       'blocks', jsonb_build_array(
         jsonb_build_object('key','sp500','name','S&P 500 ETF','target_pct',85,'corridor', jsonb_build_array(80,90)),
         jsonb_build_object('key','korea','name','Korea Depot','target_pct',11,'corridor', jsonb_build_array(6,16)),
         jsonb_build_object('key','gold','name','Physical Gold','target_pct',4,'corridor', jsonb_build_array(0,9))),
       'rebalance_drift_pp', 5),
    'glidepath', jsonb_build_object('start_age',54,'phases', jsonb_build_array(
         jsonb_build_object('name','accumulation','age_to',54,'equity_pct',97),
         jsonb_build_object('name','derisking','age_from',55,'age_to',60),
         jsonb_build_object('name','withdrawal','age_from',61,'equity_pct',72))),
    '_meta', jsonb_build_object('last_confirmed_at','2026-06-01'));
BEGIN
  -- TEST 1: vollstaendiges, gueltiges facts -> NULL
  v_err := finance.fn_validate_financial_planning(v_full);
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [valid full]: erwartet NULL, got %', v_err; END IF;
  RAISE NOTICE 'PASS [vollstaendiges Plan-facts akzeptiert]';

  -- TEST 1b (2026-10-30): emergency_reserve ist kein Plan-Block mehr (Notreserve = Ruecklage kind emergency_reserve)
  v_err := finance.fn_validate_financial_planning(v_full || jsonb_build_object('emergency_reserve', jsonb_build_object('target_months', 6)));
  IF v_err IS NULL OR v_err NOT LIKE '%emergency_reserve is no longer a plan block%' THEN
    RAISE EXCEPTION 'FAIL [emergency_reserve-Block]: erwartet Ablehnung, got %', v_err; END IF;
  RAISE NOTICE 'PASS [emergency_reserve-Block abgewiesen]';

  -- TEST 2: PARTIAL — nur goal (target_allocation/glidepath fehlen) -> NULL (partial-tolerant)
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal',
             jsonb_build_object('withdrawal_rate_pct',4)));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [partial goal]: erwartet NULL (partial-tolerant), got %', v_err; END IF;
  RAISE NOTICE 'PASS [partial facts: nur goal akzeptiert]';

  -- TEST 3: Allokations-Summe != 100 -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{target_allocation,blocks}', jsonb_build_array(
               jsonb_build_object('key','a','name','A','target_pct',50), jsonb_build_object('key','b','name','B','target_pct',30))));
  IF v_err IS NULL OR v_err NOT ILIKE '%sum to%' THEN RAISE EXCEPTION 'FAIL [alloc sum]: erwartet Summen-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Allokations-Summe 80 abgewiesen]';

  -- TEST 4: target_pct ausserhalb seines Korridors -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{target_allocation,blocks}', jsonb_build_array(
               jsonb_build_object('key','a','name','A','target_pct',95,'corridor', jsonb_build_array(80,90)),
               jsonb_build_object('key','b','name','B','target_pct',5,'corridor', jsonb_build_array(0,9)))));
  IF v_err IS NULL OR v_err NOT ILIKE '%outside its corridor%' THEN RAISE EXCEPTION 'FAIL [corridor]: erwartet Korridor-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [target_pct ausserhalb Korridor abgewiesen]';

  -- TEST 4b (2026-10-23): reservierter Block-key outside_plan -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{target_allocation,blocks}', jsonb_build_array(
               jsonb_build_object('key','outside_plan','name','A','target_pct',60),
               jsonb_build_object('key','b','name','B','target_pct',40))));
  IF v_err IS NULL OR v_err NOT ILIKE '%reserved%' THEN RAISE EXCEPTION 'FAIL [outside_plan]: erwartet Reserviert-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Block-key outside_plan abgewiesen]';

  -- TEST 5: Glidepath-Phasen nicht geordnet -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{glidepath,phases}', jsonb_build_array(
               jsonb_build_object('name','a','age_to',60),
               jsonb_build_object('name','b','age_from',55))));
  IF v_err IS NULL OR v_err NOT ILIKE '%not strictly ordered%' THEN RAISE EXCEPTION 'FAIL [glidepath order]: erwartet Ordnungs-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Glidepath-Phasen-Ueberlappung abgewiesen]';

  -- TEST 6: withdrawal_rate ausserhalb (0,10] -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal', jsonb_build_object('withdrawal_rate_pct',15)));
  IF v_err IS NULL OR v_err NOT ILIKE '%withdrawal_rate_pct%' THEN RAISE EXCEPTION 'FAIL [rate]: erwartet Rate-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [withdrawal_rate 15 abgewiesen]';

  -- TEST 7: REKURSIVER Derived-Guard — seit WS1b GENERISCH im Core-Validator (agent.fn_validate_household_facts),
  -- der vom selben Trigger VOR der finance-fn laeuft (jeder facts-Sidecar). Hier direkt gegen den Core getestet
  -- mit p_name='financial_planning': gebackenes glidepath.start_year (nested) -> Fehler.
  v_err := agent.fn_validate_household_facts(jsonb_build_object('glidepath',
             jsonb_build_object('start_age',54,'start_year',2044)), 'financial_planning');
  IF v_err IS NULL OR v_err NOT ILIKE '%DERIVED%' THEN RAISE EXCEPTION 'FAIL [derived start_year]: erwartet Derived-Reject, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Core-Denylist: nested glidepath.start_year (abgeleitet) abgewiesen]';

  -- TEST 8: Core-Denylist — gebackenes goal.income -> Fehler; ABER horizon_years (Roh) bleibt erlaubt.
  v_err := agent.fn_validate_household_facts(jsonb_build_object('goal',
             jsonb_build_object('horizon_years',25,'income',36000)), 'financial_planning');
  IF v_err IS NULL OR v_err NOT ILIKE '%DERIVED%' THEN RAISE EXCEPTION 'FAIL [derived income]: erwartet Derived-Reject, got %', v_err; END IF;
  v_err := agent.fn_validate_household_facts(jsonb_build_object('goal',
             jsonb_build_object('horizon_years',25)), 'financial_planning');
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [raw horizon_years]: horizon_years (Roh) faelschlich abgewiesen, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Core-Denylist: goal.income abgewiesen, horizon_years (Roh) erlaubt]';

  -- TEST 9: _meta.last_confirmed_at in der Zukunft -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('_meta',
             jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE + 5, 'YYYY-MM-DD'))));
  IF v_err IS NULL OR v_err NOT ILIKE '%future%' THEN RAISE EXCEPTION 'FAIL [future as_of]: erwartet Zukunfts-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [_meta.last_confirmed_at in Zukunft abgewiesen]';

  -- TEST 11: inflation_pct ausserhalb [0,10] -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal', jsonb_build_object('inflation_pct',15)));
  IF v_err IS NULL OR v_err NOT ILIKE '%inflation_pct%' THEN RAISE EXCEPTION 'FAIL [inflation range]: got %', v_err; END IF;
  RAISE NOTICE 'PASS [inflation_pct 15 abgewiesen]';

  -- TEST 12: gebackener Nominalwert -> Derived-Reject (Nominal ist IMMER aus real abgeleitet); Core-Denylist.
  v_err := agent.fn_validate_household_facts(jsonb_build_object('goal', jsonb_build_object('nominal_income',4500)), 'financial_planning');
  IF v_err IS NULL OR v_err NOT ILIKE '%DERIVED%' THEN RAISE EXCEPTION 'FAIL [nominal key]: got %', v_err; END IF;
  RAISE NOTICE 'PASS [Core-Denylist: goal.nominal_income (abgeleitet) abgewiesen]';

  -- TEST 13 (WS2b): Block OHNE key -> Fehler (key Pflicht je Block; arch-challenge Candidate 1)
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{target_allocation,blocks}', jsonb_build_array(
               jsonb_build_object('name','A','target_pct',100))));
  IF v_err IS NULL OR v_err NOT ILIKE '%needs a key%' THEN RAISE EXCEPTION 'FAIL [block no key]: erwartet key-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Block ohne key abgewiesen]';

  -- TEST 14 (WS2b): Block-key falsches Format (Grossbuchstaben/Leerzeichen/&) -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{target_allocation,blocks}', jsonb_build_array(
               jsonb_build_object('key','S&P 500','name','A','target_pct',100))));
  IF v_err IS NULL OR v_err NOT ILIKE '%needs a key%' THEN RAISE EXCEPTION 'FAIL [block key format]: erwartet Format-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [Block-key falsches Format abgewiesen]';

  -- TEST 15 (WS2b): doppelter Block-key -> Fehler (Eindeutigkeit = stabiler Join-Key)
  v_err := finance.fn_validate_financial_planning(jsonb_set(v_full,
             '{target_allocation,blocks}', jsonb_build_array(
               jsonb_build_object('key','dup','name','A','target_pct',50,'corridor', jsonb_build_array(0,100)),
               jsonb_build_object('key','dup','name','B','target_pct',50,'corridor', jsonb_build_array(0,100)))));
  IF v_err IS NULL OR v_err NOT ILIKE '%duplicated%' THEN RAISE EXCEPTION 'FAIL [block key dup]: erwartet Dup-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [doppelter Block-key abgewiesen]';

  -- TEST 16 (WS3): goal.target_portfolio_basis 'investment'/'net_worth' -> akzeptiert (NULL)
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal',
             jsonb_build_object('target_portfolio_basis','investment')));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [basis investment]: erwartet NULL, got %', v_err; END IF;
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal',
             jsonb_build_object('target_portfolio_basis','net_worth')));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [basis net_worth]: erwartet NULL, got %', v_err; END IF;
  RAISE NOTICE 'PASS [target_portfolio_basis investment/net_worth akzeptiert]';

  -- TEST 17 (WS3): ungueltige target_portfolio_basis -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal',
             jsonb_build_object('target_portfolio_basis','gross')));
  IF v_err IS NULL OR v_err NOT ILIKE '%target_portfolio_basis%' THEN RAISE EXCEPTION 'FAIL [basis invalid]: erwartet Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [target_portfolio_basis ungueltig (gross) abgewiesen]';

  -- ===== Phase A (risk_profile): MiFID-Dimensionen tolerance/capacity + as_of-Stempel =====
  -- TEST 18: vollstaendiges risk_profile-Trio (im v_full enthalten) -> NULL (akzeptiert)
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('risk_profile',
             jsonb_build_object('risk_tolerance','low','risk_capacity','medium','as_of','2026-01-15')));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [risk_profile valid]: erwartet NULL, got %', v_err; END IF;
  RAISE NOTICE 'PASS [risk_profile Trio akzeptiert]';

  -- TEST 19: ungueltiges risk_tolerance-Enum -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('risk_profile',
             jsonb_build_object('risk_tolerance','aggressive')));
  IF v_err IS NULL OR v_err NOT ILIKE '%risk_tolerance%' THEN RAISE EXCEPTION 'FAIL [risk_tolerance enum]: erwartet Enum-Fehler, got %', v_err; END IF;
  -- ungueltiges risk_capacity-Enum -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('risk_profile',
             jsonb_build_object('risk_capacity','sehr_hoch')));
  IF v_err IS NULL OR v_err NOT ILIKE '%risk_capacity%' THEN RAISE EXCEPTION 'FAIL [risk_capacity enum]: erwartet Enum-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [risk_profile ungueltige Enums abgewiesen]';

  -- TEST 20: as_of in der Zukunft -> Fehler; kaputter Datums-String -> Fehler
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('risk_profile',
             jsonb_build_object('as_of', to_char(CURRENT_DATE + 3, 'YYYY-MM-DD'))));
  IF v_err IS NULL OR v_err NOT ILIKE '%future%' THEN RAISE EXCEPTION 'FAIL [risk_profile as_of future]: erwartet Zukunfts-Fehler, got %', v_err; END IF;
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('risk_profile',
             jsonb_build_object('as_of','nicht-ein-datum')));
  IF v_err IS NULL OR v_err NOT ILIKE '%valid DATE%' THEN RAISE EXCEPTION 'FAIL [risk_profile as_of garbage]: erwartet DATE-Fehler, got %', v_err; END IF;
  RAISE NOTICE 'PASS [risk_profile as_of Zukunft + kaputter String abgewiesen]';

  -- TEST 21: partial-tolerant — risk_profile ganz fehlend -> NULL; Block OHNE as_of -> NULL (kein Crash)
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('goal', jsonb_build_object('withdrawal_rate_pct',4)));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [no risk_profile]: erwartet NULL (partial), got %', v_err; END IF;
  v_err := finance.fn_validate_financial_planning(jsonb_build_object('risk_profile',
             jsonb_build_object('risk_tolerance','high')));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [risk_profile ohne as_of]: erwartet NULL (partial), got %', v_err; END IF;
  RAISE NOTICE 'PASS [risk_profile partial-tolerant: fehlend + ohne as_of akzeptiert]';
END $$;

-- TEST 10 (Trigger-Dispatch via Registry): kaputtes financial_planning per Direkt-UPDATE -> Exception.
-- Beweist, dass der Core-Trigger die finance-fn ueber core.context_validators dispatcht (Backstop).
DO $$
BEGIN
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('financial_planning', 'finance.fn_validate_financial_planning', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn, package = EXCLUDED.package;

  BEGIN
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
    VALUES ('financial_planning', 'x', NULL, 'lazy', E'## x',
            jsonb_build_object('managed_by','agent','facts', jsonb_build_object(
              'target_allocation', jsonb_build_object('blocks', jsonb_build_array(
                jsonb_build_object('key','a','name','A','target_pct',50))))))
    ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
    RAISE EXCEPTION 'FAIL [trigger dispatch]: kaputtes financial_planning (Summe 50) akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS [Core-Trigger dispatcht financial_planning an die finance-fn: %]', SQLERRM;
  END;
END $$;

ROLLBACK;
