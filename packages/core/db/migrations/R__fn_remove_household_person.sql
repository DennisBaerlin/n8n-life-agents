-- ============================================================
-- fn_remove_household_person (WS-5d — Person loeschen, „Tod")
--   Owner-CLI (`lifeagents household remove <person_id>`): entfernt die Person aus der Autoring-Quelle
--   `family.facts.persons[]`. fn_set_context_facts ist merge/append-only (kann nicht entfernen) ->
--   eigener JSONB-Write. Das ist der in agent.persons_init.sql vorgesehene „Remove-Pfad":
--     family-UPDATE -> BEFORE-Validator + AFTER-Reconcile-Trigger (trg_project_persons) feuern ->
--     der GC-DELETE auf agent.persons trifft FK ON DELETE RESTRICT, falls die Person noch von
--     finance-Daten referenziert wird -> foreign_key_violation -> hier in {ok:false} gefangen
--     (die Sub-Transaktion rollt zurueck, `family` bleibt unveraendert).
--   Guards: role='owner' -> {ok:false} (Owner-Identitaet nie loeschen); letzte verbleibende Person ->
--     {ok:false}; sonstiger Validator-RAISE -> {ok:false} mit dem Validator-Grund.
--   KASKADE (Phase A, Konvention „Config/Children = CASCADE"): die persons[]-Eintraege der Person in ALLEN
--     anderen Kontexten (z. B. ein Paket-Finanzprofil) werden in DERSELBEN Sub-Transaktion vor dem family-
--     UPDATE entfernt — sonst waere eine referenzierte Person nie loeschbar (die Waisen-Pruefung blockte, und
--     kein anderer Weg entfernt einen Profil-Eintrag). Echte Finanzdaten (Konten/Kredite/…) blockieren weiter
--     ueber FK RESTRICT -> dann rollt auch die Kaskade zurueck.
--   p: { person_id }
--   RUECKGABE: {ok:true, person_id, removed:true, removed_from_contexts} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_household_person.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_remove_household_person(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pid    TEXT := NULLIF(trim(p->>'person_id'), '');
    v_person JSONB;
    v_new    JSONB;
    v_ctx    INT  := 0;
BEGIN
    IF v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'person_id is required');
    END IF;

    -- Die family-Zeile sperren, bevor wir lesen + den letzte-Person-Guard auswerten (Lock-Disziplin
    -- wie fn_unlink_member_identity/fn_set_context_facts; Single-User -> faktisch kontentionsfrei).
    PERFORM 1 FROM agent.core_contexts WHERE name = 'family' FOR UPDATE;

    SELECT pp INTO v_person
    FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
    WHERE c.name = 'family' AND pp->>'person_id' = v_pid
    LIMIT 1;
    IF v_person IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('person "%s" not found in household', v_pid));
    END IF;
    IF v_person->>'role' = 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'the owner person cannot be removed');
    END IF;

    -- neue persons[] ohne die Ziel-Person
    SELECT COALESCE(jsonb_agg(pp), '[]'::jsonb) INTO v_new
    FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
    WHERE c.name = 'family' AND pp->>'person_id' <> v_pid;

    IF jsonb_array_length(v_new) = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot remove the last remaining household person');
    END IF;

    BEGIN
        -- Kaskade: die Eintraege der Person aus allen anderen persons[]-Kontexten entfernen (s. Header).
        UPDATE agent.core_contexts c
        SET metadata = jsonb_set(c.metadata, '{facts,persons}',
            (SELECT COALESCE(jsonb_agg(e), '[]'::jsonb)
             FROM jsonb_array_elements(c.metadata->'facts'->'persons') e
             WHERE e->>'person_id' IS DISTINCT FROM v_pid))
        WHERE c.name <> 'family'
          AND jsonb_typeof(c.metadata->'facts'->'persons') = 'array'
          AND EXISTS (SELECT 1 FROM jsonb_array_elements(c.metadata->'facts'->'persons') e
                      WHERE e->>'person_id' = v_pid);
        GET DIAGNOSTICS v_ctx = ROW_COUNT;

        UPDATE agent.core_contexts
        SET metadata = jsonb_set(metadata, '{facts,persons}', v_new)
        WHERE name = 'family';
    EXCEPTION
        WHEN foreign_key_violation THEN
            -- FK ON DELETE RESTRICT aus dem AFTER-Reconcile-GC: Person noch von finance-Daten referenziert.
            RETURN jsonb_build_object('ok', false, 'reason', format(
                'person "%s" is still referenced by financial records (accounts/loans/insurances/…) — reassign or remove those first', v_pid));
        WHEN raise_exception THEN
            -- BEFORE-Validator-RAISE freundlich durchreichen (Kaskade rollt mit zurueck).
            RETURN jsonb_build_object('ok', false, 'reason', SQLERRM);
    END;

    -- P0b: generischer Per-Person-Purge der per_user-Kontexte der ENTFERNTEN Person ('<base>__<pid>').
    -- Generisch ueber core.context_scopes WHERE scope='per_user' (kein career-Hardcode; nimmt jeden kuenftigen
    -- per_user-Context automatisch mit). Reihenfolge tragend: das family-UPDATE oben hat die Person SCHON
    -- entfernt -> der suffix-aware Protect-Trigger (agent.trg_core_contexts_protect_fn) sieht <pid> nicht mehr
    -- in family -> blockt NICHT -> Purge laeuft. Eine noch lebende Person/Owner bliebe geschuetzt. Der
    -- scope='per_user'-Filter + PK auf context_name -> ein household-Kontext kann nie getroffen werden. Atomar.
    DELETE FROM agent.core_contexts c
    USING core.context_scopes cs
    WHERE cs.scope = 'per_user'
      AND c.name = cs.context_name || '__' || v_pid;

    -- P2b-2: die person-suffigierten Advisor-Latches der entfernten Person mit-raeumen
    -- (core.notification_state source='advisor:<domain>:<pid>', gesetzt von fn_advisor_review_evaluate).
    -- Sonst bliebe ein verwaister 'fired'-Latch zurueck: der per-Person-gefaecherte Cron ueberspringt die
    -- Person (kein Plan mehr -> nicht in fn_context_persons) -> fn_notify_reconcile raeumt sie nie ->
    -- ein spaeterer echter Alert derselben person_id wuerde stumm unterdrueckt. split_part(.,':',3) matcht
    -- das pid-Segment EXAKT (kein LIKE-Wildcard auf dem '_'-haltigen Slug); household-Sources ('advisor:finance',
    -- 'knock', 'finance') tragen kein pid-Segment -> bleiben unberuehrt.
    DELETE FROM core.notification_state
    WHERE source LIKE 'advisor:%'
      AND split_part(source, ':', 3) = v_pid;
    -- Sticker-Bremse der Person (agent.fn_claim_persona_sticker, key = person_id exakt)
    DELETE FROM core.notification_state
    WHERE source = 'persona_sticker' AND key = v_pid;

    RETURN jsonb_build_object('ok', true, 'person_id', v_pid, 'removed', true, 'removed_from_contexts', v_ctx);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_remove_household_person(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_remove_household_person(JSONB) FROM context_ro;
    END IF;
END $$;
