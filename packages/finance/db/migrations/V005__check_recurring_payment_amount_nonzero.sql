-- V005__check_recurring_payment_amount_nonzero.sql
-- Versionierte Einmal-Migration (Flyway-V__): struktureller CHECK (amount <> 0) auf
-- finance.recurring_payments (Multi-Member WS-3a, Backlog-Item ii).
--
-- amount ist VORZEICHENBEHAFTET (+ Einnahme / - Ausgabe; interner Transfer: Quell-seitig negativ) ->
-- der Constraint ist `<> 0`, NICHT `> 0`. Eine Null-Betrag-rp ist sinnlos (keine Bewegung, monthly_equivalent=0)
-- und war bisher nur per fn-Guard abgefangen. Dieser Tabellen-Constraint ist der strukturelle BACKSTOP unter
-- den fn-Guards (Projektgesetz "Invariante so tief wie moeglich"): er haertet zugleich den WS-2 v_mag=0-Pfad
-- in fn_book_recurring_transfer. Die tool-fns (fn_create_recurring_payment etc.) fangen 0 schon DAVOR freundlich
-- ab ({ok:false}) -> der CHECK schlaegt nie als Owner-Alert (RAISE) durch, er faengt nur direktes/fehlerhaftes DML.
--
-- KEINE BEGIN/COMMIT (der Treiber wrapt jede Migration in EINE Transaktion). Idempotent geguardet
-- (pg_constraint-Check) -> ein versehentlicher Re-Apply auf bereits migrierten DBs scheitert nicht.
-- Voraussetzung: keine Bestands-Zeile mit amount=0 (Seed/Prod tragen reale Betraege) — sonst wuerde
-- ADD CONSTRAINT die Bestandsdaten validieren und scheitern (gewollt: macht eine kaputte Zeile sichtbar).

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'recurring_payments_amount_nonzero'
          AND conrelid = 'finance.recurring_payments'::regclass
    ) THEN
        ALTER TABLE finance.recurring_payments
            ADD CONSTRAINT recurring_payments_amount_nonzero CHECK (amount <> 0);
    END IF;
END $$;
