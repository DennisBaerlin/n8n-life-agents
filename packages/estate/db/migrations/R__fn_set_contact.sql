-- ============================================================
-- estate.fn_set_contact (ATOMIC WRITE — WS-2, partielles UPDATE)
--   Aendert einen bestehenden Schluessel-Kontakt ("nicht gesendet = unveraendert").
--   Die ID loest das TOOL vor dem Gate via estate.fn_resolve_contact auf; not-found hier =
--   echte Ausnahme (RAISE).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, contact_id, new_name, new_role, organization, phone, email,
--     address, notes.
--   RUECKGABE: {ok:true, contact_id} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_contact.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_contact(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm TEXT;
    v_id   BIGINT := (p->>'contact_id')::bigint;
    v_role TEXT := lower(NULLIF(trim(COALESCE(p->>'new_role', '')), ''));
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM estate.contacts WHERE id = v_id) THEN
        RAISE EXCEPTION 'Contact % not found.', v_id;
    END IF;
    IF v_role IS NOT NULL AND v_role NOT IN
        ('notary', 'tax_advisor', 'lawyer', 'physician', 'undertaker', 'employer_hr', 'landlord', 'trusted_person') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid new_role "' || v_role || '" — valid: notary | tax_advisor | lawyer | physician | undertaker | employer_hr | landlord | trusted_person.');
    END IF;

    UPDATE estate.contacts SET
        name         = COALESCE(NULLIF(trim(COALESCE(p->>'new_name', '')), ''), name),
        role         = COALESCE(v_role, role),
        organization = COALESCE(NULLIF(trim(COALESCE(p->>'organization', '')), ''), organization),
        phone        = COALESCE(NULLIF(trim(COALESCE(p->>'phone', '')), ''), phone),
        email        = COALESCE(NULLIF(trim(COALESCE(p->>'email', '')), ''), email),
        address      = COALESCE(NULLIF(trim(COALESCE(p->>'address', '')), ''), address),
        notes        = COALESCE(NULLIF(trim(COALESCE(p->>'notes', '')), ''), notes)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'contact_id', v_id);
END;
$$;
