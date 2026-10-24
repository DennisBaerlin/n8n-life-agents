-- ============================================================
-- fn_monitor_acquire (HELPER — DB-seitige Wert-Beschaffung fuer sql / none / Paket-Methoden)
--   Die EINE Quelle der nicht-Web-Beschaffung — genutzt von fn_monitor_evaluate (Cron)
--   UND fn_monitor_probe (Test-Abruf der Tools). web_search wird IMMER im Workflow
--   beschafft (HTTP-Node mit Credential) und hier abgelehnt.
--     * sql: Shape-Guard (single SELECT, kein ';', Laengen-Cap) als Beratungsebene,
--       dann EXECUTE unter SET LOCAL ROLE core_ro (strukturell read-only — das
--       GESETZ; core_ro ist die Core-Host-Leserolle: liest agent+core+jedes installierte Paket,
--       denn eine Monitor-sql-Acquisition kann beliebige Schemata treffen — der Core-Seed
--       household_facts_freshness liest agent.core_contexts, ein Paket-Trigger dessen Schema, B3)
--       mit Scalar-Subquery-Wrap 'SELECT (<q>)::numeric' (>1 Zeile/Spalte bricht kontrolliert).
--       Exception-Block = Savepoint -> GUC-Rollback; bei Erfolg wird die Rolle explizit
--       zurueckgesetzt. KEIN statement_timeout: wirkt in PG nur am Top-Level-Statement
--       (Restrisiko dokumentiert in agent.monitor_init.sql).
--     * none: ok ohne Wert (reiner Reminder).
--     * PAKET-Methode (Phase B, core.monitor_acquisition_methods): Dispatch an die acquire_fn des Pakets
--       (fn-Name nur aus der Registry, to_regprocedure-Guard ueber agent.fn_monitor_method_status) mit
--       {spec, as_of}; Methode nicht verfuegbar (Paket fehlt/inaktiv) -> {ok:false, reason} — NIE RAISE
--       (vorher las der Core finance.fx_rates ungeguardet -> ein verwaister fx-Trigger brach den Heartbeat
--       fuer ALLE Trigger ab). Ein RAISE in der Paket-fn wird ebenfalls zu {ok:false} gefangen.
--   Rueckgabe: Observation {ok, value?, unit?, as_of?, source_url?, reason?}
--   BEWUSST KEIN SET search_path (anders als fn_monitor_method_status/_validate_params): der sql-Zweig fuehrt
--   die Owner-Query des Triggers aus, die unqualifizierte Namen mit dem Default-search_path aufloest; das
--   EXECUTE-Ziel der Paket-Methode ist ohnehin schema-qualifiziert aus der Registry (Regex-CHECK).
-- ============================================================
DROP FUNCTION IF EXISTS agent.fn_monitor_acquire(text, jsonb, date, int);   -- Phase B: p_stale_days lebt beim Paket
CREATE OR REPLACE FUNCTION agent.fn_monitor_acquire(
    p_method     text,
    p_spec       jsonb,
    p_as_of      date
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_q     TEXT;
    v_value NUMERIC;
    v_st    JSONB;
    v_obs   JSONB;
BEGIN
    IF p_method = 'none' THEN
        RETURN jsonb_build_object('ok', true);
    END IF;

    IF p_method = 'sql' THEN
        v_q := trim(COALESCE(p_spec->>'query', ''));
        v_q := regexp_replace(v_q, ';\s*$', '');          -- trailing Semikolon tolerieren
        IF v_q = '' OR v_q !~* '^\s*select\y' OR position(';' in v_q) > 0 OR length(v_q) > 2000 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'sql spec rejected: must be a single SELECT statement (no semicolons, max 2000 chars)');
        END IF;
        BEGIN
            -- strukturelles read-only: laeuft als core_ro (Membership des App-Users via apply_schema Phase 4 /
            -- monitor_init-GRANT)
            PERFORM set_config('role', 'core_ro', true);
            EXECUTE 'SELECT (' || v_q || ')::numeric' INTO STRICT v_value;
            PERFORM set_config('role', 'none', true);
        EXCEPTION WHEN OTHERS THEN
            -- set_config(... is_local=true) ist subtransaktions-lokal -> der implizite Savepoint des
            -- PL/pgSQL-BEGIN..EXCEPTION-Blocks rollt die Rolle bei der Ausnahme automatisch zurueck.
            RETURN jsonb_build_object('ok', false, 'reason', 'sql failed: ' || SQLERRM);
        END;
        IF v_value IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'sql returned NULL');
        END IF;
        RETURN jsonb_build_object('ok', true, 'value', v_value,
            'as_of', p_as_of::text, 'source_url', 'sql');
    END IF;

    IF p_method = 'web_search' THEN
        -- web_search gehoert in den Workflow (Claude-web_search-HTTP-Node mit Credential)
        RETURN jsonb_build_object('ok', false,
            'reason', 'web_search observations must be acquired by the workflow, not the DB');
    END IF;

    -- Paket-Methode (Registry-Dispatch)
    v_st := agent.fn_monitor_method_status(p_method);
    IF NOT COALESCE((v_st->>'available')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_st->>'reason');
    END IF;
    BEGIN
        EXECUTE format('SELECT %s($1)', v_st->>'acquire_fn') INTO v_obs
            USING jsonb_build_object('spec', COALESCE(p_spec, '{}'::jsonb), 'as_of', p_as_of::text);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('%s acquisition failed: %s', p_method, SQLERRM));
    END;
    IF v_obs IS NULL OR jsonb_typeof(v_obs) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('%s acquisition returned no observation', p_method));
    END IF;
    RETURN v_obs;
END;
$$;
