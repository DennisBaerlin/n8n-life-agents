-- tests/db/finance/test_fn_account_interest_defaults.sql
-- Testet fn_account_interest_defaults: die vorgeschlagenen Zins-Werte eines NEUEN Kontos (Kadenz, Zinsmethode samt
-- Grund, Auto-Buchung) — die EINE Quelle fuer die HITL-Karte (tool_create_account, Import-Karte) UND fn_create_account.
-- Letzter Block: Karte = Write (die geschriebene Zinszeile traegt exakt die Vorschlagswerte).
BEGIN;

DO $$
DECLARE
  v    JSONB;
  v_r  JSONB;
  v_ir RECORD;
BEGIN
  -- ---------- Vorschlag aus dem Kontotyp; KEIN erfundener Rhythmus (Live-Befund 2026-10-24: vorher 'year') ----------
  v := finance.fn_account_interest_defaults('{"account_type":"cash"}'::jsonb);
  IF v ? 'unit' AND v->>'unit' IS NOT NULL
     OR v->>'first_period_end' IS NOT NULL
     OR v->>'conv' IS DISTINCT FROM finance.fn_interest_default_convention('cash')
     OR v->>'conv_reason' IS DISTINCT FROM 'default_cash' THEN
    RAISE EXCEPTION 'FAIL [cash default]: %', v;
  END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"fixed_deposit"}'::jsonb);
  IF v->>'conv' IS DISTINCT FROM finance.fn_interest_default_convention('fixed_deposit')
     OR v->>'conv_reason' IS DISTINCT FROM 'default_fixed' THEN
    RAISE EXCEPTION 'FAIL [fixed default]: %', v;
  END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"p2p"}'::jsonb);
  IF v->>'conv_reason' IS DISTINCT FROM 'default' THEN
    RAISE EXCEPTION 'FAIL [p2p default]: %', v;
  END IF;
  RAISE NOTICE 'PASS fn_account_interest_defaults [Methode + Grund je Kontotyp, kein Rhythmus erfunden]';

  -- ---------- Aufgeloeste Kadenz + erste Gutschrift (Karte zeigt sie, Kalender-Raster aus fn_interest_grid_point) ----------
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_unit":"month","interest_credit_day_of_month":"-1","interest_posting_day_of_month":"1","interest_valid_from":"2026-10-24"}'::jsonb);
  IF (v->>'interval')::int IS DISTINCT FROM 1 OR (v->>'dom')::int IS DISTINCT FROM -1 OR (v->>'pdom')::int IS DISTINCT FROM 1
     OR v->>'first_period_end' IS DISTINCT FROM '2026-10-31' OR v->>'first_credit_date' IS DISTINCT FROM '2026-11-01' THEN
    RAISE EXCEPTION 'FAIL [monatlich Monatsende + Arrears]: %', v; END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_unit":"month","interest_credit_interval":"3","interest_credit_day_of_month":"-1","interest_valid_from":"2026-10-24"}'::jsonb);
  IF (v->>'interval')::int IS DISTINCT FROM 3 OR v->>'first_period_end' IS DISTINCT FROM '2026-12-31'
     OR v->>'first_credit_date' IS DISTINCT FROM '2026-12-31' THEN
    RAISE EXCEPTION 'FAIL [Quartalsende = Kalender]: %', v; END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_unit":"year","interest_credit_day_of_month":"-1","interest_valid_from":"2026-10-24"}'::jsonb);
  IF v->>'first_period_end' IS DISTINCT FROM '2026-12-31' THEN RAISE EXCEPTION 'FAIL [Jahresende]: %', v; END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"fixed_deposit","interest_credit_unit":"year","interest_valid_from":"2026-10-24"}'::jsonb);
  IF v->>'first_period_end' IS DISTINCT FROM '2027-10-24' THEN RAISE EXCEPTION 'FAIL [Jahrestag]: %', v; END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"p2p","interest_credit_unit":"day","interest_valid_from":"2026-10-24"}'::jsonb);
  IF v->>'first_period_end' IS DISTINCT FROM '2026-10-25' OR (v->>'interval')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [taeglich]: %', v; END IF;
  -- unlesbare Zinsfelder auf einem Konto ohne Satz werfen nicht (Resolve-Knoten laeuft bei jedem create_account)
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_interval":"3.0","interest_credit_day_of_month":"last"}'::jsonb);
  IF (v->>'interval')::int IS DISTINCT FROM 1 OR v->>'dom' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [unlesbare Felder]: %', v; END IF;
  RAISE NOTICE 'PASS fn_account_interest_defaults [interval/dom/pdom aufgeloest, erste Gutschrift kalendergerecht, unlesbar wirft nicht]';

  -- ---------- Overrides schlagen den Vorschlag; auto_post folgt der Kadenz ----------
  v := finance.fn_account_interest_defaults(
         '{"account_type":"cash","interest_day_count_convention":"ACT/360","interest_auto_post":"true"}'::jsonb);
  IF v->>'conv' IS DISTINCT FROM 'ACT/360' OR v->>'conv_reason' IS DISTINCT FROM 'manual'
     OR (v->>'auto_post')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [override]: %', v;
  END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_unit":"month"}'::jsonb);
  IF v->>'unit' IS DISTINCT FROM 'month'
     OR (v->>'auto_post')::boolean IS DISTINCT FROM finance.fn_interest_auto_post_default('month') THEN
    RAISE EXCEPTION 'FAIL [kadenz month]: %', v;
  END IF;
  -- leere Strings (Einzel-Tool) = nicht genannt
  v := finance.fn_account_interest_defaults(
         '{"account_type":"cash","interest_day_count_convention":"","interest_auto_post":"","interest_credit_unit":""}'::jsonb);
  IF v->>'conv_reason' IS DISTINCT FROM 'default_cash' OR v->>'unit' IS NOT NULL
     OR v->>'valid_from' IS DISTINCT FROM to_char(CURRENT_DATE, 'YYYY-MM-DD') THEN
    RAISE EXCEPTION 'FAIL [leere Strings]: %', v;
  END IF;
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_valid_from":"2026-03-01"}'::jsonb);
  IF v->>'valid_from' IS DISTINCT FROM '2026-03-01' THEN
    RAISE EXCEPTION 'FAIL [valid_from genannt]: %', v;
  END IF;
  RAISE NOTICE 'PASS fn_account_interest_defaults [Override > Vorschlag, auto_post je Kadenz, leer = nicht genannt]';

  -- ---------- Karte = Write ----------
  v := finance.fn_account_interest_defaults('{"account_type":"cash","interest_credit_unit":"month","interest_credit_day_of_month":"-1"}'::jsonb);
  v_r := finance.fn_create_account('{"name":"__test_aid Tagesgeld","account_type":"cash","interest_rate":"2","interest_credit_unit":"month","interest_credit_day_of_month":"-1"}'::jsonb);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [karte=write]: create_account %', v_r;
  END IF;
  SELECT day_count_convention, auto_post, schedule_unit::text AS unit, valid_from INTO v_ir
  FROM finance.account_interest_rates WHERE account_id = (v_r->>'account_id')::int;
  IF v_ir.day_count_convention IS DISTINCT FROM v->>'conv'
     OR v_ir.auto_post IS DISTINCT FROM (v->>'auto_post')::boolean
     OR v_ir.unit IS DISTINCT FROM v->>'unit'
     OR v_ir.valid_from IS DISTINCT FROM (v->>'valid_from')::date THEN
    RAISE EXCEPTION 'FAIL [karte=write]: geschrieben % / % / %, Karte %', v_ir.day_count_convention, v_ir.auto_post, v_ir.unit, v;
  END IF;
  RAISE NOTICE 'PASS fn_account_interest_defaults [Karte = Write: Zinszeile traegt die Vorschlagswerte]';
END;
$$;

ROLLBACK;
