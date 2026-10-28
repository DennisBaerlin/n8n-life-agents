-- ============================================================
-- agent.fn_record_plan_wish(p) (ATOMIC WRITE — "Wunsch an den Owner" zu einem Haushalts-Plan, 2026-10-28)
--   Ein erwachsenes Mitglied (Rolle partner) haelt einen Aenderungswunsch zum AKTIVEN Haushalts-Plan der Domain fest
--   (core.fn_household_plan_active). Der Wunsch aendert den Plan nicht — der Owner entscheidet; er bekommt den Wortlaut
--   ueber die HITL-Stufe owner_info des Tools agent.tool_record_plan_wish (Mitglied bestaetigt, Owner-Info in seiner
--   Sprache). Wortlaut in Originalsprache, nur getrimmt (nie uebersetzt), plan_id = aktive Version (Provenienz).
--   p: { domain (fixer Binding-Input, nie LLM), chat_id (Identitaet, build-fix), wish_text (Pflicht, <= 2000 Zeichen) }
--   Probelauf vor der Karte ueber das generische core.fn_dry_run (New-FnWriteGate, immer zurueckgerollt).
--   RUECKGABE: Erfolg -> {ok:true, wish_id, plan_id, plan_version}; korrigierbar (kein aktiver Plan, kein Partner/unbekannt, leer, zu lang) -> {ok:false, reason} OHNE
--     Write (kein RAISE -> kein Owner-Alert). CHECK am Tabellen-Wortlaut als Backstop.
--   Tests: tests/db/core/test_fn_record_plan_wish.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_record_plan_wish(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_domain text := COALESCE(p->>'domain', '');
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_text   text := btrim(COALESCE(p->>'wish_text', ''));
    v_sender jsonb;
    v_plan   record;
    v_id     int;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(v_chat::bigint);
    END IF;
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE OR (v_sender->>'role') IS DISTINCT FROM 'partner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'only an adult household member (partner) can send a plan wish to the owner');
    END IF;
    SELECT * INTO v_plan FROM core.fn_household_plan_active(v_domain);
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'there is no published household plan for this domain');
    END IF;
    IF v_text = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'wish_text must be non-empty');
    END IF;
    IF length(v_text) > 2000 THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('wish_text is too long (%s characters, at most 2000)', length(v_text)));
    END IF;
    INSERT INTO agent.advisor_plan_wishes (plan_id, person_id, wish_text)
    VALUES (v_plan.plan_id, v_sender->>'person_id', v_text)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'wish_id', v_id, 'plan_id', v_plan.plan_id, 'plan_version', v_plan.version);
END;
$$;
