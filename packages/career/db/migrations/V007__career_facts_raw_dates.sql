-- ============================================================
-- V007 (career) -- WP3 "Ableitbares wird nie gespeichert": Jahresspannen im Bestand in Roh-Daten umrechnen.
--
--   Ab WP3 lehnen die career-Validatoren ab (R__-Phase NACH dieser V):
--     career_profile.experience_years        -> career_start_date (Jahr, in dem die Berufstaetigkeit begann)
--     career_profile.skills[].years_experience -> skills[].since (Jahr)
--     career_planning.timeline_years           -> target_date (Zieljahr)
--   Eine gespeicherte Spanne ("12 Jahre", "in 2 Jahren") ist ein Jahr spaeter falsch; das Startdatum/Zieljahr nicht.
--   Umrechnung gegen den ANKER = Tag, an dem der Wert zuletzt bestaetigt wurde (_meta.last_confirmed_at des
--   Kontexts bzw. saved_at der Draft-Sektion; fehlt er: heute). Genauigkeit = Jahr (eine Spanne in Jahren traegt
--   keinen Tag): Start = Ankerjahr - floor(N), Ziel = Ankerjahr + ceil(N). Ein schon vorhandenes Roh-Feld gewinnt.
--   Nicht-Zahlen (z. B. "5+") werden nicht geraten: der Key faellt weg, der Wert steht als Zeile in der Prosa
--   (Kontext: content; Draft-Sektion: content) -> nichts geht still verloren, kein Rest blockiert spaetere Writes.
--   Betroffen: agent.core_contexts career_profile/_planning (inkl. '<base>__<pid>') + agent.advisor_plans
--   (domain career, status draft — der naechste Publish komponiert daraus). _meta bleibt unveraendert.
--   (2) career.onboarding_state.skipped_at: ungenutzt, ableitbar aus status + status_changed_at -> drop.
--   Der facts-Trigger prueft hier noch mit den ALTEN Validatoren (R__ laeuft danach): die neuen Keys sind fuer
--   sie unbekannt (open-world), das Entfernen der alten erlaubt.
--   Test: tests/db/career/test_career_v007_migration.sql (repliziert die Umrechnung 1:1, Muster V001-Test).
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

CREATE FUNCTION pg_temp.wp3_career_raw(p jsonb, p_anchor date)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_out   jsonb := p;
    v_notes jsonb := '[]'::jsonb;
    v_y     int := extract(year FROM p_anchor)::int;
    v_sk    jsonb;
    v_arr   jsonb := '[]'::jsonb;
BEGIN
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('v', p, 'notes', v_notes);
    END IF;
    IF v_out ? 'experience_years' THEN
        IF jsonb_typeof(v_out->'experience_years') = 'number' AND NOT v_out ? 'career_start_date' THEN
            v_out := v_out || jsonb_build_object('career_start_date',
                (v_y - floor((v_out->>'experience_years')::numeric)::int)::text);
        ELSIF jsonb_typeof(v_out->'experience_years') NOT IN ('number', 'null') THEN
            v_notes := v_notes || to_jsonb('Berufserfahrung = ' || (v_out->>'experience_years'));
        END IF;
        v_out := v_out - 'experience_years';
    END IF;
    IF jsonb_typeof(v_out->'skills') = 'array' THEN
        FOR v_sk IN SELECT e FROM jsonb_array_elements(v_out->'skills') AS x (e) LOOP
            IF jsonb_typeof(v_sk) = 'object' AND v_sk ? 'years_experience' THEN
                IF jsonb_typeof(v_sk->'years_experience') = 'number' AND NOT v_sk ? 'since' THEN
                    v_sk := v_sk || jsonb_build_object('since',
                        (v_y - floor((v_sk->>'years_experience')::numeric)::int)::text);
                ELSIF jsonb_typeof(v_sk->'years_experience') NOT IN ('number', 'null') THEN
                    v_notes := v_notes || to_jsonb('Erfahrung ' || COALESCE(v_sk->>'name', '?') || ' = '
                                                   || (v_sk->>'years_experience'));
                END IF;
                v_sk := v_sk - 'years_experience';
            END IF;
            v_arr := v_arr || jsonb_build_array(v_sk);
        END LOOP;
        v_out := jsonb_set(v_out, '{skills}', v_arr);
    END IF;
    IF v_out ? 'timeline_years' THEN
        IF jsonb_typeof(v_out->'timeline_years') = 'number' AND NOT v_out ? 'target_date' THEN
            v_out := v_out || jsonb_build_object('target_date',
                (v_y + ceil((v_out->>'timeline_years')::numeric)::int)::text);
        ELSIF jsonb_typeof(v_out->'timeline_years') NOT IN ('number', 'null') THEN
            v_notes := v_notes || to_jsonb('Umstiegs-Zeitraum = ' || (v_out->>'timeline_years'));
        END IF;
        v_out := v_out - 'timeline_years';
    END IF;
    RETURN jsonb_build_object('v', v_out, 'notes', v_notes);
END;
$$;

CREATE FUNCTION pg_temp.wp3_note(p_content text, p_notes jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_note text;
    v_pos  int;
BEGIN
    IF jsonb_array_length(p_notes) = 0 THEN
        RETURN p_content;
    END IF;
    v_note := 'Migriert (nicht umrechenbar, bitte als Startjahr/Zieldatum neu erfassen): '
              || (SELECT string_agg(x, '; ') FROM jsonb_array_elements_text(p_notes) AS t (x));
    v_pos := position(E'\n## Gelernt' IN COALESCE(p_content, ''));
    IF v_pos > 0 THEN
        RETURN rtrim(left(p_content, v_pos - 1), E'\n ') || E'\n\n' || v_note || E'\n' || substr(p_content, v_pos);
    END IF;
    RETURN rtrim(COALESCE(p_content, ''), E'\n ') || E'\n\n' || v_note;
END;
$$;

DO $$
DECLARE
    c      record;
    s      record;
    v_res  jsonb;
    v_anc  date;
    v_st   jsonb;
    v_chg  boolean;
BEGIN
    -- (1a) Fakten-Kontexte
    FOR c IN SELECT name, content, metadata->'facts' AS facts FROM agent.core_contexts
              WHERE name ~ '^career_(profile|planning)(__.+)?$' AND jsonb_typeof(metadata->'facts') = 'object'
                AND (metadata->'facts' ?| ARRAY['experience_years', 'timeline_years']
                     OR EXISTS (SELECT 1 FROM jsonb_array_elements(
                                    CASE WHEN jsonb_typeof(metadata->'facts'->'skills') = 'array'
                                         THEN metadata->'facts'->'skills' ELSE '[]'::jsonb END) AS k (e)
                                 WHERE k.e ? 'years_experience')) LOOP
        v_anc := CASE WHEN c.facts->'_meta'->>'last_confirmed_at' ~ '^\d{4}-\d{2}-\d{2}$'
                      THEN (c.facts->'_meta'->>'last_confirmed_at')::date ELSE CURRENT_DATE END;
        v_res := pg_temp.wp3_career_raw(c.facts, v_anc);
        UPDATE agent.core_contexts
           SET metadata = jsonb_set(metadata, '{facts}', v_res->'v'),
               content  = pg_temp.wp3_note(c.content, v_res->'notes')
         WHERE name = c.name;
        RAISE NOTICE 'V007: % auf Roh-Daten umgerechnet (Anker %)', c.name, v_anc;
    END LOOP;

    -- (1b) Draft-Sektionen der Karriere-Plaene (der naechste Publish komponiert daraus)
    FOR c IN SELECT id, interview_state FROM agent.advisor_plans
              WHERE domain = 'career' AND status = 'draft' AND jsonb_typeof(interview_state) = 'object' LOOP
        v_st := c.interview_state;
        v_chg := false;
        FOR s IN SELECT key, value FROM jsonb_each(c.interview_state) LOOP
            CONTINUE WHEN jsonb_typeof(s.value->'data') IS DISTINCT FROM 'object'
                       OR NOT (s.value->'data' ?| ARRAY['experience_years', 'timeline_years']);
            v_anc := CASE WHEN s.value->>'saved_at' ~ '^\d{4}-\d{2}-\d{2}'
                          THEN left(s.value->>'saved_at', 10)::date ELSE CURRENT_DATE END;
            v_res := pg_temp.wp3_career_raw(s.value->'data', v_anc);
            v_st := jsonb_set(v_st, ARRAY[s.key], s.value || jsonb_build_object('data', v_res->'v',
                        'content', pg_temp.wp3_note(s.value->>'content', v_res->'notes')));
            v_chg := true;
        END LOOP;
        IF v_chg THEN
            UPDATE agent.advisor_plans SET interview_state = v_st WHERE id = c.id;
            RAISE NOTICE 'V007: Draft-Plan % auf Roh-Daten umgerechnet', c.id;
        END IF;
    END LOOP;
END $$;

DROP FUNCTION pg_temp.wp3_note(text, jsonb);
DROP FUNCTION pg_temp.wp3_career_raw(jsonb, date);

-- (2) ableitbare Onboarding-Spalte
ALTER TABLE career.onboarding_state DROP COLUMN IF EXISTS skipped_at;
