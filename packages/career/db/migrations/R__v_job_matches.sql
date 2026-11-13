-- ============================================================
-- career.v_job_matches (schlanke Read-Overview der Job-Treffer)
--   Kuratierter Read-Pfad fuer den career_advisor (postgres_select, Rolle career_ro) + das publizierte
--   read_surface.preferred_views (Aufsichtsfenster core_ro). Schmale, stabile Spaltenmenge (kein raw-jsonb).
--   Keine eigene Sortierung; der Advisor liest die "zuletzt bewertete Stelle" per ORDER BY feedback_at
--   fuer den Freitext-Grund-Loop. Idempotent (CREATE OR REPLACE VIEW).
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
