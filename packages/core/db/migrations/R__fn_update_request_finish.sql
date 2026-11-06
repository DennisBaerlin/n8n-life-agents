-- ============================================================
-- core.fn_update_request_finish(p) (Write — Update-Hinweis 2026-10-24)
--   Der root-Runner haelt das Ergebnis eines uebernommenen Auftrags fest (aus der Ergebnis-Datei von provision.sh
--   bzw. aus seinen eigenen Vor-Pruefungen). Nur ein uebernommener, offener Auftrag laesst sich abschliessen.
--   stage/reason_code nur als feste Codes ([a-z_]), sonst NULL; detail auf 500 Zeichen gekuerzt (nur Anzeige im
--   Owner-Chat, nie in Links).
--   p: {id, outcome, stage?, reason_code?, changed?, detail?}
--   RUECKGABE: {ok:true, id, outcome} | {ok:false, reason:'invalid'|'invalid_outcome'|'not_open'}. Nie RAISE.
--   INVOKER (root ueber runuser postgres). Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_update_request_finish(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id      bigint;
    v_outcome text := p->>'outcome';
    v_done    bigint;
BEGIN
    BEGIN
        v_id := (p->>'id')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_id := NULL;
    END;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid');
    END IF;
    IF v_outcome IS NULL OR v_outcome NOT IN ('succeeded', 'partial', 'held', 'failed', 'interrupted',
                                              'already_current', 'superseded') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid_outcome');
    END IF;

    UPDATE core.update_requests
       SET finished_at = now(),
           outcome     = v_outcome,
           stage       = CASE WHEN COALESCE(p->>'stage', '') ~ '^[a-z_]{1,40}$' THEN p->>'stage' END,
           reason_code = CASE WHEN COALESCE(p->>'reason_code', '') ~ '^[a-z_]{1,40}$' THEN p->>'reason_code' END,
           changed     = CASE p->'changed' WHEN 'true'::jsonb THEN true WHEN 'false'::jsonb THEN false END,
           detail      = NULLIF(left(btrim(COALESCE(p->>'detail', '')), 500), '')
     WHERE id = v_id AND claimed_at IS NOT NULL AND finished_at IS NULL
    RETURNING id INTO v_done;
    IF v_done IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_open');
    END IF;
    RETURN jsonb_build_object('ok', true, 'id', v_done, 'outcome', v_outcome);
END;
$$;
