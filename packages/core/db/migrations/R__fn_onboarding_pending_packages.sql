-- ============================================================
-- core.fn_onboarding_pending_packages (WS-3 Onboarding-UX) — generische Paket-Onboarding-Entdeckung
--   Liefert die AKTIVEN Pakete (core.package_registry.status='active', ohne den Host 'core'), deren
--   <pkg>.onboarding_state-Tabelle existiert UND >=1 OFFENE Sektion (status='unknown') hat. Ersetzt den
--   frueheren finance-Hardcode im Guide-Handoff: der Guide bietet nach Haushalts-Abschluss generisch die
--   tatsaechlich offenen Paket-Bereiche an (status-bewusst). 'completed'/'skipped' = bewusst aufgeloest ->
--   erscheinen NICHT (konsistent mit fn_onboarding_status: complete = kein 'unknown').
--
--   RUECKGABE jsonb: { ok:true, pending:[ { package, open:[ {key,label}, ... ] }, ... ] }
--   (open ordered nach ord; nur Pakete mit >=1 offener Sektion). Keine offenen -> pending:[].
--
--   D10 / Auth: SECURITY DEFINER (owned by postgres) = das publizierte Lesefenster — liest core.package_registry
--   (die enge Rolle hat dort KEIN SELECT) + die paket-<pkg>.onboarding_state-Tabellen. EXECUTE bekommt NUR
--   core_ro (der Core-Host-Lesepfad des Guide) via util_create_core_ro — KEINE Paket-Rollen (kein Paket-Agent
--   konsumiert die Liste; YAGNI). search_path auf pg_catalog gepinnt, Refs voll-qualifiziert (CVE-2018-1058).
--   Das Suffix '.onboarding_state' ist ein LITERAL (nie 2. %I), der Paketname kommt AUSSCHLIESSLICH aus
--   core.package_registry (kein Caller-Input) + Regex-Guard + to_regclass-Guard -> die Leseoberflaeche ist
--   strukturell auf *.onboarding_state-Fortschrittstabellen begrenzt (nur Flags section_key/label/status/ord).
--   Muster 1:1 wie core.fn_onboarding_status / core.fn_package_active.
--   Tests: tests/db/core/test_fn_onboarding_pending_packages.sql + test_role_permissions.sql (3d, core_ro/finance_ro).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_onboarding_pending_packages()
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_pending jsonb := '[]'::jsonb;
    v_pkg     text;
    v_rel     text;
    v_open    jsonb;
BEGIN
    FOR v_pkg IN
        SELECT package FROM core.package_registry
        WHERE status = 'active' AND package <> 'core'
        ORDER BY package
    LOOP
        -- Identifier-Schutz (defense in depth, auch wenn package_registry-Namen schon validiert sind).
        CONTINUE WHEN v_pkg !~ '^[a-z][a-z0-9_]*$';
        v_rel := to_regclass(format('%I.onboarding_state', v_pkg))::text;   -- Suffix LITERAL, nie 2. %I
        CONTINUE WHEN v_rel IS NULL;                                        -- Paket ohne onboarding_state-Tabelle

        EXECUTE format($q$
            SELECT COALESCE(
                jsonb_agg(jsonb_build_object('key', section_key, 'label', label) ORDER BY ord)
                FILTER (WHERE status = 'unknown'), '[]'::jsonb)
            FROM %s
        $q$, v_rel) INTO v_open;

        IF jsonb_array_length(v_open) > 0 THEN
            v_pending := v_pending || jsonb_build_array(
                jsonb_build_object('package', v_pkg, 'open', v_open));
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'pending', v_pending);
END;
$$;

-- SECURITY-DEFINER-Hygiene: kein PUBLIC-EXECUTE auf dem Discovery-Fenster.
-- EXECUTE bekommt NUR core_ro via packages/core/db/util/util_create_core_ro.sql (NACH dieser R__; der Grant lebt am
-- Rollen-Ort, NICHT hier — diese R__ re-REVOKEt PUBLIC bei jedem Apply und wuerde den Grant sonst loeschen).
REVOKE ALL ON FUNCTION core.fn_onboarding_pending_packages() FROM public;
