-- ============================================================
-- V003 (career) — career.job_matches person-skopieren (P2a) + die alte 2-Arg-fn_advisor_review-Signatur droppen.
--
--   WARUM eine V-Migration: (1) ADD COLUMN person_id NOT NULL + Owner-Backfill + Partial-UNIQUE-Umbau lassen
--   sich nicht idempotent ueber den Init/CREATE-OR-REPLACE ausdruecken (Bestand muss EINMALIG getaggt werden).
--   (2) CREATE OR REPLACE kann die ARITAET von career.fn_advisor_review nicht aendern: R__ legt jetzt
--   (text, text DEFAULT NULL, jsonb DEFAULT) an (uniform 3-arg-Dispatch des Core-Wrappers); die alte (text,jsonb)-
--   Form muss EINMALIG weg (sonst "function is not unique" beim 2-Arg-Call — Muster V013/V014).
--
--   PERSON-SCOPE (P2a, arch-challenge P2): person_id text NOT NULL — career.job_matches ist eine WHOLLY-PER-PERSON
--   Tabelle (kein Haushalts-Job-Match), darum NOT NULL (anders als die mixed-scope finance owner_person_id NULL=
--   Haushalt). FK -> agent.persons ON DELETE RESTRICT. Bestandszeilen werden auf den Owner gebackfillt
--   (heute Single-User; alle bisherigen Treffer gehoeren dem Owner).
--
--   OWNER-pid INLINE aus family.facts.persons[] WHERE role='owner' LIMIT 1 (V001/V002-Muster). BEWUSST NICHT
--   agent.fn_owner_person_id(): der R__-Helper existiert in der V-Phase noch nicht (R laeuft NACH V).
--
--   FAIL-LOUD (Opus-Review B2): SET NOT NULL ist nicht fail-safe bei NICHT-leerer Tabelle ohne Owner. Leere Tabelle
--   ohne Owner = gruener No-Op (Bootstrap/fresh DB); nicht-leere Tabelle ohne Owner = echter Defekt -> RAISE statt
--   stiller Inkonsistenz (sonst kippte SET NOT NULL spaeter mit "column contains null values").
--
--   IDEMPOTENT + re-run-sicher: ADD COLUMN IF NOT EXISTS, Backfill nur WHERE person_id IS NULL, FK guarded
--   (to_regclass + pg_constraint), Index DROP IF EXISTS + CREATE. Fresh DB: der Init legt person_id + den
--   (refnr, person_id)-Index schon an -> ADD/SET/Index hier sind idempotent (gleiche Endform); leere Tabelle ->
--   Backfill no-op; die 2-Arg-fn_advisor_review entstand nie -> DROP no-op.
--
--   onboarding_state bleibt in P2a HAUSHALTSWEIT (Sektions-Katalog + Core-Seeder _seed_onboarding_sections +
--   die geteilten Core-Onboarding-fns) -> person_id dort koordiniert mit dem P2b-Onboarding-Gate, NICHT hier.
--
-- APPLY-ORDER: core (Inits -> V015 droppt evaluate-2-arg) + finance (V010 droppt finance-review-2-arg) vor career;
--   career Inits (tables_init mit person_id + Index) -> V (hier) -> R (R__fn_advisor_review legt 3-arg an;
--   R__fn_record_job_match/_handle_job_feedback/_v_job_matches person-aware). Re-run-sicher.
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
    ALTER TABLE career.job_matches ADD COLUMN IF NOT EXISTS person_id text;

    -- (2) Owner-Backfill der Bestandszeilen (nur NULL -> re-run-sicher).
    IF v_owner IS NOT NULL THEN
        UPDATE career.job_matches SET person_id = v_owner WHERE person_id IS NULL;
    END IF;

    -- (3) FAIL-LOUD (B2): nicht-leere Tabelle ohne Owner = echter Defekt (kein stiller Skip).
    IF v_owner IS NULL AND EXISTS (SELECT 1 FROM career.job_matches WHERE person_id IS NULL) THEN
        RAISE EXCEPTION 'career:V003: career.job_matches hat NULL-person_id-Zeilen, aber kein Owner in family -> Backfill unmoeglich';
    END IF;

    -- (4) NOT NULL (idempotent; bei Re-Run / fresh bereits NOT NULL).
    ALTER TABLE career.job_matches ALTER COLUMN person_id SET NOT NULL;

    -- (5) FK guarded (agent.persons existiert in der V-Phase; Cross-Schema; Muster V014).
    IF to_regclass('agent.persons') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'job_matches_person_id_fkey') THEN
        ALTER TABLE career.job_matches
            ADD CONSTRAINT job_matches_person_id_fkey
            FOREIGN KEY (person_id) REFERENCES agent.persons(person_id) ON DELETE RESTRICT;
    END IF;
END $$;

-- (6) Partial-UNIQUE von (refnr) auf (refnr, person_id) umbauen (m2: CREATE IF NOT EXISTS mit gleichem Namen aber
--     neuer Spaltenliste waere ein No-Op -> expliziter DROP). Nach dem Backfill (sonst (refnr, NULL); harmlos, da
--     NULL <> NULL den partial-Index ohnehin nicht greift, aber sauberer nach NOT NULL).
DROP INDEX IF EXISTS career.uq_job_matches_refnr;
CREATE UNIQUE INDEX uq_job_matches_refnr ON career.job_matches (refnr, person_id) WHERE refnr IS NOT NULL;

-- (7) Die alte 2-Arg-Review-fn droppen (R__ legt (text, text DEFAULT NULL, jsonb DEFAULT) an). Kein DB-Objekt haengt
--     daran (der Core-Wrapper ruft sie nur dynamisch via EXECUTE).
DROP FUNCTION IF EXISTS career.fn_advisor_review(text, jsonb);
