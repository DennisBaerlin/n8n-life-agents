-- ============================================================
-- finance.fn_plan_gap_count(p_domain, p_person_id) — offene Punkte am aktiven Haushalts-Finanzplan (2026-10-28)
--   Registry-Feld core.advisors.gaps_fn der Domain 'finance' (Onboarding-Plan-Schritt "Finanzplan vervollstaendigen
--   (n offen)"). Zaehlt die drei Listen der EINEN Adresse finance.fn_plan_gaps ueber die Fakten des Sidecars
--   financial_planning: nie bestaetigte Sektionen + bestaetigte Sektionen ohne verwertbaren Block + nur im Draft
--   gespeicherte Sektionen. Ohne aktiven Plan 0 (der Zustand heisst dann "kein Plan"/"Entwurf", nicht "Luecken").
--   Die Draft-Liste zaehlt mit, damit die Zahl fuer sich stimmt; im Plan-Status ist sie praktisch 0, weil ein offener
--   Entwurf dort Vorrang hat ("fortsetzen") und gaps_fn dann nicht gerufen wird.
--   p_domain/p_person_id = die einheitliche Registry-Signatur; der Finanzplan ist haushaltsweit, beide ungenutzt.
--   STABLE/INVOKER (Muster fn_plan_gaps): einziger Aufrufer core.fn_advisor_plan_status (SECURITY DEFINER).
--   Tests: tests/db/finance/test_fn_plan_gap_count.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_gap_count(p_domain text, p_person_id text)
RETURNS int
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v jsonb;
BEGIN
    v := finance.fn_plan_gaps((SELECT c.metadata->'facts' FROM agent.core_contexts c WHERE c.name = 'financial_planning'));
    RETURN jsonb_array_length(COALESCE(v->'open_sections', '[]'::jsonb))
         + jsonb_array_length(COALESCE(v->'missing_blocks', '[]'::jsonb))
         + jsonb_array_length(COALESCE(v->'draft_only_sections', '[]'::jsonb));
END;
$$;
