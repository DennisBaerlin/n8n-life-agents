-- ============================================================
-- fn_advisor_save_section (ATOMIC WRITE — Interview-Sektion in den Draft-Plan)
--   Upsertet EINE Interview-Sektion in interview_state des Draft-Plans der Domain;
--   existiert kein Draft, wird er angelegt (version = MAX(version)+1 der Domain —
--   die DB zaehlt, nicht das LLM). Aufgerufen vom HITL-gegateten Tool
--   agent.tool_save_plan_section (domain ist dort FIXER Binding-Input, nie $fromAI).
--   P0c PERSON-SCOPE (Paritaet fn_set_context_facts): Plan-Schluessel = (domain, person_id). household-Domains
--   (finance/financial_planning) -> person_id NULL (ein Haushalts-Plan); per_user (career/career_planning,
--   core.context_scopes) -> person_id = der Sender selbst (own_user_only), aus der chat_id via fn_resolve_sender
--   (NIE LLM); unaufgeloester Sender bei per_user -> {ok:false}. Permission via fn_check_write_permission
--   (owner_only delegiert byte-gleich an fn_sender_is_member -> finance unveraendert).
--   Eingabe jsonb: domain (Pflicht — Phase B: kein 'finance'-Default mehr; ein leeres domain landete vorher
--     still im Finanzplan), chat_id (Identitaet), section_key (Pflicht, freier Text),
--     section_content (Pflicht, Markdown-Zusammenfassung der Sektion),
--     section_data (optional; jsonb-Objekt ODER JSON-String — String wird geparst),
--     plan_name (optional, nur bei Draft-Neuanlage).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, plan_id, version, status:'draft',
--     draft_created, sections, section_count} (Post-State: welche Sektionen der Draft
--     JETZT hat; draft_created = DB-entschieden).
--   Korrigierbar (fehlendes domain, leerer section_key/-content, invalides section_data-JSON)
--     -> {ok:false, reason} OHNE Write (kein RAISE -> kein Owner-Alert).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_advisor_save_section(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain  TEXT := NULLIF(trim(COALESCE(p->>'domain', '')), '');
    v_key     TEXT := trim(COALESCE(p->>'section_key', ''));
    v_content TEXT := COALESCE(p->>'section_content', '');
    v_data    JSONB;
    v_plan_id INT;
    v_version INT;
    v_created BOOLEAN := false;
    v_state   JSONB;
    v_keys    JSONB;
    -- P0c Person-Scope (Paritaet fn_set_context_facts): v_ctx = Plan-Context der Domain (core.advisors),
    -- v_scope/v_perm aus core.context_scopes; per_user -> v_pid (Sender selbst) aus der nicht-spoofbaren chat_id.
    v_ctx     TEXT;
    v_scope   TEXT;
    v_perm    TEXT;
    v_pid     TEXT;
    v_err     TEXT;
BEGIN
    IF v_domain IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'domain is required (the advisor tool binding passes it as a fixed input)');
    END IF;
    -- P0c: Plan-Context der Domain (Domain->Context-Map aus der Registry; Fallback v_domain||'_planning' fuer
    -- E2E-Sentinel-Domains ohne advisors-Zeile) -> dessen scope/write_permission steuert household vs per_user.
    v_ctx := COALESCE((SELECT plan_context FROM core.advisors WHERE domain = v_domain), v_domain || '_planning');
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm
    FROM core.context_scopes cs WHERE cs.context_name = v_ctx;
    v_scope := COALESCE(v_scope, 'household');
    v_perm  := COALESCE(v_perm, 'owner_only');

    -- per_user -> Ziel-Person == Sender (own_user_only), aus der chat_id (Numerik-Guard, NIE LLM).
    IF v_scope = 'per_user' AND p->>'chat_id' ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender((p->>'chat_id')::bigint) ->> 'person_id';
    END IF;
    -- per_user FAIL-CLOSED (das echte Gate fuer unaufgeloeste Sender, VOR Permission & Write).
    IF v_scope = 'per_user' AND v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve person for per-user plan');
    END IF;

    -- WS-5b/P0c: Schreib-Permission generisch aus der Registry (ersetzt den fn_sender_is_member-Hardcode;
    -- financial_planning->owner_only delegiert byte-gleich an fn_sender_is_member, career_planning->own_user_only).
    -- Identitaet aus der chat_id, NIE LLM. {ok:false} VOR jedem Write (RAISE-frei -> kein Owner-Alert).
    v_err := agent.fn_check_write_permission(v_perm, p->>'chat_id', v_pid);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_err);
    END IF;

    IF v_key = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'section_key must be non-empty');
    END IF;
    IF trim(v_content) = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'section_content must be non-empty');
    END IF;

    -- section_data: jsonb-Objekt direkt; JSON-String parsen (LLM-Output -> Parse-Fehler sind
    -- KORRIGIERBAR, kein RAISE)
    IF p ? 'section_data' AND jsonb_typeof(p->'section_data') IS DISTINCT FROM 'null' THEN
        IF jsonb_typeof(p->'section_data') = 'string' THEN
            BEGIN
                v_data := (p->>'section_data')::jsonb;
            EXCEPTION WHEN OTHERS THEN
                RETURN jsonb_build_object('ok', false,
                    'reason', 'section_data is not valid JSON: ' || left(p->>'section_data', 120));
            END;
        ELSE
            v_data := p->'section_data';
        END IF;
    END IF;

    -- Draft der (Domain, Person) sperren (genau einer moeglich — Partial-UNIQUE (domain, person_id)) oder anlegen.
    -- person_id IS NOT DISTINCT FROM v_pid: household (v_pid NULL) trifft die NULL-Zeilen, per_user die Person.
    SELECT id, version, interview_state INTO v_plan_id, v_version, v_state
    FROM agent.advisor_plans
    WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid AND status = 'draft'
    FOR UPDATE;

    IF NOT FOUND THEN
        SELECT COALESCE(MAX(version), 0) + 1 INTO v_version
        FROM agent.advisor_plans WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid;

        INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version)
        VALUES (
            v_domain, v_pid,
            COALESCE(NULLIF(trim(p->>'plan_name'), ''), initcap(v_domain) || ' Plan v' || v_version),
            'draft',
            v_version
        )
        RETURNING id, interview_state INTO v_plan_id, v_state;
        v_created := true;
    END IF;

    -- Sektions-Upsert (Key ueberschreiben = bewusste Korrektur des Interviews)
    v_state := jsonb_set(
        v_state, ARRAY[v_key],
        jsonb_strip_nulls(jsonb_build_object(
            'content', v_content,
            'data',    v_data,
            'saved_at', now()
        )),
        true
    );

    UPDATE agent.advisor_plans SET interview_state = v_state WHERE id = v_plan_id;

    SELECT COALESCE(jsonb_agg(k ORDER BY k), '[]'::jsonb) INTO v_keys
    FROM jsonb_object_keys(v_state) AS k;

    RETURN jsonb_build_object(
        'ok', true,
        'plan_id', v_plan_id,
        'version', v_version,
        'status', 'draft',
        'draft_created', v_created,
        'sections', v_keys,
        'section_count', jsonb_array_length(v_keys)
    );
END;
$$;
