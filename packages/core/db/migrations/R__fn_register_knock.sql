-- ============================================================
-- fn_register_knock (Owner-Notify-Anti-Spam — Phase 4 Multi-User)
--   Drosselt die Owner-Benachrichtigung ueber UNBEKANNTE Absender (Knock). Mit der auf '*'
--   geoeffneten Telegram-Allowlist kann jeder den Bot anschreiben -> ohne Drossel waere die
--   Owner-Notify ein Flood-Vektor. notify=true nur beim ERSTEN Knock bzw. wenn die letzte
--   Benachrichtigung aelter als das Cooldown-Fenster ist. Der Knockende wird vom Orchestrator
--   trotzdem JEDESMAL ge-ack'd (nur die Owner-Notify ist gedrosselt).
--   Phase Notify: der Cooldown-Zustand lebt jetzt in der GETEILTEN core.notification_state
--   (source='knock', key=uid) statt der frueheren agent.knock_log -> EINE Dedup-Adresse aller Producer.
--   WS-5d: ein in agent.access_blocks gesperrter Anklopfer -> {notify:false} (kein Owner-Spam), KEIN
--          Latch-Touch (Guard als erste Anweisung).
--   p_uid:      numerische from.id; NULL (Testpfad ohne from.id) -> {notify:false} (kein Spam).
--   p_cooldown: Mindestabstand zwischen zwei Owner-Notifies derselben Identitaet (Default 1h, als TTL).
--   RUECKGABE:  { notify: bool }
--   Race-fest ueber das fn_should_notify-Fenster (INSERT ON CONFLICT -> FOR UPDATE).
--   Tests: tests/db/core/test_fn_register_knock.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_register_knock(p_uid bigint, p_cooldown interval DEFAULT '1 hour')
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF p_uid IS NULL THEN
        RETURN jsonb_build_object('notify', false);
    END IF;

    -- WS-5d: gesperrter Anklopfer -> NIE benachrichtigen und KEIN Latch-Touch (Guard als erste Anweisung,
    -- vor jedem Read/Write -> kein Spam-Schlupf, keine Latch-Zeile fuer eine gesperrte uid).
    IF agent.fn_is_blocked(p_uid) THEN
        RETURN jsonb_build_object('notify', false, 'blocked', true);
    END IF;

    -- Phase Notify: der Cooldown laeuft jetzt ueber die GETEILTE Dedup-Schicht core.notification_state
    -- (source='knock', key=uid). p_cooldown als TTL -> erstes Mal feuert, innerhalb des Fensters still, nach
    -- Ablauf wieder -> byte-genau identisches Verhalten zur frueheren agent.knock_log-last_notified_at-Logik
    -- (Fenster ab dem letzten NOTIFY). Das frueher zurueckgegebene knock_count nutzt der Orchestrator nicht.
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
