-- ============================================================
-- fn_entity_name_report (READ, STABLE — Namens-Regel der finance-Anlagen, eine Adresse fuer Direkt-Anlage und Import)
--   Sammelt die aktiven Eintraege derselben Art samt Personen-Namen (core.fn_household_persons) und wertet sie mit
--   core.fn_name_report aus. Namen sind je Art eindeutig; Konten zusaetzlich typuebergreifend (Konto-Verweise loesen
--   nur ueber den Namen auf). Pausierte/geschlossene Eintraege sperren keinen Namen.
--   Eingabe: p_kind (account|pension|insurance|loan|real_estate|savings_goal|savings_plan), p_name, p_person_id (Slug
--   der Person des neuen Eintrags oder NULL = Haushalt).
--   Rueckgabe: das jsonb von core.fn_name_report ({existing_names, taken, similar, suggested_name, needs_person}).
--   Unbekannte Art -> RAISE (Build-Konstante der aufrufenden fn, kein Nutzer-Input).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_entity_name_report(p_kind text, p_name text, p_person_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_rows JSONB;
BEGIN
    WITH hp AS (SELECT h.person_id, h.full_name FROM core.fn_household_persons() h),
    e AS (
        SELECT a.id, a.name, a.owner_person_id AS pid FROM finance.accounts a
         WHERE p_kind = 'account' AND a.status = 'active'
        UNION ALL
        SELECT x.id, x.name, x.owner_person_id FROM finance.pension x
         WHERE p_kind = 'pension' AND x.status = 'active'
        UNION ALL
        SELECT x.id, x.name, x.policyholder_person_id FROM finance.insurances x
         WHERE p_kind = 'insurance' AND x.status = 'active'
        UNION ALL
        SELECT x.id, x.name, x.borrower_person_id FROM finance.loans x
         WHERE p_kind = 'loan' AND x.status = 'active'
        UNION ALL
        SELECT x.id, x.name, x.owner_person_id FROM finance.real_estate x
         WHERE p_kind = 'real_estate' AND x.status = 'active'
        UNION ALL
        SELECT x.id, x.name, x.beneficiary_person_id FROM finance.savings_goals x
         WHERE p_kind = 'savings_goal' AND x.status = 'active'
        UNION ALL
        SELECT x.id, x.name, x.beneficiary_person_id FROM finance.savings_plans x
         WHERE p_kind = 'savings_plan' AND x.status = 'active')
    SELECT COALESCE(jsonb_agg(jsonb_build_object('name', e.name, 'person', hp.full_name) ORDER BY e.id), '[]'::jsonb)
      INTO v_rows
      FROM e LEFT JOIN hp ON hp.person_id = e.pid;

    IF p_kind NOT IN ('account','pension','insurance','loan','real_estate','savings_goal','savings_plan') THEN
        RAISE EXCEPTION 'fn_entity_name_report: unknown kind %', p_kind;
    END IF;

    RETURN core.fn_name_report(p_name, v_rows,
        (SELECT h.full_name FROM core.fn_household_persons() h WHERE h.person_id = NULLIF(btrim(COALESCE(p_person_id, '')), '')));
END;
$$;

-- ============================================================
-- fn_entity_name_reject (READ HELPER, IMMUTABLE — einheitliche Absage einer Namens-Dublette)
--   Baut aus einem fn_entity_name_report-Ergebnis die korrigierbare Absage fuer den Probelauf vor der Karte
--   (New-FnWriteGate reicht reason, code, candidates an das Modell; die vergebenen Namen stehen darum im reason).
--   Eingabe: p_report (jsonb), p_label (englische Art fuer den Text, z. B. 'pension'), p_code (Default duplicate_name).
--   Rueckgabe: NULL (kein Konflikt) | {ok:false, code, reason, candidates:[{name}], existing_names, suggested_name}.
--     taken        -> code p_code ("already exists"), Vorschlag falls vorhanden.
--     needs_person -> code name_needs_person: ein anderes Haushaltsmitglied hat denselben Eintrag mit Personen-Zusatz.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_entity_name_reject(p_report jsonb, p_label text, p_code text DEFAULT 'duplicate_name')
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN jsonb_array_length(COALESCE(p_report->'taken', '[]')) > 0 THEN jsonb_build_object(
            'ok', false, 'code', p_code,
            'reason', 'An active ' || p_label || ' named "' || (p_report->'taken'->>0) || '" already exists. Use that one, or '
                   || 'choose a distinct name'
                   || COALESCE(' - suggestion: "' || (p_report->>'suggested_name') || '"', '')
                   || '. Names already used for this kind: '
                   || (SELECT string_agg('"' || n || '"', ', ') FROM jsonb_array_elements_text(p_report->'existing_names') n) || '.',
            'candidates', (SELECT jsonb_agg(jsonb_build_object('name', n)) FROM jsonb_array_elements_text(p_report->'taken') n),
            'existing_names', p_report->'existing_names', 'suggested_name', p_report->'suggested_name')
        WHEN (p_report->>'needs_person')::boolean THEN jsonb_build_object(
            'ok', false, 'code', 'name_needs_person',
            'reason', 'Another household member already has this ' || p_label || ' with their name added ("'
                   || COALESCE(p_report->>'sibling', p_report->'similar'->>0) || '") - name this one the same way: "' || (p_report->>'suggested_name')
                   || '" (call again with that name; the user may also choose another distinct name).',
            'candidates', (SELECT jsonb_agg(jsonb_build_object('name', n)) FROM jsonb_array_elements_text(p_report->'similar') n),
            'existing_names', p_report->'existing_names', 'suggested_name', p_report->'suggested_name')
    END;
$$;

-- ============================================================
-- fn_import_name_conflict (READ, STABLE — Namens-Dublette einer Import-Zeile, Regel wie die fn_create_*)
--   Loest die Person der Zeile wie das Einzel-Tool auf (fn_import_resolve_persons) und prueft den Namen ueber
--   fn_entity_name_report gegen den aktiven Bestand derselben Art. Ein Vorschlag mit Personen-Zusatz ohne Dublette
--   (needs_person) ist hier kein Fehler: fn_import_stage wendet ihn beim Stagen an; eine spaetere Korrektur zurueck auf
--   den blossen Namen lehnt erst fn_create_* im Commit-Probelauf ab (vor der Karte).
--   Eingabe: p_kind (Art fuer fn_entity_name_report), p_type (entity_type der Zeile), p (Payload), p_message
--   (Anfang des Zeilenfehlers, z. B. 'pension "X" already exists').
--   Rueckgabe: NULL (frei) | p_message || ' - names already used: ...' [|| '; suggestion: "..."'].
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_name_conflict(p_kind text, p_type text, p jsonb, p_message text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_field TEXT := finance.fn_import_person_field(p_type);
    v_rep   JSONB;
BEGIN
    v_rep := finance.fn_entity_name_report(p_kind, p->>'name',
        CASE WHEN v_field IS NOT NULL THEN finance.fn_import_resolve_persons(p_type, p)->'payload'->>(v_field || '_id') END);
    IF jsonb_array_length(v_rep->'taken') = 0 THEN
        RETURN NULL;
    END IF;
    RETURN p_message || ' - names already used: '
        || (SELECT string_agg('"' || n || '"', ', ') FROM jsonb_array_elements_text(v_rep->'existing_names') n)
        || COALESCE('; suggestion: "' || (v_rep->>'suggested_name') || '"', '');
END;
$$;
