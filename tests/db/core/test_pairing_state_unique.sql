-- ============================================================
-- test_pairing_state_unique -- die drei partiellen UNIQUE-Indizes auf agent.pairing_state sind das Gesetz
--   pairing_state_one_open_per_user   (telegram_user_id, offen)  -- eine Nutzer-ID hoechstens eine offene Zeile
--   pairing_state_one_open_owner      (role = owner, offen)      -- hoechstens ein offener Owner-Bind
--   pairing_state_one_open_per_person (person_id, offen)         -- eine Person hoechstens eine offene Zeile
--   Je Index: zweiter Insert -> unique_violation; das Praedikat laesst Legitimes zu (verbrauchte Zeilen, NULL-Schluessel).
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_hit BOOLEAN;
BEGIN
    DELETE FROM agent.pairing_state;

    -- ===== per_user =====
    INSERT INTO agent.pairing_state (telegram_user_id, role, challenge, expires_at)
    VALUES (900001, 'partner', 'AAAAAAAA01', now() + interval '1 hour');
    v_hit := false;
    BEGIN
        INSERT INTO agent.pairing_state (telegram_user_id, role, challenge, expires_at)
        VALUES (900001, 'child', 'AAAAAAAA02', now() + interval '1 hour');
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%pairing_state_one_open_per_user%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [per_user]: zweite offene Zeile derselben telegram_user_id akzeptiert'; END IF;
    -- Praedikat: verbrauchte Zeile derselben ID und mehrere NULL-IDs sind erlaubt
    INSERT INTO agent.pairing_state (telegram_user_id, role, challenge, expires_at, consumed_at)
    VALUES (900001, 'child', 'AAAAAAAA03', now() + interval '1 hour', now());
    INSERT INTO agent.pairing_state (role, challenge, expires_at) VALUES ('child', 'AAAAAAAA04', now() + interval '1 hour');
    INSERT INTO agent.pairing_state (role, challenge, expires_at) VALUES ('child', 'AAAAAAAA05', now() + interval '1 hour');
    RAISE NOTICE 'PASS [per_user]: zweiter offener Insert -> unique_violation, verbrauchte/NULL erlaubt';

    -- ===== owner =====
    INSERT INTO agent.pairing_state (role, challenge, expires_at) VALUES ('owner', 'BBBBBBBB01', now() + interval '1 hour');
    v_hit := false;
    BEGIN
        INSERT INTO agent.pairing_state (role, challenge, expires_at) VALUES ('owner', 'BBBBBBBB02', now() + interval '1 hour');
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%pairing_state_one_open_owner%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [owner]: zweiter offener Owner-Bind akzeptiert'; END IF;
    -- Praedikat: ein verbrauchter Owner blockt keinen neuen; mehrere offene Partner sind erlaubt
    INSERT INTO agent.pairing_state (role, challenge, expires_at, consumed_at) VALUES ('owner', 'BBBBBBBB03', now() + interval '1 hour', now());
    INSERT INTO agent.pairing_state (role, challenge, expires_at) VALUES ('partner', 'BBBBBBBB04', now() + interval '1 hour');
    INSERT INTO agent.pairing_state (role, challenge, expires_at) VALUES ('partner', 'BBBBBBBB05', now() + interval '1 hour');
    RAISE NOTICE 'PASS [owner]: zweiter offener Owner -> unique_violation, verbrauchter/Partner erlaubt';

    -- ===== per_person =====
    INSERT INTO agent.pairing_state (person_id, role, challenge, expires_at)
    VALUES ('zz_person', 'partner', 'CCCCCCCC01', now() + interval '1 hour');
    v_hit := false;
    BEGIN
        INSERT INTO agent.pairing_state (person_id, role, challenge, expires_at)
        VALUES ('zz_person', 'child', 'CCCCCCCC02', now() + interval '1 hour');
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%pairing_state_one_open_per_person%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [per_person]: zweite offene Zeile derselben person_id akzeptiert'; END IF;
    INSERT INTO agent.pairing_state (person_id, role, challenge, expires_at, consumed_at)
    VALUES ('zz_person', 'child', 'CCCCCCCC03', now() + interval '1 hour', now());
    RAISE NOTICE 'PASS [per_person]: zweiter offener Insert -> unique_violation, verbrauchte erlaubt';
END $$;
ROLLBACK;
