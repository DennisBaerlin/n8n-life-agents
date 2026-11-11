-- career:V008 — Spalte for_roles an career.onboarding_state fuer Bestandsinstallationen (Endzustand im career.tables_init.sql).
--   NULL = Abschnitt gilt fuer alle Rollen; die Werte schreibt nur der Host-Seeder aus packages/career/onboarding/sections.json.
--   Wertevorrat wie agent.pairing_state.role und der family-Validator (agent.core_init.sql).
ALTER TABLE career.onboarding_state ADD COLUMN IF NOT EXISTS for_roles text[];

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'onboarding_state_for_roles_check'
                   AND conrelid = 'career.onboarding_state'::regclass) THEN
        ALTER TABLE career.onboarding_state ADD CONSTRAINT onboarding_state_for_roles_check
            CHECK (for_roles IS NULL OR (cardinality(for_roles) > 0 AND for_roles <@ ARRAY['owner', 'partner', 'child']::text[]));
    END IF;
END $$;
