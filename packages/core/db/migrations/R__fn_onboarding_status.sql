-- ============================================================
-- fn_onboarding_status (READ)
--   Kombinierte, paket-uebergreifende Lese-Schnittstelle: liefert in einem Aufruf den Core-Onboarding-Status und
--   (optional) den eines Pakets.
--
--   p_package: NULL/'core' -> nur Core-Haushalt; '<pkg>' -> Core + dieses Paket kombiniert.
--   p_chat_id: optional; loest den Fragenden auf (per_user-Paket-Bein, viewer_is_member).
--   RUECKGABE jsonb:
--     { ok:true,
--       complete: bool,   -- core.complete AND (package.complete falls p_package gesetzt sonst true)
--       open: [ {key,label,source}, ... ],   -- Union der offenen Sektionen (fuer Gate-/Nudge-Meldung)
--       core:    { complete, sections, open },
--       package: null | { name, complete, sections, open } | { ok:false, reason:'unknown_package'|... },
--       viewer_is_member: bool }   -- p_chat_id ist ein aufgeloestes Mitglied (nicht Owner); sonst false
--   complete=true gdw keine Sektion 'unknown' ist (completed oder skipped zaehlen als bewusst aufgeloest).
--   Unbekanntes/ungueltiges Paket -> package={ok:false, reason}, complete=false (Gate bleibt sicher zu).
--
--   D10 / Auth: SECURITY DEFINER (owned by postgres, der SELECT auf agent+<pkg> hat) ist das publizierte
--   Lesefenster der engen Paket-Rollen (finance_ro hat kein SELECT auf Schema agent). EXECUTE wird in
--   core.fn_provision_package_roles an <pkg>_rw/<pkg>_ro gegrantet. search_path auf pg_catalog gepinnt,
--   alle Refs voll-qualifiziert (CVE-2018-1058). Das Suffix '.onboarding_state' ist ein Literal (nie ein
--   2. %I-Param) + Name-Regex + to_regclass-Guard -> die Leseoberflaeche ist strukturell auf
--   *.onboarding_state-Fortschrittstabellen begrenzt (nur Flags section_key/status/label/ord, keine PII/
--   Finanzdaten), nie eine beliebige Tabelle (Cybertec "Abusing SECURITY DEFINER"). p_package ist immer ein
--   build-time-konstanter Paketschluessel (nie $fromAI/LLM).
--   Konvention statt Registry: <pkg>.onboarding_state ist aus dem Paketschluessel
--   ableitbar -> kein Registry-Eintrag ("ein Fakt, eine Adresse"). Registry-Upgrade (core.onboarding_packages)
--   erst, sobald ein Paket-Statustable nicht mehr <pkg>.onboarding_state heisst.
--
--   Per-user-Scope (Parität fn_fetch_context): traegt das Paket in core.context_scopes einen per_user-
--   Context (career), ist das Onboarding pro Person. Das Paket-Bein wird dann katalog-basiert + person-gefiltert
--   gerechnet: fuer jede Sektion des (Owner-geseedeten) Katalogs zaehlt die (section_key, person_id)-Zeile der
--   fragenden Person; fehlt sie -> 'unknown' (= nicht complete) -> kein vacuous-true (eine nie-onboardete Person
--   liest nicht als complete; das Gate bleibt zu). person_id kommt deterministisch aus p_chat_id via
--   agent.fn_resolve_sender (DEFINER ruft sie ohne neuen Grant, Numerik-Guard wie fn_fetch_context; nie LLM).
--   Unaufgeloester per_user-Sender -> Paket-Bein complete=false (fail-closed). household-Pakete (finance/guide,
--   scope-frei) laufen unveraendert (kein person_id, Lese auf der einen Zeile je Sektion). STABLE: die fn
--   schreibt nicht (Materialisierung passiert nur im Schreibpfad core.fn_set_onboarding_section).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_onboarding_status(p_package text DEFAULT NULL, p_chat_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_core     jsonb;
    v_pkg      jsonb := NULL;
    v_rel      text;
    v_complete boolean;
    v_open     jsonb;
    v_per_user boolean := false;
    v_pid      text;
    v_sender   jsonb;
BEGIN
    -- ---- Core-Bein (immer): Host-Sonderfall agent.guide_onboarding_state ----
    SELECT jsonb_build_object(
        'complete', NOT EXISTS (SELECT 1 FROM agent.guide_onboarding_state WHERE status = 'unknown'),
        'sections', COALESCE((SELECT jsonb_object_agg(section_key, status) FROM agent.guide_onboarding_state), '{}'::jsonb),
        'open',     COALESCE((SELECT jsonb_agg(jsonb_build_object('key', section_key, 'label', label, 'source', 'core') ORDER BY ord)
                              FROM agent.guide_onboarding_state WHERE status = 'unknown'), '[]'::jsonb)
    ) INTO v_core;

    v_complete := (v_core->>'complete')::boolean;
    v_open     := v_core->'open';

    -- ---- Paket-Bein (optional): <pkg>.onboarding_state ----
    IF p_package IS NOT NULL AND p_package <> 'core' THEN
        IF p_package !~ '^[a-z][a-z0-9_]*$' THEN
            v_pkg := jsonb_build_object('ok', false, 'reason', 'invalid package name: ' || p_package);
        ELSE
            v_rel := to_regclass(format('%I.onboarding_state', p_package))::text;   -- Suffix literal, nie 2. %I
            IF v_rel IS NULL THEN
                v_pkg := jsonb_build_object('ok', false, 'reason', 'unknown_package');
            ELSE
                -- per_user (career) -> katalog-basiert + person-gefiltert; household (finance) -> unveraendert.
                v_per_user := core.fn_package_is_per_user(p_package);   -- die eine Regel (R__fn_package_is_per_user)
                IF v_per_user THEN
                    IF p_chat_id ~ '^[0-9]+$' THEN
                        v_pid := agent.fn_resolve_sender(p_chat_id::bigint) ->> 'person_id';
                    END IF;
                    -- Katalog (DISTINCT je Sektion, Owner-geseedet) LEFT JOIN die Zeile der Person; fehlt sie ->
                    -- 'unknown'. v_pid NULL (unaufgeloest) -> kein Match -> alles 'unknown' -> complete=false (fail-closed).
                    -- complete: Katalog nicht-leer und keine 'unknown'-Sektion fuer die Person. Der EXISTS(cat)-
                    -- Guard schliesst die vacuous-true-Falle bei leerem Katalog (z. B. Sektionen noch nicht geseedet):
                    -- NOT EXISTS ueber leer waere TRUE -> Gate fiele faelschlich offen. Leerer Katalog -> complete=false
                    -- (fail-closed; Gate bleibt zu).
                    EXECUTE format($q$
                        WITH cat AS (SELECT DISTINCT ON (section_key) section_key, ord, label FROM %1$s ORDER BY section_key, ord),
                             pp  AS (SELECT cat.section_key, cat.ord, cat.label, COALESCE(r.status, 'unknown') AS status
                                     FROM cat LEFT JOIN %1$s r ON r.section_key = cat.section_key AND r.person_id = %2$L)
                        SELECT jsonb_build_object(
                            'name', %3$L,
                            'complete', EXISTS (SELECT 1 FROM cat) AND NOT EXISTS (SELECT 1 FROM pp WHERE status = 'unknown'),
                            'sections', COALESCE((SELECT jsonb_object_agg(section_key, status) FROM pp), '{}'::jsonb),
                            'open',     COALESCE((SELECT jsonb_agg(jsonb_build_object('key', section_key, 'label', label, 'source', %3$L) ORDER BY ord)
                                                  FROM pp WHERE status = 'unknown'), '[]'::jsonb))
                    $q$, v_rel, v_pid, p_package) INTO v_pkg;
                ELSE
                    EXECUTE format($q$
                        SELECT jsonb_build_object(
                            'name', %L,
                            'complete', NOT EXISTS (SELECT 1 FROM %s WHERE status = 'unknown'),
                            'sections', COALESCE((SELECT jsonb_object_agg(section_key, status) FROM %s), '{}'::jsonb),
                            'open',     COALESCE((SELECT jsonb_agg(jsonb_build_object('key', section_key, 'label', label, 'source', %L) ORDER BY ord)
                                                  FROM %s WHERE status = 'unknown'), '[]'::jsonb))
                    $q$, p_package, v_rel, v_rel, p_package, v_rel) INTO v_pkg;
                END IF;
            END IF;
        END IF;

        -- Kombinierter Verdikt: unerreichbar/ungueltig -> Gate sicher zu; sonst beide Beine und-verknuepft.
        IF (v_pkg ? 'ok') AND NOT (v_pkg->>'ok')::boolean THEN
            v_complete := false;
        ELSE
            v_complete := v_complete AND (v_pkg->>'complete')::boolean;
            v_open := v_open || (v_pkg->'open');
        END IF;
    END IF;

    -- Rolle des Fragenden (nie LLM, Numerik-Guard) -> das Core-first-Gate der Paket-Agenten antwortet
    -- einem Mitglied "der Haushalt wird noch eingerichtet" statt "schick /onboarding" (das darf nur der Owner).
    IF p_chat_id ~ '^[0-9]{1,18}$' THEN
        v_sender := agent.fn_resolve_sender(p_chat_id::bigint);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'complete', v_complete,
        'open', v_open,
        'core', v_core,
        'package', v_pkg,
        'viewer_is_member', COALESCE((v_sender->>'found')::boolean, false) AND (v_sender->>'role') IS DISTINCT FROM 'owner'
    );
END;
$$;

-- Kein PUBLIC-EXECUTE auf dem Onboarding-Lesefenster.
-- EXECUTE bekommen nur die Paket-Rollen via core.fn_provision_package_roles (<pkg>_rw/<pkg>_ro), nach dieser R__.
REVOKE ALL ON FUNCTION core.fn_onboarding_status(text, text) FROM public;
