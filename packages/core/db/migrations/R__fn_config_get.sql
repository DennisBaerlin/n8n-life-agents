-- ============================================================
-- fn_config_get (READ-ONLY, SECURITY DEFINER — generisches Config-Lesefenster, D10)
--   Liefert den Wert EINER core.config-Zeile (package/category/key); NULL wenn keine Zeile.
--   Das EINE generische read-all-Fenster (Owner-Direktive "Lesen = alle Configs jedes Pakets
--   ueber ein Window"): jede enge Paket-Rolle (<pkg>_rw/<pkg>_ro) darf JEDE Config lesen, egal
--   von welchem Paket — Schreiben dagegen ist host-vermittelt + paket-skopiert (Seeder/CLI),
--   nie eine Paket-DB-Rolle (write-own). Eine Paket-Rolle hat KEIN direktes SELECT auf
--   core.config (D10-Isolation, core-Schema gesperrt) -> sie liest ueber diese Fn.
--
--   ZWECK (WS4a, F9): die Finance-Crons laufen unter Finance-DB-Rollen (Least Privilege) und
--   pruefen ihren Enable-Flag ueber das kombinierte Gate-SQL (DB entscheidet den Vergleich):
--       SELECT core.fn_package_active('finance')
--          AND COALESCE(core.fn_config_get('finance','cron_enable','<cron>') = 'true', false);
--   fehlende Zeile -> NULL -> COALESCE(..., false) = fail-closed; der Seeder garantiert je
--   deklariertem Cron die Default-Zeile (always-on 'true', opt-in 'false').
--
--   HAERTUNG (Pflicht bei SECURITY DEFINER):
--     * search_path hart auf pg_catalog gepinnt + Objekt schema-qualifiziert (CVE-2018-1058).
--     * REVOKE ALL FROM PUBLIC + gezieltes GRANT EXECUTE nur an die Paket-Rollen
--       (das macht core.fn_provision_package_roles, to_regprocedure-guarded).
--   KEINE Secrets in core.config (Backup-Key lebt in core.backup_key, ACL-gefenct) -> read-all unkritisch.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_config_get(p_package text, p_category text, p_key text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT value
    FROM core.config
    WHERE package = p_package AND category = p_category AND key = p_key;
$$;

-- Default-PUBLIC-EXECUTE auf SECURITY-DEFINER-fns ist eine Privileg-Flaeche -> entfernen.
-- Die Paket-Rollen bekommen EXECUTE gezielt von core.fn_provision_package_roles.
REVOKE ALL ON FUNCTION core.fn_config_get(text, text, text) FROM public;
