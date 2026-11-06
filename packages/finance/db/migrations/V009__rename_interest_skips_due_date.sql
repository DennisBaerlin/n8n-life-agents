-- ============================================================
-- V009 (finance) — Phase Z WS-Z6: interest_skips.due_date -> period_end (Naming-Klarheit).
--
--   Die Spalte traegt seit dem Zins-Ausbau (WS-5c-B) die period_end-Semantik (= stabiler Perioden-
--   Identitaets-Key, kongruent zu transactions.interest_period_end), hiess aber noch due_date. Der Rename
--   macht den Namen ehrlich. recurring_payment_skips.due_date BLEIBT (dort ist es ein echtes
--   Faelligkeitsdatum — begruendete Asymmetrie, keine Symmetrie-Umbenennung).
--
--   PK (account_id, due_date) zieht beim RENAME COLUMN automatisch mit -> (account_id, period_end);
--     kein PK-Rebuild noetig. Kein externer View/Read-Pfad referenziert die Spalte (fn_skip_interest_
--     occurrence + fn_interest_due_open im selben Commit auf period_end gezogen; fn_clear_e2e_data loescht
--     spalten-los per account_id -> rename-sicher).
--
--   GUARDED (IF due_date EXISTS): der Treiber laeuft Inits -> V -> R; auf einer FRISCHEN DB legt die Init die
--     Tabelle bereits mit period_end an, V009 laeuft aber trotzdem genau einmal -> ohne Guard wuerde der bare
--     RENAME dort hart scheitern (keine due_date-Spalte). Mit Guard = No-op auf Fresh, echter Rename auf
--     Bestands-DBs. IDEMPOTENT zusaetzlich gated ueber core.migration_should_apply (genau einmal je DB);
--     kein BEGIN/COMMIT (der db_apply/apply_schema-Treiber wrapt).
-- ============================================================

DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'finance' AND table_name = 'interest_skips' AND column_name = 'due_date'
    ) THEN
        ALTER TABLE finance.interest_skips RENAME COLUMN due_date TO period_end;
    END IF;
END $$;
