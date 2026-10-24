-- ============================================================
-- estate.fn_set_case (ATOMIC WRITE — WS-3, partielles UPDATE eines OFFENEN Falls)
--   Aendert knowledge_date / bundesland / flags eines offenen Falls und ZIEHT DIE FRISTEN NACH:
--     * Recompute aller offenen Task-Fristen (bundesland -> Werktage/Feiertage; knowledge_date ->
--       kenntnis-verankerte Fristen wie § 1944/§ 30).
--     * ADDITIVER Task-Reconcile: neu zutreffende Templates (flags/derived jetzt true) kippen von
--       'not_applicable' auf 'open'; fan_out zieht neu registrierte Sonderfall-Stubs nach. NICHTS wird
--       auto-n.a. gesetzt (dokumentierte Grenze) — beides leistet fn_instantiate_case_tasks (ON CONFLICT).
--   flags werden GEMERGT (bestehende || neue), knowledge_date/bundesland partiell (COALESCE = nicht
--   gesendet bleibt unveraendert). adults_only-DB-Backstop. Nur OFFENE Faelle. Eingabe jsonb: chat_id,
--   case_id, knowledge_date (optional), bundesland (optional), flags (optional jsonb).
--   RUECKGABE: {ok:true, case_id, phase_counts, total_open} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_case.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_case(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm      TEXT;
    v_id        BIGINT := NULLIF(p->>'case_id', '')::bigint;
    v_status    TEXT;
    v_event     DATE;
    v_new_know  DATE;
    v_new_bl    TEXT;
    v_new_flags JSONB;
    v_counts    JSONB;
    v_total     INT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'Write rejected (' || v_perm || '): only adult household members (owner/partner) may change an event case.');
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case_id is required.');
    END IF;
    SELECT status, event_date INTO v_status, v_event FROM estate.cases WHERE id = v_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case not found.');
    END IF;
    IF v_status <> 'open' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'case ' || v_id || ' is not open (status ' || v_status || ') — cannot change it.');
    END IF;

    BEGIN
        v_new_know := NULLIF(p->>'knowledge_date', '')::date;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'knowledge_date must be a valid date (YYYY-MM-DD).');
    END;
    IF v_new_know IS NOT NULL AND v_new_know < v_event THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'knowledge_date cannot be before event_date.');
    END IF;

    v_new_bl := lower(NULLIF(trim(COALESCE(p->>'bundesland', '')), ''));
    IF v_new_bl IS NOT NULL AND v_new_bl NOT IN
        ('baden_wuerttemberg', 'bayern', 'berlin', 'brandenburg', 'bremen', 'hamburg', 'hessen',
         'mecklenburg_vorpommern', 'niedersachsen', 'nordrhein_westfalen', 'rheinland_pfalz',
         'saarland', 'sachsen', 'sachsen_anhalt', 'schleswig_holstein', 'thueringen') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid bundesland "' || v_new_bl || '" — use a German state slug like bayern.');
    END IF;

    v_new_flags := p->'flags';

    UPDATE estate.cases SET
        knowledge_date = COALESCE(v_new_know, knowledge_date),
        bundesland     = COALESCE(v_new_bl, bundesland),
        flags          = CASE WHEN jsonb_typeof(v_new_flags) = 'object' THEN flags || v_new_flags ELSE flags END
      WHERE id = v_id;

    PERFORM estate.fn_instantiate_case_tasks(v_id);

    SELECT COALESCE(jsonb_object_agg(phase, cnt), '{}'::jsonb), COALESCE(sum(cnt), 0)::int
      INTO v_counts, v_total
      FROM (SELECT phase, count(*) AS cnt FROM estate.case_tasks
             WHERE case_id = v_id AND status = 'open' GROUP BY phase) s;

    RETURN jsonb_build_object('ok', true, 'case_id', v_id, 'phase_counts', v_counts, 'total_open', v_total);
END;
$$;
