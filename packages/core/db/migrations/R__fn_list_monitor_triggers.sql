-- ============================================================
-- fn_list_monitor_triggers (READ-ONLY, SECURITY DEFINER — publiziertes Core-Lesefenster, D10)
--   Liefert die BESTEHENDEN Trigger einer Domain (Label + Typ + Status + kompakte Spec-Zeile) aus
--   agent.monitor_triggers. ZWECK: der Advisor scannt beim Plan-Publish den Plan auf monitorbare
--   Trigger und schlaegt nur NEUE vor — dafuer muss er die schon registrierten LESEN koennen
--   (Dubletten-Bewusstsein; das create-Tool faengt exakte Label-Dubletten ohnehin via unique_violation,
--   dieses Fenster verhindert das blinde Vorschlagen + semantische Dubletten unter abweichendem Label).
--   Eine finance-/advisor-Rolle (finance_ro) darf agent.monitor_triggers NICHT direkt lesen (Schema-
--   Isolation D10) -> sie liest ueber dieses publizierte Fenster (analog core.fn_monitor_trigger_summary,
--   das nur Zaehler liefert; hier braucht der Scan die LABELS).
--
--   GENERISCH: p_domain ist Parameter (read-all, keine own-Restriktion) — der Career-Advisor liest mit
--   domain='career'. Lesen filtert per `domain`; Besitz/Purge per `package` (zwei Schluessel) — in der
--   Praxis ist der Advisor der einzige Writer seiner Domain, daher unkritisch.
--   CONTENT-GUARD: spec_summary wird AUSSCHLIESSLICH aus den TYPISIERTEN Vergleichs-Spalten gebaut
--   (acquisition_method-Enum, comparator, threshold_value, drawdown_pct, due_date) — NIE aus
--   acquisition_spec (freier Web-Prompt/Roh-SQL) oder action_note (freier DE-Text): sonst Prompt-
--   Injection-Echo + Token-Bombe zurueck in den Advisor-Kontext. label wird verbatim zurueckgegeben
--   (der Advisor braucht es zum Dedup). Nur status IN ('armed','fired') — disabled ist fuer Dedup irrelevant.
--
--   SECURITY DEFINER + gepinnter search_path (CVE-2018-1058) + REVOKE ALL FROM PUBLIC + EXECUTE nur an
--   die Paket-Rollen (erteilt in core.fn_provision_package_roles, to_regprocedure-guarded). READ-ONLY.
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
      AND t.status IN ('armed', 'fired')
    ORDER BY t.label;
$$;

REVOKE ALL ON FUNCTION core.fn_list_monitor_triggers(text) FROM public;
