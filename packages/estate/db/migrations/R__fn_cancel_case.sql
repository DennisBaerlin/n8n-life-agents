-- ============================================================
-- estate.fn_cancel_case (ATOMIC WRITE — WS-3, Break-Glass owner_info; NEUES Verb 'cancel', Floor 0)
--   Bricht einen OFFENEN Ereignisfall ab (status -> 'cancelled', closed_at materialisiert). Die
--   case_tasks bleiben als Audit erhalten (CASCADE greift erst beim echten Loeschen des Falls, das es
--   nicht gibt). Danach ist die partial-UNIQUE(subject) WHERE open frei -> ein neuer/korrigierter Fall
--   ist anlegbar (Fall-Korrektur = cancel + create). Verb 'cancel' Floor 0 (owner_info-faehig, Break-
--   Glass): ein erwachsenes Mitglied kann einen Fall allein abbrechen (Owner-Info = Audit) — bewusste
--   Konsequenz (Plan). adults_only-DB-Backstop (Kind -> {ok:false}). case_id vom Tool geliefert (der
--   Agent liest ihn per postgres_select). Nicht gefunden/nicht offen = korrigierbar ({ok:false}, kein
--   RAISE -> kein Owner-Alert-Sturm bei einer veralteten id).
--   Eingabe jsonb: chat_id, case_id. RUECKGABE: {ok:true, case_id, status:'cancelled'} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_cancel_case.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_cancel_case(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm   TEXT;
    v_id     BIGINT := NULLIF(p->>'case_id', '')::bigint;
    v_status TEXT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'Write rejected (' || v_perm || '): only adult household members (owner/partner) may cancel an event case.');
    END IF;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case_id is required.');
    END IF;
    SELECT status INTO v_status FROM estate.cases WHERE id = v_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case ' || v_id || ' not found.');
    END IF;
    IF v_status <> 'open' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'case ' || v_id || ' is not open (status ' || v_status || ') — nothing to cancel.');
    END IF;

    UPDATE estate.cases SET status = 'cancelled', closed_at = now() WHERE id = v_id;
    RETURN jsonb_build_object('ok', true, 'case_id', v_id, 'status', 'cancelled');
END;
$$;
