-- ============================================================
-- core.fn_fetch_context (read-only — DIE eine gemeinsame Stelle des Lazy-Fetch)
--   Ersetzt das direkte SELECT der inline load_context-postgresTool-Bindings:
--     SELECT content FROM core.fn_fetch_context('<name>'[, '<chat_id>'])
--
--   GENERISCHE RENDER-ENGINE (WS1a, Core-Advisor-Engine): traegt die Zeile einen Eintrag in der
--   Host-Registry core.context_renderers, ruft die Engine die paket-/core-gefuetterte render_fn(name)
--   — die liefert NUR den autoritativen Fakten-HEADER (Ableitungen via SQL) — und WRAPPT generisch:
--   Banner + Header + _meta-Stempel + '---' + Prosa-content. Das spiegelt die bereits validierte
--   core.context_validators-Registry (Deklaration-vs-Ausfuehrung; Paket fuettert das Spezifische,
--   der Core haelt die generische Mechanik). DREI OUTPUT-ZUSTAENDE (P1-3): Header da -> gewrappt;
--   Header NULL/leer trotz Registry -> roher content (kein Banner ueber Leere); kein Registry-Eintrag
--   -> roher content.
--
--   PER-USER-SCOPE (P0b): traegt der BASIS-Name in core.context_scopes scope='per_user', liegt der
--   physische Inhalt suffigiert als '<base>__<person_id>' (Mutterplan-Arbiter Name-Suffix; career_profile/
--   career_preferences). Die person_id kommt DETERMINISTISCH aus der nicht-spoofbaren chat_id via
--   agent.fn_resolve_sender (NIE LLM/$fromAI; Numerik-Guard wie fn_check_write_permission). person_id NULL
--   (unaufgeloeste/Sentinel-chat_id) -> physischer Name = Basis-Name -> die (nach der Migration leere) Basis-
--   Zeile -> leere Menge = FAIL-CLOSED (liest niemandes Daten; das echte Gate fuer unaufgeloeste Sender).
--   STRIP-VOR-REGISTRY: Content-/Metadata-Read + render_fn(...) laufen auf dem PHYSISCHEN (suffigierten)
--   Namen, ALLE Registry-Lookups (context_renderers/_scopes) auf dem BASIS-Namen (Registries bleiben
--   exakt-match). Kontexte ohne scope-Zeile (family/financial_planning/finance_profile) -> kein Suffix
--   (unveraendert). 1-Arg-Aufrufer (finance/guide/monitor/finance_advisor: p_chat_id Default NULL) ->
--   person_id NULL -> kein Suffix -> verhaltensgleich zu vor P0b.
--   Identitaets-Aufloesung INTERN (Paritaet zum Schwester-Write-Fenster fn_set_context_facts, DRY/SSOT):
--   der DEFINER (owner=superuser) ruft agent.fn_resolve_sender ohne neuen Grant; der context_ro-Aufrufer
--   braeuchte sonst selbst EXECUTE darauf (CVE-2018-1058-Anti-Pattern). arch-challenge ADOPT Option B.
--
--   WS1b: family/finance_profile laufen jetzt ueber DIESELBE generische Registry-Engine (Header-only
--   fn(text), via core.context_renderers) — der frueher name-gebundene Legacy-Whitelist-Zweig +
--   das mutable metadata.render_fn-Flag sind ENTFERNT (EIN Render-Pfad fuer alle Contexts).
--
--   SECURITY DEFINER (publiziertes Lesefenster, Muster fn_advisor_read_plan): die fn liest core.context_
--   renderers + core.context_scopes (Registry-Dispatch) + agent.fn_resolve_sender (family). Die Agenten
--   binden load_context unter der ENGEN Rolle context_ro (D10: KEIN core-Zugriff) -> als Invoker brach JEDER
--   load_context-Call mit "permission denied for schema core" ab (real-LLM-Abnahme 2026-06-22). DEFINER +
--   gepinnter search_path (pg_catalog,agent,core sind nicht nutzer-schreibbar, CVE-2018-1058) + REVOKE ALL
--   FROM PUBLIC; render_fn-Wert nur aus der host-geseedeten Registry (to_regprocedure-Guard) -> keine
--   Eskalation. KEINE neue Datenexposition (context_ro hat ohnehin SELECT auf core_contexts).
--   SCHEMA core (nicht agent): publizierte cross-schema-Lesefenster gehoeren per Konvention nach `core` (zu
--   fn_advisor_read_plan/fn_config_get/fn_package_active/…) -> EINE auditierbare Stelle aller Grenzuebertritte.
--   Der Umzug agent->core erfolgte mit core:V008 (DROP der alten agent.fn_fetch_context); der Signatur-
--   Wechsel auf 2-Arg (P0b) droppt die alte core.fn_fetch_context(text) via core:V013.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_fetch_context(p_name text, p_chat_id text DEFAULT NULL)
RETURNS TABLE (content text)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, agent, core, pg_temp
AS $$
DECLARE
    v_content  TEXT;
    v_meta     JSONB;
    v_fn       TEXT;
    v_header   TEXT;
    v_stamp    TEXT;
    v_scope    TEXT;
    v_pid      TEXT;
    v_physical TEXT;
BEGIN
    -- Per-User-Scope-Aufloesung (P0b): Basis-Name -> scope; person_id aus der chat_id (Numerik-Guard
    -- wie fn_check_write_permission; nicht-numerisch/NULL -> kein Resolver-Call -> NULL). Suffix NUR wenn
    -- per_user UND person_id aufgeloest; sonst physischer = Basis-Name (household/1-Arg unveraendert).
    SELECT cs.scope INTO v_scope FROM core.context_scopes cs WHERE cs.context_name = p_name;
    IF v_scope = 'per_user' AND p_chat_id ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender(p_chat_id::bigint) ->> 'person_id';
    END IF;
    v_physical := CASE WHEN v_scope = 'per_user' AND v_pid IS NOT NULL
                       THEN p_name || '__' || v_pid ELSE p_name END;

    SELECT c.content, c.metadata INTO v_content, v_meta
    FROM agent.core_contexts c
    WHERE c.name = v_physical
      AND c.load_strategy = 'lazy';

    IF NOT FOUND THEN
        RETURN;  -- keine lazy-Zeile (inkl. per_user fail-closed: leere/fehlende Basis-Zeile) -> leere Menge
    END IF;

    -- Generische Render-Engine: Registry-Eintrag (BASIS-Name) -> render_fn(PHYSISCHER Name) liefert NUR den Header.
    SELECT cr.render_fn INTO v_fn FROM core.context_renderers cr WHERE cr.context_name = p_name;
    IF v_fn IS NOT NULL AND to_regprocedure(v_fn || '(text)') IS NOT NULL THEN
        EXECUTE format('SELECT %s($1)', v_fn) INTO v_header USING v_physical;
        IF v_header IS NOT NULL AND length(trim(v_header)) > 0 THEN
            v_stamp := v_meta->'facts'->'_meta'->>'last_confirmed_at';
            RETURN QUERY SELECT
                E'**Authoritative facts — these override anything stated in the prose below.**\n\n'
                || v_header
                || CASE WHEN COALESCE(v_stamp, '') <> '' THEN E'\n\n_Facts last confirmed: ' || v_stamp || '_' ELSE '' END
                || E'\n\n---\n\n'
                || COALESCE(v_content, '');
            RETURN;
        END IF;
        -- 3. Zustand: Header NULL/leer trotz Registry-Eintrag -> roher content (kein Banner ueber Leere).
    END IF;

    RETURN QUERY SELECT v_content;
END;
$$;

-- SECURITY-DEFINER-Hygiene: kein PUBLIC-EXECUTE. EXECUTE bekommt NUR context_ro (die load_context-Rolle
-- ALLER Agenten) — explizit in util_create_context_ro.sql (laeuft NACH dieser R__; dort auch GRANT USAGE ON
-- SCHEMA core). core_ro/finance_ro binden load_context NICHT -> kein Grant noetig (NICHT "ON ALL FUNCTIONS").
REVOKE ALL ON FUNCTION core.fn_fetch_context(text, text) FROM public;
