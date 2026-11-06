-- ============================================================
-- V001 (career) — Bestands-Career-PII von haushaltsweit auf per_user (Name-Suffix) migrieren.
--
--   WARUM eine V-Migration: P0b stellt career_profile/career_preferences im Manifest auf scope='per_user'
--   um (physischer Speicher '<base>__<person_id>'). Eine Bestands-DB (Prod), in der der Owner bereits
--   Career-Profil/-Vorlieben am BASIS-Namen erfasst hat, braucht eine EINMALIGE Umbenennung auf den
--   suffigierten Owner-Namen — sonst stuende die Bestands-PII am leeren Basis-Namen und der per_user-Read
--   (fn_fetch_context mit chat_id) faende sie nie (genau der "einmalige Daten-Backfill", fuer den V__-
--   Migrationen da sind, db/CLAUDE.md *Migrations-Modell*).
--
--   OWNER-pid DIREKT aus family.facts.persons[] WHERE role='owner' (person_id-Slug; NICHT via
--   fn_resolve_sender, das eine telegram_user_id braeuchte). Genau ein Owner-Person (LIMIT 1 deterministisch).
--
--   SICHER + IDEMPOTENT: UPDATE name (KEIN DELETE -> der BEFORE-DELETE-Protect-Trigger feuert nicht; der
--   Validate-Trigger re-validiert die UNVERAENDERTEN facts = ok). Per-Kontext geguardet (ein halb-fertiger
--   Re-Run vollendet den anderen Kontext): Basis-Zeile fehlt / Ziel-Zeile existiert schon / kein Owner -> skip.
--   Fresh DB OHNE Bestands-Basis-Zeile = no-op. Re-Run nach vollzogener Migration = no-op (Basis weg).
--
--   APPLY-ORDER: Inits -> V (hier) -> R (die fns lesen danach den suffigierten Namen). Re-run-sicher.
-- ============================================================

DO $$
DECLARE
    v_owner TEXT;
    v_base  TEXT;
BEGIN
    SELECT pp->>'person_id' INTO v_owner
    FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
    WHERE c.name = 'family' AND pp->>'role' = 'owner'
    LIMIT 1;

    IF v_owner IS NULL THEN
        RAISE NOTICE 'V001(career): kein Owner in family -> skip (Bootstrap/fresh DB)';
        RETURN;
    END IF;

    FOREACH v_base IN ARRAY ARRAY['career_profile', 'career_preferences'] LOOP
        -- Nur wenn die Basis-Zeile existiert UND die Ziel-(Suffix-)Zeile noch nicht -> umbenennen; sonst skip.
        IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = v_base)
           AND NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = v_base || '__' || v_owner) THEN
            UPDATE agent.core_contexts SET name = v_base || '__' || v_owner WHERE name = v_base;
            RAISE NOTICE 'V001(career): % -> %__%', v_base, v_base, v_owner;
        END IF;
    END LOOP;
END $$;
