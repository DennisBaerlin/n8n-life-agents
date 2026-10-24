-- ============================================================
-- V003 (core) — WS-B3: DRY-Onboarding. Die Onboarding-Zustandsmaschine wird Core-generisch
--   (core.fn_onboarding_status / core.fn_set_onboarding_section, paket-schluessel-parametrisiert), die
--   DATEN paket-besessen. Diese versioned Migration raeumt den ALTBESTAND einer Vor-WS-B3-DB (einmalig,
--   ledger-gegated). Fresh-DB: die Inits legen bereits den Endzustand an -> jeder Schritt ist No-op.
--
--   (a) agent.guide_onboarding_state.status: ENUM -> text+CHECK (arch-challenge D4 — vermeidet die
--       Cross-Schema-Type-USAGE-Falle, wenn finance_rw seine gleichgeformte Tabelle unter INVOKER schreibt).
--       Idempotent geguarded ueber information_schema (nur falls die Spalte noch USER-DEFINED/enum ist).
--   (b) DROP TYPE agent.onboarding_status (nach dem Spalten-Swap; plpgsql-fn-Bodies sind keine Dependency).
--   (c) DROP-Orphans agent.fn_onboarding_status() + agent.fn_set_onboarding_section(jsonb) — nach core
--       verschoben (R__-Repeatables legen core.fn_* an; die alten R__-Bodies emittieren die agent.fn_* nicht
--       mehr, sonst machte die R-Phase diesen DROP jeden Apply rueckgaengig).
--   (d) Split-Backfill (idempotent): die 5 Finanz-Sektions-Zeilen (inkl. status) nach finance.onboarding_state
--       heben (falls Paket installiert), dann aus der Core-Tabelle entfernen (immer — Core haelt nur 'household').
--
-- APPLY-ORDER: Inits (guide_init=text+CHECK-Endzustand, finance.onboarding_state) -> V (hier) -> R (core.fn_*)
--   -> seed_data (sections.json). Re-run-sicher; ledger-gegated = laeuft genau einmal.
-- ============================================================

-- (a) status ENUM -> text+CHECK (nur falls noch USER-DEFINED; Fresh-DB hat die Spalte schon als text)
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'agent' AND table_name = 'guide_onboarding_state'
          AND column_name = 'status' AND data_type = 'USER-DEFINED'
    ) THEN
        ALTER TABLE agent.guide_onboarding_state ALTER COLUMN status DROP DEFAULT;
        ALTER TABLE agent.guide_onboarding_state ALTER COLUMN status TYPE text USING status::text;
        ALTER TABLE agent.guide_onboarding_state ALTER COLUMN status SET DEFAULT 'unknown';
        ALTER TABLE agent.guide_onboarding_state
            ADD CONSTRAINT guide_onboarding_state_status_check
            CHECK (status IN ('unknown', 'completed', 'skipped'));
    END IF;
END $$;

-- (b) geteilten ENUM droppen (Spalten nutzen ihn nach (a) nicht mehr; Fresh: nie angelegt -> No-op)
DROP TYPE IF EXISTS agent.onboarding_status;

-- (c) Orphan-fns droppen (nach core verschoben)
DROP FUNCTION IF EXISTS agent.fn_onboarding_status();
DROP FUNCTION IF EXISTS agent.fn_set_onboarding_section(jsonb);

-- (d) Split-Backfill: Finanz-Sektionen aus der Core-Tabelle -> finance.onboarding_state (Daten-Erhalt)
DO $$ BEGIN
    IF to_regclass('finance.onboarding_state') IS NOT NULL THEN
        INSERT INTO finance.onboarding_state (section_key, ord, label, status, skipped_at)
        SELECT section_key, ord, label, status, skipped_at
        FROM agent.guide_onboarding_state
        WHERE section_key IN ('accounts', 'investments', 'liabilities', 'protection', 'goals')
        ON CONFLICT (section_key) DO NOTHING;
    END IF;
END $$;

DELETE FROM agent.guide_onboarding_state
WHERE section_key IN ('accounts', 'investments', 'liabilities', 'protection', 'goals');
