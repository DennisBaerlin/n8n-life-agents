-- ============================================================
-- core.fn_set_onboarding_section (WS-B3 DRY-Onboarding O3) — eine Onboarding-Sektion auf Status setzen
--   p: { package?, section_key, status }  (package default 'core'; status in {completed,skipped,unknown})
--   - 'core' -> agent.guide_onboarding_state (Host-Sonderfall); sonst <pkg>.onboarding_state.
--   - skipped -> skipped_at = now() (Audit: wann bewusst ausgelassen); sonst skipped_at = NULL.
--   - unbekannte Sektion / ungueltiger Status / unbekanntes Paket -> {ok:false, reason} (kein Write, kein RAISE).
--   RUECKGABE: {ok:true, section_key, status, complete, area_completed_now, area_all_skipped} | {ok:false, reason}
--     complete           = Post-State: im Bereich (Paket bzw. Person) ist keine Sektion mehr 'unknown'.
--     area_completed_now = DIESER Aufruf hat den Bereich von offen -> aufgeloest gekippt (Roter Faden: genau dann
--                          schickt das Tool die Weiter-Karte). Vor-/Nach-Read unter pg_advisory_xact_lock je
--                          (Paket, Person) -> zwei parallele Markierungen desselben Bereichs sehen einander (kein
--                          verlorener Kipp, kein Doppel-Kipp). Erneutes Markieren eines aufgeloesten Bereichs = false.
--     area_all_skipped   = der Bereich ist aufgeloest, aber keine Sektion 'completed' (Karte sagt "uebersprungen").
--   status_changed_at wird NUR bei echter Status-Aenderung gestempelt (Stillstands-Uhr des Nachfassens).
--
--   D10 / Auth: SECURITY INVOKER (bewusst KEIN DEFINER) — der Write kreuzt keine Schema-Grenze, die der
--   Aufrufer nicht ohnehin darf: der Guide/Host-Cred schreibt agent.*, finance_rw schreibt nur finance.*.
--   Die Isolation haelt damit durch die Grants des AUFRUFERS selbst (ein finance_rw-Aufruf mit package='core'
--   scheiterte an "permission denied for schema agent" — kein Eskalations-Fenster). EXECUTE wird in
--   core.fn_provision_package_roles an <pkg>_rw gegrantet. search_path gepinnt; Suffix '.onboarding_state'
--   ist LITERAL (nie 2. %I) + Name-Regex + to_regclass-Guard. package ist build-time-konstant (nie $fromAI).
--   KEIN HITL: setzt nur den Fortschritts-Marker (kein Finanz-Write); die eigentlichen Onboarding-Writes
--   laufen ueber die gebundenen HITL-Tools (tool_set_household_facts, tool_create_* etc.).
--
--   PER-USER-SCOPE (P2b-1, Parität agent.fn_set_context_facts): traegt das PAKET in core.context_scopes einen
--   per_user-Context (career), ist das Onboarding pro Person. Die person_id kommt DETERMINISTISCH aus der nicht-
--   spoofbaren chat_id (p->>'chat_id') via agent.fn_resolve_sender (NIE LLM/$fromAI; Numerik-Guard wie fetch_context).
--   Unaufgeloester Sender auf per_user -> {ok:false, unresolved_sender} OHNE Write (fail-closed; das echte Gate).
--   Vor dem UPDATE materialisiert core.fn_ensure_onboarding_person die Sektionszeilen der Person aus dem Katalog
--   (Lazy-Onboarding einer weiteren Person). UPDATE + Completeness-Read tragen dann das person_id-Praedikat.
--   household-Pakete (finance/guide/estate, scope-frei in context_scopes): kein person_id; schreiben darf NUR der
--   Owner — ein positiv aufgeloestes Mitglied (p->>'chat_id') -> {ok:false, reason:'owner_only'} ohne Write, ueber
--   das publizierte Fenster core.fn_check_write_permission('owner_only') (Pass-Through ohne chat_id = CLI/Test).
--   Die Paket-Tools reichen dafuer die build-fixe chat_id (nie LLM) im Payload durch.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_set_onboarding_section(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_pkg      text := COALESCE(NULLIF(p->>'package', ''), 'core');
    v_key      text := p->>'section_key';
    v_status   text := p->>'status';
    v_chat     text := NULLIF(p->>'chat_id', '');
    v_rel      text;
    v_rows     int;
    v_complete boolean;
    v_was_complete boolean;
    v_none_done    boolean;
    v_per_user boolean := false;
    v_pid      text;
    v_pfilter  text := '';   -- '' (household) | ' AND person_id = <quoted pid>' (per_user)
BEGIN
    IF v_status NOT IN ('completed', 'skipped', 'unknown') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            format('invalid status %s (expected completed/skipped/unknown)', COALESCE(v_status, 'NULL')));
    END IF;
    IF v_pkg !~ '^[a-z][a-z0-9_]*$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid package name: ' || v_pkg);
    END IF;

    -- Tabelle aufloesen ('core' = Host-Sonderfall; sonst <pkg>.onboarding_state, Suffix LITERAL).
    IF v_pkg = 'core' THEN
        v_rel := 'agent.guide_onboarding_state';
    ELSE
        v_rel := to_regclass(format('%I.onboarding_state', v_pkg))::text;
    END IF;
    IF v_rel IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_package');
    END IF;

    -- Per-User-Scope (P0a-Registry, package-keyed): scope aus core.context_scopes; person aus chat_id (Numerik-
    -- Guard wie fn_fetch_context), NIE LLM. Unaufgeloest auf per_user -> fail-closed {ok:false} (kein Write).
    v_per_user := core.fn_package_is_per_user(v_pkg);   -- die eine Regel (R__fn_package_is_per_user)
    IF v_per_user THEN
        IF v_chat ~ '^[0-9]+$' THEN
            v_pid := agent.fn_resolve_sender(v_chat::bigint) ->> 'person_id';
        END IF;
        IF v_pid IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'unresolved_sender');
        END IF;
        -- Sektionszeilen dieser Person lazy materialisieren (vor UPDATE + Completeness-Read).
        PERFORM core.fn_ensure_onboarding_person(v_pkg, v_pid);
        v_pfilter := format(' AND person_id = %L', v_pid);   -- v_pid DB-aufgeloest (person_id) -> %L sicher
    ELSIF core.fn_check_write_permission('owner_only', v_chat, NULL) IS NOT NULL THEN
        -- Haushalts-Sektion (core/household-Paket): nur der Owner. Sonst setzte ein Mitglied z. B. household auf
        -- 'unknown' und sperrte per Core-first-Gate alle Paket-Agenten fuer den ganzen Haushalt. Publiziertes
        -- DEFINER-Fenster (laeuft auch unter den engen <pkg>_rw-Rollen); Pass-Through ohne/nicht-numerische chat_id.
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;

    -- Roter Faden: Vor-/Nach-Zustand des Bereichs serialisiert je (Paket, Person) -> genau EIN Kipp je Uebergang.
    -- Der Lock steht VOR dem Vor-Read: unter READ COMMITTED sieht die naechste Anweisung danach den Commit eines
    -- parallelen Aufrufers (der Lock wird erst an dessen Transaktionsende frei).
    PERFORM pg_advisory_xact_lock(hashtext('onboarding_area:' || v_pkg || ':' || COALESCE(v_pid, '')));
    EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM %s WHERE status = ''unknown''%s)', v_rel, v_pfilter)
        INTO v_was_complete;

    EXECUTE format(
        'UPDATE %s SET status = $1, skipped_at = CASE WHEN $1 = ''skipped'' THEN now() ELSE NULL END, '
        'status_changed_at = CASE WHEN status IS DISTINCT FROM $1 THEN now() ELSE status_changed_at END '
        'WHERE section_key = $2%s',
        v_rel, v_pfilter) USING v_status, v_key;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('unknown onboarding section %s', COALESCE(v_key, 'NULL')));
    END IF;

    -- Completeness je Person (per_user) bzw. Haushalt (household): keine 'unknown'-Zeile mehr offen.
    EXECUTE format('SELECT NOT EXISTS (SELECT 1 FROM %s WHERE status = ''unknown''%s), '
                   'NOT EXISTS (SELECT 1 FROM %s WHERE status = ''completed''%s)', v_rel, v_pfilter, v_rel, v_pfilter)
        INTO v_complete, v_none_done;
    RETURN jsonb_build_object('ok', true, 'section_key', v_key, 'status', v_status, 'complete', v_complete,
        'area_completed_now', v_complete AND NOT v_was_complete,
        'area_all_skipped',   v_complete AND v_none_done);
END;
$$;
