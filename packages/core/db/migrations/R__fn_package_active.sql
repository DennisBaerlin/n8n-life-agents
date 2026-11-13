-- ============================================================
-- fn_package_active (READ-ONLY, SECURITY DEFINER)
--   Liefert TRUE genau dann, wenn das Paket in core.package_registry den Status 'active' hat.
--   Unbekanntes Paket / NULL -> FALSE (fail-closed); das Host-Paket 'core' ist immer 'active'.
--   Eingabe: p_package text (Paketschluessel).
--   Rueckgabe: boolean (kein jsonb, kein ok:false).
--   Der Status kippt zur Laufzeit per CLI active<->inactive ohne Redeploy; das Routing-Gate am Eingang
--   der Paket-Agenten liest diese fn vor dem LLM (kein LLM-Cost bei inaktivem Paket).
--   Warum DEFINER: eine enge Paket-Rolle (<pkg>_ro/<pkg>_rw) hat kein SELECT auf core.package_registry;
--   ein direkter GRANT oeffnete core-Schema-USAGE (core.config etc.), diese fn gibt nur den Boolean heraus.
--   Seiteneffekte: keine. EXECUTE-Grant an die Paket-Rollen setzt core.fn_provision_package_roles
--   (to_regprocedure-guarded).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_package_active(p_package text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM core.package_registry
        WHERE package = p_package AND status = 'active'
    );
$$;

-- Default-PUBLIC-EXECUTE auf SECURITY-DEFINER-fns ist eine Privileg-Flaeche.
REVOKE ALL ON FUNCTION core.fn_package_active(text) FROM public;
