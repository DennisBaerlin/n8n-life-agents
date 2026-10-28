-- ============================================================
-- core.fn_advisor_plan_status(p_chat_id) — Plan-Zustand je Berater-Domaene fuer den Onboarding-Plan-Schritt (2026-10-28)
--   Die EINE Adresse fuer "welcher Plan-Schritt, in welchem Zustand, darf ich, reichen die Daten": gelesen vom
--   Menue-Sub core.sub_send_onboarding_menu (Fertig-Karte, Bereichsansicht, Uebersicht; unter core_ro) und von
--   core.fn_handle_plan_cb (Knopf plan:<domain>). Bewusst NICHT in core.fn_onboarding_overview: deren weitere Aufrufer
--   (fn_onboarding_progress_event, fn_onboarding_nudges_due) brauchen nur die Abschnitte und sollen weder die Paket-
--   fns bezahlen noch an ihnen scheitern (Code-Review 2026-10-28).
--   Je core.advisors-Zeile mit plan_step=true, deren Paket aktiv ist (core.package_registry):
--     state   draft    -> ein Entwurf liegt vor ("fortsetzen"; hat Vorrang vor einem aktiven Plan)
--             gaps     -> aktiver Plan, gaps_fn meldet > 0 offene Punkte ("vervollstaendigen (n offen)")
--             complete -> aktiver Plan ohne offene Punkte (ohne gaps_fn: jeder aktive Plan) ("ueberpruefen")
--             none     -> weder Entwurf noch aktiver Plan ("erstellen")
--     open      = gaps_fn-Ergebnis (0 ausser bei gaps)
--     ready/missing = readiness_fn {ready, missing:[{key, section}]} (ohne readiness_fn: reif, [])
--     per_user  = core.context_scopes.scope des plan_context = 'per_user' (sonst Haushalt)
--     can_write = der Betrachter ist der Owner: die Plan-Schreib-Tools (agent.tool_save_plan_section /
--                 tool_publish_plan) sind approval_matrix-Stufe owner_only (Owner-Vorgabe 6: Mitglieder beraten, Plaene
--                 aendert nur der Owner). Die write_permission des plan_context (owner_only/own_user_only) laesst den
--                 Owner fuer seinen Scope immer zu -> sie aendert das Ergebnis heute nicht. Wird die Tool-Stufe je
--                 gelockert, gehoert hier die write_permission-Regel von agent.fn_check_write_permission hin.
--   Scope der Plan-Zeile wie core.fn_advisor_read_plan: household -> person_id NULL, per_user -> der Betrachter.
--   Betrachter = agent.fn_resolve_sender(p_chat_id) (nie LLM); unaufgeloest/nicht numerisch -> [] (fail-closed).
--   gaps_fn/readiness_fn nur aus der installer-geschriebenen Registry (CHECK-Format), Arity per to_regprocedure
--   (text,text) geprueft, Name per format(%s) aus dem regproc (kein Caller-Text im EXECUTE). Fehlt eine fn
--   (Manifest-Typo/Apply-Order) ODER wirft sie -> neutral (0 Luecken bzw. reif) statt Fehler: Menue und Knopf-Handler
--   ("nie RAISE") duerfen an einem Paket-Fehler nicht brechen; die Paket-fn ist dann im eigenen db_test rot.
--   RUECKGABE jsonb-Array [{domain, package, state, open, ready, missing, per_user, can_write}] ORDER BY domain.
--   SECURITY DEFINER (owned by der DDL-Cred): liest agent.advisor_plans (RLS), core.* und ruft die Paket-fns; EXECUTE
--   nur core_ro (Menue-Read, Grant in util_create_core_ro.sql) + die Host-Cred (Knopf-Handler). STABLE, search_path
--   gepinnt, Body schema-qualifiziert. LANGUAGE plpgsql: ruft alphabetisch spaetere R__-fns -> late-bound.
--   Tests: tests/db/core/test_fn_advisor_plan_status.sql, tests/db/cross/test_role_permissions.sql (core_ro)
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_plan_status(p_chat_id text)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_sender  jsonb;
    v_pid     text;
    v_role    text;
    r         record;
    v_scope   text;
    v_target  text;
    v_draft   boolean;
    v_active  boolean;
    v_open    int;
    v_ready   jsonb;
    v_fn      regprocedure;
    v_state   text;
    v_out     jsonb := '[]'::jsonb;
BEGIN
    IF p_chat_id IS NULL OR p_chat_id !~ '^[0-9]{1,18}$' THEN
        RETURN v_out;
    END IF;
    v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN v_out;
    END IF;
    v_pid  := v_sender->>'person_id';
    v_role := v_sender->>'role';

    FOR r IN
        SELECT a.domain, a.package, a.plan_context, a.gaps_fn, a.readiness_fn
        FROM core.advisors a
        JOIN core.package_registry pr ON pr.package = a.package AND pr.status = 'active'
        WHERE a.plan_step
        ORDER BY a.domain
    LOOP
        v_scope  := COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = r.plan_context), 'household');
        v_target := CASE WHEN v_scope = 'per_user' THEN v_pid END;

        SELECT bool_or(ap.status = 'draft'), bool_or(ap.status = 'active') INTO v_draft, v_active
        FROM agent.advisor_plans ap
        WHERE ap.domain = r.domain AND ap.person_id IS NOT DISTINCT FROM v_target AND ap.status IN ('draft', 'active');

        v_open := 0;
        IF COALESCE(v_active, false) AND NOT COALESCE(v_draft, false) AND r.gaps_fn IS NOT NULL THEN
            v_fn := to_regprocedure(r.gaps_fn || '(text,text)');
            IF v_fn IS NOT NULL THEN
                BEGIN
                    EXECUTE format('SELECT %s($1, $2)', v_fn::regproc) INTO v_open USING r.domain, v_target;
                EXCEPTION WHEN OTHERS THEN
                    v_open := 0;
                END;
            END IF;
        END IF;
        v_state := CASE WHEN COALESCE(v_draft, false) THEN 'draft'
                        WHEN COALESCE(v_active, false) AND COALESCE(v_open, 0) > 0 THEN 'gaps'
                        WHEN COALESCE(v_active, false) THEN 'complete'
                        ELSE 'none' END;

        v_ready := NULL;
        IF r.readiness_fn IS NOT NULL THEN
            v_fn := to_regprocedure(r.readiness_fn || '(text,text)');
            IF v_fn IS NOT NULL THEN
                BEGIN
                    EXECUTE format('SELECT %s($1, $2)', v_fn::regproc) INTO v_ready USING r.domain, v_target;
                EXCEPTION WHEN OTHERS THEN
                    v_ready := NULL;
                END;
            END IF;
        END IF;

        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'domain',    r.domain,
            'package',   r.package,
            'state',     v_state,
            'open',      CASE WHEN v_state = 'gaps' THEN v_open ELSE 0 END,
            'ready',     COALESCE((v_ready->>'ready')::boolean, true),
            'missing',   CASE WHEN jsonb_typeof(v_ready->'missing') = 'array' THEN v_ready->'missing' ELSE '[]'::jsonb END,
            'per_user',  v_scope = 'per_user',
            'can_write', v_role IS NOT DISTINCT FROM 'owner'));
    END LOOP;
    RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_plan_status(text) FROM public;
-- EXECUTE fuer core_ro (Menue-Read) erteilt packages/core/db/util/util_create_core_ro.sql (am Rollen-Ort, nach dieser R__).
