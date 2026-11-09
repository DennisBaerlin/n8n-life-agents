-- ============================================================
-- fn_plan_rollout (WRITE, Latch) -- Schritt "Bank-Zettel" der gefuehrten Abfolge nach dem Plan
--   rollout_fn von core.fn_plan_rollout_next: Reihenfolge und "keine Aufgabe mehr offen" prueft der Aufrufer.
--   messages = fn_bank_todo_claim(heute, 'handoff'). wait=true, solange ein Punkt aus der Uebergabe sichtbar ist und seine
--   erste Sendung juenger als 7 Tage ist. Eingaben: p_domain, p_person (Haushalt, ungenutzt). Rueckgabe: {wait, messages}.
--   Tests: tests/db/finance/test_fn_plan_rollout.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_rollout(p_domain text, p_person text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_msgs jsonb := finance.fn_bank_todo_claim(core.fn_today(), 'handoff');
BEGIN
    RETURN jsonb_build_object('messages', v_msgs, 'wait', EXISTS (
        SELECT 1 FROM finance.bank_todos t
         WHERE t.status = 'open' AND finance.fn_bank_todo_visible(t.id)
           AND t.first_sent_at > now() - interval '7 days'
           AND (t.source = 'backfill' OR t.created_at IN (SELECT core.fn_handoff_done_stamps('finance')))));
END $$;
