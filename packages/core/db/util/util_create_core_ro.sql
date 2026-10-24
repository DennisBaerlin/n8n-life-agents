-- ============================================================
-- util_create_core_ro.sql — Read-Only-Login-Rolle fuer den LESEPFAD DER CORE-AGENTEN
--   Anwenden via: db_apply.ps1 -File packages/core/db/util/util_create_core_ro.sql
--
--   Zweck (Core/Package-Architektur, D10 + Owner-Lock 2026-06-18): die CORE-Agenten
--   (agent.monitor, agent.guide) lassen das LLM freies SELECT-SQL formulieren
--   (postgres_select). Sie lesen quer ueber ihre EIGENEN Core-Tabellen (agent.monitor_*,
--   agent.guide_onboarding_state) UND ueber die Finance-Uebersichten. Die enge Paket-Rolle
--   `finance_ro` (schema-scoped, via core.fn_provision_package_roles) reicht dafuer NICHT —
--   sie sieht NUR `finance`. `core_ro` ist die Leserolle des PRIVILEGIERTEN CORE-HOSTS:
--   read-only auf agent + core (seine eigenen Daten); den Finance-Lesezugriff oeffnet das
--   Finance-PAKET selbst bei der Provisionierung (core.fn_provision_package_roles grantet
--   core_ro SELECT auf `finance` — own-schema-scoped, faellt bei Deinstall weg).
--
--   ABGRENZUNG zu den Paket-Isolations-Rollen: `core_ro` ist KEINE Isolations-Paketrolle
--   (Core ist der privilegierte, isolations-ausgenommene Host — er DARF jedes Paket
--   read-only sehen; das ist ein System-Invariant, kein Paket-Opt-in). Die Phase-2-Contract-
--   Notiz "Core hat keine core_rw/core_ro" meinte die ISOLATIONS-Paketrollen (die Core nicht
--   bekommt); `core_ro` ist davon getrennt: die Schreibschutz-Leserolle des Frei-SQL-Pfads.
--
--   Schreibschutz ist der Kern: das LLM formuliert beliebiges SQL → eine read-only-Rolle
--   stellt strukturell sicher, dass ein halluziniertes DELETE/UPDATE physisch scheitert.
--
--   KEIN Passwort hier (kein Secret im Repo). Der Installer setzt es out-of-band
--   (bootstrap_owner._provision_ro_secrets) + hinterlegt es in der n8n-Credential.
-- ============================================================

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        CREATE ROLE core_ro LOGIN;
    END IF;
END $$;

-- Sicherheits-Defaults der Rolle (greifen beim Connect)
ALTER ROLE core_ro SET default_transaction_read_only = on;          -- jeder Write scheitert
ALTER ROLE core_ro SET statement_timeout = '15s';                   -- kein Query-DoS
ALTER ROLE core_ro SET idle_in_transaction_session_timeout = '30s';
-- search_path: nur die Host-Basis (pg_catalog, agent, core). Der PAKET-Tail (finance/career/…) kommt
-- generisch je Paket-Install ueber core.fn_sync_role_search_paths('core_ro') in fn_provision_package_roles
-- (Desired-State aus core.package_registry) — KEIN finance-Hardcode mehr (Multi-Paket, B). Bei Core-Apply
-- existiert noch kein Paket -> reine Basis; jeder Paket-Install recomputet den Tail dazu.
ALTER ROLE core_ro SET search_path = pg_catalog, agent, core;

-- Lesen auf den Core-Schemata (TABLES deckt auch VIEWs ab). Finance NICHT hier — das
-- Lesefenster oeffnet das Finance-Paket bei der Provisionierung (core.fn_provision_package_roles).
GRANT USAGE ON SCHEMA agent, core TO core_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA agent TO core_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core  TO core_ro;

-- Kuenftige Tabellen/Views (von postgres angelegt) automatisch lesbar machen.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA agent GRANT SELECT ON TABLES TO core_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA core  GRANT SELECT ON TABLES TO core_ro;

-- AUSNAHME (Security-Review Krypto-Rework, Finding 1; uebernommen aus dem retired
-- util_create_finance_ro): core.backup_key traegt den Backup-Schluessel und darf NIE an eine
-- LLM-Leserolle. Der REVOKE lebt HIER (wo der breite core-GRANT entsteht), damit ein
-- Routine-Re-Apply die ACL nicht still re-grantet. test_core_backup_key_acl.sql asserted das.
DO $$ BEGIN
    IF to_regclass('core.backup_key') IS NOT NULL THEN
        REVOKE ALL ON core.backup_key FROM core_ro;
    END IF;
END $$;

-- DENY-LISTE (Security-Audit 2026-10, Owner-Entscheid "strikt privat"): Tabellen mit fremden Gespraechen, Einmal-Codes
-- oder rohen Eingaengen sind fuer den Frei-SQL-Pfad (guide/monitor-LLM, Monitor-Specs) tabu. Gleiche Begruendung wie
-- core.backup_key: der REVOKE lebt am Ort des Sammel-Grants, damit ein Re-Apply nichts still re-grantet. Die
-- *_chat_memory-Tabellen legt n8n zur Laufzeit an -> dynamisch ueber pg_tables. Die per_user-Kontext- und
-- Personen-Plan-ZEILEN sperrt RLS (agent.core_init.sql / agent.advisor_init.sql). Test: test_core_ro_deny_acl.sql.
DO $$
DECLARE v_t text;
BEGIN
    FOR v_t IN
        SELECT format('%I.%I', schemaname, tablename) FROM pg_tables
         WHERE schemaname = 'agent'
           AND (right(tablename, 12) = '_chat_memory'
                OR tablename IN ('pairing_state', 'ingress_buffer', 'hitl_pending'))
    LOOP
        EXECUTE format('REVOKE ALL ON %s FROM core_ro', v_t);
    END LOOP;
END $$;

-- Monitor-Specs (Security-Audit 2026-10): agent.fn_monitor_ro_eval fuehrt die gespeicherte Trigger-Abfrage als
-- SECURITY DEFINER mit Eigentuemer core_ro aus — in einer DEFINER-fn lehnt PostgreSQL jeden Rollenwechsel ab, die
-- Abfrage kann core_ro also nicht ablegen. Der Eigentuemerwechsel lebt HIER (die Rolle existiert erst ab hier; ein
-- Superuser darf OWNER TO ohne CREATE-Recht, CREATE OR REPLACE in der R__ behaelt den Eigentuemer). EXECUTE an
-- core_ro: die App-Rolle (Cron) erreicht die fn ueber ihre core_ro-Mitgliedschaft, die Paket-Rollen nicht.
DO $$ BEGIN
    IF to_regprocedure('agent.fn_monitor_ro_eval(text, text)') IS NOT NULL THEN
        ALTER FUNCTION agent.fn_monitor_ro_eval(text, text) OWNER TO core_ro;
        REVOKE ALL ON FUNCTION agent.fn_monitor_ro_eval(text, text) FROM public;
        GRANT EXECUTE ON FUNCTION agent.fn_monitor_ro_eval(text, text) TO core_ro;
    END IF;
END $$;

-- Gebundene Person-Lesefenster (Security-Audit 2026-10): der career_advisor liest seinen Plan ueber read_plan unter der
-- Haupt-Credential (chat_id build-fix, nie $fromAI); die App-Rolle erreicht das DEFINER-Fenster ueber ihre
-- core_ro-Mitgliedschaft. Ein Frei-SQL-Aufruf (Login-Rolle *_ro) bekommt fuer per_user-Domaenen nichts
-- (core.fn_is_free_sql_session im Fenster).
DO $$ BEGIN
    IF to_regprocedure('core.fn_advisor_read_plan(text, text)') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_advisor_read_plan(text, text) TO core_ro;
    END IF;
END $$;

-- WS-2 (Onboarding-UX): EXECUTE auf das kombinierte Onboarding-Lesefenster core.fn_onboarding_status(text)
-- fuer core_ro. Der Guide (Core-Agent, core_ro) zeigt die frische Wiedereinstiegs-Checkliste ueber diese
-- EINE fn (statt eines rohen UNION ueber agent.guide_onboarding_state + finance.onboarding_state) —
-- zentralisiert die Paket-Absenz-to_regclass-Logik ("ein Fakt, eine Adresse"). Das DEFINER-Fenster REVOKEt
-- PUBLIC in seiner R__ und grantet sonst nur die Paket-Rollen; der core_ro-Grant lebt deshalb HIER am
-- Rollen-Ort (NICHT in der fn-R__: die re-REVOKEt PUBLIC bei jedem Apply und wuerde diesen Grant nicht
-- erfassen). DEFINER-Hygiene bleibt: das Lesefenster ist strukturell auf *.onboarding_state begrenzt.
-- Guarded auf fn-Existenz (Apply-Order Baseline->V->R->util garantiert sie; Guard = idempotenter Backstop).
DO $$ BEGIN
    IF to_regprocedure('core.fn_onboarding_status(text, text)') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_onboarding_status(text, text) TO core_ro;   -- P2b-1: +p_chat_id (core:V016 droppt die 1-arg-Form -> Grant MUSS auf die neue Arity, sonst stiller permission denied)
    END IF;
END $$;

-- WS-3 (Onboarding-Sequenzierung): EXECUTE auf das Discovery-Fenster core.fn_onboarding_pending_packages()
-- fuer core_ro. Der Guide bietet nach Haushalts-Abschluss generisch die offenen Paket-Onboardings an (liest
-- die fn unter core_ro). Das DEFINER-Fenster REVOKEt PUBLIC in seiner R__ und grantet sonst NICHTS -> der
-- core_ro-Grant lebt HIER am Rollen-Ort (NICHT in der fn-R__: die re-REVOKEt PUBLIC bei jedem Apply und
-- wuerde diesen Grant nicht erfassen). KEINE Paket-Rollen (kein Paket-Agent konsumiert die Liste). Guarded
-- auf fn-Existenz (idempotenter Backstop; Apply-Order Baseline->V->R->util garantiert sie).
DO $$ BEGIN
    IF to_regprocedure('core.fn_onboarding_pending_packages()') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_onboarding_pending_packages() TO core_ro;
    END IF;
END $$;

-- P1 (Generisches Paket-Onboarding; P2b-1 +p_chat_id): EXECUTE auf das DB-getriebene Menue-Lesefenster
-- core.fn_onboarding_overview(text) fuer core_ro (V016 droppt die no-arg-Form). core.sub_send_onboarding_menu (laeuft unter
-- __CRED_POSTGRES_CORE_RO__) liest damit den kompletten Menue-Zustand (Core-Haushalt + alle aktiven
-- Pakete) ueber EINE fn — kein build-time-Sektions-Read, kein Paket-Literal mehr (core_literal #5).
-- Grant lebt HIER am Rollen-Ort (NICHT in der fn-R__: die re-REVOKEt PUBLIC bei jedem Apply und wuerde
-- diesen Grant nicht erfassen). KEINE Paket-Rollen (nur der Core-Host-Menue-Sub konsumiert die fn).
-- Guarded auf fn-Existenz (idempotenter Backstop; Apply-Order Baseline->V->R->util garantiert sie).
DO $$ BEGIN
    IF to_regprocedure('core.fn_onboarding_overview(text)') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_onboarding_overview(text) TO core_ro;   -- P2b-1: +p_chat_id (core:V016 droppt die no-arg-Form -> Grant MUSS auf die neue Arity)
    END IF;
END $$;

-- Roter Faden Paket B: das /reminders-Menue (core.sub_send_reminders_menu, unter __CRED_POSTGRES_CORE_RO__) liest sein
-- Datenmodell ueber das DEFINER-Fenster core.fn_reminders_overview(text). Grant am Rollen-Ort (die R__ re-REVOKEt PUBLIC).
DO $$ BEGIN
    IF to_regprocedure('core.fn_reminders_overview(text)') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_reminders_overview(text) TO core_ro;
    END IF;
END $$;

-- Install-UX-Phase 6: EXECUTE auf die Owner-Begruessung core.fn_render_welcome(text) fuer core_ro (der Orchestrator
-- liest sie im /start-Zweig 'Start onboarding read' unter __CRED_POSTGRES_CORE_RO__, mit der Owner-Sprache). Die fn
-- REVOKEt PUBLIC in ihrer R__ -> Grant HIER am Rollen-Ort (Muster oben). Guarded auf fn-Existenz.
DO $$ BEGIN
    IF to_regprocedure('core.fn_render_welcome(text)') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_render_welcome(text) TO core_ro;
    END IF;
END $$;

-- Fix C (Karte-offen-Sperre): EXECUTE auf agent.fn_get_hitl_pending_state(bigint) fuer core_ro — der Orchestrator-
-- Pre-Router ('Card open check') liest unter __CRED_POSTGRES_CORE_RO__. DEFINER (agent.hitl_pending steht auf der
-- Deny-Liste oben); die fn REVOKEt PUBLIC in ihrer R__ -> Grant HIER am Rollen-Ort (Muster oben). Guarded auf fn-Existenz.
DO $$ BEGIN
    IF to_regprocedure('agent.fn_get_hitl_pending_state(bigint)') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION agent.fn_get_hitl_pending_state(bigint) TO core_ro;
    END IF;
END $$;

-- Phase A: EXECUTE auf den Aktualitaets-Waechter core.fn_stale_facts_count() fuer core_ro — fn_monitor_acquire
-- fuehrt die gespeicherte Spec 'SELECT core.fn_stale_facts_count()' als core_ro aus (agent.fn_monitor_ro_eval). Expliziter
-- Grant am Rollen-Ort (nicht auf den PUBLIC-Default verlassen). Guarded auf fn-Existenz.
DO $$ BEGIN
    IF to_regprocedure('core.fn_stale_facts_count()') IS NOT NULL THEN
        GRANT EXECUTE ON FUNCTION core.fn_stale_facts_count() TO core_ro;
    END IF;
END $$;
