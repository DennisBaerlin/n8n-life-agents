-- ============================================================
-- career.v_job_matches (schlanke Read-Overview der Job-Treffer)
--   Schmale, stabile Spaltenmenge der Job-Treffer (kein raw-jsonb). Person-privat: fuer career_ro/core_ro gesperrt
--   (core.fn_provision_package_roles), nicht in read_surface.preferred_views; der Advisor liest seine Treffer ueber
--   career.fn_read_job_matches. Keine eigene Sortierung. Idempotent (CREATE OR REPLACE VIEW).
-- ============================================================
CREATE OR REPLACE VIEW career.v_job_matches AS
SELECT
    id,
    person_id,          -- wholly-per-person (welche Person den Treffer fuehrt)
    source,             -- Ingestion-Provider (bundesagentur|adzuna|jsearch|forwarded)
    board,              -- Original-Board (nur jsearch via job_publisher; sonst NULL)
    external_id,        -- generischer Per-Provider-Schluessel (BA: refnr)
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
