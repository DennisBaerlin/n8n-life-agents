-- ============================================================
-- core.fn_onboarding_overview (P1 Generisches Paket-Onboarding) — DAS DB-getriebene Menue-Modell
--   Schnittstelle fuer core.sub_send_onboarding_menu (p_chat_id text DEFAULT NULL — P2b-1: per_user-Pakete
--   wie career person-gefaechert; ohne chat_id = alle per_user-Sektionen 'unknown'): liefert in EINEM Aufruf das vollstaendige
--   Onboarding-Menue ueber den Core-Haushalt UND alle AKTIVEN Pakete — der Menue-Builder braucht KEINE
--   build-time-Sektions-Liste (packages/finance/onboarding/sections.json) und KEIN Paket-Literal mehr
--   (loest core_literal #5 ab). Loest das BACKLOG-Item "Menue-Labels DB-getrieben (fn_onboarding_overview),
--   sobald ein 2. Paket existiert" ein (career = das 2. Onboarding-Paket).
--
--   RUECKGABE jsonb: { ok:true, sections:[ {package, key, label, status, ord, per_user, changed_at}, ... ], viewer_role, active_packages }
--     changed_at = status_changed_at der Zeile (NULL bei noch nicht materialisierter per_user-Zeile) — Stillstands-Uhr
--     von core.fn_onboarding_nudges_due (Roter Faden); das Menue ignoriert das Feld.
--     per_user = core.fn_package_is_per_user(package) (core: false); viewer_role = Rolle des Tappers aus
--     fn_resolve_sender(p_chat_id) (NULL = unaufgeloest) -> das Menue zeigt Mitgliedern nur persoenliche Bereiche als offen.
--     EINE FLACHE Liste — der Build-menu-JS-Node liest daraus nur den Status, gekeyt auf '<package>:<key>';
--     die ANZEIGE-Reihenfolge legt der Menue-Build fest (abgeleitete Abhaengigkeits-Reihenfolge, nicht diese fn). Sortierung:
--       (a) Core-Haushalt zuerst (package='core' — KEINE package_registry-Zeile, explizit vorangestellt),
--       (b) dann die aktiven Pakete ALPHABETISCH (ORDER BY package, Parität fn_onboarding_pending_packages),
--       (c) je Paket nach ord.
--     status = 'unknown'|'completed'|'skipped' (Tri-State der <pkg>.onboarding_state-Zeile, 1:1).
--
--   D10 / Auth: SECURITY DEFINER (owned by postgres, der SELECT auf agent + jedes Paket-Schema hat) =
--   das publizierte Menue-Lesefenster. EXECUTE bekommt NUR core_ro (der Core-Host-Lesepfad des Menue-Subs,
--   der unter __CRED_POSTGRES_CORE_RO__ laeuft) — gegrantet AM ROLLEN-ORT packages/core/db/util/util_create_core_ro.sql,
--   NICHT in fn_provision_package_roles (das ist der <pkg>_rw/_ro-Pfad fuer fn_onboarding_status). Diese R__
--   re-REVOKEt PUBLIC bei jedem Apply und wuerde einen hier gesetzten Grant sonst loeschen.
--   search_path auf pg_catalog gepinnt, alle Refs voll-qualifiziert (CVE-2018-1058). Das Suffix
--   '.onboarding_state' ist ein LITERAL (nie 2. %I), der Paketname kommt AUSSCHLIESSLICH aus
--   core.package_registry (kein Caller-Input) + Regex-Guard + to_regclass-Guard -> die Leseoberflaeche ist
--   strukturell auf *.onboarding_state-Fortschrittstabellen begrenzt (nur Flags section_key/label/status/ord).
--   Muster 1:1 wie core.fn_onboarding_status / core.fn_onboarding_pending_packages.
--
--   "Bei uns anders" (P1, arch-challenge D1 REJECT-mit-Notiz): Onboarding-Routing/Menue bleibt build-time-/
--   konventions-generiert statt einer Runtime-Registry-Tabelle — geschlossenes Monorepo (alle Pakete
--   build-time bekannt) + statische n8n-Switch-Nodes; <pkg>.onboarding_state ∩ core.package_registry IST
--   bereits die Runtime-Registry. Eine core.onboarding_sections-Tabelle waere redundant (label/ord/status
--   stehen schon in onboarding_state) und eliminierte die build-time Switch-Generierung nicht.
--
--   PER-USER-SCOPE (P2b-1): traegt ein Paket in core.context_scopes einen per_user-Context (career), zeigt das
--   Menue dem TAPPENDEN Nutzer SEINE Sektionen — fuer jede Katalog-Sektion seine (section_key, person_id)-Zeile,
--   fehlt sie -> 'unknown'. person_id kommt DETERMINISTISCH aus p_chat_id via agent.fn_resolve_sender (DEFINER,
--   kein neuer Grant; NIE LLM). v_pid NULL (unaufgeloest / no chat_id) -> alle per_user-Sektionen 'unknown'
--   (sicher: jeder taps sein eigenes Onboarding, nie das eines anderen). household-Pakete (finance) UNVERAENDERT.
--   STABLE bleibt (kein Write).
--   Tests: tests/db/core/test_fn_onboarding_overview.sql + test_role_permissions.sql (core_ro EXECUTE).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_onboarding_overview(p_chat_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_sections jsonb;
    v_pkg      text;
    v_rel      text;
    v_pkg_secs jsonb;
    v_per_user boolean;
    v_pid      text;
    v_role     text;
BEGIN
    -- Person EINMAL aus der chat_id aufloesen (p_chat_id konstant ueber alle Pakete); nicht-numerisch/NULL -> NULL.
    IF p_chat_id ~ '^[0-9]+$' THEN
        SELECT s->>'person_id', CASE WHEN (s->>'found')::boolean THEN s->>'role' END INTO v_pid, v_role
        FROM (SELECT agent.fn_resolve_sender(p_chat_id::bigint) AS s) x;
    END IF;

    -- ---- CORE-Bein (immer zuerst): Host-Sonderfall agent.guide_onboarding_state, package='core' (household) ----
    SELECT COALESCE(
        jsonb_agg(jsonb_build_object(
            'package', 'core', 'key', section_key, 'label', label, 'status', status, 'ord', ord, 'per_user', false, 'changed_at', status_changed_at
        ) ORDER BY ord), '[]'::jsonb)
    INTO v_sections
    FROM agent.guide_onboarding_state;

    -- ---- PAKET-Beine (alphabetisch): aktive Pakete (≠core) mit <pkg>.onboarding_state ----
    FOR v_pkg IN
        SELECT package FROM core.package_registry
        WHERE status = 'active' AND package <> 'core'
        ORDER BY package
    LOOP
        CONTINUE WHEN v_pkg !~ '^[a-z][a-z0-9_]*$';                          -- Identifier-Schutz (defense in depth)
        v_rel := to_regclass(format('%I.onboarding_state', v_pkg))::text;    -- Suffix LITERAL, nie 2. %I
        CONTINUE WHEN v_rel IS NULL;                                         -- Paket ohne onboarding_state-Tabelle

        v_per_user := core.fn_package_is_per_user(v_pkg);   -- die eine Regel (R__fn_package_is_per_user)
        IF v_per_user THEN
            -- per_user: Katalog (DISTINCT je Sektion) LEFT JOIN die Zeile des Tappers; fehlt sie -> 'unknown'.
            EXECUTE format($q$
                WITH cat AS (SELECT DISTINCT ON (section_key) section_key, ord, label FROM %1$s ORDER BY section_key, ord)
                SELECT COALESCE(jsonb_agg(jsonb_build_object(
                           'package', %2$L, 'key', cat.section_key, 'label', cat.label,
                           'status', COALESCE(r.status, 'unknown'), 'ord', cat.ord, 'per_user', true, 'changed_at', r.status_changed_at) ORDER BY cat.ord), '[]'::jsonb)
                FROM cat LEFT JOIN %1$s r ON r.section_key = cat.section_key AND r.person_id = %3$L
            $q$, v_rel, v_pkg, v_pid) INTO v_pkg_secs;
        ELSE
            EXECUTE format($q$
                SELECT COALESCE(
                    jsonb_agg(jsonb_build_object(
                        'package', %L, 'key', section_key, 'label', label, 'status', status, 'ord', ord, 'per_user', false, 'changed_at', status_changed_at
                    ) ORDER BY ord), '[]'::jsonb)
                FROM %s
            $q$, v_pkg, v_rel) INTO v_pkg_secs;
        END IF;

        v_sections := v_sections || v_pkg_secs;   -- leeres onboarding_state -> '[]' -> kein Beitrag, kein Fehler
    END LOOP;

    -- Install-UX-Phase 4: active_packages (≠core, sortiert) -> der Menue-Builder beschriftet build-time-Knoepfe
    -- nicht aktiver Pakete ("nicht installiert"); gleiche Registry-Quelle wie die Paket-Schleife oben.
    -- viewer_role = Rolle des Tappers (owner/partner/child/...; NULL = unaufgeloest/ohne chat_id) -> das Menue zeigt
    -- Mitgliedern nur ihre persoenlichen Bereiche als 'fuer dich offen' (per_user je Sektion, gleiche Regel wie der Handler).
    RETURN jsonb_build_object('ok', true, 'sections', v_sections, 'viewer_role', v_role,
        'active_packages', COALESCE((SELECT jsonb_agg(package ORDER BY package) FROM core.package_registry
                                      WHERE status = 'active' AND package <> 'core'), '[]'::jsonb));
END;
$$;

-- SECURITY-DEFINER-Hygiene: kein PUBLIC-EXECUTE auf dem Menue-Lesefenster.
-- EXECUTE bekommt NUR core_ro via packages/core/db/util/util_create_core_ro.sql (NACH dieser R__; der Grant lebt am
-- Rollen-Ort, NICHT hier — diese R__ re-REVOKEt PUBLIC bei jedem Apply und wuerde den Grant sonst loeschen).
REVOKE ALL ON FUNCTION core.fn_onboarding_overview(text) FROM public;
