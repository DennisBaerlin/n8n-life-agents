-- tests/db/core/test_fn_next_check.sql
-- Testet fn_next_check(prev, interval, now): anker-erhaltender Cadence-Advance.
-- Vertrag: Ergebnis = prev + interval * k (k minimal), IMMER strikt > now (kein Sofort-Re-Fire),
--          Anker (Uhrzeit/Wochentag) bleibt erhalten, Catch-up nach Downtime ueberspringt
--          verpasste Slots statt sie nachzufeuern.
BEGIN;

DO $$
DECLARE
  v_next TIMESTAMPTZ;
BEGIN

  -- TEST 1: normaler Advance — Anker (09:00) bleibt erhalten
  v_next := agent.fn_next_check('2026-06-01 09:00+02'::timestamptz, INTERVAL '1 day',
                                '2026-06-01 10:00+02'::timestamptz);
  IF v_next IS DISTINCT FROM '2026-06-02 09:00+02'::timestamptz THEN
    RAISE EXCEPTION 'FAIL fn_next_check [normal advance]: erwartet 02.06. 09:00, got %', v_next;
  END IF;
  RAISE NOTICE 'PASS fn_next_check [normaler Advance, Anker erhalten]';

  -- TEST 2: Catch-up nach Downtime — verpasste Slots werden uebersprungen, nicht nachgefeuert
  v_next := agent.fn_next_check('2026-06-01 09:00+02'::timestamptz, INTERVAL '1 day',
                                '2026-06-05 10:00+02'::timestamptz);
  IF v_next IS DISTINCT FROM '2026-06-06 09:00+02'::timestamptz THEN
    RAISE EXCEPTION 'FAIL fn_next_check [catch-up]: erwartet 06.06. 09:00, got %', v_next;
  END IF;
  RAISE NOTICE 'PASS fn_next_check [Catch-up ueberspringt verpasste Slots]';

  -- TEST 3: now exakt auf einem Slot -> Ergebnis strikt in der Zukunft (naechster Slot)
  v_next := agent.fn_next_check('2026-06-01 09:00+02'::timestamptz, INTERVAL '1 day',
                                '2026-06-03 09:00+02'::timestamptz);
  IF v_next <= '2026-06-03 09:00+02'::timestamptz THEN
    RAISE EXCEPTION 'FAIL fn_next_check [boundary]: Ergebnis nicht strikt > now, got %', v_next;
  END IF;
  IF v_next IS DISTINCT FROM '2026-06-04 09:00+02'::timestamptz THEN
    RAISE EXCEPTION 'FAIL fn_next_check [boundary]: erwartet 04.06. 09:00, got %', v_next;
  END IF;
  RAISE NOTICE 'PASS fn_next_check [exakter Slot -> strikt naechster Slot]';

  -- TEST 4: now VOR prev (Trigger frisch angelegt, next_check in der Zukunft) -> prev + 1 Intervall
  v_next := agent.fn_next_check('2026-06-10 09:00+02'::timestamptz, INTERVAL '1 day',
                                '2026-06-08 12:00+02'::timestamptz);
  IF v_next IS DISTINCT FROM '2026-06-11 09:00+02'::timestamptz THEN
    RAISE EXCEPTION 'FAIL fn_next_check [now < prev]: erwartet 11.06. 09:00, got %', v_next;
  END IF;
  RAISE NOTICE 'PASS fn_next_check [now < prev -> prev + 1 Intervall]';

  -- TEST 5: Wochen-Anker — Montag bleibt Montag
  v_next := agent.fn_next_check('2026-06-01 08:00+02'::timestamptz, INTERVAL '7 days',  -- Mo 01.06.
                                '2026-06-03 15:00+02'::timestamptz);                     -- Mi
  IF v_next IS DISTINCT FROM '2026-06-08 08:00+02'::timestamptz THEN                     -- Mo 08.06.
    RAISE EXCEPTION 'FAIL fn_next_check [weekly]: erwartet Mo 08.06. 08:00, got %', v_next;
  END IF;
  RAISE NOTICE 'PASS fn_next_check [Wochen-Anker erhalten]';

  -- TEST 6: 12h-Intervall (Web-Minimum) — zwei Slots pro Tag
  v_next := agent.fn_next_check('2026-06-01 06:00+02'::timestamptz, INTERVAL '12 hours',
                                '2026-06-01 19:00+02'::timestamptz);
  IF v_next IS DISTINCT FROM '2026-06-02 06:00+02'::timestamptz THEN
    RAISE EXCEPTION 'FAIL fn_next_check [12h]: erwartet 02.06. 06:00, got %', v_next;
  END IF;
  RAISE NOTICE 'PASS fn_next_check [12h-Intervall]';

END $$;

ROLLBACK;
