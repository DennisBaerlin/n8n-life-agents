-- tests/db/finance/test_fn_price_gaps.sql
-- Kurs-Luecken-Erinnerung: fn_price_gaps (Lueckenliste + Feed-Ausfall + Re-Arm behobener Luecken)
-- und fn_price_gap_claim (Latch je Position, TTL 7 Tage, source 'finance:prices'). Prueft:
--   (1) Lueckenliste enthaelt missing + stale, nicht ok; Referenzkurs = letzter Kurs, sonst Einstand;
--   (2) claim: erste Meldung true, im TTL false, nach TTL-Ablauf wieder true;
--   (3) behobene Luecke -> fn_price_gaps setzt den Latch zurueck (naechste Luecke meldet sofort);
--   (4) fremde finance-Latches (andere source) bleiben unberuehrt;
--   (5) Feed-Ausfall: >= 2 Positionen mit Kurs-Historie, keine ok -> feed_down; ein frischer Kurs -> false;
--   (6) finance_rw darf beide fns ausfuehren (Rollen-Perspektive).
BEGIN;
DO $$
DECLARE
  v_days int := COALESCE(NULLIF(core.fn_config_get('core','advisor','price_stale_days'), '')::int, 7);
  v_cash int; v_depot int; v_a int; v_b int; v_c int;
  r jsonb; g jsonb;
  v_b1 boolean; v_b2 boolean; v_b3 boolean;
  v_state text;
BEGIN
  -- Isolation fuer den Feed-Ausfall-Fall: alle bestehenden Kurse weg (Rollback am Ende)
  DELETE FROM finance.market_prices;

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pg_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__pg_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TESTPG01','PGA','Fonds A', 2, 50, 'EUR') RETURNING id INTO v_a;   -- bekommt frischen Kurs
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TESTPG02','PGB','Fonds B', 3, 40, 'EUR') RETURNING id INTO v_b;   -- stale
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TESTPG03','PGC','Fonds C', 4, 30, 'EUR') RETURNING id INTO v_c;   -- missing
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('PGA', 52, 'EUR', current_date),
    ('PGB', 44, 'EUR', current_date - v_days - 2);

  -- (1) Lueckenliste (+ FX-Karte fuer den Plausi-Vergleich in EUR, fn_fx_rate_map: juengster Kurs gewinnt)
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES
    ('EUR','USD', 1.05, current_date - 3, 'test'), ('EUR','USD', 1.10, current_date, 'test')
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
  r := finance.fn_price_gaps();
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'gaps') e WHERE e->>'account_label' IS DISTINCT FROM finance.fn_account_label(NULL, 'stocks_depot', '__pg_depot__')) THEN
    RAISE EXCEPTION 'FAIL [1 account_label]: %', r->'gaps'; END IF;
  IF (r->'fx'->>'EUR')::numeric <> 1 OR (r->'fx'->>'USD')::numeric <> 1.10 THEN
    RAISE EXCEPTION 'FAIL [1 fx]: erwartet EUR 1 / USD 1.10, got %', r->'fx'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'gaps') e WHERE (e->>'holding_id')::int = v_a) THEN
    RAISE EXCEPTION 'FAIL [1]: ok-Position in der Lueckenliste: %', r->'gaps'; END IF;
  SELECT e INTO g FROM jsonb_array_elements(r->'gaps') e WHERE (e->>'holding_id')::int = v_b;
  IF g IS NULL OR g->>'status' <> 'stale' OR (g->>'price')::numeric <> 44 OR g->>'price_currency' <> 'EUR'
     OR (g->>'avg_price')::numeric <> 40 OR g->>'currency' <> 'EUR'
     OR g->>'isin' <> 'IE00TESTPG02' OR g->>'name' <> 'Fonds B' OR g->>'feed_symbol' <> 'PGB' THEN
    RAISE EXCEPTION 'FAIL [1 stale]: got %', g; END IF;
  SELECT e INTO g FROM jsonb_array_elements(r->'gaps') e WHERE (e->>'holding_id')::int = v_c;
  IF g IS NULL OR g->>'status' <> 'missing' OR g->>'price' IS NOT NULL OR (g->>'avg_price')::numeric <> 30 THEN
    RAISE EXCEPTION 'FAIL [1 missing, nur Einstand als Referenz]: got %', g; END IF;
  IF (r->>'feed_down')::boolean THEN
    RAISE EXCEPTION 'FAIL [1 feed_down]: eine ok-Position vorhanden, feed_down muss false sein'; END IF;
  RAISE NOTICE 'PASS fn_price_gaps [missing+stale, Referenzen letzter Kurs + Einstand, kein feed_down]';

  -- (2) claim: true, dann still, nach TTL-Ablauf wieder true
  v_b1 := finance.fn_price_gap_claim(v_c::text);
  v_b2 := finance.fn_price_gap_claim(v_c::text);
  UPDATE core.notification_state SET expires_at = now() - interval '1 minute'
   WHERE source = 'finance:prices' AND key IN (v_c::text, 'card_today');
  v_b3 := finance.fn_price_gap_claim(v_c::text);
  IF NOT v_b1 OR v_b2 OR NOT v_b3 THEN
    RAISE EXCEPTION 'FAIL [2 claim]: erwartet true/false/true, got %/%/%', v_b1, v_b2, v_b3; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:prices' AND key = v_c::text
                  AND expires_at BETWEEN now() + interval '6 days 23 hours' AND now() + interval '7 days 1 minute') THEN
    RAISE EXCEPTION 'FAIL [2 ttl]: Latch muss 7 Tage gelten'; END IF;
  RAISE NOTICE 'PASS fn_price_gap_claim [erste Meldung, still im TTL, erneut nach 7 Tagen]';

  -- (3) Luecke behoben -> fn_price_gaps re-armt; (4) fremder finance-Latch bleibt
  INSERT INTO core.notification_state (source, key, state) VALUES ('finance', 'reserve_breach:999999', 'fired')
  ON CONFLICT (source, key) DO UPDATE SET state = 'fired';
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('PGC', 31, 'EUR', current_date);
  r := finance.fn_price_gaps();
  SELECT state INTO v_state FROM core.notification_state WHERE source = 'finance:prices' AND key = v_c::text;
  IF v_state IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'FAIL [3 re-arm]: Latch nach Behebung muss ok sein, got %', v_state; END IF;
  SELECT state INTO v_state FROM core.notification_state WHERE source = 'finance' AND key = 'reserve_breach:999999';
  IF v_state IS DISTINCT FROM 'fired' THEN
    RAISE EXCEPTION 'FAIL [4 fremder Latch]: reserve_breach-Latch veraendert, got %', v_state; END IF;
  RAISE NOTICE 'PASS fn_price_gaps [behobene Luecke re-armt, fremde Latches unberuehrt]';

  -- (5) Feed-Ausfall: alle Positionen mit Historie stale, keine ok
  DELETE FROM finance.market_prices;
  -- Grenze: genau 2 Positionen mit (veralteter) Historie reichen schon
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('PGA', 50, 'EUR', current_date - v_days - 3),
    ('PGB', 44, 'EUR', current_date - v_days - 3);
  IF NOT (finance.fn_price_gaps()->>'feed_down')::boolean THEN
    RAISE EXCEPTION 'FAIL [5 feed_down bei genau 2 veralteten Kursen]'; END IF;
  DELETE FROM finance.market_prices;
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('PGA', 50, 'EUR', current_date - v_days - 3),
    ('PGB', 44, 'EUR', current_date - v_days - 3),
    ('PGC', 30, 'EUR', current_date - v_days - 3);
  r := finance.fn_price_gaps();
  IF NOT (r->>'feed_down')::boolean OR (r->>'stale_since')::date <> current_date - v_days - 3 THEN
    RAISE EXCEPTION 'FAIL [5 feed_down]: erwartet true + stale_since, got %/%', r->>'feed_down', r->>'stale_since'; END IF;
  v_b1 := finance.fn_price_gap_claim('feed_down');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('PGA', 51, 'EUR', current_date);
  r := finance.fn_price_gaps();
  SELECT state INTO v_state FROM core.notification_state WHERE source = 'finance:prices' AND key = 'feed_down';
  IF (r->>'feed_down')::boolean OR v_state IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'FAIL [5 feed zurueck]: feed_down=% latch=%', r->>'feed_down', v_state; END IF;
  RAISE NOTICE 'PASS fn_price_gaps [Feed-Ausfall erkannt + nach erstem frischen Kurs re-armt]';

  -- (6) Rollen-Perspektive finance_rw (Kurs-Cron-Credential)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_price_gaps();
  v_b1 := finance.fn_price_gap_claim(v_b::text);
  RESET ROLE;
  RAISE NOTICE 'PASS finance_rw [fn_price_gaps + fn_price_gap_claim ausfuehrbar]';
END $$;
DO $$
DECLARE o text := '__pg_o__';
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'pg fixture', NULL, 'lazy', E'## f',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id',o,'first_name','PG','last_name','O','role','owner','birth_date','1980-01-01','telegram_user_id',7921,'as_of','2026-11-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred; DELETE FROM core.notification_state WHERE source = 'finance:prices';
  IF finance.fn_price_gap_claim('1001') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [PB1 erste Karte]'; END IF;
  IF finance.fn_price_gap_claim('1002') IS NOT FALSE OR finance.fn_price_gap_claim('1003') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [PB1 nur eine je Tag]'; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:prices' AND key IN ('1002','1003') AND state='fired') THEN RAISE EXCEPTION 'FAIL [PB1 kein Merker]'; END IF;
  -- Folgetag: naechste Luecke; die gemeldete verbraucht nichts
  UPDATE core.proactive_budget SET day = day - 1;
  UPDATE core.notification_state SET expires_at = now() - interval '1 minute' WHERE source = 'finance:prices' AND key = 'card_today';
  IF finance.fn_price_gap_claim('1001') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [PB2 told]'; END IF;
  IF EXISTS (SELECT 1 FROM core.proactive_budget WHERE day = core.fn_today()) THEN RAISE EXCEPTION 'FAIL [PB2 told belegt keinen Slot]'; END IF;
  IF finance.fn_price_gap_claim('1002') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [PB2 naechste]'; END IF;
  -- kein Platz -> nichts gemerkt
  DELETE FROM core.proactive_budget; DELETE FROM core.notification_state WHERE source = 'finance:prices';
  PERFORM core.fn_proactive_claim(o, 'a', 'normal'); PERFORM core.fn_proactive_claim(o, 'b', 'normal');
  IF finance.fn_price_gap_claim('1004') IS NOT FALSE OR finance.fn_price_gap_claim('feed_down') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [PB3 voll]'; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'finance:prices' AND state='fired') THEN RAISE EXCEPTION 'FAIL [PB3 Merker]'; END IF;
  -- feed_down eigener Slot
  DELETE FROM core.proactive_budget;
  IF finance.fn_price_gap_claim('feed_down') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [PB4]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE slot = 'price_feed_down') THEN RAISE EXCEPTION 'FAIL [PB4 Slot]'; END IF;
  RAISE NOTICE 'PASS test_fn_price_gaps Budget';
END $$;

ROLLBACK;
