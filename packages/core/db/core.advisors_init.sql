-- ============================================================
-- core.advisors — generische Advisor-Registry (WS2, Core-Advisor-Engine)
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.advisors_init.sql
--
-- Zweck: bindet eine Advisor-Domaene (z. B. 'finance') an ihren Soll-Anker-Context (plan_context) +
--   die PAKET-Review-fn, die Soll-Ist-Drift + Staleness + den periodischen Digest rechnet. Der generische
--   Core-Eval-Wrapper core.fn_advisor_review_evaluate(domain) dispatcht GENERISCH ueber diese Tabelle
--   (domain -> review_fn -> dyn. EXECUTE) — der Core nennt KEIN Paket hartkodiert. Geschwister zu
--   core.context_validators / core.context_renderers / core.protected_contexts / core.services.
--
-- plan_context = der Soll-Anker der Domaene, aber NICHT zwingend ein publizierter Plan:
--   * finance/career: plan_context ist das PUBLIZIERTE Plan-Sidecar (financial_planning/career_planning),
--     das die Berater-Maschinerie (agent.advisor_plans + fn_advisor_publish_plan) schreibt — Soll = Plan.
--   * estate (WS-4): plan_context 'estate_overview' ist ein RENDER-AT-FETCH-Lese-Context (die Register-
--     Tabellen sind die Wahrheit), der NIE publiziert wird (arch-challenge P5) — ein realer Primaer-Anker,
--     kein Sentinel; die review_fn liest die Register-/Gap-Wahrheit direkt, nicht ein Plan-Sidecar.
--   Der Wrapper/Cron braucht den Unterschied nicht zu kennen (er joint nur die gerenderten alert/digest-text-
--   Felder der review_fn); plan_context steuert nur, WAS die Domaene als Soll versteht.
--
-- BOUNDARY (Deklaration vs. Ausfuehrung, docs/package-contract.md §3): das PAKET DEKLARIERT die
--   Bindung NUR im manifest.json ("advisors"-Block, verschachtelt {domain:{plan_context,review_fn}});
--   der HOST (seed_data.sh, jq) UPSERTET die Zeile (own-schema-scoped: review_fn muss <pkg>.* sein).
--   Paket-Rollen sind via D10 schema-isoliert und haben auf Schema core KEINEN Zugriff -> koennen die
--   Registry strukturell nicht schreiben (einziger Schreiber = Installer/Owner-Superuser).
--
-- EINE Zeile je Domain (PRIMARY KEY domain).
--
-- SICHERHEIT (dyn. SQL im Eval-Wrapper, CVE-2018-1058): review_fn ist NUR installer-geschrieben (nie
--   $fromAI/User-Input). Der CHECK erzwingt einen schema-qualifizierten, kleingeschriebenen Bezeichner
--   ohne Injection-Zeichen; der Wrapper pinnt search_path=pg_catalog + to_regprocedure-Guard.
--
-- Tunbare Skalare (Kadenz schedule.drift_check/plan_review, Modell model.advisor_review) leben in
--   core.config (NICHT hier — KEINE Modell-Kopplung in die Registry; der Selector-Node fragt Config ab).
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.advisors (
    domain        text PRIMARY KEY,                -- == agent.advisor_plans.domain (z. B. 'finance')
    plan_context  text NOT NULL,                   -- agent.core_contexts.name des Soll-Sidecars (z. B. 'financial_planning')
    review_fn     text NOT NULL                    -- schema-qualifizierte fn(text,text,jsonb)->jsonb (domain, person_id, opts); rechnet Drift/Staleness/Digest
                  CHECK (review_fn ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),  -- schema.fn, lowercase, kein Injection-Zeichen
    -- Datenquelle Domaene->Agent (Phase 0 WS-0c #1): der Orchestrator-Interview-Pin emittiert per JOIN den
    -- advisor_agent der Domaene mit aktivem Interview-Draft -> der Router-Prompt pinnt dorthin (statt frueher
    -- hartkodiert agent.finance_advisor). nullable bis der Seed sie aus dem Manifest-advisors-Block setzt;
    -- der benannte CHECK kommt idempotent ueber das ALTER unten (deckt fresh CREATE + additiven Nachbau).
    advisor_agent text,                            -- Router-Ziel der Domaene, z. B. 'agent.finance_advisor' / 'agent.career_advisor'
    package       text NOT NULL DEFAULT '',        -- deklarierendes Paket (Audit / Uninstall-Purge-Scope)
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);
-- Additive DDL (idempotent, kein V noetig): advisor_agent-Spalte + benannter CHECK nachruesten, falls die
-- Tabelle aus einer aelteren Version stammt (CREATE TABLE oben ist dann ein No-op). EIN CHECK, EINMAL benannt.
ALTER TABLE core.advisors ADD COLUMN IF NOT EXISTS advisor_agent text;
-- Phase A: explizites Opt-in, ob das Plan-Dokument (plan_context) owner-bestaetigte Lern-Notizen ('## Gelernt')
-- tragen darf — Quelle von core.fn_note_context_allowed (ersetzt die Literal-Liste family/financial_planning).
-- Default false (fail-closed); der Seed setzt es aus dem Manifest-advisors-Block.
ALTER TABLE core.advisors ADD COLUMN IF NOT EXISTS learn_notes boolean NOT NULL DEFAULT FALSE;
-- Roter Faden (2026-10-23): die Domaene hat einen EIGENEN Review-Cron (estate: cron_review_register, kein Publish)
-- -> die geteilten Advisor-Crons (drift_check/plan_review, Get-AdvisorFanoutCte) lassen sie aus. Sonst latchte der
-- geteilte Drift-Waechter ihre Alerts unter "Plan-Abweichung" (falscher Rahmen + falscher Abschalten-Knopf) und der
-- eigene Cron faende den Latch schon verbraucht. Default false; der Seed setzt es aus dem Manifest-advisors-Block.
ALTER TABLE core.advisors ADD COLUMN IF NOT EXISTS own_review_cron boolean NOT NULL DEFAULT FALSE;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'advisors_advisor_agent_check') THEN
        ALTER TABLE core.advisors ADD CONSTRAINT advisors_advisor_agent_check
            CHECK (advisor_agent IS NULL OR advisor_agent ~ '^agent\.[a-z][a-z0-9_]*$');
    END IF;
END $$;
-- KEIN updated_at-Touch-Trigger (Muster core.context_validators/_renderers): core.touch_updated_at lebt
-- in core.package_registry_init.sql, das ALPHABETISCH NACH dieser Datei applied wird (advisors < package).
-- Der Seed setzt updated_at im ON CONFLICT DO UPDATE explizit.

-- ============================================================
-- Latch-/Alert-Dedup-State der Drift-Engine: MIGRIERT (Phase Notify).
--   Der frueher engine-eigene Latch core.advisor_review_state ((domain,metric_key)) ist auf die GETEILTE
--   core.notification_state (core.notification_init.sql; source='advisor:'||domain, key=metric_key) umgezogen
--   -> EINE Dedup-Adresse aller Owner-Benachrichtigungs-Producer (knock/Folds/advisor). Der Engine-Latch
--   laeuft jetzt ueber core.fn_should_notify/fn_notify_reconcile (s. R__fn_advisor_review_evaluate.sql).
--   Die alte Tabelle droppt einmalig V012__consolidate_notification_state.sql.
-- ============================================================
