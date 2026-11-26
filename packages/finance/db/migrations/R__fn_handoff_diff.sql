-- ============================================================
-- fn_handoff_diff (READ, STABLE) -- Unterschied zwischen dem vereinbarten Soll einer Plan-Aufgabe und dem heutigen Stand
--   Registry-Feld core.advisors.handoff_diff_fn (Signatur (int) -> jsonb), gelesen von core.fn_handoff_register: eine erledigte
--   Aufgabe mit nicht leerem Unterschied ist "anders eingetragen". Der Unterschied wird nie gespeichert, sondern bei jedem
--   Lesen neu gerechnet: korrigiert der Nutzer die Sache selbst, verschwindet die Zeile von allein.
--   fn_handoff_diff(p_task_id int): liest wanted und entered_refs ueber core.fn_handoff_tasks_read (agent.* ist der
--   Paketrolle verschlossen) und rechnet nur fuer status done; sonst [].
--   fn_handoff_diff_of(p_wanted jsonb, p_entered_refs jsonb): die Rechnung selbst. wanted = {tool, input} oder Array davon
--   (finance.fn_handoff_precheck); je Aufruf die k-te Sache derselben Art aus entered_refs (Reihenfolge der Aufrufe).
--   Verglichen werden nur Felder, die der Aufruf nennt und finance.fn_handoff_tool_spec unter state fuehrt; Betraege und
--   Tage als Zahl, Daten ueber core.fn_resolve_date (nicht aufloesbar -> kein Vergleich), Namen und Status ohne Gross-/
--   Kleinschreibung. Ohne wanted (Altbestand) -> [].
--   Rueckgabe: [{field, wanted, current, ref:{type, id}}], [] = wie vereinbart. Sache fehlt oder ist geloescht ->
--   {field:'exists', wanted:true, current:false}. Tests: tests/db/finance/test_fn_handoff_diff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_handoff_diff_of(p_wanted jsonb, p_entered_refs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_spec  jsonb := finance.fn_handoff_tool_spec();
    v_calls jsonb;
    v_call  jsonb;
    v_s     jsonb;
    v_type  text;
    v_seen  jsonb := '{}'::jsonb;   -- je Art: wie viele Aufrufe dieser Art schon zugeordnet sind
    v_k     int;
    v_ref   jsonb;
    v_state jsonb;
    v_in    text;
    v_fld   text;
    v_want  jsonb;
    v_cur   jsonb;
    v_d     date;
    v_out   jsonb := '[]'::jsonb;
BEGIN
    IF p_wanted IS NULL OR jsonb_typeof(p_wanted) NOT IN ('object', 'array') THEN
        RETURN '[]'::jsonb;
    END IF;
    v_calls := CASE WHEN jsonb_typeof(p_wanted) = 'array' THEN p_wanted ELSE jsonb_build_array(p_wanted) END;
    FOR v_call IN SELECT x FROM jsonb_array_elements(v_calls) x LOOP
        v_s := v_spec->(v_call->>'tool');
        CONTINUE WHEN v_s IS NULL;
        v_type := v_s->>'type';
        v_k := COALESCE((v_seen->>v_type)::int, 0);
        v_seen := v_seen || jsonb_build_object(v_type, v_k + 1);
        SELECT e INTO v_ref
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_entered_refs) = 'array' THEN p_entered_refs ELSE '[]'::jsonb END)
               WITH ORDINALITY AS t(e, n)
         WHERE e->>'type' = v_type
         ORDER BY n OFFSET v_k LIMIT 1;
        v_state := CASE WHEN v_ref IS NULL THEN NULL
                        ELSE finance.fn_handoff_ref_state(v_type, (v_ref->>'id')::int) END;
        IF v_state IS NULL THEN
            v_out := v_out || jsonb_build_array(jsonb_build_object('field', 'exists', 'wanted', true, 'current', false));
            CONTINUE;
        END IF;
        FOR v_in, v_fld IN SELECT key, value #>> '{}' FROM jsonb_each(v_s->'state') LOOP
            CONTINUE WHEN NULLIF(btrim(COALESCE(v_call->'input'->>v_in, '')), '') IS NULL;
            v_cur := v_state->v_fld;
            IF v_fld IN ('amount', 'target_amount', 'guaranteed_monthly_pension', 'contribution_amount', 'day') THEN
                CONTINUE WHEN (v_call->'input'->>v_in) !~ '^-?[0-9]+(\.[0-9]+)?$';
                v_want := to_jsonb((v_call->'input'->>v_in)::numeric);
                CONTINUE WHEN v_cur IS NOT NULL AND jsonb_typeof(v_cur) = 'number' AND (v_cur #>> '{}')::numeric = (v_want #>> '{}')::numeric;
            ELSIF v_fld IN ('valid_to', 'target_date') THEN
                v_d := core.fn_resolve_date(v_call->'input'->>v_in);
                CONTINUE WHEN v_d IS NULL;
                v_want := to_jsonb(v_d);
                CONTINUE WHEN (v_cur #>> '{}')::date IS NOT DISTINCT FROM v_d;
            ELSE
                v_want := to_jsonb(btrim(v_call->'input'->>v_in));
                CONTINUE WHEN lower(btrim(COALESCE(v_cur #>> '{}', ''))) = lower(v_want #>> '{}');
            END IF;
            v_out := v_out || jsonb_build_array(jsonb_build_object('field', v_fld, 'wanted', v_want,
                                                                   'current', COALESCE(v_cur, 'null'::jsonb), 'ref', v_ref));
        END LOOP;
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION finance.fn_handoff_diff(p_task_id int)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_t jsonb := core.fn_handoff_tasks_read(ARRAY[p_task_id])->0;
BEGIN
    IF v_t IS NULL OR v_t->>'status' IS DISTINCT FROM 'done' THEN
        RETURN '[]'::jsonb;
    END IF;
    RETURN finance.fn_handoff_diff_of(v_t->'wanted', v_t->'entered_refs');
END;
$$;
