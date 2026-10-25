-- ============================================================
-- estate.fn_preview_case (WS-3 — read-only Dry-Run + Validierung; DIE HITL-Preview-Quelle)
--   Berechnet, was fn_create_case anlegen WUERDE, ohne zu schreiben: validiert alle Eingaben und gibt
--   die Task-ZAHL je Phase zurueck (Trauer-UX: die HITL-Summary zeigt eine Zusammenfassung, keine
--   Voll-Liste). Der create_case-Tool ruft sie VOR dem Gate fuer die Bestaetigungs-Nachricht; fn_create_
--   case ruft sie zur Write-Zeit erneut (re-validiert -> eine Quelle, kein TOCTOU). STABLE (kein Write).
--   VALIDIERUNG (alle korrigierbar -> {ok:false, reason}, kein RAISE):
--     * adults_only-Backstop (core.fn_check_write_permission; Kind -> reject).
--     * case_type ∈ {death, incapacity}; subject_person_id Pflicht + muss ein Haushaltsmitglied sein
--       (core.fn_household_persons, NIE agent.persons direkt, D10).
--     * subject == Sender selbst -> {ok:false, subject_is_sender} (v1-Grenze; nur numerischer Pfad).
--     * event_date Pflicht, nicht in der Zukunft; knowledge_date >= event_date (Default = event_date); beide
--       YYYY-MM-DD oder relativ (core.fn_resolve_date) — die Rueckgabe traegt die AUFGELOESTEN Daten, die der
--       Tool-Write danach unveraendert uebernimmt (Karte = Speicher).
--     * intake_facts / unknown_flags: Intake-Merkmale des Falltyps, wirksam true bzw. unbekannt (Register via
--       estate.fn_case_register_flags, ueberstimmt von p.flags).
--     * bundesland FAIL-CLOSED: Parameter -> Config estate.general.bundesland -> sonst
--       {ok:false, bundesland_required}; unbekannter Slug -> reject. (Der Agent fragt dann nach.)
--     * offener Fall derselben Person: gleicher Typ -> reject (Idempotenz); death ueber offenem
--       incapacity -> supersede_case_id gesetzt (Auto-Supersede in fn_create_case); incapacity ueber
--       offenem death -> reject.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_preview_case.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_preview_case(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_perm      TEXT;
    v_chat      TEXT := p->>'chat_id';
    v_type      TEXT := lower(NULLIF(trim(COALESCE(p->>'case_type', '')), ''));
    v_subject   TEXT := NULLIF(trim(COALESCE(p->>'subject_person_id', '')), '');
    v_subrole   TEXT;
    v_found     BOOLEAN;
    v_event     DATE;
    v_know      DATE;
    v_bl        TEXT;
    v_flags     JSONB := COALESCE(p->'flags', '{}'::jsonb);
    v_open_id   BIGINT;
    v_open_type TEXT;
    v_super     BIGINT := NULL;
    v_counts    JSONB;
    v_total     INT;
    v_eff       JSONB;
    v_known     JSONB;
    v_unknown   JSONB;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', v_chat, NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'Write rejected (' || v_perm || '): only adult household members (owner/partner) may open an event case.');
    END IF;

    IF v_type NOT IN ('death', 'incapacity') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'case_type must be death or incapacity.');
    END IF;
    IF v_subject IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'subject_person_id is required (resolve the affected household member first).');
    END IF;

    SELECT role, true INTO v_subrole, v_found FROM core.fn_household_persons() WHERE person_id = v_subject;
    IF NOT COALESCE(v_found, false) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'subject person "' || v_subject || '" is not a known household member.');
    END IF;

    IF v_chat ~ '^[0-9]+$' AND core.fn_person_chat_id(v_subject) = v_chat::bigint THEN
        RETURN jsonb_build_object('ok', false, 'subject_is_sender', true,
            'reason', 'You cannot open an event case for yourself — the affected person (subject) must be a DIFFERENT household member (this is a v1 limitation).');
    END IF;

    -- WP3: relative Angaben ("yesterday", "-3 days", "last friday") rechnet die DB, das LLM uebersetzt nur.
    IF NULLIF(trim(COALESCE(p->>'event_date', '')), '') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'event_date is required.');
    END IF;
    v_event := core.fn_resolve_date(p->>'event_date');
    IF v_event IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'event_date must be YYYY-MM-DD or relative to today (e.g. yesterday, -3 days, last friday).');
    END IF;
    IF v_event > core.fn_today() THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'event_date cannot be in the future.');
    END IF;
    IF NULLIF(trim(COALESCE(p->>'knowledge_date', '')), '') IS NULL THEN
        v_know := v_event;
    ELSE
        v_know := core.fn_resolve_date(p->>'knowledge_date');
        IF v_know IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'knowledge_date must be YYYY-MM-DD or relative to today (e.g. yesterday, -3 days).');
        END IF;
    END IF;
    IF v_know < v_event THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'knowledge_date cannot be before event_date.');
    END IF;

    v_bl := lower(COALESCE(NULLIF(trim(COALESCE(p->>'bundesland', '')), ''),
                           NULLIF(core.fn_config_get('estate', 'general', 'bundesland'), '')));
    IF v_bl IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bundesland_required',
            'reason', 'No German state (Bundesland) was given and none is configured — ask the user which German state the affected person lived in (e.g. Bayern, Nordrhein-Westfalen) and pass it as bundesland; the database needs it to compute the legal deadlines.');
    END IF;
    IF v_bl NOT IN ('baden_wuerttemberg', 'bayern', 'berlin', 'brandenburg', 'bremen', 'hamburg', 'hessen',
                    'mecklenburg_vorpommern', 'niedersachsen', 'nordrhein_westfalen', 'rheinland_pfalz',
                    'saarland', 'sachsen', 'sachsen_anhalt', 'schleswig_holstein', 'thueringen') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid bundesland "' || v_bl || '" — use a German state slug like bayern or nordrhein_westfalen.');
    END IF;

    SELECT id, case_type INTO v_open_id, v_open_type
      FROM estate.cases WHERE subject_person_id = v_subject AND status = 'open' LIMIT 1;
    IF v_open_id IS NOT NULL THEN
        IF v_open_type = v_type THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'An open ' || v_type || ' case already exists for this person (case ' || v_open_id || ').');
        ELSIF v_type = 'death' AND v_open_type = 'incapacity' THEN
            v_super := v_open_id;   -- Auto-Supersede: die Todesnachricht scheitert nie am Doppelfall.
        ELSE
            RETURN jsonb_build_object('ok', false, 'reason',
                'A death case is already open for this person (case ' || v_open_id || '); cancel it first if this is a correction.');
        END IF;
    END IF;

    SELECT COALESCE(jsonb_object_agg(phase, cnt), '{}'::jsonb), COALESCE(sum(cnt), 0)::int
      INTO v_counts, v_total
      FROM (SELECT phase, count(*) AS cnt
              FROM estate.fn_case_template_rows(v_type, v_subject, v_flags, v_event, v_know, v_bl)
             WHERE status = 'open'
             GROUP BY phase) s;

    -- WP3: Intake-Merkmale dieses Falltyps — wirksam (Register || Angabe) true = intake_facts (Karte), weder Register
    -- noch Angabe = unknown_flags (genau das fragt der Agent, einmal gesammelt). Derived-Conditions zaehlen nicht.
    v_eff := jsonb_strip_nulls(estate.fn_case_register_flags(v_subject)) || v_flags;
    SELECT COALESCE(jsonb_agg(k ORDER BY k) FILTER (WHERE v_eff->>k = 'true'), '[]'::jsonb),
           COALESCE(jsonb_agg(k ORDER BY k) FILTER (WHERE NOT v_eff ? k), '[]'::jsonb)
      INTO v_known, v_unknown
      FROM (SELECT DISTINCT t.condition_key AS k FROM estate.task_templates t
             WHERE t.case_type = v_type AND NOT t.retired AND t.condition_key IS NOT NULL
               AND t.condition_key NOT IN ('adult_subject', 'finance_absent', 'minor_children')) s;

    RETURN jsonb_build_object(
        'ok', true,
        'case_type', v_type,
        'subject_person_id', v_subject,
        'event_date', v_event,
        'knowledge_date', v_know,
        'bundesland', v_bl,
        'phase_counts', v_counts,
        'total_open', v_total,
        'intake_facts', v_known,
        'unknown_flags', v_unknown,
        'supersede_case_id', v_super);
END;
$$;
