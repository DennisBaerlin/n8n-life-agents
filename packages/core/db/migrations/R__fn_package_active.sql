-- ============================================================
-- fn_package_active (READ-ONLY, SECURITY DEFINER — Core↔Paket-Contract-Muster, D10)
--   Liefert TRUE genau dann, wenn das Paket in core.package_registry den Status 'active' hat.
--   Lebenszyklus-Status: installing|installed|active|inactive (CHECK in package_registry_init);
--   nur 'active' = verdrahtet/geroutet. Unbekanntes Paket / NULL -> FALSE (fail-closed auf den
--   expliziten Zustand). Das Host-Paket 'core' ist immer 'active'.
--
--   ZWECK (WS-B8, R4): das Routing-Status-Gate am Eingang der Paket-Agenten (agent.finance /
--   agent.finance_advisor) liest diese fn VOR dem LLM und bricht bei nicht-aktivem Paket mit
--   {ok:false,error:'package_inactive'} ab (kein LLM-Cost) — analog zum Depth-Gate. Der Status
--   kann zur Laufzeit per CLI active<->inactive kippen OHNE Redeploy; dieses Gate kappt den
--   deaktivierten Pfad strukturell (nicht per LLM-Prompt — der ist "nur Komfort und driftet").
--
--   DIES IST DAS PUBLIZIERTE-READ-fn-MUSTER (D10, wie fn_core_api_version/fn_onboarding_status):
--   eine enge Paket-Rolle (<pkg>_ro/<pkg>_rw) hat KEIN SELECT auf core.package_registry — den EINEN
--   Boolean, den sie legitim braucht, bekommt sie NUR ueber diese SECURITY-DEFINER-fn (laeuft mit
--   Owner-Rechten, liest die Tabelle, gibt AUSSCHLIESSLICH den Aktiv-Boolean zurueck). Ein direkter
--   GRANT SELECT core.package_registry an finance_ro wuerde core-Schema-USAGE oeffnen (core.config etc.).
--
--   HAERTUNG (Pflicht bei SECURITY DEFINER):
--     * search_path hart auf pg_catalog gepinnt + Objekt schema-qualifiziert (CVE-2018-1058).
--     * REVOKE ALL FROM PUBLIC + gezieltes GRANT EXECUTE nur an die Paket-Rollen
--       (das macht core.fn_provision_package_roles, to_regprocedure-guarded).
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

-- Default-PUBLIC-EXECUTE auf SECURITY-DEFINER-fns ist eine Privileg-Flaeche -> entfernen.
-- Die Paket-Rollen bekommen EXECUTE gezielt von core.fn_provision_package_roles.
REVOKE ALL ON FUNCTION core.fn_package_active(text) FROM public;
