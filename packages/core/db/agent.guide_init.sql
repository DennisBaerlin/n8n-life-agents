-- ============================================================
-- Guide-Agent — Onboarding-Zustand
-- Zweck:   agent.guide_onboarding_state traegt den Tri-State je Core-Onboarding-Sektion
--          (unknown/completed/skipped). 'skipped' = bewusst uebersprungen ist selbst ein
--          Beratungsfakt (WpHG-Doku-Praxis) und zaehlt als aufgeloest; nur 'unknown' haelt
--          das Pflicht-Gate geschlossen. Single-User: section_key ist der Key
--          (kein chat_id — eine Onboarding-Spur). Naming agent.{agent}_* (Owner = guide).
--          Der Core haelt nur 'household'; die Finanz-Sektionen sind paket-besessen in
--          finance.onboarding_state (gleiche Spalten). Gelesen/
--          geschrieben wird ueber die Core-Schnittstelle core.fn_onboarding_status /
--          core.fn_set_onboarding_section (eine Zustandsmaschine, paket-schluessel-parametrisiert).
--          status ist text+CHECK (kein geteilter Cross-Schema-ENUM: vermeidet die
--          USAGE-Falle, wenn finance_rw seine gleichgeformte Tabelle unter INVOKER-Rechten schreibt).
-- Usage:   db_apply.ps1 -File packages\core\db\agent.guide_init.sql
-- Tests:   tests/db/core/test_fn_onboarding_status.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.guide_onboarding_state (
    section_key text PRIMARY KEY,
    ord         int  NOT NULL,                       -- Anzeige-/Interview-Reihenfolge
    label       text NOT NULL,                       -- nutzerfreundlicher Sektionsname (DE)
    status      text NOT NULL DEFAULT 'unknown' CHECK (status IN ('unknown', 'completed', 'skipped')),
    skipped_at  timestamptz,                          -- Altlast, ungenutzt (ableitbar aus status+status_changed_at): bleibt nur, weil core:V003 sie beim frischen Bootstrap liest; core:V032 droppt sie
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Kanonische Core-Sektionsliste (nur 'household'; Finanz-Sektionen siehe finance.onboarding_state).
-- Idempotenter Seed: vorhandene Status bleiben erhalten.
INSERT INTO agent.guide_onboarding_state (section_key, ord, label) VALUES
    ('household',   1, 'Haushalt & Personen')
ON CONFLICT (section_key) DO NOTHING;

-- Helper idempotent mit-definiert (Muster agent.monitor_init.sql / agent.advisor_init.sql), damit
-- guide_init standalone anwendbar bleibt — unabhaengig von der Init-Reihenfolge (paket-bewusster Apply:
-- guide sortiert vor monitor/advisor, die den Helper sonst zuerst anlegten).
CREATE OR REPLACE FUNCTION agent.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

-- Roter Faden (Nachfassen): Zeitpunkt der letzten Status-Aenderung (nicht updated_at — Label-Resyncs des Seeders
-- beruehren updated_at). Gesetzt nur von core.fn_set_onboarding_section / core.fn_reset_onboarding_state (die
-- Schreibwege); core.fn_onboarding_nudges_due misst daran den Stillstand. Konvention fuer jedes <pkg>.onboarding_state.
ALTER TABLE agent.guide_onboarding_state ADD COLUMN IF NOT EXISTS status_changed_at timestamptz NOT NULL DEFAULT now();

DROP TRIGGER IF EXISTS trg_guide_onboarding_touch ON agent.guide_onboarding_state;
CREATE TRIGGER trg_guide_onboarding_touch BEFORE UPDATE ON agent.guide_onboarding_state
    FOR EACH ROW EXECUTE FUNCTION agent.touch_updated_at();

-- Lesepfad: der Guide ist ein Core-Agent → sein Frei-SQL laeuft unter der Core-Host-Leserolle
-- core_ro (nicht finance_ro, das eng auf `finance` skopiert ist). Massgeblich ist
-- die Erlaubnisliste in util_create_core_ro (fuehrt diese Tabelle); der GRANT hier ist Backstop. No-op falls core_ro (noch) fehlt (Phase 1 < util_create_core_ro = Phase 4).
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        GRANT SELECT ON agent.guide_onboarding_state TO core_ro;
    END IF;
END $$;
