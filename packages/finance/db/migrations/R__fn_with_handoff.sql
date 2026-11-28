-- ============================================================
-- fn_with_handoff (ATOMIC WRITE) — fuehrt einen finance-Write fuer eine vereinbarte Plan-Aufgabe aus
--   Jede Schreib-fn, die eine Vormerkung erfuellen kann, ruft sie als erste Anweisung, wenn p.handoff_task_id gesetzt ist:
--   RETURN finance.fn_with_handoff('<eigene Signatur>'::regprocedure, p). Welche das sind, steht im Manifest
--   (advisors.finance.handoff_tools); contract_lint prueft Werkzeug-Eingang und diesen Aufruf.
--   Eingabe: p_fn regprocedure (die aufrufende fn), p jsonb (deren Payload inkl. handoff_task_id, chat_id).
--   Fuer (2) liest sie je Art die Kennung aus p: recurring_payment_id | goal_id | pension_id | savings_plan_name (Name,
--   fn_resolve_savings_plan); fehlt sie, kein Vorher-Stand und keine Aenderungs-Zeilen, und ein weiterer Teil einer
--   fn_set_* wird abgelehnt (handoff_task_invalid).
--   Ablauf in derselben Transaktion: (1) core.fn_handoff_task_check (Aufgabe working oder in dieser Runde freigegeben, oder
--   in dieser Runde schon erledigt = weiterer Teil derselben Vormerkung: mit Soll nur ein vereinbarter Aufruf dieses
--   Werkzeugs, zu dem noch keine Sache eingetragen ist, ohne Soll nur eine fn_create_*; dieselbe Sache nie zweimal; Person
--   des Absenders aus p.chat_id), sonst {ok:false, code:'handoff_task_invalid', reason} ohne Write; (2) Stand der geaenderten
--   Sache vor dem Write (nur fn_set_*, finance.fn_handoff_ref_state); (3) die Ziel-fn mit p ohne handoff_task_id, waehrend der transaktionslokale Wert
--   finance.handoff_task_id gesetzt ist (finance.fn_bank_note_recorded haengt damit den Bank-Punkt an die Vormerkung und
--   gibt die Kurz-Zeile statt des Bank-Absatzes); (4) nur bei ok:true core.fn_complete_handoff_task -> done mit
--   entered_refs [{type, id, call?}] = die angelegte bzw. geaenderte Sache (ein weiterer Teil haengt seine an); call = Stelle
--   des vereinbarten Aufrufs im Soll, den sie erfuellt (0-basiert, nur mit Soll; Zuordnung finance.fn_handoff_pairs).
--   Scheitert der Abschluss in (4) (parallel geaenderte Aufgabe) -> RAISE, Rollback samt Ziel-Write.
--   Rueckgabe: Ergebnis der Ziel-fn + handoff_task_id + handoff_diff (finance.fn_handoff_diff_of gegen wanted nach dem
--   Write, [] = wie vereinbart, fehlt ohne wanted); bei mehrteiligem Soll zaehlt ein noch nicht eingetragener Teil nicht als
--   exists-Abweichung + Kartenzeilen am Ende von card_lines in dieser Reihenfolge:
--   core.hitl.handoff_pos {k, n} (Stelle in der Runde, core.fn_handoff_position; fehlt ohne Claim), core.hitl.handoff_note
--   {text}, core.hitl.handoff_why {why} (nur mit why), je geaendertem Feld core.hitl.value_before_after {field, before,
--   after} (field = Katalog-Key finance.handoff.field.<feld>, Werte typisiert; der Probelauf zeigt so "bisher -> neu"),
--   core.hitl.handoff_rest {text} (nur mit offenem Rest). ok:false der Ziel-fn -> unveraendert zurueck, der Zustand der
--   Aufgabe aendert sich nicht. Status-Wechsel stehen nicht in den Aenderungs-Zeilen (die Karte des Werkzeugs zeigt sie).
--   p_fn ist eine Build-/Code-Konstante der aufrufenden fn, nie Nutzer-Input (dynamischer EXECUTE nur darauf).
--   SECURITY INVOKER (laeuft unter finance_rw wie die Ziel-fn; agent.* liest sie nur ueber core.fn_handoff_tasks_read und
--   core.fn_handoff_position). Tests: tests/db/finance/test_fn_with_handoff.sql, tests/db/finance/test_fn_reopen_handoff_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_with_handoff(p_fn regprocedure, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
-- kein gepinnter search_path: er galt sonst auch in der Ziel-fn, die unqualifizierte Namen ueber den Rollen-Pfad aufloest
AS $$
DECLARE
    v_chk    jsonb;
    v_r      jsonb;
    v_done   jsonb;
    v_name   text := (SELECT pr.proname FROM pg_catalog.pg_proc pr WHERE pr.oid = p_fn);
    v_tool   text;
    v_type   text;
    v_id     int;
    v_before jsonb;
    v_after  jsonb;
    v_task   jsonb;
    v_pos    jsonb;
    v_lines  jsonb := '[]'::jsonb;
    v_fld    text;
    v_cur    text;
    v_diff   jsonb;
    v_has_wanted boolean;
    v_open   jsonb := '[]'::jsonb;
    v_call_i int;
BEGIN
    v_chk := core.fn_handoff_task_check(p);
    IF (v_chk->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_chk;
    END IF;
    v_tool := regexp_replace(v_name, '^fn_', '');
    v_type := finance.fn_handoff_tool_spec()->v_tool->>'type';
    -- geaenderte Sache vor dem Write: Eingabe-Kennung der set-fn (Sparplan als Name savings_plan_name = plan_name beim Anlegen)
    v_id := CASE v_type
        WHEN 'recurring_payment' THEN NULLIF(p->>'recurring_payment_id', '')::int
        WHEN 'savings_goal'      THEN NULLIF(p->>'goal_id', '')::int
        WHEN 'pension'           THEN NULLIF(p->>'pension_id', '')::int
        WHEN 'savings_plan'      THEN (SELECT r.id FROM finance.fn_resolve_savings_plan(p->>'savings_plan_name', TRUE) r)
    END;
    v_task := core.fn_handoff_tasks_read(ARRAY[(v_chk->>'task_id')::int])->0;
    v_has_wanted := jsonb_typeof(v_task->'wanted') IN ('object', 'array');
    -- vereinbarte Aufrufe dieses Werkzeugs, zu denen noch keine Sache eingetragen ist
    IF v_has_wanted THEN
        SELECT COALESCE(jsonb_agg(x ORDER BY (x->>'i')::int), '[]'::jsonb) INTO v_open
          FROM jsonb_array_elements(finance.fn_handoff_pairs(v_task->'wanted', v_task->'entered_refs')) x
         WHERE x->'ref' = 'null'::jsonb AND x->'call'->>'tool' = v_tool;
    END IF;
    -- Ein weiterer Teil einer erledigten Aufgabe: mit Soll nur ein noch offener vereinbarter Aufruf (eine Buchung unter der
    -- falschen Kennung haengt sich sonst an eine fertige Aufgabe), ohne Soll nur etwas Neues (create). Dieselbe Sache noch
    -- einmal zu aendern waere eine Wiederholung; eine Raten-Kette ist eine Sache, gleich welches Glied genannt wird.
    IF (v_chk->>'part')::boolean
       AND (CASE WHEN v_has_wanted THEN jsonb_array_length(v_open) = 0 ELSE v_name NOT LIKE 'fn\_create\_%' END
            OR (v_name NOT LIKE 'fn\_create\_%' AND (v_id IS NULL OR EXISTS (
                SELECT 1
                  FROM jsonb_array_elements(COALESCE(NULLIF(v_task->'entered_refs', 'null'::jsonb), '[]'::jsonb)) e
                 WHERE e->>'type' = v_type
                   AND CASE WHEN v_type = 'recurring_payment'
                            THEN finance.fn_handoff_rp_latest((e->>'id')::int) = finance.fn_handoff_rp_latest(v_id)
                            ELSE (e->>'id')::int = v_id END)))) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || (v_chk->>'task_id') || ' is already done and has no agreed call left for this tool. Do not book under it again.');
    END IF;
    IF v_name LIKE 'fn\_set\_%' AND v_id IS NOT NULL THEN
        v_before := finance.fn_handoff_ref_state(v_type, v_id);
    END IF;

    -- Ein RAISE der Ziel-fn bricht die Transaktion bzw. den Savepoint ab; damit faellt auch der lokale Wert zurueck.
    PERFORM set_config('finance.handoff_task_id', v_chk->>'task_id', true);
    EXECUTE format('SELECT %s($1)', p_fn::regproc) INTO v_r USING (p - 'handoff_task_id');
    -- nur fuer diesen einen Write: ein spaeterer Aufruf derselben Transaktion gehoert nicht zur Vormerkung
    PERFORM set_config('finance.handoff_task_id', '', true);
    IF (v_r->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_r;
    END IF;

    v_id := COALESCE(NULLIF(v_r->>CASE v_type WHEN 'savings_goal' THEN 'goal_id' ELSE v_type || '_id' END, '')::int, v_id);
    -- Welchen vereinbarten Aufruf erfuellt die Sache? Unter den offenen dieses Werkzeugs der mit dem kleinsten Unterschied
    -- zum neuen Stand, bei Gleichstand der mit ihrem Namen, dann der erste. Die Stelle (call) geht mit in entered_refs, damit
    -- finance.fn_handoff_pairs nicht nach der Reihenfolge der Karten zuordnet (ein nicht bestaetigter frueher Teil
    -- verschoebe sonst alle folgenden).
    IF v_has_wanted AND v_type IS NOT NULL AND v_id IS NOT NULL THEN
        SELECT (x->>'i')::int INTO v_call_i
          FROM jsonb_array_elements(v_open) x
         ORDER BY jsonb_array_length(finance.fn_handoff_diff_of(x->'call', jsonb_build_array(jsonb_build_object('type', v_type, 'id', v_id)))),
                  (lower(COALESCE(x->'call'->'input'->>COALESCE(finance.fn_handoff_tool_spec()->v_tool->>'target',
                            CASE WHEN x->'call'->'input' ? 'name' THEN 'name' WHEN x->'call'->'input' ? 'goal_name' THEN 'goal_name'
                                 ELSE 'plan_name' END), ''))
                     IS DISTINCT FROM lower(finance.fn_handoff_ref_state(v_type, v_id)->>'name')),
                  (x->>'i')::int
         LIMIT 1;
    END IF;
    v_done := core.fn_complete_handoff_task(p || jsonb_build_object('entered_refs',
                  CASE WHEN v_type IS NOT NULL AND v_id IS NOT NULL
                       THEN jsonb_build_array(jsonb_build_object('type', v_type, 'id', v_id)
                                || CASE WHEN v_call_i IS NOT NULL THEN jsonb_build_object('call', v_call_i) ELSE '{}'::jsonb END)
                       ELSE '[]'::jsonb END));
    IF (v_done->>'ok')::boolean IS NOT TRUE THEN
        -- zwischen Pruefung und Abschluss geaendert (paralleler Lauf): den Write nicht ohne "erledigt" stehen lassen
        RAISE EXCEPTION 'finance.fn_with_handoff: handoff task % could not be completed: %', p->>'handoff_task_id', v_done->>'reason';
    END IF;

    -- nach dem Abschluss neu gelesen (entered_refs, Rest)
    v_task := core.fn_handoff_tasks_read(ARRAY[(v_chk->>'task_id')::int])->0;
    v_pos  := core.fn_handoff_position((v_chk->>'task_id')::int);
    IF v_pos IS NOT NULL THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_pos', 'params', v_pos));
    END IF;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_note',
                                                               'params', jsonb_build_object('text', v_chk->>'text')));
    IF NULLIF(v_task->>'why', '') IS NOT NULL THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_why',
                                                                   'params', jsonb_build_object('why', v_task->>'why')));
    END IF;
    -- bisher -> neu: Stand nach dem Write in derselben Transaktion (im Probelauf vor dem Rollback)
    IF v_before IS NOT NULL THEN
        v_after := finance.fn_handoff_ref_state(v_type, v_id);
        v_cur   := COALESCE(v_after->>'currency', v_before->>'currency');
        FOR v_fld IN SELECT DISTINCT value #>> '{}' FROM jsonb_each(finance.fn_handoff_tool_spec()->v_tool->'state') LOOP
            CONTINUE WHEN v_fld = 'status' OR (v_before->v_fld) IS NOT DISTINCT FROM (v_after->v_fld);
            v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.value_before_after',
                'params', jsonb_build_object('field', jsonb_build_object('kind', 'key', 'value', finance.fn_handoff_field_key(v_fld)),
                                             'before', finance.fn_handoff_ui_value(v_fld, v_before->v_fld, v_cur),
                                             'after', finance.fn_handoff_ui_value(v_fld, v_after->v_fld, v_cur))));
        END LOOP;
    END IF;
    IF NULLIF(v_task->>'rest', '') IS NOT NULL THEN
        v_lines := v_lines || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_rest',
                                                                   'params', jsonb_build_object('text', v_task->>'rest')));
    END IF;
    v_diff := CASE WHEN v_task->'wanted' IS NOT NULL AND v_task->'wanted' <> 'null'::jsonb
                   THEN finance.fn_handoff_diff_of(v_task->'wanted', v_task->'entered_refs') END;
    -- mehrteiliges Soll: solange weniger Sachen eingetragen sind als Aufrufe vereinbart, ist der fehlende Teil nur noch
    -- nicht dran und keine Abweichung (das Register sieht den Rest weiter ueber finance.fn_handoff_diff)
    IF jsonb_typeof(v_task->'wanted') = 'array'
       AND jsonb_array_length(COALESCE(v_task->'entered_refs', '[]'::jsonb)) < jsonb_array_length(v_task->'wanted') THEN
        v_diff := COALESCE((SELECT jsonb_agg(d) FROM jsonb_array_elements(v_diff) d WHERE d->>'field' <> 'exists'), '[]'::jsonb);
    END IF;

    RETURN v_r || jsonb_build_object(
        'handoff_task_id', (v_chk->>'task_id')::int,
        'card_lines', COALESCE(v_r->'card_lines', '[]'::jsonb) || v_lines)
        || CASE WHEN v_diff IS NOT NULL THEN jsonb_build_object('handoff_diff', v_diff) ELSE '{}'::jsonb END;
END;
$$;

-- fn_handoff_field_key: Katalog-Key der Feld-Bezeichnung auf der Eintrags-Karte; ganze Literale, damit locale_lint jeden
-- Key gegen den Katalog prueft. Unbekanntes Feld -> NULL (der Renderer zeigt den Leer-Strich).
CREATE OR REPLACE FUNCTION finance.fn_handoff_field_key(p_field text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE p_field
        WHEN 'amount'                     THEN 'finance.handoff.field.amount'
        WHEN 'day'                        THEN 'finance.handoff.field.day'
        WHEN 'valid_to'                   THEN 'finance.handoff.field.valid_to'
        WHEN 'target_amount'              THEN 'finance.handoff.field.target_amount'
        WHEN 'target_date'                THEN 'finance.handoff.field.target_date'
        WHEN 'provider'                   THEN 'finance.handoff.field.provider'
        WHEN 'guaranteed_monthly_pension' THEN 'finance.handoff.field.guaranteed_monthly_pension'
        WHEN 'contribution_amount'        THEN 'finance.handoff.field.contribution_amount'
    END;
$$;

-- fn_handoff_ui_value: Rohwert eines Stand-Felds (finance.fn_handoff_ref_state) als typisierter Kartenwert; NULL -> NULL
-- (der Renderer zeigt dann den Leer-Strich).
CREATE OR REPLACE FUNCTION finance.fn_handoff_ui_value(p_field text, p_value jsonb, p_currency text)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN p_value IS NULL OR p_value = 'null'::jsonb THEN NULL
        WHEN p_field IN ('amount', 'target_amount', 'guaranteed_monthly_pension', 'contribution_amount')
            THEN core.fn_ui_money((p_value #>> '{}')::numeric, COALESCE(p_currency, 'EUR'))
        WHEN p_field IN ('valid_to', 'target_date') THEN core.fn_ui_date((p_value #>> '{}')::date)
        WHEN p_field = 'day' THEN CASE (p_value #>> '{}')::int
            WHEN -1 THEN jsonb_build_object('kind', 'key', 'value', 'finance.value.last_day_of_month')
            WHEN -2 THEN jsonb_build_object('kind', 'key', 'value', 'finance.value.second_to_last_day_of_month')
            ELSE core.fn_ui_tpl('finance.tpl.day_of_month', jsonb_build_object('day', (p_value #>> '{}')::int)) END
        ELSE p_value
    END;
$$;
