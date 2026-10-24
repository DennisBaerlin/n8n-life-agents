-- ============================================================
-- fn_owner_person_id (read-only, Identity-Helper — DIE eine Owner-Person-Quelle)
--   Liefert den person_id-Slug des Haushalts-Owners aus dem family-Facts-Sidecar
--   (persons[] WHERE role='owner'). Schwester von agent.fn_resolve_sender (das eine
--   telegram_user_id->person braucht); dieser Helper braucht keine Identitaet — er
--   liefert den FESTEN Owner-Anker des Haushalts.
--
--   ZWECK (P0c): EINE deterministische Quelle fuer den Owner-Anker, statt das Muster
--   in mehreren fns/Migrationen zu duplizieren (DRY). Konsumenten:
--     * core.fn_advisor_read_plan (per_user-Fallback, wenn kein chat_id geliefert wird:
--       der LLM-Frei-SQL-Lesepfad des career_advisor -> Owner-Plan, P0c Single-Person)
--     * career.fn_advisor_review (liest career_planning/career_profile am Owner-Suffix,
--       da der geteilte Review-Wrapper KEINE Person-Dimension hat -> P0c Single-Person)
--     * cron.refresh_market_signals (always-on: liest career_planning am Owner-Suffix)
--     * career:V002 (Daten-Backfill: career_planning + advisor_plans -> Owner-pid)
--
--   DETERMINISTISCH + RAISE-FREI: LIMIT 1 (agent.persons/family erzwingen KEINE
--   "genau ein owner"-Invariante -> ohne LIMIT 1 wuerfe ein Scalar-Subquery-Aufruf
--   "more than one row" und kippte die RAISE-verbotene Review-fn). Muster = V001:27-30.
--   Kein Owner (Bootstrap/fresh DB) -> NULL (die Aufrufer degradieren graceful).
--
--   search_path NICHT gepinnt (Paritaet zu fn_resolve_sender; alle Refs schema-qualifiziert).
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_owner_person_id.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_owner_person_id()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT pp->>'person_id'
    FROM agent.core_contexts c,
         jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family' AND pp->>'role' = 'owner'
    LIMIT 1;
$$;
