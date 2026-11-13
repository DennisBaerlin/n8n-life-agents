-- ============================================================
-- fn_check_write_permission (READ, Authz-Praedikat)
--   Generische Durchsetzung der core.context_scopes-write_permission-Achse: gibt ein positives Verdikt als
--   Grund-Text zurueck (NULL = erlaubt; sonst der write_permission-Token), Vertrag wie fn_validate_* (NULL=ok).
--   Identitaet immer aus der deterministischen, nicht-spoofbaren chat_id via agent.fn_resolve_sender, nie aus
--   LLM-Werten. Gerufen von den fn-Guards (agent.fn_set_context_facts, Plan-Write-fns); der owner_only-Zweig
--   delegiert an fn_sender_is_member (kein Duplikat-Code).
--   Eingabe: p_write_permission, p_chat_id (Telegram-chat, text), p_target_person_id (nur fuer own_user_only).
--
--   Stufen (p_write_permission):
--     owner_only     -> nur role=owner. Delegiert an agent.fn_sender_is_member (TRUE = positiv aufgeloester
--                       Nicht-Owner -> ablehnen). Nicht-numerisch / unresolved / owner -> erlaubt (Pass-Through).
--     adults_only    -> role in {owner, partner}. Nur auf dem aufgeloesten Pfad geprueft.
--     own_user_only  -> aufgeloeste Person == p_target_person_id (setzt per_user voraus, Registry-CHECK).
--                       Nur auf dem aufgeloesten Pfad; p_target_person_id IS NULL -> ablehnen (ohne Ziel nicht
--                       verifizierbar = hier fail-closed).
--
--   Pass-Through (bewusst, Sentinel/Bootstrap-Paritaet mit fn_sender_is_member): nicht-numerische /
--     leere / NULL chat_id -> NULL (erlaubt); der Resolver wird nie mit ::bigint gerufen (E2E-Sentinel/Test);
--     numerisch aber found=false (nicht in family, anomal/Bootstrap) -> NULL (erlaubt). Diese Faelle laufen
--     vor der Stufen-Pruefung durch, auch own_user_only ist hier fail-open. Die echte Absicherung
--     unaufgeloester Sender bei per_user leisten die Aufrufer: person_id kommt aus fn_resolve_sender
--     (nie $fromAI), unaufgeloest -> {ok:false} vor diesem Aufruf.
--
--   search_path nicht gepinnt: Paritaet zu fn_sender_is_member / fn_resolve_sender (keines pinnt; fahren auf
--     dem Rollen-Default). Alle internen Aufrufe sind schema-qualifiziert (agent.fn_*) -> CVE-2018-1058-sicher.
--   Rueckgabe: NULL (erlaubt) | write_permission-Token (abgelehnt) | 'unknown_write_permission' (Fremd-Token;
--     der core.context_scopes-CHECK verhindert das strukturell; fail-closed-Backstop).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_check_write_permission(
    p_write_permission text,
    p_chat_id          text,
    p_target_person_id text
) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_sender JSONB;
    v_role   TEXT;
    v_pid    TEXT;
BEGIN
    -- owner_only: fn_sender_is_member ist die Quelle der Wahrheit (Pass-Through inklusive).
    IF p_write_permission = 'owner_only' THEN
        RETURN CASE WHEN agent.fn_sender_is_member(p_chat_id) THEN 'owner_only' ELSE NULL END;
    END IF;

    IF p_write_permission NOT IN ('adults_only', 'own_user_only') THEN
        RETURN 'unknown_write_permission';   -- Fremd-Token (Registry-CHECK verhindert das strukturell)
    END IF;

    -- adults_only / own_user_only: eigener Resolve-Zweig. Numerik-Guard vor dem ::bigint-Cast (wie
    -- fn_sender_is_member): nicht-numerisch/leer/NULL = Test/Sentinel/Bootstrap -> durchlassen (kein Wurf).
    IF p_chat_id IS NULL OR p_chat_id !~ '^[0-9]+$' THEN
        RETURN NULL;
    END IF;
    v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN NULL;   -- nicht in family (anomal/Bootstrap) -> durchlassen, wie bei owner_only
    END IF;
    v_role := v_sender->>'role';
    v_pid  := v_sender->>'person_id';

    IF p_write_permission = 'adults_only' THEN
        RETURN CASE WHEN v_role IN ('owner', 'partner') THEN NULL ELSE 'adults_only' END;
    END IF;

    -- own_user_only: kein Ziel -> nicht verifizierbar (fail-closed); sonst aufgeloeste Person == Ziel.
    IF p_target_person_id IS NULL THEN
        RETURN 'own_user_only';
    END IF;
    RETURN CASE WHEN v_pid IS NOT DISTINCT FROM p_target_person_id THEN NULL ELSE 'own_user_only' END;
END;
$$;

-- ============================================================
-- core.fn_check_write_permission (publiziertes SECURITY-DEFINER-Fenster auf das agent-Primitiv oben)
--   Die Write-fns der Paket-Rollen (z. B. estate_rw, wie finance_rw) laufen unter der engen Rolle und
--   muessen den adults_only-DB-Backstop pruefen; agent.fn_check_write_permission
--   liest via fn_resolve_sender das Schema agent, das die engen <pkg>_rw-Rollen nicht
--   sehen ('permission denied for schema agent'). Cross-Schema-Read-Regel (.claude/rules/sql.md):
--   so eine fn muss als publiziertes DEFINER-Fenster nach core. Generisch (kein Paket-Literal):
--   EXECUTE grantet core.fn_provision_package_roles an jede <pkg>_rw. Reiner Delegat; die
--   Stufen-/Pass-Through-Logik lebt ausschliesslich im agent-Primitiv oben.
--   Beide fns in dieser Datei (bewusste Ausnahme von "eine Repeatable pro Function"): gleicher
--   Name, ein Konzern (Primitiv + Fenster), aendern sich nur zusammen.
--   DEFINER-Hygiene: search_path gepinnt (CVE-2018-1058), Body schema-qualifiziert,
--   REVOKE ALL FROM PUBLIC (Grants zentral in fn_provision_package_roles), kein dyn. EXECUTE.
--   Rueckgabe: identisch zum Primitiv — NULL (erlaubt) | write_permission-Token (abgelehnt).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_check_write_permission(
    p_write_permission text,
    p_chat_id          text,
    p_target_person_id text
) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
    SELECT agent.fn_check_write_permission(p_write_permission, p_chat_id, p_target_person_id);
$$;

REVOKE ALL ON FUNCTION core.fn_check_write_permission(text, text, text) FROM public;
