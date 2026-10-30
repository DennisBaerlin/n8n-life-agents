-- ============================================================
-- test_fn_match_household_holder -- Gegenpart-/Inhaber-Name einer Bank gegen die Haushaltsmitglieder ("Import zuerst")
--   Namen erfunden.
--   Personen: Maximilian Zweistein, Erika Zweistein, Jörg Brückner (Umlaute), Greta Ida Quell + Ida Quell (Teilmenge),
--   zweimal Paul Doppel (gleiche Namen), Solo (nur ein Token).
-- ============================================================
BEGIN;
INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('__t_hh_max__',   'Maximilian Zweistein', 'owner'),
    ('__t_hh_erika__', 'Erika Zweistein',      'partner'),
    ('__t_hh_joerg__', 'Jörg Brückner',        'partner'),
    ('__t_hh_al__',    'Greta Ida Quell',      'child'),
    ('__t_hh_l__',     'Ida Quell',           'child'),
    ('__t_hh_p1__',    'Paul Doppel',          'child'),
    ('__t_hh_p2__',    'Paul Doppel',          'child'),
    ('__t_hh_solo__',  'Solo',                 'child')
ON CONFLICT (person_id) DO UPDATE SET full_name = excluded.full_name;

DO $$
DECLARE
    v JSONB;
BEGIN
    -- ---------- Treffer ----------
    v := finance.fn_match_household_holder('Maximilian Zweistein');
    IF (v->>'matched')::boolean IS DISTINCT FROM true OR v->>'owner_person_id' IS DISTINCT FROM '__t_hh_max__'
       OR (v->>'joint')::boolean THEN
        RAISE EXCEPTION 'FAIL [H1 Einzelname]: %', v;
    END IF;
    v := finance.fn_match_household_holder('ZWEISTEIN, MAXIMILIAN');
    IF v->>'owner_person_id' IS DISTINCT FROM '__t_hh_max__' THEN RAISE EXCEPTION 'FAIL [H2 Nachname, Vorname]: %', v; END IF;
    v := finance.fn_match_household_holder('Herr Dr. Maximilian Zweistein');
    IF v->>'owner_person_id' IS DISTINCT FROM '__t_hh_max__' THEN RAISE EXCEPTION 'FAIL [H3 Anrede/Titel]: %', v; END IF;
    v := finance.fn_match_household_holder('JOERG BRUECKNER');
    IF v->>'owner_person_id' IS DISTINCT FROM '__t_hh_joerg__' THEN RAISE EXCEPTION 'FAIL [H4 ue-Schreibweise]: %', v; END IF;
    v := finance.fn_match_household_holder('JORG BRUCKNER');
    IF v->>'owner_person_id' IS DISTINCT FROM '__t_hh_joerg__' THEN RAISE EXCEPTION 'FAIL [H5 u-Schreibweise]: %', v; END IF;
    v := finance.fn_match_household_holder('Maximilian und Erika Zweistein');
    IF (v->>'matched')::boolean IS DISTINCT FROM true OR NOT (v->>'joint')::boolean OR v->>'owner_person_id' IS NOT NULL
       OR jsonb_array_length(v->'person_ids') <> 2 THEN
        RAISE EXCEPTION 'FAIL [H6 zwei Namen = gemeinsam]: %', v;
    END IF;
    v := finance.fn_match_household_holder('Greta Ida Quell');
    IF v->>'owner_person_id' IS DISTINCT FROM '__t_hh_al__' THEN RAISE EXCEPTION 'FAIL [H7 Teilmenge faellt weg]: %', v; END IF;
    v := finance.fn_match_household_holder('Ida Quell');
    IF v->>'owner_person_id' IS DISTINCT FROM '__t_hh_l__' THEN RAISE EXCEPTION 'FAIL [H8 kurzer Name]: %', v; END IF;
    RAISE NOTICE 'PASS [H1-H8 Treffer]';

    -- ---------- kein Treffer ----------
    v := finance.fn_match_household_holder('Maximilian Zweistein GmbH');
    IF (v->>'matched')::boolean THEN RAISE EXCEPTION 'FAIL [H9 Fremd-Token GmbH]: %', v; END IF;
    v := finance.fn_match_household_holder('Zweistein');
    IF (v->>'matched')::boolean THEN RAISE EXCEPTION 'FAIL [H10 nur Nachname]: %', v; END IF;
    v := finance.fn_match_household_holder('Solo');
    IF (v->>'matched')::boolean THEN RAISE EXCEPTION 'FAIL [H11 Ein-Token-Person zaehlt nie]: %', v; END IF;
    v := finance.fn_match_household_holder('Paul Doppel');
    IF (v->>'matched')::boolean THEN RAISE EXCEPTION 'FAIL [H12 gleiche Namen = mehrdeutig]: %', v; END IF;
    v := finance.fn_match_household_holder('PayPal Europe');
    IF (v->>'matched')::boolean THEN RAISE EXCEPTION 'FAIL [H13 Dienstleister]: %', v; END IF;
    v := finance.fn_match_household_holder(NULL);
    IF (v->>'matched')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [H14 NULL]: %', v; END IF;
    v := finance.fn_match_household_holder('   ');
    IF (v->>'matched')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [H15 leer]: %', v; END IF;
    RAISE NOTICE 'PASS [H9-H15 kein Treffer]';
END $$;
ROLLBACK;
