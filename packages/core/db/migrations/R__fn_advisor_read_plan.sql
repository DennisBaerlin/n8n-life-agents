-- ============================================================
-- fn_advisor_read_plan (READ, SECURITY DEFINER — Core-Lesefenster)
--   Das einzige Lesefenster der engen Paket-Leserolle finance_ro/career_ro auf die domaenen-neutrale
--   Plan-Persistenz agent.advisor_plans (bleibt in `agent`, Shared-Infra fuer die Advisor-Domaenen).
--   Der Advisor-Agent liest seinen Plan-Stand zur Laufzeit per freiem postgres_select (Interview fortsetzen /
--   publizierte Version pruefen); unter der engen Rolle erreicht er agent.* nicht direkt und ruft stattdessen
--   diese fn:
--       SELECT status, version, interview_state, plan_md FROM core.fn_advisor_read_plan('finance');
--
--   Eingabe: p_domain (Pflicht; deckt auch den E2E-Sentinel '__e2e_finance__' ab: household, kein scope-Eintrag
--   -> person_id NULL), p_chat_id (optional, nur fuer per_user relevant).
--   Person-Scope (Paritaet zum Schreibpfad fn_advisor_save_section/_publish_plan): der Plan-Schluessel
--   ist (domain, person_id). Die Domain -> ihr Plan-Context (core.advisors.plan_context, Fallback
--   '<domain>_planning') -> dessen scope (core.context_scopes). household -> person_id IS NULL (der eine
--   Haushalts-Plan; finance/financial_planning). per_user -> die Person:
--     * chat_id geliefert + aufgeloest (fn_resolve_sender, nie LLM) -> dessen person_id;
--     * kein/unaufgeloester chat_id -> leere Menge (fail-closed, kein Owner-Fallback).
--     * Aufruf aus einer Frei-SQL-Sitzung (core.fn_is_free_sql_session: Login-Rolle *_ro) -> leere Menge: dort waere
--       die chat_id LLM-gesteuert. Der career_advisor liest seinen Plan ueber das gebundene read_plan-Werkzeug unter
--       der Haupt-Credential ("strikt privat").
--
--   Rueckgabe: Tabelle (domain, plan_name, status, version, interview_state, plan_md, updated_at) mit den operativ
--   relevanten Zeilen (draft + active), keine superseded-Historie. interview_state kommt gerendert: ein Abschnitt
--   mit Themen traegt content = seine Themen als "<Thema>: <Text>" in Reihenfolge (gespeichert ist dort kein
--   content), dazu topics und legacy_content (Alt-Gesamttext, nur Quelle).
--
--   SECURITY DEFINER + gepinnter search_path + REVOKE ALL FROM PUBLIC + EXECUTE nur an die Paket-Rollen
--   (erteilt in core.fn_provision_package_roles) = das Muster von core.fn_core_api_version. Read-only.
--   2-Arg-Signatur: core:V014 droppt die alte 1-Arg-Form; der 1-Arg-Call ('career') matcht den
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
-- LANGUAGE plpgsql (nicht sql): die fn ruft agent.fn_resolve_sender; eine sql-fn wuerde den Body beim CREATE
-- pruefen, aber R__fn_advisor_read_plan wird alphabetisch vor R__fn_resolve_sender applied -> "function does not
-- exist". plpgsql verschiebt die Body-Pruefung auf den ersten Aufruf (alle R da).
DECLARE
    v_ctx   text;
    v_scope text;
    v_pid   text;
BEGIN
    -- Domain -> Plan-Context (Registry/Fallback) -> scope.
    v_ctx   := COALESCE((SELECT a.plan_context FROM core.advisors a WHERE a.domain = p_domain), p_domain || '_planning');
    v_scope := COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = v_ctx), 'household');
    -- Ziel-person_id: household -> NULL; per_user -> aufgeloester Sender, sonst nichts (fail-closed).
    IF v_scope = 'per_user' THEN
        IF core.fn_is_free_sql_session() THEN
            RETURN;
        END IF;
        IF p_chat_id ~ '^[0-9]+$' THEN
            v_pid := agent.fn_resolve_sender(p_chat_id::bigint) ->> 'person_id';
        END IF;
        IF v_pid IS NULL THEN
            RETURN;
        END IF;
    END IF;

    -- Themen-Abschnitte (fn_advisor_save_section mit topic) speichern keinen Abschnitts-content: content wird hier aus den
    -- Themen in Reihenfolge gerendert ("<Thema>: <Text>"); topics und legacy_content bleiben fuer den Berater drin.
    RETURN QUERY
    SELECT ap.domain, ap.plan_name, ap.status, ap.version,
           CASE WHEN jsonb_typeof(ap.interview_state) = 'object' THEN
               COALESCE((SELECT jsonb_object_agg(s.key, CASE
                           WHEN jsonb_typeof(s.value->'topics') = 'array' AND jsonb_array_length(s.value->'topics') > 0
                           THEN s.value || jsonb_build_object('content',
                                  (SELECT string_agg((t->>'topic') || ': ' || (t->>'content'), E'\n\n' ORDER BY i)
                                     FROM jsonb_array_elements(s.value->'topics') WITH ORDINALITY AS x(t, i)))
                           ELSE s.value END)
                         FROM jsonb_each(ap.interview_state) AS s), '{}'::jsonb)
           ELSE ap.interview_state END,
           ap.plan_md, ap.updated_at
    FROM agent.advisor_plans ap
    WHERE ap.domain = p_domain
      AND ap.person_id IS NOT DISTINCT FROM v_pid
      AND ap.status IN ('draft', 'active')
    ORDER BY ap.status;   -- 'active' < 'draft' alphabetisch: deterministische Reihenfolge
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_read_plan(text, text) FROM public;
-- EXECUTE-GRANT an die Paket-Leserollen erteilt core.fn_provision_package_roles (idempotent,
-- to_regprocedure-geguardet auf die 2-Arg-Signatur); die App-Rolle (read_plan-Werkzeug) hat EXECUTE per Sammel-Grant
-- (apply_schema.sh) — hier nur der PUBLIC-REVOKE als Default-Schutz.
