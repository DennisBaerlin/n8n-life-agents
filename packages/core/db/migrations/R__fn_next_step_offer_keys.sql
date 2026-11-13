-- ============================================================
-- fn_next_step_offer_keys (READ)
--   Latch-Keys der Vorschlags-Grenzen. Eingabe: p_person_id, p_callback, p_state, p_generation.
--   Die eine Key-Bildung fuer das Lesen (core.fn_get_next_step, Feld offer) und das Setzen (core.fn_claim_next_step_offer),
--   damit beide nie auseinanderlaufen. Ein Vorschlag mit Knopf bei Gruss/Lebenszeichen kommt hoechstens
--   offer_per_day je Kalendertag (core.fn_today, Haushalts-Zeitzone), und derselbe Schritt in derselben Lage hoechstens
--   offer_max_repeats mal ohne gueltigen Tipp.
--   Keys (source in Klammern, core.notification_state, NULL-TTL):
--     day    (next_step_day)   <pid>:<YYYY-MM-DD>:<i>                       i = 1..offer_per_day
--     repeat (next_step_offer) <pid>:<callback>:<state>:<generation>:<n>    n = 1..offer_max_repeats
--   generation = Epoch der letzten Lage-Aenderung (Abschnitt status_changed_at, Plan updated_at): eine Rueckkehr in eine
--   fruehere Lage ergibt neue Keys, die Ruhe endet also nicht nur beim Schrittwechsel.
--   Grenzen aus core.config (core/next_step/offer_per_day, offer_max_repeats); unlesbar/negativ -> Default 1 bzw. 3; 0 = aus
--   (leeres Array = keine Grenze).
--   RUECKGABE jsonb: { day:[key…], repeat:[key…] }. STABLE, INVOKER (nur Aufrufer sind die beiden DEFINER-fns).
--   Tests: tests/db/core/test_fn_claim_next_step_offer.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_next_step_offer_keys(p_person_id text, p_callback text, p_state text, p_generation bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_day    int;
    v_rep    int;
    v_today  text := to_char(core.fn_today(), 'YYYY-MM-DD');
BEGIN
    BEGIN
        v_day := NULLIF(core.fn_config_get('core', 'next_step', 'offer_per_day'), '')::int;
    EXCEPTION WHEN OTHERS THEN
        v_day := NULL;
    END;
    BEGIN
        v_rep := NULLIF(core.fn_config_get('core', 'next_step', 'offer_max_repeats'), '')::int;
    EXCEPTION WHEN OTHERS THEN
        v_rep := NULL;
    END;
    IF v_day IS NULL OR v_day < 0 THEN v_day := 1; END IF;
    IF v_rep IS NULL OR v_rep < 0 THEN v_rep := 3; END IF;
    RETURN jsonb_build_object(
        'day',    COALESCE((SELECT jsonb_agg(p_person_id || ':' || v_today || ':' || i ORDER BY i) FROM generate_series(1, v_day) i), '[]'::jsonb),
        'repeat', COALESCE((SELECT jsonb_agg(p_person_id || ':' || COALESCE(p_callback, '') || ':' || COALESCE(p_state, '') || ':'
                                             || COALESCE(p_generation, 0) || ':' || n ORDER BY n) FROM generate_series(1, v_rep) n), '[]'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_next_step_offer_keys(text, text, text, bigint) FROM public;
