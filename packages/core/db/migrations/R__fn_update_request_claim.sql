-- ============================================================
-- core.fn_update_request_claim(p) (Write — Update-Hinweis 2026-10-24)
--   Der root-Runner (`lifeagents update --run-requested`) ruft sie UNTER der Update-Sperre (flock): erst werden
--   haengende Auftraege geschlossen (uebernommen, aber nie abgeschlossen = der Runner starb, z. B. Neustart
--   mitten im Update; unter der Sperre laeuft sicher kein anderer), dann wird der offene Auftrag uebernommen.
--   Ein haengender Auftrag gilt als succeeded, wenn VERSION schon = sein Tag ist UND es beim Start nicht war (Abbruch
--   nach dem CLI-Tausch; eine Wiederholung nach partial startet schon mit VERSION = Tag -> interrupted), sonst als
--   interrupted — der Runner meldet beides (core.fn_update_report).
--   p: {installed} = Inhalt von VERSION (Tag oder 'dev'; anderes -> NULL)
--   RUECKGABE: {recovered:[{id, tag, kind, outcome}], claimed:{id, tag, kind, from_version} | null}. Nie RAISE.
--   Atomar (eine fn = eine TX). INVOKER (root ueber runuser postgres).
--   Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_update_request_claim(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_inst      text;
    v_recovered jsonb;
    v_claimed   jsonb;
BEGIN
    v_inst := CASE WHEN COALESCE(p->>'installed', '') ~ '^[A-Za-z0-9._-]{1,64}$' THEN p->>'installed' END;

    WITH r AS (
        UPDATE core.update_requests
           SET finished_at = now(),
               -- fertig nur, wenn der Lauf VERSION wirklich umgestellt hat (Retry nach partial startet schon mit VERSION = Tag)
               outcome     = CASE WHEN tag = v_inst AND from_version IS DISTINCT FROM tag THEN 'succeeded' ELSE 'interrupted' END
         WHERE claimed_at IS NOT NULL AND finished_at IS NULL
        RETURNING id, tag, kind, outcome
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'tag', tag, 'kind', kind, 'outcome', outcome) ORDER BY id), '[]'::jsonb)
      INTO v_recovered
      FROM r;

    WITH c AS (
        UPDATE core.update_requests
           SET claimed_at = now(), from_version = v_inst
         WHERE claimed_at IS NULL AND finished_at IS NULL
        RETURNING id, tag, kind, from_version
    )
    SELECT jsonb_build_object('id', id, 'tag', tag, 'kind', kind, 'from_version', from_version)
      INTO v_claimed
      FROM c;

    RETURN jsonb_build_object('recovered', v_recovered, 'claimed', COALESCE(v_claimed, 'null'::jsonb));
END;
$$;
