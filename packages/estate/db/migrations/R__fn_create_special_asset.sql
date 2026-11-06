-- ============================================================
-- estate.fn_create_special_asset (ATOMIC WRITE — WS-2)
--   Legt einen NEUEN Sonderfall-Stub an (Owner-Entscheid 7: erkennen + ehrlich verweisen).
--   Geschlossene asset_type-Liste OHNE 'other' (jeder Typ mappt auf eine WS-3-Checklisten-
--   Condition — ein offener Typ loeste still nichts aus; Tabellen-CHECK ist das Gesetz).
--   Dubletten-Backstop (Beschreibung) faehrt das TOOL vor dem Gate (fn_resolve_special_asset).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, owner_person_id (Slug, ''=Haushalt),
--     asset_type (vehicle|business_interest|firearm|pet), description, notes.
--   RUECKGABE: {ok:true, special_asset_id} | {ok:false, reason} (korrigierbar, kein RAISE).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_create_special_asset.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_special_asset(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm TEXT;
    v_type TEXT := lower(NULLIF(trim(COALESCE(p->>'asset_type', '')), ''));
    v_desc TEXT := NULLIF(trim(COALESCE(p->>'description', '')), '');
    v_id   BIGINT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF v_desc IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'description is required (non-empty).');
    END IF;
    IF v_type IS NULL OR v_type NOT IN ('vehicle', 'business_interest', 'firearm', 'pet') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid asset_type "' || COALESCE(v_type, '') || '" — valid: vehicle | business_interest | firearm | pet (deliberately no other: each type maps to an event-checklist condition).');
    END IF;

    INSERT INTO estate.special_assets (owner_person_id, asset_type, description, notes)
    VALUES (NULLIF(trim(COALESCE(p->>'owner_person_id', '')), ''), v_type, v_desc,
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'special_asset_id', v_id);
END;
$$;
