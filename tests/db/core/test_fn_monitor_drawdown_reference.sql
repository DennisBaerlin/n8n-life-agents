-- tests/db/core/test_fn_monitor_drawdown_reference.sql
-- Testet agent.fn_monitor_drawdown_reference: die eine Adresse fuer den Hoechststand (Referenz) eines Drawdown-Waechters.
-- sql mit history_query -> laufendes Maximum der Reihe (Wert, Datum, Reihen-Beginn); ohne Reihe -> heutiger Probe-Wert
-- (basis current); weder Reihe noch Probe -> basis none. Die Reihen hier sind VALUES-Listen (keine Tabelle noetig).
BEGIN;

DO $$
DECLARE
  v   jsonb;
  c_hist CONSTANT text := 'SELECT d, v FROM (VALUES (''2026-10-05''::date, 21.80), (''2026-10-14''::date, 23.47), '
                       || '(''2026-11-12''::date, 22.15), (''2026-11-26''::date, 20.95)) x(d, v)';
BEGIN
  -- 1: Reihe -> Maximum mit Datum und Reihen-Beginn
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 20.95', 'history_query', c_hist),
         'current_value', 20.95, 'current_as_of', '2026-11-26'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric IS DISTINCT FROM 23.47
     OR v->>'as_of' IS DISTINCT FROM '2026-10-14' OR v->>'since' IS DISTINCT FROM '2026-10-05'
     OR v->>'basis' IS DISTINCT FROM 'history' THEN
    RAISE EXCEPTION 'FAIL ddref [Reihe -> Maximum]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [Reihe -> Maximum mit Datum und Beginn]';

  -- 2: since schneidet die Reihe ab
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 20.95', 'history_query', c_hist), 'since', '2026-11-01',
         'current_value', 20.95, 'current_as_of', '2026-11-26'));
  IF (v->>'value')::numeric IS DISTINCT FROM 22.15 OR v->>'as_of' IS DISTINCT FROM '2026-11-12'
     OR v->>'since' IS DISTINCT FROM '2026-11-01' THEN
    RAISE EXCEPTION 'FAIL ddref [since]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [since schneidet ab]';

  -- 3: heutiger Wert ueber dem Reihen-Maximum -> heutiger Wert (Referenz nie unter dem aktuellen Wert)
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 25', 'history_query', c_hist),
         'current_value', 25, 'current_as_of', '2026-11-27'));
  IF (v->>'value')::numeric IS DISTINCT FROM 25 OR v->>'as_of' IS DISTINCT FROM '2026-11-27' OR v->>'basis' IS DISTINCT FROM 'history' THEN
    RAISE EXCEPTION 'FAIL ddref [aktuell > Maximum]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [aktueller Wert ueber dem Maximum]';

  -- 4: leere Reihe -> heutiger Wert
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 20.95', 'history_query', c_hist), 'since', '2027-01-01',
         'current_value', 20.95, 'current_as_of', '2026-11-26'));
  IF (v->>'value')::numeric IS DISTINCT FROM 20.95 OR v->>'basis' IS DISTINCT FROM 'current' THEN
    RAISE EXCEPTION 'FAIL ddref [leere Reihe]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [leere Reihe -> heutiger Wert]';

  -- 5: Methode ohne Reihe (Web, Paket-Methode) -> heutiger Probe-Wert, gemessen ab heute
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'web_search',
         'spec', jsonb_build_object('prompt', 'x'), 'current_value', 112.34, 'current_as_of', '2026-06-09'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric IS DISTINCT FROM 112.34
     OR v->>'basis' IS DISTINCT FROM 'current' OR (v->>'since')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL ddref [web -> current]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [ohne Reihe -> heutiger Wert]';

  -- 6: weder Reihe noch Probe -> basis none (die erste saubere Messung setzt den Wert)
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'web_search', 'spec', '{}'::jsonb));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR v->'value' IS DISTINCT FROM 'null'::jsonb OR v->>'basis' IS DISTINCT FROM 'none' THEN
    RAISE EXCEPTION 'FAIL ddref [none]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [ohne alles -> none]';

  -- 7: unbrauchbare Reihen-Abfrage -> {ok:false}, kein RAISE
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 1', 'history_query', 'DELETE FROM agent.monitor_triggers'),
         'current_value', 1));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%history_sql%' THEN
    RAISE EXCEPTION 'FAIL ddref [kein SELECT]: got %', v;
  END IF;
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 1', 'history_query', 'SELECT 1'), 'current_value', 1));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%history_sql%' THEN
    RAISE EXCEPTION 'FAIL ddref [eine Spalte]: got %', v;
  END IF;
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 1', 'history_query', 'SELECT ''kein Datum'', 1'), 'current_value', 1));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%history_sql%' THEN
    RAISE EXCEPTION 'FAIL ddref [kein Datum]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [unbrauchbare Reihe -> ok:false]';

  -- 8: die Reihe laeuft read-only (dieselbe Leserolle wie die Beschaffung): ein Zugriff, den nur ein Superuser darf (pg_authid), scheitert als ok:false
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 1',
           'history_query', 'SELECT now()::date, (SELECT count(*) FROM pg_catalog.pg_authid)'), 'current_value', 1));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL ddref [read-only Rolle]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [Reihe laeuft unter der Leserolle]';

  -- 9: Zeilen ohne Datum zaehlen nicht (sonst stuende der Hoechststand ohne Datum auf der Karte)
  v := agent.fn_monitor_drawdown_reference(jsonb_build_object('method', 'sql',
         'spec', jsonb_build_object('query', 'SELECT 1',
           'history_query', 'SELECT d, v FROM (VALUES (NULL::date, 99.0), (''2026-10-14''::date, 23.47)) x(d, v)'), 'current_value', 12));
  IF (v->>'value')::numeric IS DISTINCT FROM 23.47 OR v->>'as_of' IS DISTINCT FROM '2026-10-14' THEN
    RAISE EXCEPTION 'FAIL ddref [Zeile ohne Datum]: got %', v;
  END IF;
  RAISE NOTICE 'PASS ddref [Zeile ohne Datum zaehlt nicht]';

  -- 10: Meldegrenze und Auswertung folgen derselben Regel: bei der Grenze meldet sie, einen Schritt darueber nicht
  IF agent.fn_monitor_drawdown_alert_level(23.47, 20) IS DISTINCT FROM 18.77
     OR agent.fn_monitor_drawdown_pct(23.47, 18.77) < 20 OR agent.fn_monitor_drawdown_pct(23.47, 18.78) >= 20 THEN
    RAISE EXCEPTION 'FAIL ddref [Meldegrenze]: level=% pct(18.77)=% pct(18.78)=%', agent.fn_monitor_drawdown_alert_level(23.47, 20),
      agent.fn_monitor_drawdown_pct(23.47, 18.77), agent.fn_monitor_drawdown_pct(23.47, 18.78);
  END IF;
  IF agent.fn_monitor_drawdown_alert_level(100, 20) IS DISTINCT FROM 80 THEN
    RAISE EXCEPTION 'FAIL ddref [Meldegrenze glatt]: %', agent.fn_monitor_drawdown_alert_level(100, 20);
  END IF;
  RAISE NOTICE 'PASS ddref [Meldegrenze = Regel der Auswertung]';

  -- 11: Einheit: nur ein ISO-Code (drei Grossbuchstaben) wird Geldbetrag
  IF agent.fn_monitor_amount_params(45, 'MWh')#>>'{value,kind}' IS DISTINCT FROM 'number'
     OR agent.fn_monitor_amount_params(45, 'MWh')->>'unit' IS DISTINCT FROM ' MWh'
     OR agent.fn_monitor_amount_params(23.47, 'EUR')#>>'{value,kind}' IS DISTINCT FROM 'money' THEN
    RAISE EXCEPTION 'FAIL ddref [Einheit]: % / %', agent.fn_monitor_amount_params(45, 'MWh'), agent.fn_monitor_amount_params(23.47, 'EUR');
  END IF;
  RAISE NOTICE 'PASS ddref [Einheit: Waehrung vs. sonstige]';
END $$;

ROLLBACK;
