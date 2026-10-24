-- ============================================================
-- career.fn_skill_gap (WS-3 — deterministische Skill-Luecke Soll-Ist, DRY-Kern)
--   Rechnet je Ziel-Rolle die Luecke zwischen den VERLANGTEN Skills (Soll, career_planning.target_roles[].
--   required_skills[]) und den AKTUELLEN Skills (Ist, career_profile.skills[]) — DETERMINISTISCH in der DB
--   (CLAUDE.md "LLM rechnet nicht"). Karriere-Analog der finance-Allokations-Drift (Soll-Block-Array join Ist).
--   PURE: nimmt die beiden Fakten-Blobs (kein eigener SELECT) -> von Renderer (fn_render_career_planning) UND
--   Review (fn_advisor_review) aufrufbar (DRY: EINE Definition der Level-Arithmetik).
--
--   Klassifikation je Soll-Skill (Name-Match lower(trim), erster Treffer):
--     * kein Ist-Treffer                                  -> missing
--     * Ist-Treffer + presence-only (min_level fehlt, req_rank 0) -> met   (Level egal, Ueberskill irrelevant)
--     * Ist-Treffer, have_rank < req_rank                 -> weak   (auch: Ist ohne level -> have_rank 0 < req_rank)
--     * Ist-Treffer, have_rank > req_rank                 -> overskilled (KEINE Luecke; nur bei gesetztem min_level)
--     * sonst (have_rank == req_rank)                     -> met
--   req_rank/have_rank via career.fn_skill_level_rank (unbekannt/NULL -> 0; fehlt min_level -> presence-only).
--
--   RAISE-FREI (speist die all-Advisor-CTE von fn_advisor_review_evaluate): kein ::boolean-Cast auf Junk
--   (jsonb_typeof-Guard), Profil/required_skills fehlend/kein Array -> still leer.
--
--   RUECKGABE jsonb:
--     { gap_count, blocker_gap_count, overskill_count,
--       roles:[ { title, required_count, met_count,
--                 missing:[{name,required,is_blocker}],
--                 weak:[{name,have,required,is_blocker}],
--                 overskilled:[{name,have,required}] } ] }
--     roles[] enthaelt NUR Ziel-Rollen mit einem required_skills-Array (Konsumenten matchen per title).
--   Anwenden via: db_apply.ps1 -File packages\career\db\migrations\R__fn_skill_gap.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_skill_gap(p_plan_facts jsonb, p_profile_facts jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_roles_out  jsonb := '[]'::jsonb;
    v_gap_count  int := 0;
    v_blk_count  int := 0;
    v_ovr_count  int := 0;
    v_skills     jsonb;
    v_role       jsonb;
    v_req        jsonb;
    v_missing    jsonb;
    v_weak       jsonb;
    v_over       jsonb;
    v_met        int;
    v_reqcnt     int;
    v_name       text;
    v_nname      text;
    v_minlvl     text;
    v_blocker    boolean;
    v_reqrank    smallint;
    v_ist        jsonb;
    v_havelvl    text;
    v_haverank   smallint;
BEGIN
    IF p_plan_facts IS NULL OR jsonb_typeof(p_plan_facts) <> 'object'
       OR jsonb_typeof(p_plan_facts->'target_roles') <> 'array' THEN
        RETURN jsonb_build_object('gap_count', 0, 'blocker_gap_count', 0, 'overskill_count', 0, 'roles', '[]'::jsonb);
    END IF;

    v_skills := CASE WHEN jsonb_typeof(p_profile_facts->'skills') = 'array'
                     THEN p_profile_facts->'skills' ELSE '[]'::jsonb END;

    FOR v_role IN SELECT * FROM jsonb_array_elements(p_plan_facts->'target_roles') LOOP
        -- Rolle ohne required_skills-Array traegt nichts bei (IS DISTINCT FROM: fehlt -> jsonb_typeof NULL
        -- -> NULL <> 'array' waere NULL und wuerde NICHT skippen)
        CONTINUE WHEN jsonb_typeof(v_role->'required_skills') IS DISTINCT FROM 'array';
        v_missing := '[]'::jsonb; v_weak := '[]'::jsonb; v_over := '[]'::jsonb;
        v_met := 0; v_reqcnt := 0;

        FOR v_req IN SELECT * FROM jsonb_array_elements(v_role->'required_skills') LOOP
            v_name := COALESCE(v_req->>'name', '');
            CONTINUE WHEN length(trim(v_name)) = 0;   -- defensiv; der Validator faengt leere Namen
            v_reqcnt  := v_reqcnt + 1;
            v_nname   := lower(trim(v_name));
            v_minlvl  := v_req->>'min_level';          -- NULL = presence-only
            v_blocker := CASE WHEN jsonb_typeof(v_req->'is_blocker') = 'boolean'
                              THEN (v_req->>'is_blocker')::boolean ELSE false END;
            v_reqrank := career.fn_skill_level_rank(v_minlvl);

            SELECT s INTO v_ist
            FROM jsonb_array_elements(v_skills) s
            WHERE lower(trim(COALESCE(s->>'name', ''))) = v_nname
            LIMIT 1;

            IF v_ist IS NULL THEN
                v_missing := v_missing || jsonb_build_object('name', v_name, 'required', v_minlvl, 'is_blocker', v_blocker);
                v_gap_count := v_gap_count + 1;
                IF v_blocker THEN v_blk_count := v_blk_count + 1; END IF;
            ELSE
                v_havelvl  := v_ist->>'level';
                v_haverank := career.fn_skill_level_rank(v_havelvl);
                IF v_reqrank = 0 THEN
                    v_met := v_met + 1;       -- presence-only (kein Mindest-Level) -> Praesenz erfuellt, Level egal
                ELSIF v_haverank < v_reqrank THEN
                    v_weak := v_weak || jsonb_build_object('name', v_name, 'have', v_havelvl, 'required', v_minlvl, 'is_blocker', v_blocker);
                    v_gap_count := v_gap_count + 1;
                    IF v_blocker THEN v_blk_count := v_blk_count + 1; END IF;
                ELSIF v_haverank > v_reqrank THEN
                    v_over := v_over || jsonb_build_object('name', v_name, 'have', v_havelvl, 'required', v_minlvl);
                    v_ovr_count := v_ovr_count + 1;
                    v_met := v_met + 1;       -- uebererfuellt = erfuellt (zaehlt zu met_count)
                ELSE
                    v_met := v_met + 1;       -- have == req
                END IF;
            END IF;
        END LOOP;

        v_roles_out := v_roles_out || jsonb_build_object(
            'title',          v_role->>'title',
            'required_count', v_reqcnt,
            'met_count',      v_met,
            'missing',        v_missing,
            'weak',           v_weak,
            'overskilled',    v_over);
    END LOOP;

    RETURN jsonb_build_object(
        'gap_count',         v_gap_count,
        'blocker_gap_count', v_blk_count,
        'overskill_count',   v_ovr_count,
        'roles',             v_roles_out);
END;
$$;
