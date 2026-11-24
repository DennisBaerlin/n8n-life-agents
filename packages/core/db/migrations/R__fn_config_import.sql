-- ============================================================
-- fn_config_export + fn_config_import — geaenderte Einstellungen fuer Sicherung und Umzug
--
--   fn_config_export() -> jsonb-Array [{package, category, key, value}]
--     Die eine Regel, welche Einstellung reist: managed_by = 'owner' und value IS DISTINCT FROM default_value.
--     managed_by 'system' (setzt jedes Update) und 'instance' (Wissen dieser Installation, z. B. telegram.bot_username
--     per getMe) reisen nie. Geordnet nach package, category, key.
--
--   fn_config_import(p jsonb {rows: [{package?, category, key, value}]}) -> {ok, applied, reset, skipped} | {ok:false, reason}
--     Je Zeile: bekannte owner-Zeile + Wert, den die Pruef-Trigger annehmen (Typ, Grenzen, Modell) -> gesetzt (applied[]).
--     Sonst skipped[] {package, category, key, reason}: unknown (Zeile fehlt hier) | system | instance | invalid (der
--     Trigger lehnt ab). Nie der Wert in der Antwort (Zugangs-Adressen o. ae.). Danach geht jede owner-Zeile, die rows nicht
--     nennt und vom Standard abweicht, auf default_value zurueck (reset[]): der Stand nach dem Einspielen ist der der
--     Sicherung, auch auf demselben Rechner. Uebersprungene Zeilen bleiben unberuehrt.
--     applied/reset: [{package, category, key}] (der Aufrufer deployt bei category 'schedule' das Paket neu).
--     reason (ok:false): rows_required. Kein RAISE fuer einzelne Zeilen.
--     Aufrufer: lifeagents backup restore, move apply, config import (postgres-Superuser). SECURITY INVOKER.
--   Tests: tests/db/core/test_fn_config_export.sql, tests/db/core/test_fn_config_import.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_config_export()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('package', package, 'category', category, 'key', key, 'value', value)
                              ORDER BY package, category, key), '[]'::jsonb)
      FROM core.config
     WHERE managed_by = 'owner' AND value IS DISTINCT FROM default_value;
$$;

CREATE OR REPLACE FUNCTION core.fn_config_import(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_row     jsonb;
    v_cfg     core.config%ROWTYPE;
    v_applied jsonb := '[]';
    v_reset   jsonb := '[]';
    v_skipped jsonb := '[]';
    v_named   text[] := '{}';
    v_reason  text;
BEGIN
    IF jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'rows_required');
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(p->'rows') LOOP
        v_named := v_named || ((v_row->>'category') || '/' || (v_row->>'key'));
        v_reason := NULL;
        SELECT * INTO v_cfg FROM core.config WHERE category = v_row->>'category' AND key = v_row->>'key' FOR UPDATE;
        IF NOT FOUND THEN
            v_reason := 'unknown';
        ELSIF v_cfg.managed_by <> 'owner' THEN
            v_reason := v_cfg.managed_by;                          -- system | instance
        ELSE
            BEGIN
                UPDATE core.config SET value = v_row->>'value' WHERE id = v_cfg.id;
            EXCEPTION WHEN OTHERS THEN
                v_reason := 'invalid';                             -- Pruef-Trigger (Typ/Grenzen/Modell) oder FK lehnt ab
            END;
        END IF;
        IF v_reason IS NULL THEN
            v_applied := v_applied || jsonb_build_object('package', v_cfg.package, 'category', v_cfg.category, 'key', v_cfg.key);
        ELSE
            v_skipped := v_skipped || jsonb_build_object('package', COALESCE(v_cfg.package, v_row->>'package'),
                                                         'category', v_row->>'category', 'key', v_row->>'key', 'reason', v_reason);
        END IF;
    END LOOP;

    WITH r AS (
        UPDATE core.config SET value = default_value
         WHERE managed_by = 'owner' AND default_value IS NOT NULL AND value IS DISTINCT FROM default_value
           AND NOT (category || '/' || key) = ANY (v_named)
        RETURNING package, category, key)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('package', package, 'category', category, 'key', key)
                              ORDER BY package, category, key), '[]') INTO v_reset FROM r;

    RETURN jsonb_build_object('ok', true, 'applied', v_applied, 'reset', v_reset, 'skipped', v_skipped);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_config_export() FROM public;
REVOKE ALL ON FUNCTION core.fn_config_import(jsonb) FROM public;
