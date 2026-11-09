-- ============================================================
-- fn_setup_close (WRITE) -- Ersteinrichtung beenden: Lauf-Zeile samt file_id und unbestaetigtem Stapel entfernen
--   Eingabe: chat_id, profile (opt; ohne = der zuletzt aktive Lauf des Chats). Bestaetigte Konten und Positionen bleiben.
--   Kein HITL: nur Ablauf-Zustand.
--   RUECKGABE: {ok:true, closed (war ein Lauf offen)}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_close(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_s finance.setup_session%ROWTYPE;
BEGIN
    SELECT * INTO v_s FROM finance.setup_session
    WHERE chat_id = p->>'chat_id' AND (NULLIF(p->>'profile', '') IS NULL OR profile = p->>'profile')
    ORDER BY updated_at DESC LIMIT 1;
    IF v_s.id IS NULL THEN
        RETURN jsonb_build_object('ok', true, 'closed', false);
    END IF;
    DELETE FROM finance.import_staging WHERE batch_id = v_s.batch_id AND status <> 'committed';
    DELETE FROM finance.setup_session WHERE id = v_s.id;
    RETURN jsonb_build_object('ok', true, 'closed', true);
END;
$$;
