-- ============================================================
-- fn_resolve_person (PUBLIZIERTE SECURITY-DEFINER-READ-FN — Core-Lesefenster, D10)
--   Loest einen Personen-Bezug ("Erika", "meine Frau", "Lena Beispiel", "Mustermann") gegen das
--   family-Facts-Sidecar (agent.core_contexts) auf: case-insensitiver Match auf first_name, last_name,
--   "first_name last_name" oder einen Alias. Rueckgabe wie alle Resolver:
--   (person_id, full_name, hit_count, candidates) — 0/>1 Treffer => person_id NULL, der Aufrufer fragt nach.
--   Bei 0 Treffern (genannter Name) sind candidates ALLE Haushaltsmitglieder (Auswahl statt Nachname-Rueckfrage).
--
--   KONSUMENT: die finance create_*/set_*-Write-Tools (WS-4, Person-Zuordnung) unter finance_rw —
--   plus finance_ro fuer Reads. Diese ENGEN Paket-Rollen erreichen agent.* NICHT direkt (D10:
--   search_path/USAGE nur pg_catalog,<pkg>,core) -> der Resolver liegt in CORE (nicht agent) und liest
--   agent.core_contexts per SECURITY DEFINER. Gespiegeltes Fenster-Muster: core.fn_household_persons /
--   core.fn_advisor_read_plan (eine finance-Schicht liest agent.* nie selbst).
--
--   SECURITY DEFINER + gepinnter search_path + REVOKE ALL FROM PUBLIC + EXECUTE nur an die Paket-Rollen
--   (erteilt in core.fn_provision_package_roles). READ-ONLY (nur SELECT).
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_resolve_person.sql
--   (Vorgaenger agent.fn_resolve_member wird von core:V010 gedroppt — Rename, kein CREATE-OR-REPLACE.)
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_resolve_person(p_name text)
RETURNS TABLE (
    person_id  text,
    full_name  text,
    hit_count  int,
    candidates jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, agent, core, pg_temp
AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         TEXT;
    v_full       TEXT;
    v_q          TEXT := lower(trim(COALESCE(p_name, '')));
BEGIN
    SELECT
        jsonb_agg(jsonb_build_object(
            'person_id', p.person_id,
            'full_name', p.full_name,
            'role',      p.role
        ) ORDER BY p.person_id),
        COUNT(*),
        MIN(p.person_id),
        MIN(p.full_name)
    INTO v_candidates, v_count, v_id, v_full
    FROM (
        SELECT pp->>'person_id' AS person_id,
               (pp->>'first_name') || ' ' || (pp->>'last_name') AS full_name,
               pp->>'role' AS role
        FROM agent.core_contexts c,
             jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
        WHERE c.name = 'family'
          AND v_q <> ''
          AND (
                lower(pp->>'first_name') = v_q
             OR lower(pp->>'last_name')  = v_q
             OR lower((pp->>'first_name') || ' ' || (pp->>'last_name')) = v_q
             OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(pp->'aliases','[]'::jsonb)) a
                        WHERE lower(a) = v_q)
          )
    ) p;

    -- 0 Treffer bei genanntem Namen -> ALLE Haushaltsmitglieder als candidates: der Agent zeigt eine Auswahl
    -- ("Meinst du Lena Beispiel?") statt nach einem Nachnamen zu fragen. hit_count bleibt 0 (Aufrufer-Logik gleich).
    IF COALESCE(v_count, 0) = 0 AND v_q <> '' THEN
        SELECT jsonb_agg(jsonb_build_object(
                   'person_id', pp->>'person_id',
                   'full_name', (pp->>'first_name') || ' ' || (pp->>'last_name'),
                   'role',      pp->>'role'
               ) ORDER BY pp->>'person_id')
        INTO v_candidates
        FROM agent.core_contexts c,
             jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
        WHERE c.name = 'family';
    END IF;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id   ELSE NULL END,
        CASE WHEN v_count = 1 THEN v_full ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_resolve_person(text) FROM public;
-- EXECUTE-GRANT an die Paket-Rollen erteilt core.fn_provision_package_roles (idempotent,
-- to_regprocedure-geguardet) — hier nur der PUBLIC-REVOKE als Default-Schutz.
