-- ============================================================
-- R__zz_drop_agent_finance_orphans — Phase-3a-Extraktion: Orphan-Cleanup in Schema 'agent'
--   Sortiert als Repeatable BEWUSST ZULETZT (zz): laeuft NACH allen finance.fn_*/Views (phase-major
--   R__-Reihenfolge), erst dann existieren die finance-Kopien, an denen die Orphan-Erkennung haengt.
--   Ein versioned V__ liefe in Phase 2 (vor den R__) -> die finance-fns gaebe es da noch nicht.
--   BESTANDS-DB (lifeagents update): die Init hat agent.finance_* per SET SCHEMA nach finance verschoben;
--     zurueck bleiben (a) die alten agent.<fn>-Kopien (CREATE OR REPLACE legte die finance-Kopie an, liess
--     die agent-Kopie stehen) und (b) die alten agent.finance_*-Views (OID-gueltig, aber falsch beheimatet).
--   FRESH-DB: nichts davon existiert je -> reiner No-op. Idempotent (DROP IF EXISTS).
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
    -- (1) Funktions-Orphans: agent.<fn> die es identisch (Name + Identity-Args) auch in finance gibt.
    --     AUSGENOMMEN sind gewollt gleichnamige Core-Funktionen:
    --       touch_updated_at   — geteilter Core-Helfer (monitor/advisor/guide/core_contexts-Trigger haengen an
    --                            agent.touch_updated_at; nur die Finance-Tabellen nutzen finance.touch_updated_at);
    --       fn_clear_e2e_data  — Phase B: der Core-Dispatcher agent.fn_clear_e2e_data(text) ruft je Paket den
    --                            Konventions-Hook <pkg>.fn_clear_e2e_data(text) — gleicher Name + Args by design
    --                            (sonst loeschte DIESE Datei den Dispatcher bei jedem Apply).
    FOR r IN
        SELECT 'agent.' || quote_ident(p.proname) || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'agent' AND p.proname NOT IN ('touch_updated_at', 'fn_clear_e2e_data')
          AND EXISTS (
              SELECT 1 FROM pg_proc p2 JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
              WHERE n2.nspname = 'finance' AND p2.proname = p.proname
                AND pg_get_function_identity_arguments(p2.oid) = pg_get_function_identity_arguments(p.oid))
    LOOP
        EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
    END LOOP;

    -- (2) View-Orphans: die alten agent.finance_*-Views (Core haelt keine agent.finance_*-Objekte).
    FOR r IN
        SELECT 'agent.' || quote_ident(viewname) AS v FROM pg_views
        WHERE schemaname = 'agent' AND viewname LIKE 'finance\_%'
    LOOP
        EXECUTE 'DROP VIEW IF EXISTS ' || r.v || ' CASCADE';
    END LOOP;
END $$;
