-- ============================================================
-- V002 (career) — career_planning von haushaltsweit auf per_user (Name-Suffix) migrieren + die
--   advisor_plans-Career-Zeilen auf den Owner-Anker setzen (P0c).
--
--   WARUM eine V-Migration: P0c stellt career_planning im Manifest auf scope='per_user' um. Eine
--   Bestands-DB, in der der Owner bereits einen Career-Plan veroeffentlicht hat, traegt (a) das
--   Prosa-Plan-Doc am BASIS-Namen 'career_planning' in agent.core_contexts und (b) advisor_plans-Zeilen
--   (domain='career') mit person_id IS NULL. Beides braucht eine EINMALIGE Ausrichtung auf den
--   suffigierten Owner-Namen bzw. die Owner-person_id — sonst stuende die Bestands-PII am leeren
--   Basis-Namen und der per_user-Read (fn_fetch_context mit chat_id) faende sie nie (genau der
--   "einmalige Daten-Backfill", fuer den V__-Migrationen da sind). Pendant zu career:V001
--   (career_profile/career_preferences).
--
--   OWNER-pid INLINE aus family.facts.persons[] WHERE role='owner' LIMIT 1 (V001-Muster). BEWUSST NICHT
--   agent.fn_owner_person_id(): dieser Helper ist eine R__-Repeatable und wird ERST in der R-Phase erzeugt,
--   die NACH der V-Phase laeuft -> in der Migration existiert er noch nicht ("function does not exist").
--   Die Runtime-Konsumenten (read_plan/review/refresh_market_signals) nutzen den Helper, die Migration inlined.
--
--   SICHER + IDEMPOTENT: (a) UPDATE name (KEIN DELETE -> der BEFORE-DELETE-Protect-Trigger feuert nicht;
--   der Validate-Trigger re-validiert die UNVERAENDERTEN facts = ok), per-Kontext geguardet
--   (Basis-Zeile fehlt / Ziel-Zeile existiert schon / kein Owner -> skip). (b) advisor_plans-Backfill
--   nur fuer person_id IS NULL (re-run-sicher). Fresh DB OHNE Bestand = no-op.
--
--   APPLY-ORDER: core (Inits -> V014 person_id-Spalte) laeuft vor der career-Installation; career
--   (Inits -> V hier -> R) danach. Die person_id-Spalte existiert also (V014, core-V-Phase vor career).
-- ============================================================

DO $$
DECLARE
    v_owner TEXT;
BEGIN
    SELECT pp->>'person_id' INTO v_owner
    FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family' AND pp->>'role' = 'owner'
    LIMIT 1;

    IF v_owner IS NULL THEN
        RAISE NOTICE 'V002(career): kein Owner in family -> skip (Bootstrap/fresh DB)';
        RETURN;
    END IF;

    -- (a) Prosa-Plan-Doc career_planning -> career_planning__<owner> (wie V001 fuer profile/preferences).
    IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'career_planning')
       AND NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'career_planning__' || v_owner) THEN
        UPDATE agent.core_contexts SET name = 'career_planning__' || v_owner WHERE name = 'career_planning';
        RAISE NOTICE 'V002(career): career_planning -> career_planning__%', v_owner;
    END IF;

    -- (b) advisor_plans-Career-Zeilen (Draft/Active/Superseded) auf den Owner-Anker setzen.
    UPDATE agent.advisor_plans SET person_id = v_owner
    WHERE domain = 'career' AND person_id IS NULL;
END $$;
