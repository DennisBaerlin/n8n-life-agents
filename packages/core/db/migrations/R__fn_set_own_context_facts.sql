-- ============================================================
-- fn_set_own_context_facts (ATOMIC WRITE — Schreibweg der Freigabe-Stufe self)
--   Duenner Delegat auf agent.fn_set_context_facts, der scope='per_user' SELBST setzt (ein mitgeschickter
--   scope wird ueberschrieben, Muster "package fest in der fn"). Damit ist ueber diesen Weg NUR der eigene
--   per_user-Kontext der aus chat_id aufgeloesten Person schreibbar (physisch '<base>__<pid>', own_user_only):
--   household-/family-Kontexte scheitern am Scope-Check bzw. family-Gate, Plan-Dokumente an der Plan-Sperre,
--   fremde Personen am Suffix-/Resolve-Pfad. Das ist die DB-Seite der Stufe self (agent.tool_set_own_context_facts:
--   die eigene Person bestaetigt, kein Owner beteiligt/informiert) — approval_lint erzwingt, dass ein self-Workflow
--   ausschliesslich diese fn ruft.
--   Eingabe/Rueckgabe: identisch zu agent.fn_set_context_facts (context_name, facts, content, description, chat_id).
--   Tests: tests/db/core/test_fn_set_own_context_facts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_own_context_facts(p jsonb)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT agent.fn_set_context_facts(COALESCE(p, '{}'::jsonb) || jsonb_build_object('scope', 'per_user'));
$$;
