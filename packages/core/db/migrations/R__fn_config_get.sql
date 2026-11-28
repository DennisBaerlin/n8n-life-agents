-- ============================================================
-- fn_config_get (READ, SECURITY DEFINER — generisches Config-Lesefenster)
--   Liefert den Wert einer core.config-Zeile (package/category/key); NULL wenn keine Zeile.
--   Das eine generische read-all-Fenster: jede enge Paket-Rolle (<pkg>_rw/<pkg>_ro) darf jede Config
--   lesen, egal von welchem Paket; Schreiben dagegen ist host-vermittelt + paket-skopiert (Seeder/CLI),
--   nie eine Paket-DB-Rolle. Eine Paket-Rolle hat kein direktes SELECT auf
--   core.config (core-Schema gesperrt) -> sie liest ueber diese fn.
--   Eingabe: p_package, p_category, p_key. Rueckgabe: text-Wert oder NULL.
--
--   Typischer Aufrufer: die Paket-Crons laufen unter ihren Paket-DB-Rollen (Least Privilege) und
--   pruefen ihren Enable-Flag ueber das kombinierte Gate-SQL (DB entscheidet den Vergleich):
--       SELECT core.fn_package_active('finance')
--          AND COALESCE(core.fn_config_get('finance','cron_enable','<cron>') = 'true', false);
--   fehlende Zeile -> NULL -> COALESCE(..., false) = fail-closed; der Seeder garantiert je
--   deklariertem Cron die Default-Zeile (always-on 'true', opt-in 'false').
--
--   Haertung: DEFINER-Checkliste (.claude/rules/sql.md); EXECUTE nur an die Paket-Rollen via core.fn_provision_package_roles.
--   Keine Secrets in core.config (Backup-Key lebt in core.backup_key, ACL-gefenct) -> read-all unkritisch.
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

-- Die Paket-Rollen bekommen EXECUTE gezielt von core.fn_provision_package_roles.
REVOKE ALL ON FUNCTION core.fn_config_get(text, text, text) FROM public;
