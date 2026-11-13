-- ============================================================
-- core.fn_fetch_context (READ — die eine gemeinsame Stelle des Lazy-Fetch)
--   Ersetzt das direkte SELECT der inline load_context-postgresTool-Bindings:
--     SELECT content FROM core.fn_fetch_context('<name>'[, '<chat_id>'])
--   Eingabe: p_name (Basis-Name des Kontexts), p_chat_id (optional). Rueckgabe: Tabelle content (0 oder 1 Zeile).
--
--   Generische Render-Engine: traegt die Zeile einen Eintrag in der
--   Host-Registry core.context_renderers, ruft die Engine die paket-/core-gefuetterte render_fn(name)
--   — die liefert nur den autoritativen Fakten-Header (Ableitungen via SQL) — und wrappt generisch:
--   Banner + Header + _meta-Stempel + '---' + Prosa-content. Das spiegelt die
--   core.context_validators-Registry (Deklaration vs. Ausfuehrung; Paket fuettert das Spezifische,
--   der Core haelt die generische Mechanik). Drei Output-Zustaende: Header da -> gewrappt;
--   Header NULL/leer trotz Registry -> roher content (kein Banner ueber Leere); kein Registry-Eintrag
--   -> roher content. Alle Kontexte (auch family/finance_profile) laufen ueber diesen einen Render-Pfad.
--
--   Per-User-Scope: traegt der Basis-Name in core.context_scopes scope='per_user', liegt der
--   physische Inhalt suffigiert als '<base>__<person_id>' (Name-Suffix; career_profile/
--   career_preferences). Die person_id kommt deterministisch aus der nicht-spoofbaren chat_id via
--   agent.fn_resolve_sender (nie LLM/$fromAI; Numerik-Guard wie fn_check_write_permission). person_id NULL
--   (unaufgeloeste/Sentinel-chat_id) -> physischer Name = Basis-Name -> die leere Basis-
--   Zeile -> leere Menge = fail-closed (liest niemandes Daten; das echte Gate fuer unaufgeloeste Sender).
--   Ein physischer Name '<base>__<pid>' als p_name -> leere Menge (agent.fn_is_per_user_row).
--   Strip vor Registry: Content-/Metadata-Read + render_fn(...) laufen auf dem physischen (suffigierten)
--   Namen, alle Registry-Lookups (context_renderers/_scopes) auf dem Basis-Namen (Registries bleiben
--   exakt-match). Kontexte ohne scope-Zeile (family/financial_planning/finance_profile) -> kein Suffix.
--   1-Arg-Aufrufer (finance/guide/monitor/finance_advisor: p_chat_id Default NULL) ->
--   person_id NULL -> kein Suffix.
--   Identitaets-Aufloesung intern (Paritaet zum Schwester-Write-Fenster fn_set_context_facts):
--   der DEFINER (owner=superuser) ruft agent.fn_resolve_sender ohne neuen Grant; der context_ro-Aufrufer
--   braeuchte sonst selbst EXECUTE darauf (CVE-2018-1058-Anti-Pattern).
--
--   Kinder-Sicht: mit p_chat_id prueft die fn core.fn_sender_sees_household; ohne Haushalts-Sicht liefert sie
--   fuer Paket-Kontexte (package <> 'core', Scope nicht per_user) eine feste Hinweiszeile und fuer family nur Vornamen
--   und Rollen. p_chat_id NULL bleibt der Systempfad (voller Inhalt); Agenten-Werkzeuge uebergeben immer die chat_id.
--
--   SECURITY DEFINER (publiziertes Lesefenster, Muster fn_advisor_read_plan): die fn liest core.context_
--   renderers + core.context_scopes (Registry-Dispatch) + agent.fn_resolve_sender (family). Die Agenten
--   binden load_context unter der engen Rolle context_ro (kein core-Zugriff) -> als Invoker brach jeder
--   load_context-Call mit "permission denied for schema core" ab. DEFINER +
--   gepinnter search_path (pg_catalog,agent,core sind nicht nutzer-schreibbar, CVE-2018-1058) + REVOKE ALL
--   FROM PUBLIC; render_fn-Wert nur aus der host-geseedeten Registry (to_regprocedure-Guard) -> keine
--   Eskalation. Keine neue Datenexposition (context_ro hat ohnehin SELECT auf core_contexts).
--   Schema core (nicht agent): publizierte cross-schema-Lesefenster gehoeren per Konvention nach `core` (zu
--   fn_advisor_read_plan/fn_config_get/fn_package_active/…) -> eine auditierbare Stelle aller Grenzuebertritte.
--   Signatur 2-Arg: core:V013 droppt die alte core.fn_fetch_context(text).
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
    v_pkg      TEXT;
    v_sees     BOOLEAN;
BEGIN
    -- Physische per_user-Zeile '<base>__<pid>' direkt angefragt (der Name kommt vom LLM) -> leere Menge: eine Person
    -- liest per_user-Inhalte nur ueber den Basisnamen + ihre eigene chat_id (sonst laese B A's Zeile per Namen).
    IF agent.fn_is_per_user_row(p_name) THEN
        RETURN;
    END IF;

    -- Per-User-Scope-Aufloesung: Basis-Name -> scope; person_id aus der chat_id (Numerik-Guard
    -- wie fn_check_write_permission; nicht-numerisch/NULL -> kein Resolver-Call -> NULL). Suffix nur wenn
    -- per_user und person_id aufgeloest; sonst physischer = Basis-Name (household/1-Arg).
    SELECT cs.scope INTO v_scope FROM core.context_scopes cs WHERE cs.context_name = p_name;
    IF v_scope = 'per_user' AND p_chat_id ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender(p_chat_id::bigint) ->> 'person_id';
    END IF;
    v_physical := CASE WHEN v_scope = 'per_user' AND v_pid IS NOT NULL
                       THEN p_name || '__' || v_pid ELSE p_name END;

    SELECT c.content, c.metadata, c.package INTO v_content, v_meta, v_pkg
    FROM agent.core_contexts c
    WHERE c.name = v_physical
      AND c.load_strategy = 'lazy';

    IF NOT FOUND THEN
        RETURN;  -- keine lazy-Zeile (inkl. per_user fail-closed: leere/fehlende Basis-Zeile) -> leere Menge
    END IF;

    -- Kinder-Sicht (core.fn_sender_sees_household): ein Absender ohne Haushalts-Sicht bekommt keine Paket-Kontexte
    -- (Haushalts-Inhalt; eigene per_user-Kontexte ausgenommen, keine Scope-Zeile = Haushalt) und von family nur Vornamen
    -- und Rollen. p_chat_id NULL = Systempfad ohne Absender (Tests, Renderer) -> voller Inhalt; jedes Agenten-Werkzeug
    -- uebergibt die build-fixe chat_id (contract_lint LOAD-CONTEXT-CHAT).
    IF p_chat_id IS NOT NULL THEN
        v_sees := core.fn_sender_sees_household(p_chat_id);
        -- Besitzendes Paket auch dann, wenn die Zeile 'core' traegt (restauriertes Alt-Bundle): Plan-Kontext eines Paket-
        -- Beraters bzw. Renderer eines Pakets zaehlen als Paket-Inhalt.
        IF v_pkg IS NOT DISTINCT FROM 'core' THEN
            v_pkg := COALESCE((SELECT a.package FROM core.advisors a WHERE a.plan_context = p_name AND a.package <> 'core' LIMIT 1),
                              (SELECT r.package FROM core.context_renderers r WHERE r.context_name = p_name AND r.package <> 'core'),
                              v_pkg);
        END IF;
        IF NOT v_sees AND v_pkg IS DISTINCT FROM 'core' AND v_scope IS DISTINCT FROM 'per_user' THEN
            RETURN QUERY SELECT 'This document is only available to the adults of the household. Do not guess its content.'::text;
            RETURN;
        END IF;
        IF NOT v_sees AND p_name = 'family' THEN
            RETURN QUERY SELECT 'Household members (first name, role): ' || COALESCE((
                SELECT string_agg(COALESCE(pp->>'first_name', '?') || ' (' || COALESCE(pp->>'role', '?') || ')', ', ' ORDER BY x.ord)
                FROM jsonb_array_elements(COALESCE(v_meta->'facts'->'persons', '[]'::jsonb)) WITH ORDINALITY AS x(pp, ord)), '-')
                || E'.\nOther household details are only available to the adults of the household.';
            RETURN;
        END IF;
    END IF;

    -- Generische Render-Engine: Registry-Eintrag (Basis-Name) -> render_fn(physischer Name) liefert nur den Header.
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

-- SECURITY-DEFINER-Hygiene: kein PUBLIC-EXECUTE. EXECUTE bekommt nur context_ro (die load_context-Rolle
-- aller Agenten) — explizit in util_create_context_ro.sql (laeuft nach dieser R__; dort auch GRANT USAGE ON
-- SCHEMA core). core_ro/finance_ro binden load_context nicht -> kein Grant noetig (nicht "ON ALL FUNCTIONS").
REVOKE ALL ON FUNCTION core.fn_fetch_context(text, text) FROM public;
