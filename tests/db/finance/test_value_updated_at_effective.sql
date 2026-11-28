-- tests/db/finance/test_value_updated_at_effective.sql
-- Bewertungsdatum auf der Karte: fn_create_pension, fn_set_pension, fn_create_real_estate, fn_set_real_estate setzen
-- value_updated_at = heute, wenn nur current_value kommt, und geben den gespeicherten Wert in effective.value_updated_at
-- zurueck (auch im Probelauf core.fn_dry_run); ein genanntes Datum kommt so zurueck, ohne current_value fehlt der Schluessel.
BEGIN;

DO $$
DECLARE
  r jsonb; v_pen int; v_re int;
BEGIN
  -- create_pension: nur Wert -> heute; Wert + Datum -> das Datum
  r := finance.fn_create_pension(jsonb_build_object('name','__t_vua_pen__','pension_type','occupational','current_value',1000));
  v_pen := (r->>'pension_id')::int;
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [create_pension nur Wert]: %', r; END IF;
  r := finance.fn_create_pension(jsonb_build_object('name','__t_vua_pen2__','pension_type','occupational','current_value',1000,
         'value_updated_at','2026-01-15'));
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM DATE '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL [create_pension mit Datum]: %', r; END IF;
  r := finance.fn_create_pension(jsonb_build_object('name','__t_vua_pen3__','pension_type','occupational'));
  IF r->'effective' ? 'value_updated_at' THEN RAISE EXCEPTION 'FAIL [create_pension ohne Wert]: %', r; END IF;

  -- set_pension: nur Wert -> heute (auch im Probelauf); ohne Wert kein Schluessel
  UPDATE finance.pension SET value_updated_at = DATE '2025-01-01' WHERE id = v_pen;
  r := core.fn_dry_run('finance.fn_set_pension(jsonb)'::regprocedure, jsonb_build_object('pension_id', v_pen, 'current_value', 1200));
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [set_pension Probelauf]: %', r; END IF;
  r := finance.fn_set_pension(jsonb_build_object('pension_id', v_pen, 'current_value', 1200));
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [set_pension nur Wert]: %', r; END IF;
  r := finance.fn_set_pension(jsonb_build_object('pension_id', v_pen, 'notes', 'x'));
  IF r->'effective' ? 'value_updated_at' THEN RAISE EXCEPTION 'FAIL [set_pension ohne Wert]: %', r; END IF;

  -- create_real_estate / set_real_estate
  r := finance.fn_create_real_estate(jsonb_build_object('name','__t_vua_re__','current_value',300000));
  v_re := (r->>'real_estate_id')::int;
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [create_real_estate nur Wert]: %', r; END IF;
  UPDATE finance.real_estate SET value_updated_at = DATE '2025-01-01' WHERE id = v_re;
  r := core.fn_dry_run('finance.fn_set_real_estate(jsonb)'::regprocedure, jsonb_build_object('real_estate_id', v_re, 'current_value', 310000));
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [set_real_estate Probelauf]: %', r; END IF;
  r := finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_re, 'current_value', 310000, 'value_updated_at', '2026-02-01'));
  IF (r->'effective'->>'value_updated_at')::date IS DISTINCT FROM DATE '2026-02-01' THEN
    RAISE EXCEPTION 'FAIL [set_real_estate mit Datum]: %', r; END IF;
  r := finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_re, 'notes', 'x'));
  IF r->'effective' ? 'value_updated_at' THEN RAISE EXCEPTION 'FAIL [set_real_estate ohne Wert]: %', r; END IF;

  RAISE NOTICE 'PASS value_updated_at_effective [vier fns, Probelauf, mit und ohne Datum]';
END $$;

ROLLBACK;
