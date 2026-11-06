-- ============================================================
-- fn_pkg_register (ATOMIC WRITE — Paket in core.package_registry an-/nachmelden)
--   Idempotenter Upsert je `package` (PK). Erstanlage -> status='installing'
--   (Lifecycle-Start; `active` setzt erst fn_pkg_set_status zuletzt). Re-Register
--   (gleiches Paket) aktualisiert version/description/requires/core_api/checksum,
--   laesst den `status` UNANGETASTET (ein Update-Lauf kippt nicht ungewollt aktiv->installing).
--   Aufgerufen vom CLI-Lifecycle (pkg_lifecycle.sh) NACH erfolgreicher DB-Migration/Deploy.
--   Eingabe jsonb: package (Pflicht), version, description, display_name (deutscher Anzeigename,
--     Install-UX-Phase 6), core_api (Mindest-Core-API), requires (jsonb-Array von Paketnamen), manifest_checksum.
--   RUECKGABE: {ok:true, package, version, status, created} (created = DB-entschieden:
--     true bei Erstanlage, false bei Upsert). Leerer package -> {ok:false, reason} ohne Write.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_register(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pkg     TEXT := trim(COALESCE(p->>'package', ''));
    v_req     TEXT[];
    v_created BOOLEAN;
    v_version TEXT;
    v_status  TEXT;
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;

    -- requires: jsonb-Array -> text[] (fehlt/null -> leer)
    IF p ? 'requires' AND jsonb_typeof(p->'requires') = 'array' THEN
        SELECT COALESCE(array_agg(value::text), '{}') INTO v_req
        FROM jsonb_array_elements_text(p->'requires') AS value;
    ELSE
        v_req := '{}';
    END IF;

    INSERT INTO core.package_registry
        (package, version, description, display_name, core_api_at_install, requires, manifest_checksum, status)
    VALUES (
        v_pkg,
        COALESCE(p->>'version', ''),
        COALESCE(p->>'description', ''),
        COALESCE(p->>'display_name', ''),
        COALESCE(p->>'core_api', ''),
        v_req,
        COALESCE(p->>'manifest_checksum', ''),
        'installing'
    )
    ON CONFLICT (package) DO UPDATE SET
        version             = COALESCE(p->>'version', core.package_registry.version),
        description         = COALESCE(p->>'description', core.package_registry.description),
        display_name        = COALESCE(p->>'display_name', core.package_registry.display_name),
        core_api_at_install = COALESCE(p->>'core_api', core.package_registry.core_api_at_install),
        requires            = v_req,
        manifest_checksum   = COALESCE(p->>'manifest_checksum', core.package_registry.manifest_checksum)
        -- status BEWUSST nicht angefasst (Re-Register kippt den Lebenszyklus nicht)
    RETURNING (xmax = 0) AS inserted, version, status INTO v_created, v_version, v_status;

    RETURN jsonb_build_object(
        'ok', true, 'package', v_pkg, 'version', v_version, 'status', v_status, 'created', v_created
    );
END;
$$;
