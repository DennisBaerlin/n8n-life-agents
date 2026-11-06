-- tests/db/cross/test_views_smoke.sql
-- Generische All-Package-View-Smoke (E7): JEDE View ALLER Nicht-System-Schemas existiert +
-- ist abfragbar (LIMIT 1) — paket-uebergreifend statt hartkodierter finance-Liste. Faengt
-- Migrations-Brueche (append-only-View-Regel) und die DROP-CASCADE-Falle der R__-Sammeldateien
-- (eine per CASCADE mitgedroppte View fehlt hier sofort — via Floor + Sentinels, s. u.).
BEGIN;

DO $$
DECLARE
  r       RECORD;
  v_count INT := 0;
BEGIN
  FOR r IN
    SELECT schemaname, viewname
    FROM pg_views
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY schemaname, viewname
  LOOP
    BEGIN
      EXECUTE format('SELECT * FROM %I.%I LIMIT 1', r.schemaname, r.viewname);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'FAIL views_smoke: SELECT auf %.% fehlgeschlagen: %',
        r.schemaname, r.viewname, SQLERRM;
    END;
    v_count := v_count + 1;
  END LOOP;

  -- Anti-Silent-Green: eine leere pg_views-Menge (Bootstrap-/R__-Apply-Bruch) darf NICHT
  -- gruen durchlaufen. Floor bei bewusstem View-Abbau senken (Stand: 19 Paket-Views).
  IF v_count < 15 THEN
    RAISE EXCEPTION 'FAIL views_smoke: nur % Views gefunden (Floor 15) — Bootstrap/R__-Apply pruefen', v_count;
  END IF;

  -- Sentinels: je View-besitzendem Paket eine bekannte View (faengt fehlendes Paket-Schema).
  IF to_regclass('finance.account_overview') IS NULL THEN
    RAISE EXCEPTION 'FAIL views_smoke: Sentinel finance.account_overview fehlt';
  END IF;
  IF to_regclass('career.v_job_matches') IS NULL THEN
    RAISE EXCEPTION 'FAIL views_smoke: Sentinel career.v_job_matches fehlt';
  END IF;

  RAISE NOTICE 'PASS views_smoke: % Views existieren + abfragbar (alle Paket-Schemas)', v_count;
END $$;

ROLLBACK;
