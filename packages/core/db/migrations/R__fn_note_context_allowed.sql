-- ============================================================
-- core.fn_note_context_allowed(p_name text) -> boolean   (Phase C, WS-2; geteilt mit WS-3; Phase A registry-getrieben)
--   Harte Knowledge-Context-Allowlist fuer den Prosa-Lern-Pfad ("## Gelernt"): TRUE nur, wenn der
--   Ziel-Kontext EXISTIERT, managed_by='agent' ist UND ein Prosa-Wissens-Kontext ist: der Host-Kontext 'family'
--   ODER das Plan-Dokument (core.advisors.plan_context) einer Advisor-Domaene, die das per learn_notes=true
--   ausdruecklich erlaubt (Manifest-advisors-Block) und deren Paket AKTIV ist. Ersetzt die Literal-Liste
--   family/financial_planning (Core kannte einen Paket-Kontextnamen). Verhindert, dass der Lern-Loop Prosa in
--   Instruktions-/Seed-Kontexte (managed_by='seed', Verhaltens-Korruption) ODER in reine Fakten-Kontexte
--   (facts-strukturiert, kein Prosa-Body) schreibt. Exakter Namensvergleich -> per_user-Plan-Dokumente
--   ('<base>__<pid>') sind nie erlaubt (contract_lint: learn_notes nur fuer household-Plan-Kontexte).
--   EINE Quelle fuer beide Aufrufer (agent.fn_record_learn_candidates Vorfilter + core.fn_append_context_note
--   Backstop) -> kein Drift. Roh-INVOKER (kein Secret) — der Aufrufer braucht ohnehin SELECT auf agent.core_contexts.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_note_context_allowed(p_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, agent, core
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM agent.core_contexts c
        WHERE c.name = p_name
          AND c.managed_by = 'agent'
          AND (c.name = 'family'
               OR EXISTS (SELECT 1
                          FROM core.advisors a
                          JOIN core.package_registry r ON r.package = a.package AND r.status = 'active'
                          WHERE a.plan_context = c.name AND a.learn_notes))
    );
$$;
