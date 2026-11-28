-- ============================================================
-- core.fn_advisor_hint_state(p_domain) — Lage der Berater-Hinweise fuer die Paket-Leserolle (READ)
--   Lesefenster fuer den Snapshot des Pakets (INVOKER unter <pkg>_ro, sieht agent.*/core.notification_state nicht):
--     draft_open = es gibt einen frischen Haushalts-Entwurf der Domaene (core.fn_advisor_hot_since; Plan-Gespraech laeuft: nur
--                  urgent-Hinweise ansprechen; ein pausierter Entwurf haelt nichts zurueck);
--     deferred   = Hinweis-Keys mit gesetztem Merker "spaeter" (core.notification_state source advisor_hint, key
--                  '<domain>:<hint key>', nicht abgelaufen; gesetzt von core.fn_advisor_defer_hint_key).
--   Paket-Grenze wie core.fn_advisor_open_handoffs: eine Paket-Rolle liest nur Domaenen ihres Pakets, nur household.
--   Rueckgabe {draft_open: bool, deferred: [key]}. SECURITY DEFINER, STABLE, search_path gepinnt; EXECUTE an die
--   Paket-Rollen (core.fn_provision_package_roles).
--   Familie: core.fn_advisor_handoff_mentions(p_domain, p_names) -> text[]: welche der Namen in einer offenen Vormerkung
--     der Domaene vorkommen (als Teil des text oder als ganzer Stringwert im payload, ohne Gross-/Kleinschreibung); payload selbst bleibt
--     verborgen (core.fn_advisor_open_handoffs liefert ihn bewusst nicht). Dieselbe Paket-Grenze.
--   Familie: core.fn_advisor_defer_hint_key(p_domain, p_key) -> boolean: setzt den Merker (30 Tage, fn_should_notify).
--   Tests: tests/db/finance/test_fn_advisor_hints.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_hint_state(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_ctx    text;
    v_pkg    text;
    v_caller text := core.fn_session_package();
BEGIN
    SELECT a.plan_context, a.package INTO v_ctx, v_pkg FROM core.advisors a WHERE a.domain = p_domain;
    IF COALESCE((SELECT cs.scope FROM core.context_scopes cs
                  WHERE cs.context_name = COALESCE(v_ctx, p_domain || '_planning')), 'household') <> 'household'
       OR (v_caller IS NOT NULL AND v_caller IS DISTINCT FROM v_pkg) THEN
        RETURN jsonb_build_object('draft_open', false, 'deferred', '[]'::jsonb);
    END IF;
    RETURN jsonb_build_object(
        'draft_open', EXISTS (SELECT 1 FROM agent.advisor_plans ap WHERE ap.domain = p_domain AND ap.person_id IS NULL AND ap.status = 'draft'
                                AND ap.updated_at > core.fn_advisor_hot_since()),
        'deferred', COALESCE((SELECT jsonb_agg(substr(n.key, length(p_domain) + 2) ORDER BY n.key)
                                FROM core.notification_state n
                               WHERE n.source = 'advisor_hint' AND n.state = 'fired' AND left(n.key, length(p_domain) + 1) = p_domain || ':'
                                 AND (n.expires_at IS NULL OR n.expires_at > now())), '[]'::jsonb));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_hint_state(text) FROM public;

CREATE OR REPLACE FUNCTION core.fn_advisor_handoff_mentions(p_domain text, p_names text[])
RETURNS text[]
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_ctx    text;
    v_pkg    text;
    v_caller text := core.fn_session_package();
BEGIN
    SELECT a.plan_context, a.package INTO v_ctx, v_pkg FROM core.advisors a WHERE a.domain = p_domain;
    IF COALESCE((SELECT cs.scope FROM core.context_scopes cs
                  WHERE cs.context_name = COALESCE(v_ctx, p_domain || '_planning')), 'household') <> 'household'
       OR (v_caller IS NOT NULL AND v_caller IS DISTINCT FROM v_pkg) THEN
        RETURN ARRAY[]::text[];
    END IF;
    RETURN ARRAY(
        SELECT DISTINCT nm FROM unnest(p_names) AS nm
         WHERE btrim(COALESCE(nm, '')) <> ''
           AND EXISTS (SELECT 1 FROM agent.handoff_tasks h
                        WHERE h.domain = p_domain AND h.status IN ('open', 'working')
                          AND (position(lower(nm) IN lower(h.text)) > 0
                               OR EXISTS (SELECT 1 FROM jsonb_each_text(h.payload) v WHERE lower(btrim(v.value)) = lower(btrim(nm))))));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_handoff_mentions(text, text[]) FROM public;

CREATE OR REPLACE FUNCTION core.fn_advisor_defer_hint_key(p_domain text, p_key text)
RETURNS boolean
LANGUAGE plpgsql VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- Ein schon gesetzter, nicht abgelaufener Merker bleibt (fn_should_notify liefert dann false); gesetzt ist er danach immer.
    PERFORM core.fn_should_notify('advisor_hint', p_domain || ':' || p_key, interval '30 days');
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_advisor_defer_hint_key(text, text) FROM public;
