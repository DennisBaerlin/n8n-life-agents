-- ============================================================
-- estate.fn_set_system_profile (ATOMIC UPSERT — Haushalts-Singleton)
--   Erfasst/aendert den System-Steckbrief + den Fundort der Offline-Kopie des core.backup_key.
--   Geheimnisse nie — nur Fundort-Verweise (die Tool-Description + Instructions
--   tragen "nur Verweis, nie das Geheimnis"; strukturell nicht erzwingbar).
--   Singleton (scope='household', CHECK-fixiert): genau 0/1 Zeile -> set_-Semantik via UPSERT auf den
--   festen Schluessel; partielles Update "nicht gesendet = unveraendert".
--   Einfacher als fn_set_person_record: kein person_id/-Resolve, kein agent.*-Read (die
--   fn beruehrt nur estate.system_profile + das core.fn_check_write_permission-DEFINER-Fenster).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false} ohne Write.
--   Eingabe jsonb: chat_id, backup_key_location, system_location, admin_access, restore_hint, notes.
--   Rueckgabe: {ok:true, created} | {ok:false, reason} (korrigierbar); reason 'Write rejected (<perm>): …'.
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_system_profile(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm    TEXT;
    v_created BOOLEAN;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may edit the system profile.');
    END IF;
    -- Household-Singleton: kein agent.*-Read (kein person_id, kein FK).
    v_created := NOT EXISTS (SELECT 1 FROM estate.system_profile);

    INSERT INTO estate.system_profile (scope, backup_key_location, system_location, admin_access, restore_hint, notes)
    VALUES ('household',
            NULLIF(trim(COALESCE(p->>'backup_key_location', '')), ''),
            NULLIF(trim(COALESCE(p->>'system_location', '')), ''),
            NULLIF(trim(COALESCE(p->>'admin_access', '')), ''),
            NULLIF(trim(COALESCE(p->>'restore_hint', '')), ''),
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    ON CONFLICT (scope) DO UPDATE SET
        backup_key_location = COALESCE(EXCLUDED.backup_key_location, estate.system_profile.backup_key_location),
        system_location     = COALESCE(EXCLUDED.system_location, estate.system_profile.system_location),
        admin_access        = COALESCE(EXCLUDED.admin_access, estate.system_profile.admin_access),
        restore_hint        = COALESCE(EXCLUDED.restore_hint, estate.system_profile.restore_hint),
        notes               = COALESCE(EXCLUDED.notes, estate.system_profile.notes);

    RETURN jsonb_build_object('ok', true, 'created', v_created);
END;
$$;
