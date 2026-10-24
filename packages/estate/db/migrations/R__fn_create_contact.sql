-- ============================================================
-- estate.fn_create_contact (ATOMIC WRITE — WS-2)
--   Legt einen NEUEN Schluessel-Kontakt des Ereignis-/Vorsorgefalls an (Notar, Steuerberater,
--   Anwalt, Hausarzt, Bestatter, Arbeitgeber-HR, Vermieter, Vertrauensperson). KEIN UNIQUE
--   auf role (mehrere trusted_person/physician legitim); Dubletten-Backstop (Name+Rolle)
--   faehrt das TOOL vor dem Gate (fn_resolve_contact).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, owner_person_id (Slug, ''=Haushalts-Kontakt), role, name,
--     organization, phone, email, address, notes.
--   RUECKGABE: {ok:true, contact_id} | {ok:false, reason} (korrigierbar, kein RAISE).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_create_contact.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_contact(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm TEXT;
    v_name TEXT := NULLIF(trim(COALESCE(p->>'name', '')), '');
    v_role TEXT := lower(NULLIF(trim(COALESCE(p->>'role', '')), ''));
    v_id   BIGINT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF v_name IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'name is required (non-empty).');
    END IF;
    IF v_role IS NULL OR v_role NOT IN
        ('notary', 'tax_advisor', 'lawyer', 'physician', 'undertaker', 'employer_hr', 'landlord', 'trusted_person') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid role "' || COALESCE(v_role, '') || '" — valid: notary | tax_advisor | lawyer | physician | undertaker | employer_hr | landlord | trusted_person.');
    END IF;

    INSERT INTO estate.contacts (owner_person_id, role, name, organization, phone, email, address, notes)
    VALUES (NULLIF(trim(COALESCE(p->>'owner_person_id', '')), ''), v_role, v_name,
            NULLIF(trim(COALESCE(p->>'organization', '')), ''),
            NULLIF(trim(COALESCE(p->>'phone', '')), ''),
            NULLIF(trim(COALESCE(p->>'email', '')), ''),
            NULLIF(trim(COALESCE(p->>'address', '')), ''),
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'contact_id', v_id);
END;
$$;
