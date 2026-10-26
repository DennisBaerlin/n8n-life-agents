-- ============================================================
-- fn_pension_statements_due (READ, STABLE) -- welche Renteninformation faellig ist (Erinnerung, Plan 2026-10-26)
--   Aktive gesetzliche/betriebliche Renten, deren juengste Renteninformation aelter als 13 Monate ist (stale) -- dieselbe
--   Regel wie finance.fn_pension_outlook (eine Adresse). Ohne Information (never) nur die GESETZLICHE Rente: die DRV
--   schickt sie jaehrlich, viele Arbeitgeber eine bAV-Standmitteilung dagegen nicht (Review 2026-10-26: sonst kaeme
--   jeden Monat eine nicht abschaltbare bAV-Zeile). Konsument: der deterministische Cron
--   agent.finance.cron_remind_pension_statement (finance_ro, kein LLM).
--   RUECKGABE jsonb-Array (leer = '[]'): [{name, owner, owner_person_id, last_statement_date | null, never}].
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_pension_statements_due()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'name', e->>'name', 'owner', e->>'owner', 'owner_person_id', e->>'owner_person_id',
               'last_statement_date', e->'statement_date', 'never', (e->>'never')::boolean)), '[]'::jsonb)
    FROM jsonb_array_elements(finance.fn_pension_outlook('{}'::jsonb)->'pensions') e
    WHERE (e->>'pension_type' = 'statutory' AND (e->>'never')::boolean)
       OR (e->>'pension_type' IN ('statutory', 'occupational') AND COALESCE((e->>'stale')::boolean, false));
$$;
