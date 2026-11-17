-- ============================================================
-- fn_name_report (READ HELPER, IMMUTABLE — vergebene/aehnliche Namen einer Art + Namensvorschlag)
--   Rein (liest keine Tabelle): der Paket-Sammler (z. B. finance.fn_entity_name_report) reicht die aktiven Eintraege
--   derselben Art herein, damit Direkt-Anlage und Import dieselbe Regel sehen.
--   Eingabe: p_name (neuer Name), p_existing jsonb [{name, person}] (person = voller Name der Person des Eintrags
--   oder null), p_person (voller Name der Person des neuen Eintrags, optional).
--   Rueckgabe: {existing_names:[<=20, Eingabe-Reihenfolge], taken:[...], similar:[...], suggested_name, needs_person,
--   sibling (Name des ausloesenden Geschwisters oder null)}
--     taken        = gleiche Normalform (fn_name_key).
--     similar      = nicht taken, eine Normalform ist die andere plus ganze Woerter ("Riester" ~ "Riester Erika").
--     needs_person = ein aehnliches Geschwister einer ANDEREN Person heisst genau neuer Name + deren vollen Namen
--                    bzw. deren erstes Namenswort; suggested_name haengt dann den Namen der neuen Person in
--                    derselben Form an (die zweite Person bekommt den Aufbau der ersten).
--     suggested_name sonst nur bei taken mit p_person: Name + erstes Namenswort der Person (wie der Hinweis in
--                    finance.fn_create_account), solange die Person nicht schon im Namen steht; ein Vorschlag, der
--                    selbst vergeben ist, entfaellt (null).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_name_report(p_name text, p_existing jsonb, p_person text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_key     TEXT := core.fn_name_key(p_name);
    v_person  TEXT := NULLIF(btrim(COALESCE(p_person, '')), '');
    v_first   TEXT := NULLIF(split_part(btrim(COALESCE(p_person, '')), ' ', 1), '');
    v_e       JSONB;
    v_ekey    TEXT;
    v_eper    TEXT;
    v_all     JSONB := '[]'::jsonb;
    v_taken   JSONB := '[]'::jsonb;
    v_similar JSONB := '[]'::jsonb;
    v_sugg    TEXT;
    v_needs   BOOLEAN := false;
    v_sib     TEXT;      -- Geschwister, das needs_person ausloest
BEGIN
    FOR v_e IN SELECT e FROM jsonb_array_elements(COALESCE(p_existing, '[]'::jsonb)) e LOOP
        CONTINUE WHEN NULLIF(btrim(COALESCE(v_e->>'name', '')), '') IS NULL;
        v_all  := v_all || to_jsonb(v_e->>'name');
        v_ekey := core.fn_name_key(v_e->>'name');
        v_eper := NULLIF(btrim(COALESCE(v_e->>'person', '')), '');
        IF v_key = '' THEN CONTINUE; END IF;
        IF v_ekey = v_key THEN
            v_taken := v_taken || to_jsonb(v_e->>'name');
        ELSIF v_ekey LIKE v_key || ' %' OR v_key LIKE v_ekey || ' %' THEN
            v_similar := v_similar || to_jsonb(v_e->>'name');
            IF NOT v_needs AND v_person IS NOT NULL AND v_eper IS NOT NULL
               AND core.fn_name_key(v_eper) <> core.fn_name_key(v_person) THEN
                IF v_ekey = v_key || ' ' || core.fn_name_key(v_eper) THEN
                    v_needs := true; v_sugg := btrim(p_name) || ' ' || v_person; v_sib := v_e->>'name';
                ELSIF v_ekey = v_key || ' ' || core.fn_name_key(split_part(v_eper, ' ', 1)) THEN
                    v_needs := true; v_sugg := btrim(p_name) || ' ' || v_first; v_sib := v_e->>'name';
                END IF;
            END IF;
        END IF;
    END LOOP;

    IF NOT v_needs AND jsonb_array_length(v_taken) > 0 AND v_first IS NOT NULL
       AND (' ' || v_key || ' ') NOT LIKE ('% ' || core.fn_name_key(v_first) || ' %') THEN
        v_sugg := btrim(p_name) || ' ' || v_first;
    END IF;
    IF v_sugg IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_all) n
                                       WHERE core.fn_name_key(n) = core.fn_name_key(v_sugg)) THEN
        v_sugg := NULL; v_needs := false; v_sib := NULL;
    END IF;

    RETURN jsonb_build_object(
        'existing_names', COALESCE((SELECT jsonb_agg(x) FROM (SELECT x FROM jsonb_array_elements(v_all) WITH ORDINALITY t(x, o)
                                                               ORDER BY o LIMIT 20) s), '[]'::jsonb),
        'taken', v_taken, 'similar', v_similar,
        'suggested_name', v_sugg, 'needs_person', v_needs, 'sibling', v_sib);
END;
$$;

-- ============================================================
-- fn_name_key (READ HELPER, IMMUTABLE — Normalform eines Eintrags-Namens)
--   Die eine Vergleichsform aller Dubletten-/Aehnlich-Pruefungen: lower, jede Folge aus Leerraum und ASCII-
--   Satzzeichen (auch typografische Anfuehrungszeichen/Gedankenstriche) -> ein Leerzeichen, getrimmt.
--   Nur Leerraum und Satzzeichen werden ersetzt, Buchstaben jeder Schrift (Umlaute, Hangul) bleiben (Test test_fn_name_report).
--   Eingabe: p_name text. Rueckgabe: text ('' fuer NULL/leer).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_name_key(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT btrim(regexp_replace(lower(COALESCE(p_name, '')),
                                '[[:space:]!-/:-@\[-`{-~„“”‚‘’–—«»]+', ' ', 'g'));
$$;
