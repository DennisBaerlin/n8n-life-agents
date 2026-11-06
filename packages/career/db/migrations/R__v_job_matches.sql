-- ============================================================
-- career.v_job_matches (WS-2 — schlanke Read-Overview der Job-Treffer)
--   Kuratierter Read-Pfad fuer den career_advisor (postgres_select, Rolle career_ro) + das publizierte
--   read_surface.preferred_views (Aufsichtsfenster core_ro). Schmale, stabile Spaltenmenge (kein raw-jsonb);
--   neueste zuerst -> der Advisor liest u. a. die "zuletzt bewertete Stelle" (ORDER BY feedback_at) fuer den
--   Freitext-Grund-Loop. Idempotent (CREATE OR REPLACE VIEW). Anwenden via:
--     db_apply.ps1 -File packages\career\db\migrations\R__v_job_matches.sql
-- ============================================================
CREATE OR REPLACE VIEW career.v_job_matches AS
SELECT
    id,
    person_id,          -- P2a: wholly-per-person (welche Person den Treffer fuehrt)
    source,             -- V005: Ingestion-Provider (bundesagentur|adzuna|jsearch|forwarded)
    board,              -- V005: Original-Board (nur jsearch via job_publisher; sonst NULL)
    external_id,        -- V005: war refnr; generischer Per-Provider-Schluessel
    title,
    employer,
    location,
    url,
    score,
    is_serendipity,
    status,
    feedback_at,
    created_at,
    updated_at
FROM career.job_matches;
