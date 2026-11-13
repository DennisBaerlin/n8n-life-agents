-- ============================================================
-- fn_monitor_validate_params (READ)
--   Prueft und normalisiert die Methoden-Parameter einer Paket-Methode (p_method, p_params). Dispatch an die
--   validate_fn der registrierten Methode (Muster core.fn_dispatch_callback:
--   fn-Name nur aus der Registry, to_regprocedure-Guard, EXECUTE format). Genutzt von fn_create/
--   set_monitor_trigger + fn_monitor_probe (freundliche Meldung vor dem Write) und vom BEFORE-Trigger
--   trg_monitor_triggers_validate_spec (DB-Gesetz). Core-Builtins validieren ihre Felder selbst (nicht hier).
--   p_params: das vom Modell gelieferte Objekt (Tool-Input acquisition_params) bzw. die gespeicherte Spec.
--     Ein Nicht-Objekt (z. B. der Build-Sentinel '__invalid_json__' bei kaputtem JSON) -> {ok:false}.
--   RUECKGABE: {ok:true, available:true, spec, display (tpl-Objekt oder String)} | {ok:false, available:<bool>, reason}
--     available=false = Methode gerade nicht nutzbar (der Trigger-Backstop ueberspringt dann, create lehnt ab).
--   Idempotenz-Vertrag der Paket-validate_fn: sie muss ihre eigene normalisierte spec als params akzeptieren und
--     unveraendert zurueckgeben (der BEFORE-Trigger validiert die gespeicherte spec, fn_set_monitor_trigger
--     validiert spec || neue params) -> params und spec haben dieselbe Form (docs/package-contract.md §3.9).
--   Nie RAISE: auch ein RAISE der Paket-validate_fn wird zu {ok:false} gefangen (Paritaet zu fn_monitor_acquire).
--   Tests: tests/db/core/test_monitor_acquisition_methods.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_validate_params(p_method text, p_params jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_st jsonb := agent.fn_monitor_method_status(p_method);
    v_r  jsonb;
BEGIN
    IF COALESCE((v_st->>'builtin')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false, 'available', true,
            'reason', format('%s is a core method — it takes no acquisition_params', p_method));
    END IF;
    IF NOT COALESCE((v_st->>'available')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false, 'available', false, 'reason', v_st->>'reason');
    END IF;
    IF p_params IS NULL OR jsonb_typeof(p_params) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('ok', false, 'available', true,
            'reason', format('acquisition_params for %s must be a JSON object', p_method));
    END IF;
    BEGIN
        EXECUTE format('SELECT %s($1)', v_st->>'validate_fn') INTO v_r
            USING jsonb_build_object('params', p_params);
    EXCEPTION WHEN OTHERS THEN
        -- wie fn_monitor_acquire: ein RAISE der Paket-fn wird zur korrigierbaren Ablehnung (kein Owner-Alert);
        -- der BEFORE-Trigger macht aus {ok:false} weiterhin ein check_violation -> der Write bleibt blockiert.
        RETURN jsonb_build_object('ok', false, 'available', true,
            'reason', format('validate_fn of %s failed: %s', p_method, SQLERRM));
    END;
    IF v_r IS NULL OR NOT COALESCE((v_r->>'ok')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false, 'available', true,
            'reason', COALESCE(v_r->>'reason', format('acquisition_params rejected by %s', p_method)));
    END IF;
    IF jsonb_typeof(v_r->'spec') IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('ok', false, 'available', true,
            'reason', format('validate_fn of %s returned no spec object', p_method));
    END IF;
    RETURN jsonb_build_object('ok', true, 'available', true, 'spec', v_r->'spec',
        -- display: typisierter Text-Verweis (tpl-Objekt, Textkatalog) unveraendert, sonst der String
        'display', CASE WHEN jsonb_typeof(v_r->'display') = 'object' THEN v_r->'display'
                        ELSE to_jsonb(COALESCE(v_r->>'display', '')) END);
END;
$$;
