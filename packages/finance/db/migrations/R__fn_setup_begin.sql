-- ============================================================
-- fn_setup_begin (WRITE, kein HITL: Ablauf-Zustand, keine Domaenen-Daten) -- Ersteinrichtung aus einer Export-Datei starten oder fortsetzen
--   Eingabe: chat_id, file_id, table:{rows}. Raeumt abgelaufene Laeufe (7 Tage) mit ihren unbestaetigten Stapeln ab.
--   Start, wenn das Konto fehlt (account_unknown ohne Kandidaten) oder bei Broker-Datei mit Kaeufen und Depot ohne Bestand oder
--   bei gedrucktem Stand ein unberuehrtes Konto spaeter startet (fn_setup_reanchor_plan). Gleiche Datei = gleicher Lauf; andere
--   Datei ersetzt file_id, solange keine Position bestaetigt ist. Schritt statement oder done: Lauf endet hier, die Datei laeuft als Monats-Check.
--   RUECKGABE: {ok:true, setup:false} (normaler Monats-Check) | {ok:true, setup:true, ...fn_setup_next}
--   | {ok:false, code:'setup_file_changed'|'setup_in_progress', reason}. Datei unlesbar -> setup:false (der normale Weg meldet es).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_begin(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_norm JSONB := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
    v_load JSONB;
    v_prof JSONB;
    v_chat TEXT := p->>'chat_id';
    v_hash TEXT := md5((p->'table')::text);
    v_s    finance.setup_session%ROWTYPE;
    v_acct INT;
    v_next JSONB;
    v_start BOOLEAN := false;
BEGIN
    DELETE FROM finance.import_staging i USING finance.setup_session s
    WHERE i.batch_id = s.batch_id AND i.status <> 'committed' AND s.created_at <= now() - interval '7 days';
    DELETE FROM finance.setup_session WHERE created_at <= now() - interval '7 days';

    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN jsonb_build_object('ok', true, 'setup', false);
    END IF;
    SELECT pr INTO v_prof FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr WHERE pr->>'key' = v_norm->>'profile';
    v_load := finance.fn_bank_export_load(jsonb_build_object('table', p->'table'));
    IF (v_load->>'ok')::boolean THEN
        v_acct := (v_load->>'account_id')::int;
    END IF;

    SELECT * INTO v_s FROM finance.setup_session WHERE profile = v_norm->>'profile' AND chat_id = v_chat;
    IF v_s.id IS NOT NULL THEN
        IF v_s.file_hash <> v_hash THEN
            IF EXISTS (SELECT 1 FROM finance.depot_holdings h JOIN finance.accounts d ON d.id = h.account_id
                       WHERE d.settlement_account_id = v_s.cash_account_id AND h.shares > 0) THEN
                RETURN jsonb_build_object('ok', false, 'code', 'setup_file_changed',
                    'reason', 'A setup from another file is still open and its positions are already confirmed. Finish or cancel it first (tool_import_setup).');
            END IF;
            UPDATE finance.setup_session SET file_id = p->>'file_id', file_hash = v_hash, updated_at = now() WHERE id = v_s.id;
        ELSE
            UPDATE finance.setup_session SET file_id = p->>'file_id', updated_at = now() WHERE id = v_s.id;
        END IF;
    ELSE
        IF v_acct IS NOT NULL AND EXISTS (SELECT 1 FROM finance.setup_session s WHERE s.cash_account_id = v_acct) THEN
            RETURN jsonb_build_object('ok', false, 'code', 'setup_in_progress',
                'reason', 'Another household member is setting up this account from a file. Wait until that setup is finished.');
        END IF;
        IF v_load->>'code' = 'account_unknown' AND jsonb_array_length(COALESCE(v_load->'candidates', '[]'::jsonb)) = 0 THEN
            v_start := true;
        ELSIF v_acct IS NOT NULL AND (v_prof->>'is_broker')::boolean
              AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_norm->'rows') r WHERE r->>'kind' = 'buy')
              AND NOT EXISTS (SELECT 1 FROM finance.depot_holdings h JOIN finance.accounts d ON d.id = h.account_id
                              WHERE d.settlement_account_id = v_acct AND h.shares > 0) THEN
            v_start := true;
        ELSIF v_acct IS NOT NULL AND (v_norm->>'printed_balance')::boolean
              AND (finance.fn_setup_reanchor_plan(v_acct, v_norm)->>'ok')::boolean THEN
            v_start := true;
        END IF;
        IF NOT v_start THEN
            RETURN jsonb_build_object('ok', true, 'setup', false);
        END IF;
        INSERT INTO finance.setup_session (profile, chat_id, file_id, file_hash, cash_account_id)
        VALUES (v_norm->>'profile', v_chat, p->>'file_id', v_hash, v_acct);
    END IF;

    v_next := finance.fn_setup_next(jsonb_build_object('chat_id', v_chat, 'table', p->'table'));
    IF v_next->>'phase' IN ('statement', 'done') THEN
        PERFORM finance.fn_setup_close(jsonb_build_object('chat_id', v_chat, 'profile', v_norm->>'profile'));
        RETURN jsonb_build_object('ok', true, 'setup', false);
    END IF;
    -- Positionen stellt erst tool_import_setup ein (dort liegt auch der Kurs-Abruf)
    RETURN jsonb_build_object('setup', true) || v_next
        || CASE WHEN v_next->>'phase' IN ('positions', 'open_items')
                THEN jsonb_build_object('say', 'Call tool_import_setup (action continue) now.') ELSE '{}'::jsonb END;
END;
$$;
