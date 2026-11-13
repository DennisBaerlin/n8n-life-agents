-- ============================================================
-- fn_core_api_version (READ, SECURITY DEFINER — Core↔Paket-Contract-Muster)
--   Liefert CORE_API_VERSION (core.config category='api' key='core_version') als text.
--   '' wenn nicht geseedet. Keine Eingabe.
--
--   Das Muster der publizierten Read-fn: eine Paket-Rolle
--   (<pkg>_ro/<pkg>_rw) hat kein SELECT auf core-Tabellen, core.config ist
--   ihr direkt verschlossen. Den einen Wert, den sie legitim braucht (die Core-API-
--   Version, um Kompatibilitaet zu pruefen), bekommt sie nur ueber diese
--   SECURITY-DEFINER-Funktion: sie laeuft mit den Rechten des Owners (postgres),
--   liest core.config, gibt aber ausschliesslich die Version zurueck. Sensible Reads
--   (z. B. core.fn_household_persons) folgen demselben Muster.
--
--   Haertung (Pflicht bei SECURITY DEFINER):
--     * search_path hart auf pg_catalog gepinnt + alle Objekte schema-qualifiziert
--       (CVE-2018-1058: kein shadowing ueber einen Angreifer-search_path).
--     * REVOKE ALL FROM PUBLIC + explizites GRANT EXECUTE nur an die Paket-Rollen
--       (das macht core.fn_provision_package_roles) — kein Default-PUBLIC-EXECUTE,
--       damit "nur ueber publizierte Read-fns" auch grant-seitig stimmt.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_core_api_version()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(
        (SELECT value FROM core.config WHERE category = 'api' AND key = 'core_version'),
        ''
    );
$$;

-- Default-PUBLIC-EXECUTE auf SECURITY-DEFINER-fns ist eine Privileg-Flaeche -> entfernen.
-- Die Paket-Rollen bekommen EXECUTE gezielt von core.fn_provision_package_roles.
REVOKE ALL ON FUNCTION core.fn_core_api_version() FROM public;
