-- ============================================================
-- fn_config_seed + fn_config_reset (Install-UX-Phase 4) — dpkg-conffile-Semantik fuer core.config
--
--   fn_config_seed(p jsonb {category, key, value, description?, summary?, package?, type?, minimum?, maximum?,
--                           managed_by?}) -> {ok, action}
--     DER Upsert des Config-Seeders (provisioning/lib/seed_data.sh::_seed_package_config). Regel:
--       * neue Zeile                         -> value = default_value = Manifest-Wert   (action 'inserted')
--       * default_value := Manifest-Wert IMMER (merkt den zuletzt ausgelieferten Default)
--       * description (EN Entwickler-Text), summary (DE Owner-Einzeiler), type/minimum/maximum (-> value_type/
--         minimum/maximum, Default string/NULL) und managed_by (Default owner) IMMER aus dem Manifest
--       * value ueberschreiben NUR, wenn der Owner ihn nie geaendert hat:
--           value IS NOT DISTINCT FROM altem default_value                            (action 'updated')
--         sonst bleibt der Owner-Wert                                                 (action 'kept')
--       * Ausnahmen: managed_by='system' (z. B. api.core_version) -> immer ueberschreiben;
--         Owner-Wert passt nicht (mehr) zu Typ/Grenzen des Manifests -> zurueck auf den Default (NOTICE; der
--         Pruef-Trigger trg_config_check_value_type prueft nur NEUE Werte, darum raeumt der Seed hier auf);
--         cron_enable = Laufzeit-Schalter -> value nie ueberschreiben (frueher DO NOTHING);
--         model, dessen Owner-Wert nicht zur Modell-Art des (neuen) Standards passt (core.fn_model_value_eligible,
--         dieselbe Regel wie der Modell-Trigger trg_config_check_model_value) -> zurueck auf den Default (NOTICE;
--         sonst blockierte der Trigger den ganzen Seed). Ein verwaister Modell-Key ist seit core:V024 unmoeglich
--         (Fremdschluessel auf agent.ai_models).
--     Bestandszeilen von vor default_value (NULL) gelten als vom Owner gesetzt; ist ihr Wert gleich dem
--     neuen Default, folgen sie ab dann kuenftigen Defaults (default_value ist ab diesem Seed gesetzt). Vorher
--     traegt core:V026 fuer nie geaenderte Zeilen den damals (v0.2.0) ausgelieferten Standard nach -> sie folgen
--     dem heutigen Standard schon in diesem Seed.
--     WARUM DB-seitig: "DB ist Gesetz" — die Regel gilt fuer JEDEN Schreibweg (lifeagents config set,
--     Paket-Wizard, Agent-fns wie fn_set_cron_enable, psql), ohne dass ein Schreiber ein Flag setzen muss.
--     Vorher: DO UPDATE SET value=EXCLUDED.value -> jedes Update setzte z. B. general.paperless_url zurueck.
--
--   fn_config_reset(p jsonb {category, key}) -> {ok, value} | {ok:false, reason}
--     `lifeagents config reset`: value := default_value (der aktuell ausgelieferte Default).
--
--   Aufrufer: postgres-Superuser (Seeder/CLI via runuser). SECURITY INVOKER, kein Grant an Lese-Rollen.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_config_seed(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_cat   text := NULLIF(p->>'category', '');
    v_key   text := NULLIF(p->>'key', '');
    v_val   text := COALESCE(p->>'value', '');
    v_desc  text := COALESCE(p->>'description', '');
    v_sum   text := COALESCE(p->>'summary', '');
    v_pkg   text := COALESCE(NULLIF(p->>'package', ''), 'core');
    v_type  text := COALESCE(NULLIF(p->>'type', ''), 'string');
    v_min   numeric := NULLIF(p->>'minimum', '')::numeric;
    v_max   numeric := NULLIF(p->>'maximum', '')::numeric;
    v_mb    text := COALESCE(NULLIF(p->>'managed_by', ''), 'owner');
    v_old   core.config%ROWTYPE;
    v_new   text;
    v_action text;
BEGIN
    IF v_cat IS NULL OR v_key IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'category_and_key_required');
    END IF;

    SELECT * INTO v_old FROM core.config WHERE category = v_cat AND key = v_key FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO core.config (category, key, value, description, summary, package, default_value,
                                 value_type, minimum, maximum, managed_by)
        VALUES (v_cat, v_key, v_val, v_desc, v_sum, v_pkg, v_val, v_type, v_min, v_max, v_mb);
        RETURN jsonb_build_object('ok', true, 'action', 'inserted');
    END IF;

    IF v_mb = 'system' THEN
        v_new := v_val;                                          -- System-Wert: immer der ausgelieferte
    ELSIF NOT core.fn_config_value_valid(v_type, v_old.value, v_min, v_max) THEN
        v_new := v_val;                                          -- passt nicht (mehr) zum Typ -> Default
        RAISE NOTICE 'core.config %/%: Wert "%" passt nicht zu %, zurück auf den Standard "%"',
            v_cat, v_key, v_old.value, core.fn_config_value_expectation(v_type, v_min, v_max), v_val;
    ELSIF v_cat = 'cron_enable' THEN
        v_new := v_old.value;                                    -- Laufzeit-Schalter: nie ueberschreiben
    ELSIF v_cat = 'model' AND NOT core.fn_model_value_eligible(v_old.value, v_val) THEN
        v_new := v_val;                                          -- Modell passt nicht (mehr) zum Standard -> Default
        RAISE NOTICE 'core.config model/%: Modell "%" passt nicht zur Art des Standards, zurück auf "%"',
            v_key, v_old.value, v_val;
    ELSIF v_old.value IS NOT DISTINCT FROM v_old.default_value THEN
        v_new := v_val;                                          -- nie geaendert -> folgt dem Default
    ELSE
        v_new := v_old.value;                                    -- Owner-Wert bleibt
    END IF;

    v_action := CASE WHEN v_new IS DISTINCT FROM v_old.value THEN 'updated'
                     WHEN v_new IS DISTINCT FROM v_val       THEN 'kept'
                     ELSE 'unchanged' END;

    UPDATE core.config
       SET value = v_new, default_value = v_val, description = v_desc, summary = v_sum, package = v_pkg,
           value_type = v_type, minimum = v_min, maximum = v_max, managed_by = v_mb
     WHERE id = v_old.id;
    RETURN jsonb_build_object('ok', true, 'action', v_action);
END;
$$;

CREATE OR REPLACE FUNCTION core.fn_config_reset(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_cat text := NULLIF(p->>'category', '');
    v_key text := NULLIF(p->>'key', '');
    v_val text;
BEGIN
    IF v_cat IS NULL OR v_key IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'category_and_key_required');
    END IF;
    UPDATE core.config SET value = default_value
     WHERE category = v_cat AND key = v_key AND default_value IS NOT NULL
    RETURNING value INTO v_val;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_key_or_no_default');
    END IF;
    RETURN jsonb_build_object('ok', true, 'value', v_val);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_config_seed(jsonb) FROM public;
REVOKE ALL ON FUNCTION core.fn_config_reset(jsonb) FROM public;
