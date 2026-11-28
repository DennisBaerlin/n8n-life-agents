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
--   Haertung: DEFINER-Checkliste (.claude/rules/sql.md); EXECUTE nur an die Paket-Rollen via core.fn_provision_package_roles.
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

-- Die Paket-Rollen bekommen EXECUTE gezielt von core.fn_provision_package_roles.
REVOKE ALL ON FUNCTION core.fn_core_api_version() FROM public;
