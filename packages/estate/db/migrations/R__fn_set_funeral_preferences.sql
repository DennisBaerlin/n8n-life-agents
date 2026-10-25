-- ============================================================
-- estate.fn_set_funeral_preferences (ATOMIC UPSERT — WS-2, 1 Zeile je Person)
--   Erfasst/aendert die Bestattungswuensche EINER Person (PK person_id -> set_-Semantik mit
--   UPSERT wie fn_set_person_record; partielles Update). person_id loest das TOOL vor dem
--   Gate via core.fn_resolve_person auf (Pflicht-Input).
--   has_prepaid_contract ist TRI-STATE (NULL = unbekannt): nur ein explizit gesendeter
--   true/false-Wert aendert ihn (tolerant geparst, kein Cast-RAISE). WP3: ein genannter Anbieter setzt ihn auf true
--   (DB leitet ab, der Agent fragt nicht), false leert den Anbieter; beides zugleich widerspricht sich -> {ok:false}.
--   CHECK funeral_preferences_provider_implies_contract ist der Backstop.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, person_id (Slug, Pflicht), burial_type (erdbestattung|
--     feuerbestattung|seebestattung|baumbestattung|sonstige), has_prepaid_contract,
--     prepaid_contract_provider, wishes.
--   RUECKGABE: {ok:true, person_id, created, has_prepaid_contract (Post-State)} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_funeral_preferences.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_funeral_preferences(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm     TEXT;
    v_person   TEXT := NULLIF(trim(COALESCE(p->>'person_id', '')), '');
    v_burial   TEXT := lower(NULLIF(trim(COALESCE(p->>'burial_type', '')), ''));
    v_pre_raw  TEXT := lower(NULLIF(trim(COALESCE(p->>'has_prepaid_contract', '')), ''));
    v_prepaid  BOOLEAN;
    v_provider TEXT := NULLIF(trim(COALESCE(p->>'prepaid_contract_provider', '')), '');
    v_created  BOOLEAN;
    v_post     BOOLEAN;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF v_person IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'person_id is required (resolve the household member first).');
    END IF;
    -- KEIN expliziter agent.persons-Read (SECURITY INVOKER unter estate_rw ohne agent-USAGE, D10):
    -- die FK person_id -> agent.persons(person_id) ist der Backstop (RI-Check intern, kein Grant noetig),
    -- der Tool-Resolve ist der Guard. Siehe fn_set_person_record fuer die volle Begruendung.

    IF v_burial IS NOT NULL AND v_burial NOT IN
        ('erdbestattung', 'feuerbestattung', 'seebestattung', 'baumbestattung', 'sonstige') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid burial_type "' || v_burial || '" — valid: erdbestattung | feuerbestattung | seebestattung | baumbestattung | sonstige.');
    END IF;
    IF v_pre_raw IS NOT NULL THEN
        v_prepaid := CASE WHEN v_pre_raw IN ('true', 'yes', '1', 'ja') THEN TRUE
                          WHEN v_pre_raw IN ('false', 'no', '0', 'nein') THEN FALSE
                          ELSE NULL END;
        IF v_prepaid IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'invalid has_prepaid_contract "' || v_pre_raw || '" — use true or false (omit = unknown).');
        END IF;
    END IF;

    -- WP3: ein genannter Anbieter HEISST Vorsorgevertrag vorhanden (nicht fragen); 'kein Vertrag' + Anbieter widerspricht sich.
    IF v_provider IS NOT NULL AND v_prepaid IS FALSE THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'has_prepaid_contract=false contradicts a prepaid_contract_provider — send one of them.');
    END IF;
    IF v_provider IS NOT NULL THEN
        v_prepaid := TRUE;
    END IF;

    v_created := NOT EXISTS (SELECT 1 FROM estate.funeral_preferences f WHERE f.person_id = v_person);

    INSERT INTO estate.funeral_preferences (person_id, burial_type, has_prepaid_contract,
                                            prepaid_contract_provider, wishes)
    VALUES (v_person, v_burial, v_prepaid,
            v_provider,
            NULLIF(trim(COALESCE(p->>'wishes', '')), ''))
    ON CONFLICT (person_id) DO UPDATE SET
        burial_type               = COALESCE(EXCLUDED.burial_type, estate.funeral_preferences.burial_type),
        -- Tri-State: nur ein explizit gesendeter Wert aendert (EXCLUDED NULL = unveraendert):
        has_prepaid_contract      = COALESCE(EXCLUDED.has_prepaid_contract, estate.funeral_preferences.has_prepaid_contract),
        -- 'kein Vertrag' leert den Anbieter (CHECK funeral_preferences_provider_implies_contract)
        prepaid_contract_provider = CASE WHEN EXCLUDED.has_prepaid_contract IS FALSE THEN NULL
                                         ELSE COALESCE(EXCLUDED.prepaid_contract_provider, estate.funeral_preferences.prepaid_contract_provider) END,
        wishes                    = COALESCE(EXCLUDED.wishes, estate.funeral_preferences.wishes);

    SELECT has_prepaid_contract INTO v_post FROM estate.funeral_preferences WHERE person_id = v_person;
    RETURN jsonb_build_object('ok', true, 'person_id', v_person, 'created', v_created, 'has_prepaid_contract', v_post);
END;
$$;
