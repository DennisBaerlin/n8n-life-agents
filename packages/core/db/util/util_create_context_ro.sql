-- ============================================================
-- util_create_context_ro.sql — Read-Only-Login-Rolle fuer den agent-uebergreifenden load_context-Pfad
--   Anwenden via: db_apply.ps1 -File packages/core/db/util/util_create_context_ro.sql
--
--   Zweck: das `load_context`-Tool liest `agent.core_contexts` (Grounding-/Memory-Dokumente) und ist
--   nicht finance-spezifisch (jeder Agent nutzt es). Darum eine eigene, sauber benannte Rolle statt
--   `finance_ro` (dessen Name fuer den Finance-Agenten reserviert ist). Minimal-privilegiert:
--   nur EXECUTE auf core.fn_fetch_context (DEFINER), Read-Only-Transaktionen, Statement-Timeout.
--
--   Kein Passwort hier (kein Secret im Repo). Nach diesem Skript einmalig setzen:
--     ALTER ROLE context_ro PASSWORD '<starkes-passwort>';
--   und dasselbe Passwort in der neuen n8n-Postgres-Credential hinterlegen.
-- ============================================================

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        CREATE ROLE context_ro LOGIN;
    END IF;
END $$;

ALTER ROLE context_ro SET default_transaction_read_only = on;
ALTER ROLE context_ro SET statement_timeout = '15s';
ALTER ROLE context_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE context_ro SET search_path = pg_catalog, agent;

GRANT USAGE ON SCHEMA agent TO context_ro;
-- Kein direktes SELECT auf agent.core_contexts: der einzige Lesepfad ist das DEFINER-Fenster
-- unten, das per_user-Zeilen nur zur eigenen chat_id herausgibt. Der REVOKE raeumt einen Grant auf Bestands-DBs ab.
REVOKE SELECT ON agent.core_contexts FROM context_ro;
-- load_context ruft core.fn_fetch_context (SECURITY DEFINER: liest core.context_renderers/_scopes + den
-- Identity-Resolver, die context_ro nicht direkt sehen darf). USAGE auf Schema core noetig, um die Function
-- aufzurufen (kein Tabellen-SELECT -> D10 bleibt dicht: USAGE erlaubt nur die granteten Funktionen, nicht das
-- Lesen von core-Tabellen). Die fn REVOKEt PUBLIC -> hier explizit EXECUTE an die load_context-Rolle (laeuft
-- nach der R__-Phase, fn existiert). Signatur 2-Arg (per_user, p_chat_id Default NULL via core:V013).
GRANT USAGE ON SCHEMA core TO context_ro;
GRANT EXECUTE ON FUNCTION core.fn_fetch_context(text, text) TO context_ro;
