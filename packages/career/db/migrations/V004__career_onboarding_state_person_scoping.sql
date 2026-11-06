-- ============================================================
-- V004 (career) — career.onboarding_state person-skopieren (P2b-1) + PK section_key -> (section_key, person_id).
--
--   WARUM eine V-Migration: ADD COLUMN person_id NOT NULL + Owner-Backfill + PK-Umbau lassen sich nicht
--   idempotent ueber den CREATE-OR-REPLACE-Init ausdruecken (Bestand muss EINMALIG getaggt werden) — exakt das
--   Muster von career:V003 (job_matches.person_id). career.onboarding_state ist WHOLLY-PER-PERSON: jede Person
--   pflegt ihr EIGENES Career-Onboarding (career pro Person), darum person_id NOT NULL (kein Haushalts-Onboarding;
--   anders als die household onboarding_state von finance/guide, die UNVERAENDERT bleiben).
--
--   OWNER-pid INLINE aus family.facts.persons[] WHERE role='owner' LIMIT 1 (V001/V002/V003-Muster). BEWUSST NICHT
--   agent.fn_owner_person_id(): der R__-Helper existiert in der V-Phase noch nicht (R laeuft NACH V).
--
--   FAIL-LOUD (V003-Muster, Opus-Review B2): SET NOT NULL ist nicht fail-safe bei NICHT-leerer Tabelle ohne Owner.
--   Leere Tabelle ohne Owner = gruener No-Op (fresh/Bootstrap, der Seeder seedet erst NACH den Migrationen); nicht-
--   leere Tabelle ohne Owner = echter Defekt -> RAISE statt stiller Inkonsistenz.
--
--   PK-REBUILD: section_key -> (section_key, person_id). Ein PK-CONSTRAINT kann NICHT 'IF NOT EXISTS' (anders als
--   V003' Partial-Index DROP+CREATE) -> pg_constraint-Existenz-Guards: 1-spaltigen alten PK droppen, composite-PK
--   nur anlegen wenn noch keiner da ist. Fresh-DB: der Init legt person_id + composite-PK schon an -> ADD/SET/PK
--   hier sind idempotent (gleiche Endform); leere Tabelle -> Backfill no-op.
--
--   FK -> agent.persons ON DELETE RESTRICT, guarded (to_regclass + pg_constraint; Cross-Schema; Muster V003/V014).
--
-- APPLY-ORDER: core (Inits + V) + finance vor career; career Inits (tables_init mit person_id + composite-PK) ->
--   V (hier) -> R (R__fn_set_onboarding_section/_onboarding_status/_onboarding_overview/_ensure_onboarding_person
--   person-aware) -> util (Grants neue Arity). Re-run-sicher.
-- ============================================================

DO $$
DECLARE
    v_owner TEXT;
BEGIN
    SELECT pp->>'person_id' INTO v_owner
    FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family' AND pp->>'role' = 'owner'
    LIMIT 1;

    -- (1) Spalte (Bestand; fresh hat sie aus dem Init).
    ALTER TABLE career.onboarding_state ADD COLUMN IF NOT EXISTS person_id text;

    -- (2) Owner-Backfill der Bestandszeilen (nur NULL -> re-run-sicher).
    IF v_owner IS NOT NULL THEN
        UPDATE career.onboarding_state SET person_id = v_owner WHERE person_id IS NULL;
    END IF;

    -- (3) FAIL-LOUD (B2): nicht-leere Tabelle ohne Owner = echter Defekt (kein stiller Skip).
    IF v_owner IS NULL AND EXISTS (SELECT 1 FROM career.onboarding_state WHERE person_id IS NULL) THEN
        RAISE EXCEPTION 'career:V004: career.onboarding_state hat NULL-person_id-Zeilen, aber kein Owner in family -> Backfill unmoeglich';
    END IF;

    -- (4) NOT NULL (idempotent; bei Re-Run / fresh bereits NOT NULL).
    ALTER TABLE career.onboarding_state ALTER COLUMN person_id SET NOT NULL;

    -- (5) PK section_key -> (section_key, person_id). PK kann nicht 'IF NOT EXISTS' -> pg_constraint-Guards.
    --     Den alten 1-spaltigen PK droppen (nur wenn er noch 1-spaltig ist; fresh hat schon den 2-spaltigen).
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'onboarding_state_pkey'
          AND conrelid = 'career.onboarding_state'::regclass
          AND array_length(conkey, 1) = 1
    ) THEN
        ALTER TABLE career.onboarding_state DROP CONSTRAINT onboarding_state_pkey;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'onboarding_state_pkey'
          AND conrelid = 'career.onboarding_state'::regclass
    ) THEN
        ALTER TABLE career.onboarding_state ADD PRIMARY KEY (section_key, person_id);
    END IF;

    -- (6) FK guarded (agent.persons existiert in der V-Phase; Cross-Schema; Muster V003).
    IF to_regclass('agent.persons') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'onboarding_state_person_id_fkey') THEN
        ALTER TABLE career.onboarding_state
            ADD CONSTRAINT onboarding_state_person_id_fkey
            FOREIGN KEY (person_id) REFERENCES agent.persons(person_id) ON DELETE RESTRICT;
    END IF;
END $$;
