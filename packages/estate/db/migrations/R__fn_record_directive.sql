-- ============================================================
-- estate.fn_record_directive (ATOMIC UPSERT — WS-2, Verb record_ wie career.fn_record_job_match)
--   DIE eine Schreib-fn des Vorsorge-Dokumente-Registers estate.directives: UPSERT auf den
--   UNIQUE NULLS NOT DISTINCT (owner_person_id, doc_type)-Key — genau EIN Registereintrag je
--   (Person|Haushalt, Dokumenttyp); ein Re-Record AKTUALISIERT (idempotent, kein Duplikat,
--   darum record_ statt create_: der create_-Vertrag "legt nur NEUES an" widersprraeche dem
--   UPSERT strukturell). owner_person_id NULL/leer = gemeinschaftliche HAUSHALTS-Urkunde
--   (Berliner Testament, Erbvertrag beider Partner).
--   "Entfernen" eines Eintrags = doc_status 'does_not_exist' (bewusst erfasster, ehrlicher
--   Gap) — es gibt KEIN delete_directive (Plan WS-2, Register-Semantik).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) in JEDER estate-Write-fn
--   (erste Live-Nutzung von adults_only; Kind -> {ok:false} ohne Write). NUR Metadaten, NIE
--   Dokument-Inhalte/Geheimnisse (Owner-Entscheid 2; Inhalt haerten Tool-Description + Prompt).
--   UPDATE-Semantik: doc_status wird IMMER uebernommen (Kern-Aussage des Eintrags); alle
--   anderen Felder partiell (COALESCE: nicht gesendet = unveraendert).
--   Eingabe jsonb: chat_id, owner_person_id (Slug, ''=Haushalt), doc_type (estate.directive_types),
--     doc_status (exists|does_not_exist|planned), form (privat|notariell|amtlich), registry
--     (ztr|zvr), storage_place_name (-> in-fn Resolve, 0/>1 -> {ok:false}), location_note,
--     authorized_person (Freitext, darf haushalts-extern sein), notes.
--   RUECKGABE: {ok:true, directive_id, created, doc_status} | {ok:false, reason} (korrigierbar,
--     kein RAISE -> kein Owner-Alert). updated_at pflegt der Touch-Trigger.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_record_directive.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_record_directive(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm     TEXT;
    v_person   TEXT := NULLIF(trim(COALESCE(p->>'owner_person_id', '')), '');
    v_doc_type TEXT := NULLIF(trim(COALESCE(p->>'doc_type', '')), '');
    v_status   TEXT := NULLIF(trim(COALESCE(p->>'doc_status', '')), '');
    v_form     TEXT := NULLIF(trim(COALESCE(p->>'form', '')), '');
    v_registry TEXT := lower(NULLIF(trim(COALESCE(p->>'registry', '')), ''));
    v_sp_name  TEXT := NULLIF(trim(COALESCE(p->>'storage_place_name', '')), '');
    v_sp       RECORD;
    v_sp_id    BIGINT;
    v_existing BIGINT;
    v_id       BIGINT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    -- Korrigierbare Validierung VOR dem Write (die CHECKs/FKs sind der strukturelle Backstop):
    IF v_doc_type IS NULL OR NOT EXISTS (SELECT 1 FROM estate.directive_types dt WHERE dt.doc_type = v_doc_type) THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'unknown doc_type "' || COALESCE(v_doc_type, '') || '" — valid: '
            || (SELECT string_agg(dt.doc_type, ', ' ORDER BY dt.ord) FROM estate.directive_types dt));
    END IF;
    IF v_status IS NULL OR v_status NOT IN ('exists', 'does_not_exist', 'planned') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'doc_status is required: exists | does_not_exist | planned (got "' || COALESCE(v_status, '') || '").');
    END IF;
    IF v_form IS NOT NULL AND v_form NOT IN ('privat', 'notariell', 'amtlich') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid form "' || v_form || '" — valid: privat | notariell | amtlich.');
    END IF;
    IF v_registry IS NOT NULL AND v_registry NOT IN ('ztr', 'zvr') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid registry "' || v_registry || '" — valid: ztr | zvr (or omit when not registered).');
    END IF;

    -- Optionale Fundstellen-Aufloesung in-fn ({ok:false} statt RAISE — korrigierbar):
    IF v_sp_name IS NOT NULL THEN
        SELECT r.id, r.hit_count INTO v_sp FROM estate.fn_resolve_storage_place(v_sp_name) r;
        IF v_sp.hit_count = 0 THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'storage place "' || v_sp_name || '" not found — create it first (create_storage_place) or use location_note for a free-text location.');
        END IF;
        IF v_sp.hit_count > 1 THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'storage place "' || v_sp_name || '" is ambiguous (' || v_sp.hit_count || ' matches) — ask the user which one.');
        END IF;
        v_sp_id := v_sp.id;
    END IF;

    -- created-Flag: existiert der (Person|Haushalt, Typ)-Eintrag schon? (NULLS NOT DISTINCT-Key)
    SELECT d.id INTO v_existing FROM estate.directives d
    WHERE d.owner_person_id IS NOT DISTINCT FROM v_person AND d.doc_type = v_doc_type;

    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, form, registry,
                                   storage_place_id, location_note, authorized_person, notes)
    VALUES (v_person, v_doc_type, v_status, v_form, v_registry, v_sp_id,
            NULLIF(trim(COALESCE(p->>'location_note', '')), ''),
            NULLIF(trim(COALESCE(p->>'authorized_person', '')), ''),
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    ON CONFLICT (owner_person_id, doc_type) DO UPDATE SET
        doc_status        = EXCLUDED.doc_status,   -- Kern-Aussage: immer uebernehmen
        form              = COALESCE(EXCLUDED.form, estate.directives.form),
        registry          = COALESCE(EXCLUDED.registry, estate.directives.registry),
        storage_place_id  = COALESCE(EXCLUDED.storage_place_id, estate.directives.storage_place_id),
        location_note     = COALESCE(EXCLUDED.location_note, estate.directives.location_note),
        authorized_person = COALESCE(EXCLUDED.authorized_person, estate.directives.authorized_person),
        notes             = COALESCE(EXCLUDED.notes, estate.directives.notes)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'directive_id', v_id,
                              'created', (v_existing IS NULL), 'doc_status', v_status);
END;
$$;
