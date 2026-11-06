-- tests/db/finance/test_fn_resolve_plan_schedule.sql
-- Depot-Kalender (accounts.plan_execution_days) + Broker-Vorbelegung (fn_broker_plan_days) + Ableitung des
-- gespeicherten Sparplan-Rhythmus (fn_resolve_plan_schedule). Erfundene Banken/Daten.
--   Kalender {2,9,16,23} (Vorbelegung "Trade Republic"): week/1 -> 4 Tage, week/2 -> jeder zweite Tag ab Start,
--   month/n -> Einzeltag; Start nicht auf dem Kalender -> {ok:false} + naechster Tag.
--   Kalender {1,15}: week/2 -> beide Tage, week/1 -> {ok:false}. '{}' = echte Intervalle (unveraendert).
--   Unbekannter Kalender: week -> needs_calendar; Monatsplan -> keine Nachfrage; Nutzer-Antwort wird normalisiert.
BEGIN;

DO $$
DECLARE
  v_cash INT; v_tr INT; v_b115 INT; v_free INT; v_unk INT;
  r JSONB;
BEGIN
  -- ===== fn_broker_plan_days: Bank-Varianten =====
  IF finance.fn_broker_plan_days('Trade Republic Bank GmbH') IS DISTINCT FROM '{2,9,16,23}'::smallint[]
     OR finance.fn_broker_plan_days('trade republic') IS DISTINCT FROM '{2,9,16,23}'::smallint[] THEN
    RAISE EXCEPTION 'FAIL [broker days]: TR-Varianten nicht erkannt'; END IF;
  IF finance.fn_broker_plan_days('Beispielbank') IS NOT NULL OR finance.fn_broker_plan_days(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [broker days]: unbekannte Bank/NULL lieferte einen Kalender'; END IF;
  RAISE NOTICE 'PASS [fn_broker_plan_days]';

  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rps_cash__', 'cash', 'EUR', 'active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id)
    VALUES ('__rps_tr__', 'stocks_depot', 'Trade Republic Bank GmbH', 'EUR', 'active', v_cash) RETURNING id INTO v_tr;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id, plan_execution_days)
    VALUES ('__rps_b115__', 'stocks_depot', 'Beispielbank', 'EUR', 'active', v_cash, '{1,15}') RETURNING id INTO v_b115;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id, plan_execution_days)
    VALUES ('__rps_free__', 'stocks_depot', 'Beispielbank', 'EUR', 'active', v_cash, '{}') RETURNING id INTO v_free;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id)
    VALUES ('__rps_unk__', 'crypto_depot', 'Musterbroker', 'EUR', 'active', v_cash) RETURNING id INTO v_unk;

  -- ===== TR-Vorbelegung: week/1 -> {2,9,16,23}, Kalender neu (am Depot zu speichern) =====
  r := finance.fn_resolve_plan_schedule(v_tr, 'week', 1::smallint, NULL, DATE '2026-11-02', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR r->>'schedule_unit' <> 'month' OR (r->>'schedule_interval')::int <> 1
     OR r->'schedule_day_of_month' <> 'null'::jsonb
     OR r->'schedule_days_of_month' <> '[2,9,16,23]'::jsonb
     OR r->'calendar' <> '[2,9,16,23]'::jsonb OR (r->>'calendar_changed')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [TR week/1]: %', r; END IF;
  RAISE NOTICE 'PASS [TR week/1 -> month + 2,9,16,23, Kalender neu]';

  -- week/2 ab dem 9. -> {9,23}; ab dem 2. -> {2,16}
  r := finance.fn_resolve_plan_schedule(v_tr, 'week', 2::smallint, NULL, DATE '2026-11-09', NULL);
  IF r->'schedule_days_of_month' <> '[9,23]'::jsonb THEN RAISE EXCEPTION 'FAIL [TR week/2 ab 9.]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_tr, 'week', 2::smallint, NULL, DATE '2026-11-02', NULL);
  IF r->'schedule_days_of_month' <> '[2,16]'::jsonb THEN RAISE EXCEPTION 'FAIL [TR week/2 ab 2.]: %', r; END IF;
  RAISE NOTICE 'PASS [TR week/2 -> jeder zweite Kalendertag ab Start]';

  -- month/1 ab dem 16. -> Einzeltag 16, keine Tage-Liste
  r := finance.fn_resolve_plan_schedule(v_tr, 'month', 1::smallint, NULL, DATE '2026-11-16', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'schedule_unit' <> 'month'
     OR (r->>'schedule_day_of_month')::int <> 16 OR r->'schedule_days_of_month' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [TR month/1]: %', r; END IF;
  -- quartalsweise ab dem 2. -> month/3 + Tag 2
  r := finance.fn_resolve_plan_schedule(v_tr, 'month', 3::smallint, NULL, DATE '2026-11-02', NULL);
  IF (r->>'schedule_interval')::int <> 3 OR (r->>'schedule_day_of_month')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL [TR month/3]: %', r; END IF;
  RAISE NOTICE 'PASS [TR month/n -> Einzeltag aus dem Start]';

  -- Start nicht auf dem Kalender -> {ok:false} mit naechstem moeglichen Tag
  r := finance.fn_resolve_plan_schedule(v_tr, 'week', 1::smallint, NULL, DATE '2026-11-10', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'next_possible_date' <> '2026-11-16' OR r->>'reason' IS NULL THEN
    RAISE EXCEPTION 'FAIL [TR Start 10.]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_tr, 'month', 1::smallint, NULL, DATE '2026-11-28', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'next_possible_date' <> '2026-12-02' THEN
    RAISE EXCEPTION 'FAIL [TR Start 28. -> naechster Monat]: %', r; END IF;
  -- fester Tag ausserhalb des Kalenders (Start passt): Meldung nennt den Tag, kein next_possible_date
  r := finance.fn_resolve_plan_schedule(v_tr, 'month', 1::smallint, (-1)::smallint, DATE '2026-11-02', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r ? 'next_possible_date' OR r->>'reason' NOT LIKE '%fixed day -1%' THEN
    RAISE EXCEPTION 'FAIL [TR dom -1]: %', r; END IF;
  RAISE NOTICE 'PASS [Start ausserhalb des Kalenders -> ok:false + naechster Tag; fester Tag -> eigene Meldung]';

  -- day bzw. year bei festem Kalender -> {ok:false}
  r := finance.fn_resolve_plan_schedule(v_tr, 'day', 1::smallint, NULL, DATE '2026-11-02', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [TR day]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_tr, 'week', 3::smallint, NULL, DATE '2026-11-02', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [TR week/3]: %', r; END IF;
  RAISE NOTICE 'PASS [TR day/week3 -> ok:false]';

  -- ===== Kalender {1,15}: week/2 -> beide, week/1 -> ok:false; gespeicherter Kalender = nicht neu =====
  r := finance.fn_resolve_plan_schedule(v_b115, 'week', 2::smallint, NULL, DATE '2026-11-15', NULL);
  IF r->'schedule_days_of_month' <> '[1,15]'::jsonb OR (r->>'calendar_changed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [1/15 week/2]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_b115, 'week', 1::smallint, NULL, DATE '2026-11-15', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS NULL THEN RAISE EXCEPTION 'FAIL [1/15 week/1]: %', r; END IF;
  RAISE NOTICE 'PASS [Kalender 1/15: zweimal monatlich ok, woechentlich ok:false]';

  -- ===== '{}' = echte Intervalle: Eingabe unveraendert =====
  r := finance.fn_resolve_plan_schedule(v_free, 'week', 1::smallint, NULL, DATE '2026-11-05', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'schedule_unit' <> 'week'
     OR r->'schedule_days_of_month' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL [free week]: %', r; END IF;
  RAISE NOTICE 'PASS [kein fester Kalender -> echte Woche]';

  -- ===== Unbekannter Kalender =====
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-05', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'needs_calendar')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [unk week -> needs_calendar]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_unk, 'month', 1::smallint, NULL, DATE '2026-11-05', NULL);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'schedule_unit' <> 'month'
     OR r->'schedule_day_of_month' <> 'null'::jsonb OR r->'calendar' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [unk month -> unveraendert, keine Nachfrage]: %', r; END IF;
  RAISE NOTICE 'PASS [unbekannter Kalender: woechentlich fragt, monatlich nicht]';

  -- Nutzer-Antwort 'none' -> echte Woche, Kalender '{}' neu
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-05', 'none');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'schedule_unit' <> 'week' OR r->'calendar' <> '[]'::jsonb
     OR (r->>'calendar_changed')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [unk none]: %', r; END IF;
  -- Nutzer-Antwort "20., 5." -> normalisiert {5,20}; week/2 ab dem 5. -> {5,20}
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 2::smallint, NULL, DATE '2026-11-05', '20., 5.');
  IF r->'calendar' <> '[5,20]'::jsonb OR r->'schedule_days_of_month' <> '[5,20]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [unk 20., 5.]: %', r; END IF;
  -- "2, 9, 16 und 23" -> {2,9,16,23}
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-02', '2, 9, 16 und 23');
  IF r->'schedule_days_of_month' <> '[2,9,16,23]'::jsonb THEN RAISE EXCEPTION 'FAIL [unk und-Liste]: %', r; END IF;
  -- rohe Antworten mit Fuellwort/Ordinal-Endungen
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-02', 'am 2., 9., 16. und 23.');
  IF r->'calendar' <> '[2,9,16,23]'::jsonb THEN RAISE EXCEPTION 'FAIL [unk am-Liste]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-02', '2nd, 9th, 16th and 23rd');
  IF r->'calendar' <> '[2,9,16,23]'::jsonb THEN RAISE EXCEPTION 'FAIL [unk ordinal-Liste]: %', r; END IF;
  -- Muell / Tag 31 -> {ok:false} ohne RAISE
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-02', '2,x');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' IS NULL THEN RAISE EXCEPTION 'FAIL [unk Muell]: %', r; END IF;
  r := finance.fn_resolve_plan_schedule(v_unk, 'week', 1::smallint, NULL, DATE '2026-11-02', '2,31');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [unk Tag 31]: %', r; END IF;
  RAISE NOTICE 'PASS [Nutzer-Kalender: none / Liste normalisiert / Muell -> ok:false]';
END $$;

ROLLBACK;
