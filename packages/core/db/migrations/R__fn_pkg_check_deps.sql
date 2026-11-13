-- ============================================================
-- fn_pkg_check_deps (READ-ONLY — Abhaengigkeits-/API-Vorpruefung vor jeder Mutation)
--   Prueft, ob ein Paket installiert werden darf (Dep-Graph + API vor jeder FS-/DB-Aenderung,
--   damit kein Teil-Install mittendrin scheitert). Zwei Pruefungen:
--     (1) requires: jedes geforderte Paket existiert und ist status='active'
--         (fehlend -> missing_deps; vorhanden aber nicht aktiv -> inactive_deps).
--     (2) core_api: die geforderte Mindest-Core-API ist mit CORE_API_VERSION
--         (core.config category='api' key='core_version') kompatibel — SemVer-Caret:
--         gleiche major und current >= min (0.x: major 0). Element-weiser int[]-Vergleich.
--   Eingabe jsonb: package (Doku), core_api (Mindestversion, z. B. '0.2.0'),
--     requires (jsonb-Array von Paketnamen).
--   RUECKGABE: {ok, core_api_ok, current_core_api, required_core_api,
--     missing_deps:[…], inactive_deps:[…]}. ok = (core_api_ok AND keine missing/inactive).
--   Read-only, kein RAISE (Vorpruefung).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_check_deps(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_req        TEXT[];
    v_dep        TEXT;
    v_dep_status TEXT;
    v_missing    TEXT[] := '{}';
    v_inactive   TEXT[] := '{}';
    v_req_api    TEXT := trim(COALESCE(p->>'core_api', ''));
    v_cur_api    TEXT;
    v_api_ok     BOOLEAN := TRUE;
    v_cur_arr    INT[];
    v_req_arr    INT[];
BEGIN
    IF p ? 'requires' AND jsonb_typeof(p->'requires') = 'array' THEN
        SELECT COALESCE(array_agg(value::text), '{}') INTO v_req
        FROM jsonb_array_elements_text(p->'requires') AS value;
    ELSE
        v_req := '{}';
    END IF;

    FOREACH v_dep IN ARRAY v_req LOOP
        SELECT status INTO v_dep_status FROM core.package_registry WHERE package = v_dep;
        IF NOT FOUND THEN
            v_missing := array_append(v_missing, v_dep);
        ELSIF v_dep_status <> 'active' THEN
            v_inactive := array_append(v_inactive, v_dep);
        END IF;
    END LOOP;

    SELECT value INTO v_cur_api FROM core.config WHERE category = 'api' AND key = 'core_version';
    IF v_req_api <> '' THEN
        IF v_cur_api IS NULL OR v_cur_api = '' THEN
            v_api_ok := FALSE;   -- keine bekannte Core-API -> nicht kompatibel
        ELSE
            -- Auf 3 Stellen normalisieren, bevor verglichen wird: Postgres-Array-Vergleich ist
            -- laengen-sensitiv ('{0,3}' >= '{0,3,0}' ist FALSE), eine 2-stellige Version ('0.3') wuerde
            -- gegen eine 3-stellige ('0.2.0') still falsch verglichen. Fehlende Minor/Patch = 0.
            v_cur_arr := (string_to_array(v_cur_api, '.')::int[] || ARRAY[0,0,0])[1:3];
            v_req_arr := (string_to_array(v_req_api, '.')::int[] || ARRAY[0,0,0])[1:3];
            v_api_ok := (v_cur_arr[1] = v_req_arr[1]) AND (v_cur_arr >= v_req_arr);
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'ok',                v_api_ok AND array_length(v_missing, 1) IS NULL AND array_length(v_inactive, 1) IS NULL,
        'core_api_ok',       v_api_ok,
        'current_core_api',  COALESCE(v_cur_api, ''),
        'required_core_api', v_req_api,
        'missing_deps',      to_jsonb(v_missing),
        'inactive_deps',     to_jsonb(v_inactive)
    );
END;
$$;
