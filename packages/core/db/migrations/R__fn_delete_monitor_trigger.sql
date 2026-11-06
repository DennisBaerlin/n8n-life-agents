-- ============================================================
-- fn_delete_monitor_trigger (ATOMIC WRITE — Monitor-Trigger hart loeschen)
--   Trigger sind CONFIG, kein Ledger: Hard-DELETE ist legitim (kein FK zeigt auf die
--   Tabelle ausser monitor_observations, die per ON DELETE CASCADE mitgehen — Audit-Log
--   eines geloeschten Triggers hat keinen Wert). Aufloesung per (domain, label).
--   Stilllegen statt loeschen -> tool_set_monitor_trigger status='disabled'.
--   RUECKGABE: {ok:true, trigger_id, observations_deleted} (Count = Informationsgehalt
--   des CASCADE) | {ok:false, reason} bei 0/>1 Treffern.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_delete_monitor_trigger(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain TEXT := COALESCE(NULLIF(trim(p->>'domain'), ''), 'general');
    v_r      RECORD;
    v_obs    INT;
    v_avail  JSONB;
BEGIN
    SELECT * INTO v_r FROM agent.fn_resolve_monitor_trigger(p->>'label', v_domain, FALSE);
    IF v_r.hit_count = 0 THEN
        SELECT COALESCE(jsonb_agg(t.label ORDER BY t.label), '[]'::jsonb) INTO v_avail
        FROM agent.monitor_triggers t WHERE t.domain = v_domain;
        RETURN jsonb_build_object('ok', false,
            'reason', format('no trigger labeled "%s" in domain %s', COALESCE(p->>'label', ''), v_domain),
            'available_labels', v_avail);
    ELSIF v_r.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'label is ambiguous — specify the domain',
            'candidates', v_r.candidates);
    END IF;

    -- Core-Trigger (system-eigene wie household_facts_freshness) sind nie loeschbar — nur
    -- deaktivierbar. Freundliche Schicht; der BEFORE-DELETE-Trigger ist der Backstop.
    IF (SELECT t.origin FROM agent.monitor_triggers t WHERE t.id = v_r.id) = 'core' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'this is a core system trigger and cannot be deleted — disable it instead (set status=disabled)');
    END IF;

    SELECT COUNT(*) INTO v_obs FROM agent.monitor_observations o WHERE o.trigger_id = v_r.id;
    DELETE FROM agent.monitor_triggers WHERE id = v_r.id;  -- observations CASCADE

    RETURN jsonb_build_object('ok', true, 'trigger_id', v_r.id, 'observations_deleted', v_obs);
END;
$$;
