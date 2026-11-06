-- ============================================================
-- estate.fn_set_system_profile (ATOMIC UPSERT — WS-5, Haushalts-Singleton)
--   Erfasst/aendert den System-Steckbrief + den FUNDORT der Offline-Kopie des core.backup_key
--   (Owner-Entscheid 9). GEHEIMNISSE NIE — nur Fundort-VERWEISE (die Tool-Description + Instructions
--   tragen "nur Verweis, nie das Geheimnis"; strukturell nicht erzwingbar).
--   SINGLETON (scope='household', CHECK-fixiert): genau 0/1 Zeile -> set_-Semantik via UPSERT auf den
--   festen Schluessel; partielles Update "nicht gesendet = unveraendert".
--   EINFACHER als fn_set_person_record: KEIN person_id/-Resolve, KEIN agent.*-Read -> D10-trivial (die
--   fn beruehrt nur estate.system_profile + das core.fn_check_write_permission-DEFINER-Fenster).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false} ohne Write.
--   Eingabe jsonb: chat_id, backup_key_location, system_location, admin_access, restore_hint, notes.
--   RUECKGABE: {ok:true, created} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_system_profile.sql
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
    -- Household-Singleton: KEIN agent.*-Read (kein person_id, kein FK) -> D10-trivial.
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
