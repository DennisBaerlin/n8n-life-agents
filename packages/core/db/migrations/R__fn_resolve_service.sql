-- ============================================================
-- core.fn_resolve_service (READ-ONLY) — die EINE Pruefstelle (PDP) fuer Paket-Tool-Services (paperless Phase 2)
--   Der Core-Vermittler agent.sub_dispatch_tool (PEP) ruft Werkzeuge eines Nicht-Core-Pakets fuer FREMDE Agenten
--   (docs/package-contract.md §5 Cross-package tool services). Er fragt VOR dem Aufruf diese fn, ob er darf und
--   wohin: p jsonb {service:'<pkg>:<alias>', chat_id} ->
--     {ok:true,  workflow_id, package}
--     {ok:false, error:'unknown_service'}                                    Zeile fehlt / leere workflow_id (Bau-Drift)
--     {ok:false, error:'package_unavailable', reason, is_owner, package, package_label}  core.fn_package_status nicht ok
--     {ok:false, error:'not_permitted', reason}                              reason = unresolved_sender | <permission>
--   Reihenfolge Zeile -> Paket -> Absender. Ablehnungen sind DATEN, nie RAISE (kein Owner-Alert).
--
--   BERECHTIGUNG (core.services.permission, fail-closed DEFAULT owner_only, CHECK 3 Stufen):
--     Absender IMMER aus der chat_id re-resolvt (agent.fn_resolve_sender, RAISE-freier Cast) — nie vom LLM/Caller.
--     Unaufgeloest (nicht-numerisch/leer/unbekannt) -> unresolved_sender, FUER JEDE STUFE (Paritaet
--     core.fn_dispatch_callback: die rohe chat_id NIE an das fail-open-Primitiv geben).
--     all_members -> jedes aufgeloeste Mitglied; adults_only/owner_only -> Stufen-Logik bleibt EINE Wahrheit im
--     Primitiv agent.fn_check_write_permission (kein Rollen-Duplikat hier; der Name sagt "write", die Stufen-
--     Auswertung ist aber lese-neutral — wie beim gegateten READ-Egress estate.fn_render_emergency_binder).
--
--   ROLLENMODELL (Praezedenz core.fn_package_status / fn_dispatch_callback): SECURITY INVOKER; Aufrufer ist der
--   Vermittler ueber das Host-/RW-Credential (USAGE auf agent fuer den Re-Resolve). search_path gepinnt
--   (CVE-2018-1058), alles schema-qualifiziert. Kein Grant an Lese-/Paket-Rollen.
--   Tests: tests/db/core/test_fn_resolve_service.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_resolve_service(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_name   text := NULLIF(trim(COALESCE(p->>'service', '')), '');
    v_wid    text;
    v_pkg    text;
    v_perm   text;
    v_status jsonb;
    v_label  text;
    v_chat   bigint;
    v_sender jsonb;
    v_deny   text;
BEGIN
    -- (1) Service-Zeile
    IF v_name IS NOT NULL THEN
        SELECT s.workflow_id, s.package, s.permission INTO v_wid, v_pkg, v_perm
        FROM core.services s WHERE s.name = v_name;
    END IF;
    IF v_wid IS NULL OR v_wid = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'unknown_service', 'service', v_name);
    END IF;

    -- (2) Paket nutzbar? (eine Wahrheit: dieselbe Registry-Zeile wie agent.sub_dispatch_agent)
    v_status := core.fn_package_status(jsonb_build_object('package', v_pkg, 'chat_id', p->>'chat_id'));
    IF COALESCE((v_status->>'ok')::boolean, false) IS NOT TRUE THEN
        SELECT NULLIF(r.display_name, '') INTO v_label FROM core.package_registry r WHERE r.package = v_pkg;
        RETURN jsonb_build_object('ok', false, 'error', 'package_unavailable',
            'reason', v_status->>'reason', 'is_owner', COALESCE((v_status->>'is_owner')::boolean, false),
            'package', v_pkg, 'package_label', COALESCE(v_label, v_pkg));
    END IF;

    -- (3) Absender re-resolven (fail-closed) + Stufe pruefen
    BEGIN
        v_chat := NULLIF(trim(COALESCE(p->>'chat_id', '')), '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_permitted', 'reason', 'unresolved_sender');
    END IF;
    IF v_perm <> 'all_members' THEN
        v_deny := agent.fn_check_write_permission(v_perm, v_chat::text, NULL);
        IF v_deny IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'error', 'not_permitted', 'reason', v_deny);
        END IF;
    END IF;

    RETURN jsonb_build_object('ok', true, 'workflow_id', v_wid, 'package', v_pkg);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_resolve_service(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_resolve_service(jsonb) FROM context_ro;
    END IF;
END $$;
