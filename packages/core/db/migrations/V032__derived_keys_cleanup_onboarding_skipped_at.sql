-- ============================================================
-- V032 (core) -- WP3 "Ableitbares wird nie gespeichert": Bestand an die neuen Regeln angleichen.
--
--   (1) Fakten-Sidecars: Die Derived-Key-Denylist (agent.fn_validate_household_facts, Init) sperrt seit WP3 auch
--       die MUSTER *_year, (..._)age(_...) [ausser geplanten Roh-Altern start_age/planned_retirement_age/age_from/
--       age_to], years_since_* und is_minor/is_adult. Ein solcher Key im Bestand wuerde JEDEN weiteren facts-Write
--       dieses Kontexts blockieren (der Trigger prueft das ganze Dokument). Darum hier auf JEDER Installation gleich:
--       die Keys rekursiv aus metadata.facts entfernen und ihren Wert als Zeile in die Prosa (content) schreiben --
--       nichts geht still verloren, der Nutzer/Agent kann den Rohfakt (z. B. ein *_date) neu erfassen.
--       Die Notiz steht VOR einem system-verwalteten "## Gelernt"-Block (der bleibt das Dokument-Ende).
--       Laeuft vor den Paket-V (Core-V zuerst) -> career:V007 trifft auf bereinigte Dokumente.
--   (2) agent.guide_onboarding_state.skipped_at: liest niemand, ableitbar aus status + status_changed_at; die
--       Core-fns schreiben es seit WP3 nicht mehr. Die Spalte bleibt im Init-CREATE stehen, weil core:V003 sie beim
--       frischen Test-DB-Bootstrap (alle Inits vor allen V) noch liest -- gedroppt wird sie erst hier.
--
--   IDEMPOTENT: V laeuft genau einmal (ledger-gegated); beide Teile sind zusaetzlich wiederholbar (kein Treffer ->
--   kein UPDATE; DROP COLUMN IF EXISTS).
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

CREATE FUNCTION pg_temp.wp3_strip_derived(p jsonb, p_path text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    r       record;
    v_sub   jsonb;
    v_out   jsonb;
    v_rem   jsonb := '[]'::jsonb;
    v_i     int := 0;
BEGIN
    IF jsonb_typeof(p) = 'array' THEN
        v_out := '[]'::jsonb;
        FOR r IN SELECT e FROM jsonb_array_elements(p) AS x(e) LOOP
            v_sub := pg_temp.wp3_strip_derived(r.e, p_path || '[' || v_i || ']');
            v_out := v_out || jsonb_build_array(v_sub->'v');
            v_rem := v_rem || (v_sub->'r');
            v_i := v_i + 1;
        END LOOP;
        RETURN jsonb_build_object('v', v_out, 'r', v_rem);
    END IF;
    IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('v', p, 'r', '[]'::jsonb);
    END IF;
    v_out := '{}'::jsonb;
    FOR r IN SELECT key, value FROM jsonb_each(p) LOOP
        IF lower(r.key) ~ 'years_since_'
           OR lower(r.key) ~ '_year$'
           OR (lower(r.key) ~ '(^|_)age(_|$)'
               AND lower(r.key) NOT IN ('start_age', 'planned_retirement_age', 'age_from', 'age_to'))
           OR lower(r.key) ~ '^is_(minor|adult)$' THEN
            v_rem := v_rem || jsonb_build_array(ltrim(p_path || '.' || r.key, '.') || ' = ' || (r.value #>> '{}'));
        ELSE
            v_sub := pg_temp.wp3_strip_derived(r.value, p_path || '.' || r.key);
            v_out := v_out || jsonb_build_object(r.key, v_sub->'v');
            v_rem := v_rem || (v_sub->'r');
        END IF;
    END LOOP;
    RETURN jsonb_build_object('v', v_out, 'r', v_rem);
END;
$$;

DO $$
DECLARE
    c       record;
    v_res   jsonb;
    v_note  text;
    v_pos   int;
BEGIN
    FOR c IN SELECT name, content, metadata->'facts' AS facts FROM agent.core_contexts
              WHERE jsonb_typeof(metadata->'facts') = 'object' LOOP
        v_res := pg_temp.wp3_strip_derived(c.facts, '');
        CONTINUE WHEN jsonb_array_length(v_res->'r') = 0;
        v_note := 'Migriert (abgeleiteter Wert entfernt, bitte als Rohfakt neu erfassen): '
                  || (SELECT string_agg(x, '; ') FROM jsonb_array_elements_text(v_res->'r') AS x);
        v_pos := position(E'\n## Gelernt' IN COALESCE(c.content, ''));
        UPDATE agent.core_contexts
           SET metadata = jsonb_set(metadata, '{facts}', v_res->'v'),
               content  = CASE WHEN v_pos > 0
                               THEN rtrim(left(c.content, v_pos - 1), E'\n ') || E'\n\n' || v_note || E'\n'
                                    || substr(c.content, v_pos)
                               ELSE rtrim(COALESCE(c.content, ''), E'\n ') || E'\n\n' || v_note END
         WHERE name = c.name;
        RAISE NOTICE 'V032: % — % abgeleitete(r) Key(s) entfernt', c.name, jsonb_array_length(v_res->'r');
    END LOOP;
END $$;

DROP FUNCTION pg_temp.wp3_strip_derived(jsonb, text);

ALTER TABLE agent.guide_onboarding_state DROP COLUMN IF EXISTS skipped_at;
