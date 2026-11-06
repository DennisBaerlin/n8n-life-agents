-- ============================================================
-- V039 (finance) — Plan-Abschnitt: gespeicherten Schluessel auf den allgemeinen Namen 'crossborder' umstellen.
--
--   WARUM: der Sektionskatalog (R__fn_plan_gaps, Berater-Prompt) nennt den Abschnitt jetzt 'crossborder'. Sektionen
--   stehen als Schluessel in agent.advisor_plans.interview_state; fn_plan_gaps bildet die Union ueber ALLE
--   veroeffentlichten Versionen. Ohne Umstellung gaelte ein bestaetigter Abschnitt wieder als nie bestaetigt.
--
--   Erfasst jeden Finanz-Plan (draft, active, superseded), dessen Schluessel auf '_crossborder' endet; der Schluessel
--   'crossborder' selbst passt nicht auf das Muster. Inhalt (content, data, saved_at), status und version bleiben.
--   Stehen beide Schluessel im selben Plan, gewinnt der neue. Frische DB = keine Zeile -> No-op. Re-run-sicher.
-- ============================================================

UPDATE agent.advisor_plans ap
SET interview_state = (
    SELECT jsonb_object_agg(CASE WHEN s.key LIKE '%\_crossborder' THEN 'crossborder' ELSE s.key END, s.value
                            ORDER BY s.key = 'crossborder')
    FROM jsonb_each(ap.interview_state) s)
WHERE ap.domain = 'finance'
  AND jsonb_typeof(ap.interview_state) = 'object'
  AND EXISTS (SELECT 1 FROM jsonb_object_keys(ap.interview_state) k WHERE k LIKE '%\_crossborder');
