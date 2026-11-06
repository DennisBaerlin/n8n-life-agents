-- tests/db/career/test_fn_skill_level_rank.sql
-- career.fn_skill_level_rank: Ordinal-Map der Kompetenz-Skala (EINE Quelle der 4 Werte).
-- Monoton 1<2<3<4, case-insensitiv, unbekannt/NULL -> 0 (RAISE-frei).
BEGIN;
DO $$
BEGIN
  -- monoton 1<2<3<4
  IF career.fn_skill_level_rank('beginner')     <> 1 THEN RAISE EXCEPTION 'FAIL [beginner=1]'; END IF;
  IF career.fn_skill_level_rank('intermediate') <> 2 THEN RAISE EXCEPTION 'FAIL [intermediate=2]'; END IF;
  IF career.fn_skill_level_rank('advanced')     <> 3 THEN RAISE EXCEPTION 'FAIL [advanced=3]'; END IF;
  IF career.fn_skill_level_rank('expert')       <> 4 THEN RAISE EXCEPTION 'FAIL [expert=4]'; END IF;
  IF NOT (career.fn_skill_level_rank('beginner') < career.fn_skill_level_rank('intermediate')
          AND career.fn_skill_level_rank('intermediate') < career.fn_skill_level_rank('advanced')
          AND career.fn_skill_level_rank('advanced') < career.fn_skill_level_rank('expert')) THEN
    RAISE EXCEPTION 'FAIL [monoton]'; END IF;

  -- case-insensitiv
  IF career.fn_skill_level_rank('EXPERT')   <> 4 THEN RAISE EXCEPTION 'FAIL [EXPERT case]'; END IF;
  IF career.fn_skill_level_rank('Advanced') <> 3 THEN RAISE EXCEPTION 'FAIL [Advanced case]'; END IF;

  -- unbekannt -> 0 (RAISE-frei)
  IF career.fn_skill_level_rank('guru') <> 0 THEN RAISE EXCEPTION 'FAIL [unknown=0]'; END IF;
  IF career.fn_skill_level_rank('')     <> 0 THEN RAISE EXCEPTION 'FAIL [empty=0]'; END IF;

  -- NULL -> 0 (lower(NULL)=NULL -> ELSE), kein RAISE
  IF career.fn_skill_level_rank(NULL) <> 0 THEN RAISE EXCEPTION 'FAIL [null=0]'; END IF;

  RAISE NOTICE 'PASS test_fn_skill_level_rank [monoton/case-insensitiv/unbekannt+NULL->0]';
END $$;
ROLLBACK;
