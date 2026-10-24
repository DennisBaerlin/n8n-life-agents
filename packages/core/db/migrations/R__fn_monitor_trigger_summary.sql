-- ============================================================
-- fn_monitor_trigger_summary (READ-ONLY, SECURITY DEFINER — publiziertes Core-Lesefenster, D10)
--   Liefert die armed/fired-Zaehler der Trigger einer Domain aus agent.monitor_triggers.
--   ZWECK: der Quartals-Digest der Core-Advisor-Engine (finance.fn_advisor_review, via den generischen
--   Wrapper core.fn_advisor_review_evaluate dispatcht) braucht die Statuszeile "X scharf, Y ausgeloest".
--   Eine finance-schema-fn darf agent.monitor_triggers NICHT direkt lesen (Schema-Isolation, D10) -> sie
--   liest die Zaehler ueber dieses publizierte Fenster (analog core.fn_advisor_read_plan, das ihr
--   agent.advisor_plans oeffnet). (Loest den frueheren finance_ro-Plan-Review-Cron ab, WS2.)
--
--   read-all (p_domain ist Parameter, keine own-Restriktion) — konsistent mit dem Owner-Window-Modell.
--   SECURITY DEFINER + gepinnter search_path + REVOKE ALL FROM PUBLIC + EXECUTE nur an die Paket-Rollen
--   (erteilt in core.fn_provision_package_roles, to_regprocedure-guarded). READ-ONLY (nur SELECT).
--   status-Domaene: 'armed'|'fired'|'disabled' (CHECK in agent.monitor_init); disabled zaehlt nirgends.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_monitor_trigger_summary(p_domain text)
RETURNS TABLE (armed int, fired int)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp   -- minimal: agent.monitor_triggers ist schema-qualifiziert (CVE-2018-1058)
AS $$
    SELECT
        count(*) FILTER (WHERE status = 'armed')::int AS armed,
        count(*) FILTER (WHERE status = 'fired')::int AS fired
    FROM agent.monitor_triggers
    WHERE domain = p_domain;
$$;

REVOKE ALL ON FUNCTION core.fn_monitor_trigger_summary(text) FROM public;
