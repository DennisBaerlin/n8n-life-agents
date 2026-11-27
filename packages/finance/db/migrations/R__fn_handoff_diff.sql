-- ============================================================
-- fn_handoff_diff (READ, STABLE) -- Unterschied zwischen dem vereinbarten Soll einer Plan-Aufgabe und dem heutigen Stand
--   Registry-Feld core.advisors.handoff_diff_fn (Signatur (int) -> jsonb), gelesen von core.fn_handoff_register: eine erledigte
--   Aufgabe mit nicht leerem Unterschied ist "anders eingetragen". Der Unterschied wird nie gespeichert, sondern bei jedem
--   Lesen neu gerechnet: korrigiert der Nutzer die Sache selbst, verschwindet die Zeile von allein.
--   fn_handoff_diff(p_task_id int): liest wanted und entered_refs ueber core.fn_handoff_tasks_read (agent.* ist der
--   Paketrolle verschlossen) und rechnet nur fuer status done; sonst [].
--   fn_handoff_diff_of(p_wanted jsonb, p_entered_refs jsonb): die Rechnung selbst. wanted = {tool, input} oder Array davon
--   (finance.fn_handoff_precheck); je Aufruf seine Sache aus entered_refs (finance.fn_handoff_pairs).
--   Verglichen werden nur Felder, die der Aufruf nennt und finance.fn_handoff_tool_spec unter state fuehrt; Betraege und
--   Tage als Zahl, Daten ueber core.fn_resolve_date (nicht aufloesbar -> kein Vergleich), Namen und Status ohne Gross-/
--   Kleinschreibung. Ohne wanted (Altbestand) -> [].
--   Rueckgabe: [{field, wanted, current, ref:{type, id}}], [] = wie vereinbart. Ein vereinbarter Aufruf, zu dem noch keine
--   Sache eingetragen ist -> {field:'exists', wanted:true, current:false, call:{tool, input}} (der Aufruf ist nachholbar);
--   eingetragen und wieder geloescht -> {field:'exists', wanted:true, current:false, ref} ohne call. Tests: tests/db/finance/test_fn_handoff_diff.sql
-- ============================================================
-- fn_handoff_pairs: ordnet jedem vereinbarten Aufruf seine eingetragene Sache zu -> [{i, call, ref | null}] (i = Stelle im
-- Soll, 0-basiert). Eine Sache mit call (von finance.fn_with_handoff beim Eintragen vermerkt) gehoert zu genau diesem
-- Aufruf; Sachen ohne call (abgehakt, oder ohne Soll eingetragen) der Reihe nach zum naechsten freien Aufruf ihrer Art.
-- ref null = zu diesem Aufruf ist noch nichts eingetragen.
CREATE OR REPLACE FUNCTION finance.fn_handoff_pairs(p_wanted jsonb, p_entered_refs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_spec  jsonb := finance.fn_handoff_tool_spec();
    v_calls jsonb := CASE jsonb_typeof(p_wanted) WHEN 'array' THEN p_wanted WHEN 'object' THEN jsonb_build_array(p_wanted)
                                                 ELSE '[]'::jsonb END;
    v_refs  jsonb := CASE WHEN jsonb_typeof(p_entered_refs) = 'array' THEN p_entered_refs ELSE '[]'::jsonb END;
    v_used  int[] := '{}';
    v_i     int;
    v_type  text;
    v_ref   jsonb;
    v_n     int;
    v_out   jsonb := '[]'::jsonb;
BEGIN
    FOR v_i IN 0 .. jsonb_array_length(v_calls) - 1 LOOP
        v_type := v_spec->(v_calls->v_i->>'tool')->>'type';
        v_ref := NULL;
        v_n := NULL;
        SELECT e, n INTO v_ref, v_n FROM jsonb_array_elements(v_refs) WITH ORDINALITY AS t(e, n)
         WHERE e->>'call' = v_i::text ORDER BY n LIMIT 1;
        IF v_ref IS NULL AND v_type IS NOT NULL THEN
            SELECT e, n INTO v_ref, v_n FROM jsonb_array_elements(v_refs) WITH ORDINALITY AS t(e, n)
             WHERE NOT e ? 'call' AND e->>'type' = v_type AND NOT (n = ANY (v_used)) ORDER BY n LIMIT 1;
        END IF;
        IF v_n IS NOT NULL THEN
            v_used := v_used || v_n;
        END IF;
        v_out := v_out || jsonb_build_array(jsonb_build_object('i', v_i, 'call', v_calls->v_i, 'ref', v_ref));
    END LOOP;
    RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION finance.fn_handoff_diff_of(p_wanted jsonb, p_entered_refs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_spec  jsonb := finance.fn_handoff_tool_spec();
    v_pair  jsonb;
    v_call  jsonb;
    v_s     jsonb;
    v_type  text;
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
    FOR v_pair IN SELECT x FROM jsonb_array_elements(finance.fn_handoff_pairs(p_wanted, p_entered_refs)) x LOOP
        v_call := v_pair->'call';
        v_s := v_spec->(v_call->>'tool');
        CONTINUE WHEN v_s IS NULL;
        v_type := v_s->>'type';
        v_ref := NULLIF(v_pair->'ref', 'null'::jsonb);
        v_state := CASE WHEN v_ref IS NULL THEN NULL
                        ELSE finance.fn_handoff_ref_state(v_type, (v_ref->>'id')::int) END;
        IF v_state IS NULL THEN
            -- nie eingetragen -> der vereinbarte Aufruf selbst (nachholbar); eingetragen und wieder geloescht -> die Sache
            v_out := v_out || jsonb_build_array(jsonb_build_object('field', 'exists', 'wanted', true, 'current', false)
                         || CASE WHEN v_ref IS NULL THEN jsonb_build_object('call', v_call) ELSE jsonb_build_object('ref', v_ref) END);
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
