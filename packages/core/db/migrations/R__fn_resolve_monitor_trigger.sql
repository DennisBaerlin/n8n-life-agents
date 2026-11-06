-- ============================================================
-- fn_resolve_monitor_trigger
--   Loest (domain, label) eines Monitor-Triggers in die ID auf — Muster fn_resolve_account
--   (Rueckgabe id, hit_count, candidates; 0/>1 -> Tool fragt nach). Label-Match
--   case-insensitiv (UNIQUE-Index auf lower(label) je Domain -> innerhalb einer Domain
--   strukturell <=1 Treffer; ohne Domain-Filter kann es Mehrtreffer geben).
--   p_active_only: TRUE -> disabled ausblenden (Default FALSE — set/delete muessen auch
--   fired/disabled finden, Lifecycle-Konvention wie fn_resolve_loan).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_resolve_monitor_trigger(
    p_label       text,
    p_domain      text    DEFAULT NULL,
    p_active_only boolean DEFAULT FALSE
) RETURNS TABLE (
    id          int,
    hit_count   int,
    candidates  jsonb
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         INT;
BEGIN
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',           t.id,
            'domain',       t.domain,
            'label',        t.label,
            'trigger_type', t.trigger_type,
            'status',       t.status
        ) ORDER BY t.id),
        COUNT(*),
        MIN(t.id)
    INTO v_candidates, v_count, v_id
    FROM agent.monitor_triggers t
    WHERE lower(t.label) = lower(trim(COALESCE(p_label, '')))
      AND (p_domain IS NULL OR t.domain = p_domain)
      AND (p_active_only = FALSE OR t.status <> 'disabled');

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
