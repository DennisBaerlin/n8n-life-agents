-- ============================================================
-- estate.fn_set_person_record (ATOMIC UPSERT — WS-2, 1 Zeile je Person)
--   Erfasst/aendert die amtlichen Stammdaten EINER Person (PK person_id -> set_-Semantik mit
--   UPSERT unter der Haube: die Zeile entsteht beim ersten Write, danach partielles Update
--   "nicht gesendet = unveraendert"). person_id loest das TOOL vor dem Gate via
--   core.fn_resolve_person auf (Pflicht-Input; 0/>1 -> Tool-Rueckfrage).
--   FORMAT-NORMALISIERUNG (das LLM validiert nie — die DB): Steuer-ID + RV-Nummer werden
--   leerzeichen-bereinigt (RV zusaetzlich upper) und gegen die Gesetz-Regexes geprueft
--   (§ 139b AO 11 Ziffern; RV ^\d{8}[A-Z]\d{3}$) -> freundliche {ok:false}-Spiegelung der
--   Tabellen-CHECKs. KEINE Geheimnisse: nur amtliche Kennnummern + Fundort-Verweise.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, person_id (Slug, Pflicht), tax_id, pension_insurance_no,
--     health_insurance_type (gkv|pkv), health_insurance_name, health_insurance_no, employer,
--     certificates_location, notes.
--   RUECKGABE: {ok:true, person_id, created} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_person_record.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_person_record(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm    TEXT;
    v_person  TEXT := NULLIF(trim(COALESCE(p->>'person_id', '')), '');
    v_tax     TEXT := NULLIF(regexp_replace(COALESCE(p->>'tax_id', ''), '\s', '', 'g'), '');
    v_rv      TEXT := NULLIF(upper(regexp_replace(COALESCE(p->>'pension_insurance_no', ''), '\s', '', 'g')), '');
    v_hi_type TEXT := lower(NULLIF(trim(COALESCE(p->>'health_insurance_type', '')), ''));
    v_created BOOLEAN;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF v_person IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'person_id is required (resolve the household member first).');
    END IF;
    -- KEIN expliziter agent.persons-Read: die fn ist SECURITY INVOKER und laeuft unter estate_rw,
    -- das per D10 KEIN USAGE auf Schema agent hat -> ein `SELECT FROM agent.persons` crasht mit
    -- 'permission denied for schema agent' (finance-Muster: die FK person_id -> agent.persons(person_id)
    -- ist der Backstop, der RI-Check laeuft intern unter Constraint-Owner-Recht ohne Schema-Grant).
    -- Der Tool-Resolve (core.fn_resolve_person -> Person unique?) ist der Guard; ein bogus person_id
    -- (nur via Direkt-Call moeglich) laeuft in die FK -> foreign_key_violation = echte Ausnahme.

    -- Freundliche Spiegelung der Format-CHECKs (Gesetz-Regexes; kanonisch OHNE Leerzeichen):
    IF v_tax IS NOT NULL AND v_tax !~ '^[0-9]{11}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid tax_id "' || v_tax || '" — the German Steuer-ID has exactly 11 digits (§ 139b AO).');
    END IF;
    IF v_rv IS NOT NULL AND v_rv !~ '^[0-9]{8}[A-Z][0-9]{3}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid pension_insurance_no "' || v_rv || '" — expected 8 digits, 1 capital letter, 3 digits (e.g. 12190680M007, stored without spaces).');
    END IF;
    IF v_hi_type IS NOT NULL AND v_hi_type NOT IN ('gkv', 'pkv') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid health_insurance_type "' || v_hi_type || '" — valid: gkv | pkv.');
    END IF;

    v_created := NOT EXISTS (SELECT 1 FROM estate.person_records pr WHERE pr.person_id = v_person);

    INSERT INTO estate.person_records (person_id, tax_id, pension_insurance_no, health_insurance_type,
                                       health_insurance_name, health_insurance_no, employer,
                                       certificates_location, notes)
    VALUES (v_person, v_tax, v_rv, v_hi_type,
            NULLIF(trim(COALESCE(p->>'health_insurance_name', '')), ''),
            NULLIF(trim(COALESCE(p->>'health_insurance_no', '')), ''),
            NULLIF(trim(COALESCE(p->>'employer', '')), ''),
            NULLIF(trim(COALESCE(p->>'certificates_location', '')), ''),
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    ON CONFLICT (person_id) DO UPDATE SET
        tax_id                = COALESCE(EXCLUDED.tax_id, estate.person_records.tax_id),
        pension_insurance_no  = COALESCE(EXCLUDED.pension_insurance_no, estate.person_records.pension_insurance_no),
        health_insurance_type = COALESCE(EXCLUDED.health_insurance_type, estate.person_records.health_insurance_type),
        health_insurance_name = COALESCE(EXCLUDED.health_insurance_name, estate.person_records.health_insurance_name),
        health_insurance_no   = COALESCE(EXCLUDED.health_insurance_no, estate.person_records.health_insurance_no),
        employer              = COALESCE(EXCLUDED.employer, estate.person_records.employer),
        certificates_location = COALESCE(EXCLUDED.certificates_location, estate.person_records.certificates_location),
        notes                 = COALESCE(EXCLUDED.notes, estate.person_records.notes);

    RETURN jsonb_build_object('ok', true, 'person_id', v_person, 'created', v_created);
END;
$$;
