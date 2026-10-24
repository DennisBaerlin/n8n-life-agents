-- ============================================================
-- fn_package_status (READ-ONLY) — Laufzeit-Weiche des Core-Vermittlers (Install-UX-Phase 4)
--   p jsonb {package, chat_id?} -> {ok, status, reason, is_owner}
--     keine Registry-Zeile        -> {ok:false, reason:'not_installed'}
--     installing / installed      -> {ok:false, reason:'incomplete'}   (Install abgebrochen -> erneut installieren)
--     inactive                    -> {ok:false, reason:'inactive'}     (Owner hat ausgeschaltet -> activate)
--     active                      -> {ok:true}
--   is_owner = der Absender (chat_id) ist der Owner (agent.fn_resolve_sender role='owner') — der Vermittler
--   zeigt NUR dem Owner den CLI-Hinweis (`lifeagents package install|activate <pkg>`), Mitgliedern ein neutrales
--   "gerade nicht verfuegbar". Nicht-numerische/fehlende chat_id -> false (Harness-IDs 'test_…'; nie Exception).
--
--   ZWECK: der Core-Verteiler (agent.orchestrator.main_route) ruft Paket-Agenten nur noch ueber den Core-Sub
--   agent.sub_dispatch_agent (Ausdrucks-Workflow-ID -> n8n prueft bei der Aktivierung KEINE Paket-Workflows;
--   n8n 2.21.7 workflow-validation.service.ts). Diese fn entscheidet VOR dem Aufruf, ob das Paket nutzbar ist —
--   so laeuft der Core ohne jedes Paket und eine Deinstallation bricht den Bot nicht. Das Eingangs-Gate der
--   Paket-Agenten (fn_package_active) bleibt als Absicherung; beide lesen dieselbe Registry-Zeile (eine Wahrheit).
--   Aufrufer: der Vermittler ueber die Write-Credential (n8n-Owner-Rolle) -> SECURITY INVOKER, kein Grant an Lese-Rollen.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_package_status(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_pkg    text := NULLIF(trim(COALESCE(p->>'package', '')), '');
    v_chat   text := trim(COALESCE(p->>'chat_id', ''));
    v_status text;
    v_owner  boolean := false;
BEGIN
    IF v_pkg IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package_required', 'is_owner', false);
    END IF;

    IF v_chat ~ '^[0-9]{1,19}$' THEN
        v_owner := COALESCE((agent.fn_resolve_sender(v_chat::bigint)->>'role') = 'owner', false);
    END IF;

    SELECT status INTO v_status FROM core.package_registry WHERE package = v_pkg;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'status', NULL, 'reason', 'not_installed', 'is_owner', v_owner);
    END IF;
    IF v_status = 'active' THEN
        RETURN jsonb_build_object('ok', true, 'status', v_status, 'reason', NULL, 'is_owner', v_owner);
    END IF;
    RETURN jsonb_build_object('ok', false, 'status', v_status,
        'reason', CASE WHEN v_status = 'inactive' THEN 'inactive' ELSE 'incomplete' END,
        'is_owner', v_owner);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_package_status(jsonb) FROM public;
