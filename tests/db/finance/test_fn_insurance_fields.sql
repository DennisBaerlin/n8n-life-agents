-- tests/db/finance/test_fn_insurance_fields.sql
-- Testet fn_insurance_fields (Lese-/Pruef-Helfer fuer create/set_insurance und die Karten-Vorschau): Beitrag je Abbuchung
-- oder Jahresbeitrag, Rhythmus-Pflicht und -Default, Doppelangabe mit Rundungs-Toleranz, deutsche Zahlen, Summe/Frist/Typ,
-- und "kein Beitrag" als gueltiger Zustand (premium_amount/annual_premium NULL).
BEGIN;

DO $$
DECLARE
  v JSONB;
  v_case JSONB;
BEGIN
  -- Kein Beitrag: ok, beide NULL (Police ohne Beitrag ist gueltig)
  v := finance.fn_insurance_fields('{}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR v->>'premium_amount' IS NOT NULL OR v->>'annual_premium' IS NOT NULL
     OR (v->>'schedule_interval')::int IS DISTINCT FROM 1 OR v->>'schedule_unit' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [leer]: ok, Beitrag NULL, Intervall 1 erwartet, got %', v; END IF;

  -- Jahresbeitrag ohne Rhythmus -> jaehrlich, Betrag je Abbuchung = Jahresbeitrag
  v := finance.fn_insurance_fields('{"annual_premium":"89,50"}'::jsonb);
  IF (v->>'premium_amount')::numeric IS DISTINCT FROM 89.50 OR (v->>'annual_premium')::numeric IS DISTINCT FROM 89.50
     OR v->>'schedule_unit' IS DISTINCT FROM 'year' THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [Jahresbeitrag]: 89.50 jaehrlich erwartet, got %', v; END IF;

  -- Jahresbeitrag monatlich -> 1200 / 12 = 100 je Abbuchung; deutscher Tausenderpunkt "1.200"
  v := finance.fn_insurance_fields('{"annual_premium":"1.200","schedule_unit":"month"}'::jsonb);
  IF (v->>'premium_amount')::numeric IS DISTINCT FROM 100.00 OR (v->>'annual_premium')::numeric IS DISTINCT FROM 1200.00 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [1.200 monatlich]: 100 je Abbuchung, 1200 im Jahr erwartet, got %', v; END IF;

  -- Betrag je Abbuchung roh, Jahreswert abgeleitet; vierteljaehrlich = month x 3
  v := finance.fn_insurance_fields('{"premium_amount":30,"schedule_unit":"month","schedule_interval":"3"}'::jsonb);
  IF (v->>'premium_amount')::numeric IS DISTINCT FROM 30 OR (v->>'annual_premium')::numeric IS DISTINCT FROM 120.00
     OR (v->>'schedule_interval')::int IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [30 quartalsweise]: 30 je Abbuchung, 120 im Jahr erwartet, got %', v; END IF;

  -- Doppelangabe: bis 0,01 Abweichung ok (die Abbuchung gilt), darueber ok:false mit beiden Werten
  v := finance.fn_insurance_fields('{"premium_amount":83.34,"annual_premium":1000,"schedule_unit":"month"}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'premium_amount')::numeric IS DISTINCT FROM 83.34 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [Rundung]: 83.34 erwartet, got %', v; END IF;
  v := finance.fn_insurance_fields('{"premium_amount":30,"annual_premium":300,"schedule_unit":"month"}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR (v->>'premium_amount')::numeric IS DISTINCT FROM 30
     OR (v->>'annual_premium')::numeric IS DISTINCT FROM 300 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [unstimmig]: ok:false mit 30/300 erwartet, got %', v; END IF;

  -- Summe/Frist: Text mit Tausenderpunkt, JSON-Zahl bleibt Zahl, Frist ganze Stunden
  v := finance.fn_insurance_fields('{"coverage_amount":"50.000","claim_deadline_hours":" 48 "}'::jsonb);
  IF (v->>'coverage_amount')::numeric IS DISTINCT FROM 50000 OR (v->>'claim_deadline_hours')::int IS DISTINCT FROM 48 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [Summe/Frist]: 50000/48 erwartet, got %', v; END IF;
  v := finance.fn_insurance_fields('{"coverage_amount":50.000}'::jsonb);
  IF (v->>'coverage_amount')::numeric IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [Zahl]: 50 erwartet, got %', v; END IF;

  -- Korrigierbare Ablehnungen (je ein Fall): Betrag ohne Rhythmus, <= 0, unlesbar, Intervall < 1, Summe < 0,
  -- Frist kein ganze Zahl / 0, unbekannter Rhythmus, unbekannter Typ
  FOREACH v_case IN ARRAY ARRAY[
      '{"premium_amount":30}', '{"annual_premium":0}', '{"premium_amount":-5,"schedule_unit":"month"}',
      '{"annual_premium":"zwoelf"}', '{"annual_premium":100,"schedule_interval":"0"}', '{"coverage_amount":"-1"}',
      '{"claim_deadline_hours":"48h"}', '{"claim_deadline_hours":"0"}', '{"annual_premium":100,"schedule_unit":"yearly"}',
      '{"insurance_type":"pet"}']::jsonb[] LOOP
    v := finance.fn_insurance_fields(v_case);
    IF (v->>'ok')::boolean IS DISTINCT FROM false OR NULLIF(v->>'reason', '') IS NULL THEN
      RAISE EXCEPTION 'FAIL fn_insurance_fields [Ablehnung %]: ok:false mit reason erwartet, got %', v_case, v; END IF;
  END LOOP;

  -- Ein Platzhalter wie 1,00 ist fuer die DB ein normaler Beitrag (das Verbot steht in der Tool-Description)
  v := finance.fn_insurance_fields('{"annual_premium":1}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'premium_amount')::numeric IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_insurance_fields [1,00]: gueltig erwartet, got %', v; END IF;

  RAISE NOTICE 'PASS fn_insurance_fields [leer gueltig, Jahres-/Abbuchungsbetrag, Rundung, Zahlen, 10 Ablehnungen, 1,00 gueltig]';
END $$;

ROLLBACK;
