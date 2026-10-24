-- ============================================================
-- core.fn_dispatch_callback (Phase 0 WS-0c CB — generischer Callback-Prefix-Dispatcher)
--   Der EINE generische Eintrittspunkt fuer NEUE Einzel-fn-Callback-Prefixes: schlaegt das callback_data-
--   Prefix (Teil vor dem ersten ":") in core.callback_handlers nach und fuehrt die Paket-Handler-fn dynamisch
--   aus. Verdrahtet an der bisher toten 'extra'-Fallback-Ausgabe des Orchestrator-'Callback action'-Switch
--   (die 9 hartkodierten Multi-Node-Arme bleiben unveraendert; nur unbekannte/registrierte Prefixes landen hier).
--
--   ROLLENMODELL (Praezedenz fn_advisor_review_evaluate / fn_monitor_evaluate): SECURITY INVOKER. Der
--   Orchestrator ruft sie unter dem RW/Host-Credential (N8N_DB_USER), das per _emit_pkg_owner_grants EXECUTE
--   auf <pkg>.* UND USAGE auf agent (fuer den Sender-Re-Resolve) hat. SET search_path=pg_catalog (CVE-2018-1058)
--   + to_regprocedure-Arity-Guard auf die installer-geschriebene handler_fn (nie $fromAI).
--
--   (Mitglieder-Onboarding: der Prefix onboarding ist zugleich hartkodierter Owner-Arm UND Registry-Handler
--    core.fn_handle_onboarding_cb mit member_permeable — Mitglieder kommen nur hierher; contract_lint 9.)
--   MEMBER-CALLBACK-GATE (DB-ist-Gesetz, der EINE Callback-PEP/PDP): der Orchestrator routet seit der
--   Member-Permeabilitaet AUCH aufgeloeste Nicht-Owner-Mitglieder hierher (prefix-agnostisch). Dieser
--   Dispatcher entscheidet FAIL-CLOSED, unabhaengig + ohne einem Caller-Flag zu trauen (Zero-Trust): er
--   RE-RESOLVT den Sender selbst aus p->>'chat_id' (agent.fn_resolve_sender, RAISE-freier Cast) und laesst
--   VOR jedem EXECUTE nur durch:
--     (a) Sender NICHT aufgeloest (found=false)         -> {ok:false, unresolved_sender}   (schliesst das
--         fn_check_write_permission-Fail-Open am tiefsten geteilten Punkt — die rohe chat_id NIE an das
--         fail-open-Primitiv geben);
--     (b) aufgeloest ∧ role<>'owner' ∧ NOT member_permeable -> {ok:false, owner_only_callback};
--     (c) owner  ODER  (member_permeable ∧ aufgeloest)  -> Handler EXECUTE (die FEINE Autorisierung —
--         est=adults_only, job=Per-Item-Eigentum — liegt IM Handler, nicht hier).
--   member_permeable ist FAIL-CLOSED (core.callback_handlers.member_permeable DEFAULT false): ein
--   ungeseedeter/neuer Prefix bleibt owner-only. Nutzt bewusst NICHT fn_check_write_permission (kein Enum;
--   dies IST der eine Callback-Gate, kein verstreutes Duplikat).
--
--   p: das volle Callback-Payload { data:<callback_data>, chat_id, callback_id, ... }. Prefix = split_part(data,':',1).
--   Die Handler-fn(jsonb)->jsonb bekommt dasselbe p und gibt { ok, toast?, message? } zurueck.
--   RUECKGABE: das Handler-Ergebnis (Passthrough) | {ok:false, reason[, toast]} bei leerem/unbekanntem Prefix,
--   fehlender Handler-fn, unaufgeloestem Sender oder owner-only-Callback (kein RAISE -> kein Owner-Alert; der
--   Orchestrator quittiert generisch mit result.toast || Fallback). Die Gate-Toasts kommen aus dem Textkatalog
--   (core.toast.*) in der Sprache des Tippenden; jeder Handler liefert seinen Toast genauso (Muster
--   agent.fn_set_person_language).
--   Tests: tests/db/core/test_fn_dispatch_callback.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_dispatch_callback(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_prefix   text := split_part(COALESCE(p->>'data', ''), ':', 1);
    v_fn       text;
    v_perm     boolean;
    v_chat     bigint;
    v_sender   jsonb;
    v_result   jsonb;
BEGIN
    IF v_prefix = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'empty callback prefix (no data)');
    END IF;
    -- Registry-Lookup (handler_fn + member_permeable in EINEM SELECT)
    SELECT handler_fn, member_permeable INTO v_fn, v_perm FROM core.callback_handlers WHERE prefix = v_prefix;
    IF v_fn IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_callback_prefix', 'prefix', v_prefix);
    END IF;

    -- MEMBER-GATE (Auth VOR Handler-Existenz + EXECUTE): Sender unabhaengig re-resolven. chat_id RAISE-frei
    -- casten (der Dispatcher darf NIE RAISE-en; Muster R__fn_handle_job_feedback.sql) — leere/nicht-numerische
    -- chat_id -> NULL -> fn_resolve_sender(NULL) -> found:false -> unresolved_sender.
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_sender := agent.fn_resolve_sender(v_chat);
    -- Toasts des Gates in der Sprache des Tippenden (unaufgeloest -> Owner-Sprache; Textkatalog §3.11).
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unresolved_sender',
            'toast', core.fn_ui_text('core.toast.unresolved_sender', agent.fn_person_lang(NULL)->>'lang'));
    END IF;
    IF (v_sender->>'role') IS DISTINCT FROM 'owner' AND COALESCE(v_perm, false) IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only_callback',
            'toast', core.fn_ui_text('core.toast.owner_only', agent.fn_person_lang(v_sender->>'person_id')->>'lang'));
    END IF;

    IF to_regprocedure(v_fn || '(jsonb)') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'handler_fn_missing', 'prefix', v_prefix);
    END IF;
    -- Paket-Handler-fn dynamisch ausfuehren (handler_fn ist installer-kontrolliert + schema-qualifiziert).
    -- Die feine Autorisierung (adults_only / Per-Item-Eigentum) macht der Handler selbst.
    EXECUTE format('SELECT %s($1)', v_fn) INTO v_result USING p;
    RETURN COALESCE(v_result, jsonb_build_object('ok', false, 'reason', 'handler_returned_null', 'prefix', v_prefix));
END;
$$;

REVOKE ALL ON FUNCTION core.fn_dispatch_callback(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_dispatch_callback(JSONB) FROM context_ro;
    END IF;
END $$;
