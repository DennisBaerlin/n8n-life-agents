-- ============================================================
-- test_monitor_triggers_domain_label -- UNIQUE (domain, lower(label)) auf agent.monitor_triggers ist das Gesetz
--   Derselbe Label in derselben Domain (Gross-/Kleinschreibung egal) -> unique_violation; in einer anderen Domain erlaubt.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_hit BOOLEAN := false;
BEGIN
    INSERT INTO agent.monitor_triggers (domain, label, trigger_type, check_interval)
    VALUES ('zz_dom', 'Mein Beobachter', 'recurring_info', interval '1 day');

    BEGIN
        INSERT INTO agent.monitor_triggers (domain, label, trigger_type, check_interval)
        VALUES ('zz_dom', 'mein beobachter', 'recurring_info', interval '1 day');
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%monitor_triggers_domain_label%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [Dublette]: gleicher Label (andere Schreibweise) in derselben Domain akzeptiert'; END IF;
    RAISE NOTICE 'PASS [Dublette]: zweiter Insert derselben (domain, lower(label)) -> unique_violation';

    INSERT INTO agent.monitor_triggers (domain, label, trigger_type, check_interval)
    VALUES ('zz_other', 'Mein Beobachter', 'recurring_info', interval '1 day');
    RAISE NOTICE 'PASS [andere Domain]: gleicher Label in anderer Domain erlaubt';
END $$;
ROLLBACK;
