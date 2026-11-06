-- ============================================================
-- fn_dry_run (PROBELAUF EINER WRITE-FN VOR DER HITL-KARTE)
--   Fuehrt eine Write-fn fn(jsonb) RETURNS jsonb echt aus, gibt ihr Ergebnis zurueck (+ dry_run:true) und rollt ihre
--   Effekte IMMER zurueck (Savepoint des BEGIN/EXCEPTION-Blocks), auch bei ok:false nach einem Teil-Write.
--   Zweck: die DB entscheidet VOR der Karte (Owner-Prinzip "DB ist das Gesetz"), der Nutzer tippt nie "Bestaetigen"
--   auf etwas, das die fn danach ablehnt. Der echte Write laeuft nach dem Gate erneut (Bestand kann sich aendern).
--   Ergebnis: das jsonb der fn || {dry_run:true}. Nutzer-korrigierbare Ablehnungen sind laut Konvention Daten
--   ({ok:false, reason}); eine echte Exception der fn wird NICHT abgefangen (Owner-Alert ueber errorWorkflow bleibt).
--   Verwendung (Build-Helper New-FnWriteGate):
--     SELECT core.fn_dry_run('finance.fn_create_account(jsonb)'::regprocedure, $1::jsonb)
--   Der fn-Name ist eine Build-Konstante, nie Nutzer-Input. Nur fn(jsonb) RETURNS jsonb (sonst RAISE = Build-Fehler).
--   Der Aufruf wird aus pg_proc/pg_namespace mit quote_ident gebaut (nicht aus der search_path-abhaengigen
--   regproc-Textausgabe). Variablen ueberleben den Block-Rollback (Speicher, nicht TX), wie v_dry_ok in
--   finance.fn_import_bundle.
--   Grenze: Effekte, die erst beim COMMIT feuern (deferrable Constraints/Constraint-Trigger), sieht ein Probelauf
--   nicht; tests/db/finance/test_dry_run_finance.sql haelt fest, dass finance keine hat.
--   INVOKER (laeuft mit den Rechten der Paket-Rolle), ohne eigenen search_path: die aufgerufene fn sieht den
--   search_path des Aufrufers wie bei einem direkten Aufruf. EXECUTE nur an <pkg>_rw (fn_provision_package_roles).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_dry_run(p_fn regprocedure, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_call TEXT;
    v_res  JSONB;
BEGIN
    SELECT pg_catalog.quote_ident(n.nspname) || '.' || pg_catalog.quote_ident(pr.proname)
    INTO v_call
    FROM pg_catalog.pg_proc pr
    JOIN pg_catalog.pg_namespace n ON n.oid = pr.pronamespace
    WHERE pr.oid = p_fn
      AND pr.prokind = 'f'
      AND pr.pronargs = 1
      AND pr.proargtypes[0] = 'jsonb'::pg_catalog.regtype
      AND pr.prorettype = 'jsonb'::pg_catalog.regtype;
    IF v_call IS NULL THEN
        RAISE EXCEPTION 'fn_dry_run: % is not a function(jsonb) RETURNS jsonb', p_fn;
    END IF;

    BEGIN
        EXECUTE 'SELECT ' || v_call || '($1)' INTO v_res USING p;
        -- IMMER zurueckrollen, auch bei ok:false (ein Teil-Write vor der Ablehnung darf nicht bleiben)
        RAISE EXCEPTION USING ERRCODE = 'LA001', MESSAGE = 'fn_dry_run: always rolled back';
    EXCEPTION
        WHEN SQLSTATE 'LA001' THEN
            NULL;
        -- bewusst KEIN WHEN OTHERS: eine echte Exception der fn (Bug, kein Nutzerfehler) bricht den Probelauf ab
        -- wie heute den Write -> n8n-Node scheitert -> errorWorkflow alarmiert den Owner (nie still verschluckt).
    END;

    RETURN COALESCE(v_res, '{}'::jsonb) || pg_catalog.jsonb_build_object('dry_run', true);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_dry_run(regprocedure, jsonb) FROM public;
