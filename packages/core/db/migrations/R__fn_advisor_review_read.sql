-- ============================================================
-- core.fn_advisor_review_read (vollstaendige Lage ohne Merker)
--   Registry-Dispatch wie core.fn_advisor_review_evaluate, schreibt aber nie: Quartals-Rueckblick und die spaetere
--   Antwort auf "Was jetzt?" duerfen die Melde-Logik des Waechters nicht beruehren.
--   Eingaben: p_domain, p_person_id (optional), p_observations (optional).
--   Rueckgabe: {ok:true, alerts, digest} | {ok:false, error:'unknown_advisor_domain'|'review_fn_missing', alerts:[]}.
--   SECURITY INVOKER (Haupt-RW bzw. Host-Cred), review_fn kommt aus der Registry, nie vom Modell.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_review_read(p_domain text, p_person_id text DEFAULT NULL, p_observations jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_fn     text;
    v_result jsonb;
BEGIN
    SELECT review_fn INTO v_fn FROM core.advisors WHERE domain = p_domain;
    IF v_fn IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'unknown_advisor_domain', 'alerts', '[]'::jsonb);
    END IF;
    IF to_regprocedure(v_fn || '(text,text,jsonb)') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'review_fn_missing', 'alerts', '[]'::jsonb);
    END IF;
    EXECUTE format('SELECT %s($1, $2, $3)', v_fn) INTO v_result USING p_domain, p_person_id, p_observations;
    RETURN jsonb_build_object(
        'ok',     true,
        'alerts', COALESCE(v_result->'alerts', '[]'::jsonb),
        'digest', COALESCE(v_result->'digest', '{}'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_review_read(text, text, jsonb) FROM public;
