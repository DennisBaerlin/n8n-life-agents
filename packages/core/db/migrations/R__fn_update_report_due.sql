-- ============================================================
-- fn_update_report_due (READ-ONLY) — faellige Ergebnis-Meldungen des root-Runners
--   Offene Ergebnis-Meldungen des root-Runners, aelteste zuerst, hoechstens zwei, abgeschlossen vor hoechstens 24 Stunden.
--   Erfolg und teilweiser Erfolg warten auf den Bot, die Meldung soll erst kommen, wenn er wieder antwortet; nach 15 Minuten
--   ohne Bot gehen sie trotzdem hinaus (core.fn_update_report waehlt dann die ehrliche Klasse).
--   p: {bot_up?} — ohne Key zaehlt alles Offene (billige Leerlauf-Probe, die n8n nicht fragt).
--   Rueckgabe: [{id, params}]. Nie RAISE. INVOKER (root ueber runuser postgres).
--   Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_update_report_due(p jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'params', COALESCE(r.report_params, '{}'::jsonb)) ORDER BY r.finished_at), '[]'::jsonb)
      FROM (SELECT id, report_params, finished_at
              FROM core.update_requests
             WHERE report_state = 'due'
               AND finished_at > now() - interval '24 hours'
               AND (p->'bot_up' IS DISTINCT FROM 'false'::jsonb
                    OR outcome NOT IN ('succeeded', 'partial')
                    OR finished_at <= now() - interval '15 minutes')
             ORDER BY finished_at
             LIMIT 2) r;
$$;
