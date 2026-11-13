-- ============================================================
-- fn_register_knock (ATOMIC WRITE — Owner-Notify-Anti-Spam fuer unbekannte Absender)
--   Drosselt die Owner-Benachrichtigung ueber unbekannte Absender (Knock). Mit der auf '*'
--   geoeffneten Telegram-Allowlist kann jeder den Bot anschreiben -> ohne Drossel waere die
--   Owner-Notify ein Flood-Vektor. notify=true nur beim ersten Knock bzw. wenn die letzte
--   Benachrichtigung aelter als das Cooldown-Fenster ist. Der Knockende wird vom Orchestrator
--   trotzdem jedes Mal ge-ack'd (nur die Owner-Notify ist gedrosselt).
--   Der Cooldown-Zustand lebt in der geteilten core.notification_state (source='knock', key=uid).
--   Ein in agent.access_blocks gesperrter Anklopfer -> {notify:false, blocked:true} (kein Owner-Spam),
--   kein Latch-Touch (Guard als erste Anweisung).
--   p_uid:      numerische from.id; NULL (Testpfad ohne from.id) -> {notify:false} (kein Spam).
--   p_cooldown: Mindestabstand zwischen zwei Owner-Notifies derselben Identitaet (Default 1h, als TTL).
--   Rueckgabe:  { notify: bool, blocked?: true }
--   Race-fest ueber das fn_should_notify-Fenster (INSERT ON CONFLICT -> FOR UPDATE).
--   Tests: tests/db/core/test_fn_register_knock.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_register_knock(p_uid bigint, p_cooldown interval DEFAULT '1 hour')
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF p_uid IS NULL THEN
        RETURN jsonb_build_object('notify', false);
    END IF;

    -- Gesperrter Anklopfer -> nie benachrichtigen und kein Latch-Touch (Guard als erste Anweisung,
    -- vor jedem Read/Write -> kein Spam-Schlupf, keine Latch-Zeile fuer eine gesperrte uid).
    IF agent.fn_is_blocked(p_uid) THEN
        RETURN jsonb_build_object('notify', false, 'blocked', true);
    END IF;

    -- Cooldown ueber die geteilte Dedup-Schicht core.notification_state (source='knock', key=uid).
    -- p_cooldown als TTL -> erstes Mal feuert, innerhalb des Fensters still, nach Ablauf wieder
    -- (Fenster ab dem letzten Notify).
    RETURN jsonb_build_object('notify', core.fn_should_notify('knock', p_uid::text, p_cooldown));
END;
$$;

-- Schreibpfad-fn (Orchestrator unter der Haupt-Credential): EXECUTE-REVOKE fuer die Leserollen.
REVOKE ALL ON FUNCTION agent.fn_register_knock(bigint, interval) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_register_knock(BIGINT, INTERVAL) FROM context_ro;
    END IF;
END $$;
