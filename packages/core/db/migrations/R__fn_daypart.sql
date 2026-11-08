-- ============================================================
-- core.fn_daypart (Tageszeit des Haushalts)
--   Tageszeit zu einem Zeitpunkt in der Haushalts-Zeitzone (Sitzungs-Zeitzone wie core.fn_today), Standard p_at = now().
--   Halboffene Grenzen nach lokaler Stunde: [5,11) morning, [11,17) day, [17,22) evening, sonst night.
--   Konsumenten: Router-Flag daypart (Orchestrator 'Resolve sender'), Tagesgruss in agent.fn_claim_persona_frame.
--   RUECKGABE: 'morning' | 'day' | 'evening' | 'night'
--   Tests: tests/db/core/test_fn_daypart.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_daypart(p_at timestamptz DEFAULT pg_catalog.now())
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
             WHEN h >= 5  AND h < 11 THEN 'morning'
             WHEN h >= 11 AND h < 17 THEN 'day'
             WHEN h >= 17 AND h < 22 THEN 'evening'
             ELSE 'night'
           END
      FROM (SELECT pg_catalog.date_part('hour', p_at AT TIME ZONE pg_catalog.current_setting('TimeZone'))::int AS h) x;
$$;
