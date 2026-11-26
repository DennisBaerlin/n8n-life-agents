-- ============================================================
-- test_fn_fx_feed_gap — "liefert der Wechselkurs-Dienst noch?" (finance.fn_fx_feed_gap) + Claim fn_feed_down_claim('fx')
--   [20] feed_down an den Grenzen 1/2 Tage, gemessen am Quell-Datum as_of (nicht updated_at) gegen das UTC-Datum
--   [20b] never: ohne jede Feed-Zeile ab Paket-Installation (core.fn_package_installed_at), Anker juenger/aelter
--   [20c] EZB-Nachlauf-Zeilen (source ecb) verdecken keinen Ausfall
--   [20d] Rueckkehr -> Latch finance:fx/feed_down wieder 'ok' (spaeterer Ausfall meldet neu)
--   [20e] cron_enable refresh_fx_rates aus -> nie feed_down
--   [21] Config finance.fx_feed_alert_days wird gelesen, fehlend -> Default 2
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE
    r       jsonb;
    v_today date := (now() AT TIME ZONE 'UTC')::date;   -- Bezug = UTC-Datum wie das Quell-Datum as_of
    v_state text;
BEGIN
    -- Owner im Haushalt: ohne ihn zaehlt core.fn_proactive_claim kein Budget
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
    VALUES ('family', 'fx fixture', NULL, 'lazy', E'## f',
            jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__fx_o__','first_name','FX','last_name','O','role','owner',
                                 'birth_date','1980-01-01','telegram_user_id',7922,'as_of','2026-11-01')))))
    ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
    DELETE FROM finance.fx_rates;
    DELETE FROM core.notification_state WHERE source = 'finance:fx';
    DELETE FROM core.proactive_deferred;
    DELETE FROM core.proactive_budget;
    PERFORM finance.fn_ensure_currency('USD');
    PERFORM finance.fn_ensure_currency('JPY');
    INSERT INTO core.package_registry (package, status, installed_at) VALUES ('finance', 'active', now())
    ON CONFLICT (package) DO UPDATE SET status = 'active', installed_at = now();
    INSERT INTO core.config (category, key, value, package) VALUES ('cron_enable', 'refresh_fx_rates', 'true', 'finance')
    ON CONFLICT (category, key) DO UPDATE SET value = 'true';
    INSERT INTO core.config (category, key, value, package) VALUES ('finance', 'fx_feed_alert_days', '2', 'finance')
    ON CONFLICT (category, key) DO UPDATE SET value = '2';

    -- [20b] never, frisch installiert -> noch kein Ausfall
    r := finance.fn_fx_feed_gap();
    IF (r->>'feed_down')::boolean IS DISTINCT FROM false OR (r->>'never')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [20b never jung]: %', r; END IF;
    -- [20b] never, Installation vor 2 Tagen -> Ausfall, ohne stale_since
    UPDATE core.package_registry SET installed_at = now() - interval '2 days' WHERE package = 'finance';
    r := finance.fn_fx_feed_gap();
    IF (r->>'feed_down')::boolean IS DISTINCT FROM true OR (r->>'never')::boolean IS DISTINCT FROM true
       OR r->>'stale_since' IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [20b never alt]: %', r; END IF;

    -- [20] Feed 1 Tag aus (juengstes Quell-Datum gestern) -> kein Ausfall, auch wenn updated_at alt ist
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source, updated_at) VALUES
        ('EUR', 'USD', 1.1, v_today - 1, 'open.er-api.com', now() - interval '10 days');
    r := finance.fn_fx_feed_gap();
    IF (r->>'feed_down')::boolean IS DISTINCT FROM false OR (r->>'never')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [20 1 Tag]: %', r; END IF;
    -- [20] Feed 2 Tage aus (Quell-Datum vorgestern), updated_at frisch (Feed antwortet mit altem Stand) -> Ausfall
    UPDATE finance.fx_rates SET as_of = v_today - 2, updated_at = now() WHERE quote_currency = 'USD';
    r := finance.fn_fx_feed_gap();
    IF (r->>'feed_down')::boolean IS DISTINCT FROM true OR (r->>'stale_since')::date IS DISTINCT FROM v_today - 2 THEN
        RAISE EXCEPTION 'FAIL [20 2 Tage, as_of statt updated_at]: %', r; END IF;

    -- [20c] EZB-Zeile von heute verdeckt den Ausfall nicht
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'JPY', 1500, v_today, 'ecb');
    r := finance.fn_fx_feed_gap();
    IF (r->>'feed_down')::boolean IS DISTINCT FROM true OR (r->>'stale_since')::date IS DISTINCT FROM v_today - 2 THEN
        RAISE EXCEPTION 'FAIL [20c ecb]: %', r; END IF;

    -- [21] Config 3 -> 2 Tage aus ist noch kein Ausfall; fehlender Wert -> Default 2 (unlesbare Werte lehnt die
    -- Typ-Pruefung von core.config schon beim Schreiben ab)
    UPDATE core.config SET value = '3' WHERE category = 'finance' AND key = 'fx_feed_alert_days';
    IF (finance.fn_fx_feed_gap()->>'feed_down')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [21 Config 3]'; END IF;
    DELETE FROM core.config WHERE category = 'finance' AND key = 'fx_feed_alert_days';
    IF (finance.fn_fx_feed_gap()->>'feed_down')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [21 fehlend -> Default 2]'; END IF;
    INSERT INTO core.config (category, key, value, package) VALUES ('finance', 'fx_feed_alert_days', '2', 'finance');

    -- [20e] Abruf abgeschaltet -> keine Meldung
    UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'refresh_fx_rates';
    IF (finance.fn_fx_feed_gap()->>'feed_down')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [20e cron_enable aus]'; END IF;
    UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'refresh_fx_rates';

    -- Claim: einmal, dann still (7-Tage-Latch); eigener Slot fx_feed_down
    IF finance.fn_feed_down_claim('fx') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [claim fx erste Meldung]'; END IF;
    IF finance.fn_feed_down_claim('fx') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [claim fx zweiter Lauf still]'; END IF;
    IF NOT EXISTS (SELECT 1 FROM core.proactive_budget WHERE slot = 'fx_feed_down') THEN
        RAISE EXCEPTION 'FAIL [claim fx Slot fx_feed_down]'; END IF;
    IF (SELECT expires_at FROM core.notification_state WHERE source = 'finance:fx' AND key = 'feed_down')
       NOT BETWEEN now() + interval '6 days 23 hours' AND now() + interval '7 days 1 hour' THEN
        RAISE EXCEPTION 'FAIL [claim fx TTL 7 Tage]'; END IF;

    -- [20d] Feed zurueck -> kein Ausfall, Latch re-armt
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'USD', 1.12, v_today, 'open.er-api.com');
    r := finance.fn_fx_feed_gap();
    SELECT state INTO v_state FROM core.notification_state WHERE source = 'finance:fx' AND key = 'feed_down';
    IF (r->>'feed_down')::boolean IS DISTINCT FROM false OR v_state IS DISTINCT FROM 'ok' THEN
        RAISE EXCEPTION 'FAIL [20d Rueckkehr]: % latch=%', r, v_state; END IF;

    BEGIN
        PERFORM finance.fn_feed_down_claim('bogus');
        RAISE EXCEPTION 'FAIL [claim unbekannter Feed]: kein RAISE';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    END;

    -- Rollen-Perspektive: der Erinnerungs-Cron laeuft unter finance_rw
    SET LOCAL ROLE finance_rw;
    r := finance.fn_fx_feed_gap();
    PERFORM finance.fn_feed_down_claim('fx');
    RESET ROLE;

    RAISE NOTICE 'PASS test_fn_fx_feed_gap [20 Grenzen am as_of, 20b never, 20c ecb, 20d Rueckkehr, 20e aus, 21 Config, Claim]';
END $$;
ROLLBACK;
