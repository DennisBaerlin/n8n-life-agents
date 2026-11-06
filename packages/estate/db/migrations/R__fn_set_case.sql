-- ============================================================
-- estate.fn_set_case (ATOMIC WRITE — WS-3, partielles UPDATE eines OFFENEN Falls)
--   Aendert knowledge_date / bundesland / flags eines offenen Falls und ZIEHT DIE FRISTEN NACH:
--     * Recompute aller offenen Task-Fristen (bundesland -> Werktage/Feiertage; knowledge_date ->
--       kenntnis-verankerte Fristen wie § 1944/§ 30).
--     * Task-Reconcile (fn_instantiate_case_tasks): neu zutreffende Templates kippen von n.a. auf open, nicht mehr
--       zutreffende von open auf n.a. — nur vom SYSTEM gesetzte Status; Nutzer-Status (done, "trifft nicht zu")
--       bleiben. fan_out zieht neu registrierte Sonderfall-Stubs nach.
--   flags werden GEMERGT (bestehende || neue; ein null-Wert loescht die Aussage -> wieder Register-Ableitung),
--   knowledge_date (YYYY-MM-DD oder relativ, core.fn_resolve_input_dates)/bundesland partiell (nicht gesendet bleibt
--   unveraendert). adults_only-DB-Backstop. Nur OFFENE Faelle. Eingabe jsonb: chat_id, case_id, knowledge_date,
--   bundesland, flags (alle optional).
--   RUECKGABE: {ok:true, case_id, phase_counts, total_open, case_status, effective?{knowledge_date}} | {ok:false, reason}.
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
    v_dates     JSONB;
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

    -- WP3: relative Angabe ("yesterday", "-3 days") rechnet die DB; der Probelauf meldet das Ergebnis als effective,
    -- New-FnWriteGate reicht es an den echten Write (Karte = Speicher, auch beim Tipp nach Mitternacht).
    v_dates := core.fn_resolve_input_dates(p, ARRAY['knowledge_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    v_new_know := NULLIF(v_dates->'resolved'->>'knowledge_date', '')::date;
    IF v_new_know IS NOT NULL THEN
        IF v_new_know > core.fn_today() THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'knowledge_date cannot be in the future.');
        END IF;
    END IF;
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
        -- true/false = Aussage des Nutzers (schlaegt das Register); null = Aussage vergessen -> wieder das Register.
        flags          = CASE WHEN jsonb_typeof(v_new_flags) = 'object' THEN jsonb_strip_nulls(flags || v_new_flags)
                              ELSE flags END
      WHERE id = v_id;

    PERFORM estate.fn_instantiate_case_tasks(v_id);

    SELECT COALESCE(jsonb_object_agg(phase, cnt), '{}'::jsonb), COALESCE(sum(cnt), 0)::int
      INTO v_counts, v_total
      FROM (SELECT phase, count(*) AS cnt FROM estate.case_tasks
             WHERE case_id = v_id AND status = 'open' GROUP BY phase) s;

    SELECT status INTO v_status FROM estate.cases WHERE id = v_id;   -- nach dem Auto-Complete-Trigger

    RETURN jsonb_strip_nulls(jsonb_build_object('ok', true, 'case_id', v_id, 'phase_counts', v_counts, 'total_open', v_total,
        'case_status', v_status,
        'effective', CASE WHEN v_new_know IS NOT NULL
                          THEN jsonb_build_object('knowledge_date', to_char(v_new_know, 'YYYY-MM-DD')) END));
END;
$$;
