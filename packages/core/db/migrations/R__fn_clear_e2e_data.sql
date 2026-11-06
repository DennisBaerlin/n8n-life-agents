-- ============================================================
-- fn_clear_e2e_data (GEGUARDETES TEST-CLEANUP — KEIN Produktiv-Tool)
--   Loescht ALLE E2E-Test-Zeilen mit dem Sentinel-Marker '__E2E__', FK-sicher und atomar (eine Transaktion;
--   RAISE -> Auto-Rollback). Aufgerufen vom E2E-Write-Tier (scripts/e2e_test.ps1 Pre-/Post-Flight).
--
--   Phase B — Core kennt kein Paket: die Paket-Daten raeumt je Paket der Konventions-Hook
--   <pkg>.fn_clear_e2e_data(text) (Praezedenz <pkg>.onboarding_state, docs/package-contract.md §6). Dieser
--   Dispatcher iteriert core.package_registry ∪ core.schema_version (faengt auch --keep-data-Deinstallierte),
--   ruft je Paket mit eigenem Schema den Hook und merged die Zaehler FLACH. Paket mit Schema OHNE Hook -> RAISE
--   (Vertragsbruch laut statt still uebersprungen; contract_lint Check 17 faengt es schon beim Commit).
--   Selbst raeumt er nur die host-eigenen agent.*-Zeilen (Advisor-Plaene/-Docs, Monitor-Trigger, Lern-Loop-State,
--   Test-Chat-Memory ALLER Agenten).
--
--   GUARD 2 (Post-Assertion, agent-Teil): keine Sentinel-Zeile darf zurueckbleiben (die Paket-Hooks pruefen ihren
--   eigenen Teil selbst). Sentinel-Pattern escaped die Underscores ('\_' = literaler Underscore in LIKE).
--
--   RUN-SCOPING (A5): optionaler p_runid (alphanumerisch). NULL/'' -> GENERISCHER Sweep (fix '__E2E__ ...' UND
--   run-scoped '__E2E_<runid>__ ...'); p_runid gesetzt -> nur der eigene Lauf.
--   RUECKGABE: flache Zaehler {chat_memory, advisor_plans, contexts, monitor_triggers, guide_learn_candidates,
--     guide_learn_watermark, gelernt_notes_stripped} || die Zaehler aller Paket-Hooks
--   Tests: tests/db/core/test_fn_clear_e2e_data.sql
-- ============================================================
-- Alte parameterlose Signatur droppen (sonst Overload-Ambiguitaet mit der (text DEFAULT NULL)-Variante).
DROP FUNCTION IF EXISTS agent.fn_clear_e2e_data();
CREATE OR REPLACE FUNCTION agent.fn_clear_e2e_data(p_runid text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_pat  CONSTANT text := CASE WHEN COALESCE(p_runid,'') = '' THEN '\_\_E2E%'
                                 ELSE '\_\_E2E\_' || p_runid || '\_\_%' END;
    v_pat_any CONSTANT text := CASE WHEN COALESCE(p_runid,'') = '' THEN '%\_\_E2E%'
                                    ELSE '%\_\_E2E\_' || p_runid || '\_\_%' END;
    v_out  jsonb := '{}'::jsonb;
    v_hook jsonb;
    v_pkg  text;
    v_tbl  text;
    v_n    int;
    v_mem int := 0; v_ap int; v_ctx int; v_mt int;
    v_glc int := 0; v_glw int := 0; v_gln int := 0;
BEGIN
    -- Run-ID-Format-Guard: nur [a-z0-9] (verhindert LIKE-Injection ueber p_runid).
    IF COALESCE(p_runid,'') <> '' AND p_runid !~ '^[a-z0-9]+$' THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: ungültige run-id % (nur [a-z0-9])', p_runid;
    END IF;

    -- 1. Paket-Hooks (Konvention <pkg>.fn_clear_e2e_data(text)); Paket ohne eigenes Schema -> nichts zu raeumen.
    FOR v_pkg IN SELECT core.fn_package_schemas()
    LOOP
        IF to_regprocedure(format('%I.fn_clear_e2e_data(text)', v_pkg)) IS NULL THEN
            RAISE EXCEPTION 'fn_clear_e2e_data GUARD: Paket % hat ein Schema, aber keinen Hook %.fn_clear_e2e_data(text) — Abbruch', v_pkg, v_pkg;
        END IF;
        EXECUTE format('SELECT %I.fn_clear_e2e_data($1)', v_pkg) INTO v_hook USING p_runid;
        v_hook := COALESCE(v_hook, '{}'::jsonb);
        -- flacher Merge (E2E-Zaehler-Vertrag): ein Key-Konflikt zweier Pakete wuerde still ueberschreiben -> RAISE.
        IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_hook) k WHERE v_out ? k) THEN
            RAISE EXCEPTION 'fn_clear_e2e_data GUARD: Hook %.fn_clear_e2e_data liefert einen bereits belegten Zähler-Key — Keys je Paket eindeutig halten', v_pkg;
        END IF;
        v_out := v_out || v_hook;
    END LOOP;

    -- 2. Test-Chat-Memory der test_e2e-Sessions ALLER Agenten (Tabellen dynamisch, Muster util_clear_chat_memory).
    FOR v_tbl IN SELECT tablename FROM pg_catalog.pg_tables
                 WHERE schemaname = 'agent' AND tablename LIKE '%\_chat\_memory' ESCAPE '\'
    LOOP
        EXECUTE format('DELETE FROM agent.%I WHERE session_id LIKE %L', v_tbl, 'test\_e2e%');
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_mem := v_mem + v_n;
    END LOOP;

    -- 3. Advisor-Plaene: Sentinel via plan_name (Prefix) ODER domain (der E2E-Pfad des Advisors schreibt unter
    --    sentinel-DOMAIN '__e2e_<domain>__'). ILIKE: der Domain-Sentinel ist lowercase.
    DELETE FROM agent.advisor_plans
     WHERE plan_name LIKE v_pat OR domain ILIKE v_pat;
    GET DIAGNOSTICS v_ap = ROW_COUNT;

    -- 4. Agent-publizierte Sentinel-Plan-Docs. DOPPELT gescoped: Sentinel-Name UND managed_by='agent'.
    DELETE FROM agent.core_contexts
     WHERE name ILIKE v_pat AND managed_by = 'agent';
    GET DIAGNOSTICS v_ctx = ROW_COUNT;

    -- 5. Monitor-Trigger: Sentinel via domain ('__e2e_monitor__') ODER label; Observations per FK-CASCADE.
    DELETE FROM agent.monitor_triggers
     WHERE domain ILIKE v_pat OR label LIKE v_pat_any;
    GET DIAGNOSTICS v_mt = ROW_COUNT;

    -- 6. Lern-Loop-State: Sentinel-Kandidaten + die "## Gelernt"-Sentinel-Zeilen agent-managed Kontexte
    --    (zeilen-genauer Strip) + der Watermark (ephemerer Loop-State -> ganz raeumen).
    DELETE FROM agent.guide_learn_candidates
     WHERE proposed_value LIKE v_pat_any OR COALESCE(rationale, '') LIKE v_pat_any OR context_name LIKE v_pat_any;
    GET DIAGNOSTICS v_glc = ROW_COUNT;
    UPDATE agent.core_contexts c
       SET content = COALESCE((SELECT string_agg(ln, E'\n' ORDER BY ord)
                               FROM unnest(string_to_array(c.content, E'\n')) WITH ORDINALITY AS t(ln, ord)
                               WHERE ln NOT LIKE v_pat_any), '')
     WHERE c.managed_by = 'agent' AND c.content LIKE v_pat_any;
    GET DIAGNOSTICS v_gln = ROW_COUNT;
    DELETE FROM agent.guide_learn_watermark;
    GET DIAGNOSTICS v_glw = ROW_COUNT;

    -- GUARD 2 (agent-Teil): keine Sentinel-Zeile darf zurueckbleiben.
    IF EXISTS (SELECT 1 FROM agent.advisor_plans          WHERE plan_name LIKE v_pat OR domain ILIKE v_pat)
    OR EXISTS (SELECT 1 FROM agent.core_contexts          WHERE name ILIKE v_pat AND managed_by = 'agent')
    OR EXISTS (SELECT 1 FROM agent.monitor_triggers       WHERE domain ILIKE v_pat OR label LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM agent.guide_learn_candidates  WHERE proposed_value LIKE v_pat_any OR COALESCE(rationale,'') LIKE v_pat_any OR context_name LIKE v_pat_any)
    OR EXISTS (SELECT 1 FROM agent.core_contexts           WHERE managed_by = 'agent' AND content LIKE v_pat_any) THEN
        RAISE EXCEPTION 'fn_clear_e2e_data GUARD: Sentinel-Zeilen nach Cleanup noch vorhanden — Abbruch';
    END IF;

    RETURN v_out || jsonb_build_object(
        'chat_memory', v_mem, 'advisor_plans', v_ap, 'contexts', v_ctx, 'monitor_triggers', v_mt,
        'guide_learn_candidates', v_glc, 'guide_learn_watermark', v_glw, 'gelernt_notes_stripped', v_gln
    );
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_clear_e2e_data(text) FROM public;
