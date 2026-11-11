-- ============================================================
-- finance.fn_next_step_example(p_person_id text) — Beispielsatz des finance-Pakets fuer den naechsten Schritt (READ)
--   Einziger Aufrufer: core.fn_get_next_step_example (DEFINER, Doppel-Guard fn_package_active + to_regprocedure). Core
--   prueft zur Laufzeit ueber pg_proc: SECURITY DEFINER, search_path = pg_catalog, pg_temp, Eigentuemer = Eigentuemer
--   von Schema core (Standard-Apply), und verwirft einen Key, den core.ui_texts nicht kennt.
--   RUECKGABE text: 'finance.next_step.example' genau dann, wenn ein aktives Geld-Konto existiert (dieselbe Regel wie die
--   Plan-Reife: finance.fn_plan_readiness meldet accounts nicht als fehlend) UND core.fn_app_sees_household(p_person_id);
--   sonst NULL (Core nimmt den neutralen Key). Der Onboarding-Abschnittsstatus zaehlt nicht (Import zuerst: Konten da,
--   Abschnitt uebersprungen). Ob finance aktiv ist, prueft Core vorher. Wirft nie.
--   Tests: tests/db/finance/test_fn_next_step_example.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_next_step_example(p_person_id text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT COALESCE(core.fn_app_sees_household(p_person_id), false) THEN
        RETURN NULL;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_plan_readiness('finance', NULL)->'missing') m
                WHERE m->>'key' = 'accounts') THEN
        RETURN NULL;
    END IF;
    RETURN 'finance.next_step.example';
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION finance.fn_next_step_example(text) FROM public;
