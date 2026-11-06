-- ============================================================
-- V012 (core) -- Phase Notify: Konsolidierung der Owner-Benachrichtigungs-Dedup-State auf die GETEILTE
--   core.notification_state. Droppt die zwei alten producer-eigenen State-Tabellen EINMALIG:
--     * core.advisor_review_state  (Advisor-Drift-Edge-Latch) -> migriert; R__fn_advisor_review_evaluate
--       latcht jetzt ueber core.fn_should_notify/fn_notify_reconcile (source='advisor:'||domain).
--     * agent.knock_log            (Knock-Cooldown)           -> migriert; agent.fn_register_knock ruft
--       core.fn_should_notify('knock', uid, cooldown).
--
--   WARUM eine V-Migration: ein Tabellen-DROP ist kein CREATE-OR-REPLACE; die CREATEs sind aus den Inits
--   (core.advisors_init.sql / agent.pairing_init.sql) entfernt -> Fresh-Install legt sie nie an, aber eine
--   bestehende DB braucht den einmaligen DROP.
--
--   SICHER: kein View/FK haengt an beiden Tabellen (geprueft); plpgsql-Koerper sind keine harten pg_depend
--   -> KEIN CASCADE noetig. Apply-Order Inits -> V (hier) -> R: der DROP laeuft VOR den repointeden R__-fns
--   derselben Runde; zur Laufzeit existieren nur die neuen, auf core.notification_state gebauten Koerper.
--   Der ephemere Latch-Zustand (regeneriert sich beim naechsten Knock/Review) wird NICHT migriert -> hoechstens
--   EINE Dublette/verpasste Unterdrueckung direkt nach dem Deploy (single-user, tolerierbar). IDEMPOTENT
--   (IF EXISTS); Fresh DB = No-op.
-- ============================================================

DROP TABLE IF EXISTS core.advisor_review_state;
DROP TABLE IF EXISTS agent.knock_log;
