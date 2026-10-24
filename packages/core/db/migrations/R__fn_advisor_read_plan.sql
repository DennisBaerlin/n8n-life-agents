-- ============================================================
-- fn_advisor_read_plan (PUBLIZIERTE SECURITY-DEFINER-READ-FN — Core-Lesefenster, D10/O1)
--   Das EINZIGE Lesefenster der engen Paket-Leserolle finance_ro/career_ro auf die domaenen-neutrale
--   Plan-Persistenz agent.advisor_plans (die nach der Finance-Isolation in `agent` bleibt, O1 — Shared-
--   Infra fuer die Advisor-Domaenen). Der Advisor-Agent liest seinen Plan-Stand zur Laufzeit per freiem
--   postgres_select (Interview fortsetzen / publizierte Version pruefen); unter der engen Rolle erreicht
--   er agent.* nicht direkt → er ruft stattdessen diese Fn:
--       SELECT status, version, interview_state, plan_md FROM core.fn_advisor_read_plan('career');
--
--   P0c PERSON-SCOPE (Paritaet zum Schreibpfad fn_advisor_save_section/_publish_plan): der Plan-Schluessel
--   ist (domain, person_id). Die Domain -> ihr Plan-Context (core.advisors.plan_context, Fallback
--   '<domain>_planning') -> dessen scope (core.context_scopes). household -> person_id IS NULL (der eine
--   Haushalts-Plan; finance/financial_planning). per_user -> die Person:
--     * chat_id geliefert + aufgeloest (fn_resolve_sender, NIE LLM) -> dessen person_id;
--     * KEIN/unaufgeloester chat_id -> agent.fn_owner_person_id() (Owner-Plan). Das ist der dokumentierte
--       P0c-Single-Person-Fallback: der career_advisor liest seinen Plan per LLM-Frei-SQL ('career', 1-Arg,
--       KEIN spoofbarer $fromAI-chat_id) -> er bekommt den Owner-Plan. Die echte Per-Person-Resume-Faedelung
--       (build-fixer chat_id) kommt mit P2.
--
--   Liefert die OPERATIV relevanten Zeilen (draft + active) — KEINE superseded-Historie. p_domain deckt auch
--   den E2E-Sentinel '__e2e_finance__' ab (household, kein scope-Eintrag -> person_id NULL, m4-verifiziert).
--
--   SECURITY DEFINER + gepinnter search_path + REVOKE ALL FROM PUBLIC + EXECUTE nur an die Paket-Rollen
--   (erteilt in core.fn_provision_package_roles) = das Phase-1-Muster (core.fn_core_api_version). READ-ONLY.
--   2-Arg-Signatur (P0c): core:V014 droppt die alte 1-Arg-Form; der 1-Arg-Call ('career') matcht den
--   chat_id-DEFAULT der 2-Arg-Form (Muster fn_fetch_context/core:V013).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_read_plan(p_domain text, p_chat_id text DEFAULT NULL)
RETURNS TABLE (
    domain          text,
    plan_name       text,
    status          text,
    version         int,
    interview_state jsonb,
    plan_md         text,
    updated_at      timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, agent, core, pg_temp
AS $$
-- LANGUAGE plpgsql (NICHT sql): die fn ruft agent.fn_resolve_sender/fn_owner_person_id; eine sql-fn wuerde den
-- Body BEIM CREATE pruefen, aber R__fn_advisor_read_plan wird alphabetisch VOR R__fn_resolve_sender/-owner_*
-- applied -> "function does not exist". plpgsql verschiebt die Body-Pruefung auf den ersten Aufruf (alle R da).
DECLARE
    v_ctx   text;
    v_scope text;
    v_pid   text;
BEGIN
    -- Domain -> Plan-Context (Registry/Fallback) -> scope.
    v_ctx   := COALESCE((SELECT a.plan_context FROM core.advisors a WHERE a.domain = p_domain), p_domain || '_planning');
    v_scope := COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = v_ctx), 'household');
    -- Ziel-person_id: household -> NULL; per_user -> aufgeloester Sender ODER Owner-Fallback (P0c Single-Person).
    IF v_scope = 'per_user' THEN
        IF p_chat_id ~ '^[0-9]+$' THEN
            v_pid := agent.fn_resolve_sender(p_chat_id::bigint) ->> 'person_id';
        END IF;
        v_pid := COALESCE(v_pid, agent.fn_owner_person_id());
    END IF;

    RETURN QUERY
    SELECT ap.domain, ap.plan_name, ap.status, ap.version, ap.interview_state, ap.plan_md, ap.updated_at
    FROM agent.advisor_plans ap
    WHERE ap.domain = p_domain
      AND ap.person_id IS NOT DISTINCT FROM v_pid
      AND ap.status IN ('draft', 'active')
    ORDER BY ap.status;   -- 'active' < 'draft' alphabetisch — deterministische Reihenfolge
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_read_plan(text, text) FROM public;
-- EXECUTE-GRANT an die Paket-Leserollen erteilt core.fn_provision_package_roles (idempotent,
-- to_regprocedure-geguardet auf die 2-Arg-Signatur) — hier nur der PUBLIC-REVOKE als Default-Schutz.
