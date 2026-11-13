-- ============================================================
-- fn_list_monitor_triggers (READ)
--   Publiziertes Core-Lesefenster (SECURITY DEFINER, D10): liefert die bestehenden Trigger einer Domain
--   (label, trigger_type, status, spec_summary als kompakte Spec-Zeile) aus agent.monitor_triggers.
--   Der Advisor scannt beim Plan-Publish den Plan auf monitorbare Trigger und schlaegt nur neue vor; dafuer muss er
--   die schon registrierten lesen koennen (das create-Tool faengt exakte Label-Dubletten ohnehin via
--   unique_violation, dieses Fenster verhindert das blinde Vorschlagen und semantische Dubletten unter abweichendem Label).
--   Eine finance-/advisor-Rolle (finance_ro) darf agent.monitor_triggers nicht direkt lesen (Schema-
--   Isolation D10) -> sie liest ueber dieses Fenster (analog core.fn_monitor_trigger_summary,
--   das nur Zaehler liefert; hier braucht der Scan die Labels).
--   Eingabe: p_domain (Pflicht; read-all, keine own-Restriktion; der Career-Advisor liest mit domain='career').
--   Lesen filtert per domain; Besitz/Purge laeuft per package (zwei Schluessel) -- in der
--   Praxis ist der Advisor der einzige Writer seiner Domain, daher unkritisch.
--   Rueckgabe: Zeilen (label, trigger_type, status, spec_summary), sortiert nach label; label verbatim (der Advisor
--   braucht es zum Dedup). Enthalten sind auch disabled Trigger und abgelehnte Eintraege (status 'declined' aus
--   agent.plan_reminder_declines): beide darf der Plan-Durchlauf nicht erneut anbieten.
--   Content-Guard: spec_summary wird ausschliesslich aus den typisierten Vergleichs-Spalten gebaut
--   (acquisition_method-Enum, comparator, threshold_value, drawdown_pct, due_date), nie aus
--   acquisition_spec (freier Web-Prompt/Roh-SQL) oder action_note (freier DE-Text): sonst kaeme ein Prompt-
--   Injection-Echo samt Token-Bombe zurueck in den Advisor-Kontext.
--   EXECUTE nur an die Paket-Rollen (erteilt in core.fn_provision_package_roles, to_regprocedure-guarded).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_list_monitor_triggers(p_domain text)
RETURNS TABLE (label text, trigger_type text, status text, spec_summary text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp   -- minimal: agent.monitor_triggers ist schema-qualifiziert (CVE-2018-1058)
AS $$
    SELECT
        t.label,
        t.trigger_type,
        t.status,
        CASE t.trigger_type
            WHEN 'threshold' THEN
                format('threshold %s %s (via %s)', t.comparator, t.threshold_value, t.acquisition_method)
            WHEN 'drawdown' THEN
                format('drawdown %s%% (via %s)', t.drawdown_pct, t.acquisition_method)
            WHEN 'date' THEN
                format('date %s', t.due_date)
            WHEN 'recurring_info' THEN
                format('recurring (via %s)', t.acquisition_method)
        END AS spec_summary
    FROM agent.monitor_triggers t
    WHERE t.domain = p_domain
    UNION ALL
    SELECT d.label, 'date', 'declined', COALESCE(format('date %s', d.remind_on), 'date')
    FROM agent.plan_reminder_declines d
    WHERE d.domain = p_domain
    ORDER BY 1;
$$;

REVOKE ALL ON FUNCTION core.fn_list_monitor_triggers(text) FROM public;
