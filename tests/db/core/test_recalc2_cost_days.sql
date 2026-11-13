-- tests/db/core/test_recalc2_cost_days.sql
-- Zweitrechnung (Randfaelle), KI-Kosten: Kalendertage in der Haushalts-Zeitzone an den Fenstergrenzen.
-- Regel (fn-Kopf core.fn_get_llm_cost_report): 7 Tage = heute + 6 zurueck, Vorwoche = heute-13 .. heute-7,
-- 30 Tage = heute + 29 zurueck, Tage in der Sitzungs-Zeitzone. Sonnet 5.5 Output = 10 USD je Mio (Preisseite).
--   Zeilen (nur Output, Berliner Ortszeit): heute 00:30 1.000 = 0,01; heute-6 00:00 2.000 = 0,02;
--   heute-7 23:59:59 3.000 = 0,03; heute-13 00:00 4.000 = 0,04; heute-14 23:59 5.000 = 0,05; heute-29 00:00 1.000 = 0,01;
--   heute-30 23:59 1.000 = 0,01.
--   (1) 7 Tage = 0,01 + 0,02 = 0,03 (heute 00:30 Ortszeit ist UTC noch gestern und zaehlt trotzdem als heute).
--   (2) Vorwoche = 0,03 + 0,04 = 0,07 -> Veraenderung (0,03 - 0,07) / 0,07 = -57 %.
--   (3) 30 Tage = 0,01 + 0,02 + 0,03 + 0,04 + 0,05 + 0,01 = 0,16 (heute-30 faellt raus); Daten seit heute-30 -> 30 Tage
--       abgedeckt -> Schnitt 0,0053, Hochrechnung 0,16; teuerster Tag heute-6 (0,02).
BEGIN;

SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'recalc2 fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__r2d_owner__','first_name','Kim','last_name','Muster',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7702,'as_of','2026-10-25')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  DELETE FROM core.llm_usage;
  INSERT INTO core.llm_usage (id, ts, wf, model, output_tokens, status) VALUES
    ('1000000000011-cccccc-000001', (current_date + time '00:30')::timestamptz,          'agent.finance', 'claude-sonnet-5-5', 1000, 200),
    ('1000000000012-cccccc-000002', (current_date - 6 + time '00:00')::timestamptz,      'agent.finance', 'claude-sonnet-5-5', 2000, 200),
    ('1000000000013-cccccc-000003', (current_date - 7 + time '23:59:59')::timestamptz,   'agent.finance', 'claude-sonnet-5-5', 3000, 200),
    ('1000000000014-cccccc-000004', (current_date - 13 + time '00:00')::timestamptz,     'agent.finance', 'claude-sonnet-5-5', 4000, 200),
    ('1000000000015-cccccc-000005', (current_date - 14 + time '23:59')::timestamptz,     'agent.finance', 'claude-sonnet-5-5', 5000, 200),
    ('1000000000016-cccccc-000006', (current_date - 29 + time '00:00')::timestamptz,     'agent.finance', 'claude-sonnet-5-5', 1000, 200),
    ('1000000000017-cccccc-000007', (current_date - 30 + time '23:59')::timestamptz,     'agent.finance', 'claude-sonnet-5-5', 1000, 200);

  r := core.fn_get_llm_cost_report('{"chat_id":"7702"}');
  IF (r->'periods'->'d7'->>'total_usd')::numeric IS DISTINCT FROM 0.03 THEN
    RAISE EXCEPTION 'FAIL [1] 7 Tage: erwartet 0.03, got %', r->'periods'->'d7'; END IF;
  IF (r->'periods'->'d7'->>'prev_total_usd')::numeric IS DISTINCT FROM 0.07 OR (r->'periods'->'d7'->>'change_pct')::int IS DISTINCT FROM -57 THEN
    RAISE EXCEPTION 'FAIL [2] Vorwoche: %', r->'periods'->'d7'; END IF;
  IF (r->'periods'->'d30'->>'total_usd')::numeric IS DISTINCT FROM 0.16 OR (r->'periods'->'d30'->>'days_covered')::int IS DISTINCT FROM 30
     OR (r->'periods'->'d30'->>'avg_per_day_usd')::numeric IS DISTINCT FROM 0.0053
     OR (r->'periods'->'d30'->>'projected_month_usd')::numeric IS DISTINCT FROM 0.16
     OR (r->'insights'->>'top_day')::date IS DISTINCT FROM current_date - 6 THEN
    RAISE EXCEPTION 'FAIL [3] 30 Tage: % / top %', r->'periods'->'d30', r->'insights'; END IF;
  RAISE NOTICE 'PASS [1-3] Kosten-Fenster an Ortszeit-Mitternacht: 7 Tage, Vorwoche, 30 Tage, teuerster Tag';
END $$;

ROLLBACK;
