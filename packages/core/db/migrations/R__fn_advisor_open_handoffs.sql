-- ============================================================
-- core.fn_advisor_open_handoffs(p_domain) — vereinbarte Plan-Aufgaben, die noch nicht eingetragen sind, fuer den Berater
--   Lesefenster der engen Paket-Leserolle auf agent.handoff_tasks (finance_ro sieht agent.* nicht): finance.fn_advisor_snapshot
--   traegt es als open_handoffs, damit der Berater vor einem Loesungsvorschlag zu einer Warnung sieht, was schon vereinbart
--   ist. Eingabe p_domain (Plan-Domain). Rueckgabe jsonb-Array [{kind, text, topic, section_key, status, open_since}] in
--   Anlage-Reihenfolge, hoechstens 50; status open = wartet auf [Jetzt eintragen], working = per [Jetzt eintragen] gerade beansprucht
--   (auch ein abgelaufener Claim: eingetragen ist es erst bei done); deferred = zurueckgestellt, weil es technisch noch nicht
--   eintragbar ist (der Berater schlaegt es nicht neu vor); open_since = Anlagetag (core.fn_today). Kein payload,
--   keine Person, keine id: der Berater braucht nur den Inhalt; das Eintragen laeuft ueber tool_send_handoff_overview.
--   Leer ([]) bei per_user-Plan-Kontext (der Snapshot kennt keinen Absender, fail-closed wie core.fn_advisor_read_plan in
--   einer Frei-SQL-Sitzung) und wenn die Login-Rolle eine Paket-Rolle eines anderen Pakets ist als das der Domain
--   (core.advisors.package; career_ro liest keine finance-Vormerkungen). Nur lesend.
--   SECURITY DEFINER, EXECUTE an <pkg>_ro/_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_advisor_open_handoffs.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_open_handoffs(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
-- plpgsql: core.fn_today liegt alphabetisch spaeter (R__fn_today), eine sql-fn pruefte den Body schon beim CREATE.
DECLARE
    v_ctx    text;
    v_pkg    text;
    v_caller text := core.fn_session_package();
BEGIN
    SELECT a.plan_context, a.package INTO v_ctx, v_pkg FROM core.advisors a WHERE a.domain = p_domain;
    IF COALESCE((SELECT cs.scope FROM core.context_scopes cs
                  WHERE cs.context_name = COALESCE(v_ctx, p_domain || '_planning')), 'household') <> 'household'
       OR (v_caller IS NOT NULL AND v_caller IS DISTINCT FROM v_pkg) THEN
        RETURN '[]'::jsonb;
    END IF;
    RETURN (SELECT COALESCE(jsonb_agg(jsonb_build_object('kind', t.kind, 'text', t.text, 'topic', t.topic,
                                                         'section_key', t.section_key, 'status', t.status,
                                                         'open_since', core.fn_today(t.created_at)) ORDER BY t.id), '[]'::jsonb)
              FROM (SELECT * FROM agent.handoff_tasks h
                     WHERE h.domain = p_domain AND h.status IN ('open', 'working', 'deferred')
                     ORDER BY h.id LIMIT 50) t);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_open_handoffs(text) FROM public;
