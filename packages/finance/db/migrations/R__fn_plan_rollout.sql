-- ============================================================
-- fn_plan_rollout (WRITE, Latch) -- Schritt "Bank-Zettel" der gefuehrten Abfolge nach dem Plan
--   rollout_fn von core.fn_plan_rollout_next: Reihenfolge (nach dem Durchgehen, vor dem Warten auf liegen gebliebene
--   Eintraege) prueft der Aufrufer. Quelle fn_bank_todo_claim(heute, 'handoff'): nur Punkte aus abgeschlossenem Eintragen,
--   nur der Owner. Je Gruppe (Bank, Inhaber) eine Nachricht in der Form der Abfolge: lines = Einleitung
--   (finance.bank_todo.intro[_generic] {bank, holder}), Leerzeile, je Punkt "<n>." + dessen Zeile (fn_bank_todo_item),
--   Leerzeile, finance.bank_todo.howto; Knopf finance.bank_todo.btn_done[_generic] {bank} mit btodo:<erste>:<max>
--   (derselbe Handler wie der Cron); latches = die Merker des Claims dieser Gruppe (der Sender schreibt fest oder gibt frei).
--   wait=true, solange ein Punkt aus der Uebergabe sichtbar ist und seine erste Sendung juenger als 7 Tage ist.
--   Eingaben: p_domain, p_person (Haushalt, ungenutzt). Rueckgabe: {wait, messages}.
--   Tests: tests/db/finance/test_fn_plan_rollout.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_rollout(p_domain text, p_person text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_claim jsonb := finance.fn_bank_todo_claim(core.fn_today(), 'handoff');
    v_msgs  jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'lines', jsonb_build_array(jsonb_build_array(core.fn_ui_tpl(
                            CASE WHEN g->>'bank' IS NULL THEN 'finance.bank_todo.intro_generic' ELSE 'finance.bank_todo.intro' END,
                            jsonb_build_object('bank', COALESCE(g->>'bank', ''),
                                               'holder', COALESCE(' (' || (g->>'holder_name') || ')', '')))),
                            'null'::jsonb)
                        || (SELECT jsonb_agg(jsonb_build_array(n || '.') || (i->'line') ORDER BY n)
                              FROM jsonb_array_elements(g->'items') WITH ORDINALITY AS e(i, n))
                        || jsonb_build_array('null'::jsonb, jsonb_build_array(core.fn_ui_tpl('finance.bank_todo.howto'))),
               'buttons', jsonb_build_array(jsonb_build_object(
                            'text_key', CASE WHEN g->>'bank' IS NULL THEN 'finance.bank_todo.btn_done_generic' ELSE 'finance.bank_todo.btn_done' END,
                            'params', jsonb_build_object('bank', COALESCE(g->>'bank', '')),
                            'data', 'btodo:' || (g->>'first_id') || ':' || (g->>'max_id'))),
               'latches', (SELECT jsonb_agg(jsonb_build_object('source', 'finance:bank_todo', 'key', (i->>'id') || ':r0:owner'))
                             FROM jsonb_array_elements(g->'items') i))
           ORDER BY gn), '[]'::jsonb)
      INTO v_msgs
      FROM jsonb_array_elements(v_claim) r
     CROSS JOIN LATERAL jsonb_array_elements(r->'groups') WITH ORDINALITY AS x(g, gn)
     WHERE r->>'recipient' = 'owner';
    RETURN jsonb_build_object('messages', v_msgs, 'wait', EXISTS (
        SELECT 1 FROM finance.bank_todos t
         WHERE t.status = 'open' AND finance.fn_bank_todo_visible(t.id)
           AND t.first_sent_at > now() - interval '7 days'
           AND finance.fn_bank_todo_in_handoff(t.id)));
END $$;
