-- ============================================================
-- agent.fn_record_learn_candidates(p jsonb) -> jsonb   (Phase C, WS-2; EINE atomare Tx)
--   Nimmt die ROH-Kandidaten der LLM-Extraktion (das LLM liefert nur Rohwerte; slot_key/kind/expires_at
--   leitet die DB ab) und VERSIONIERT sie als Vorschlaege in agent.guide_learn_candidates. Schreibt
--   AUSSCHLIESSLICH guide_learn_candidates + guide_learn_watermark — NIE agent.core_contexts (M1).
--   Gelesene p-Keys:
--     candidates[]: { agent_name, source_id, target_kind(fact|note), context_name, person_slug?, field?,
--                     value, rationale? }
--     watermarks[]: { agent_name, last_seen_id }   -- MAX gesammelte id je Quelltabelle dieses Laufs
--   Pro Kandidat (DB entscheidet, nicht das LLM):
--     1. Shape-Guard (Pflichtfelder; fact braucht person_slug+field).
--     2. fact: Kontext-Pruefung core.fn_facts_context_allowed (family + household-Fakten-Kontexte AKTIVER Pakete) + Denylist-Vorfilter via der kanonischen
--        agent.fn_validate_household_facts (synthetischer Nicht-'family'-Name -> NUR die Derived-Value-
--        Denylist) -> abgeleitete Felder (age/start_year/...) fallen raus ("LLM rechnet nicht", M2).
--        note: Knowledge-Allowlist core.fn_note_context_allowed (managed_by='agent' + kuratierte Liste).
--     3. slot_key ableiten (fact: lower(context|person|field); note: context|md5(normalisierte Notiz)).
--     4. NOOP/Update: fact gegen gespeicherte metadata.facts.persons; note Substring gegen "## Gelernt".
--     5. Dedup x3: in-batch (gleicher slot) · vs offene (pending) · vs kuerzlich rejected (< expiry_days,
--        durable Rejection-Memory).
--     6. Cap LIMIT learn_context.daily_cap des KALENDERTAGS (Prio update>new), ON CONFLICT
--        (agent_name,source_id,slot_key) DO NOTHING (Idempotenz / at-most-once-lossy).
--     7. Watermark-Vorschub GREATEST je agent_name — selbe Tx (Transactional-Outbox).
--   Config-getrieben: learn_context.daily_cap (3) / learn_context.expiry_days (7) ueber core.fn_config_get.
--   Rueckgabe: { ok, new_pending, inserted:[{id, ...Karte}], skipped:{...}, watermarks_advanced, daily_cap, expiry_days }.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_record_learn_candidates(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, agent, core
AS $$
DECLARE
    v_cap     int := COALESCE(NULLIF(core.fn_config_get('core', 'learn_context', 'daily_cap'),   '')::int, 3);
    v_expiry  int := COALESCE(NULLIF(core.fn_config_get('core', 'learn_context', 'expiry_days'), '')::int, 7);
    v_cand    jsonb;
    v_tk      text;     -- target_kind
    v_ctx     text;
    v_person  text;
    v_field   text;
    v_value   text;
    v_rat     text;
    v_agent   text;
    v_source  bigint;
    v_slot    text;
    v_kind    text;     -- new|update
    v_stored  text;
    v_norm    text;
    v_content text;
    v_seen    text[] := '{}';            -- in-batch slot dedup
    v_accept  jsonb  := '[]'::jsonb;     -- akzeptierte Arbeits-Records (vor Cap)
    v_rec     jsonb;
    v_id      bigint;
    v_noop      int := 0;
    v_dedup     int := 0;
    v_denylist  int := 0;
    v_allowlist int := 0;
    v_malformed int := 0;
    v_capped    int := 0;
    v_idem      int := 0;
    v_today_pending int;
    v_allow     int;
    v_inserted  jsonb := '[]'::jsonb;
    v_ins_count int := 0;
    v_wm        jsonb;
    v_wm_adv    int := 0;
BEGIN
    -- Advisory-Lock (transaktions-skopiert -> auto-Release, kein Connection-Pool-Leak): serialisiert
    -- ueberlappende Cron-Laeufe an genau dem Punkt, der schreibt. Ein zweiter Lauf wartet, sieht dann den
    -- committeten Stand (Dedup vs pending + ON CONFLICT + Watermark-GREATEST machen ihn idempotent).
    PERFORM pg_advisory_xact_lock(hashtext('agent.fn_record_learn_candidates')::bigint);

    -- ===== 1. Per-Kandidat: validieren -> slot_key/kind -> NOOP/Dedup -> akzeptieren =====
    FOR v_cand IN SELECT * FROM jsonb_array_elements(COALESCE(p->'candidates', '[]'::jsonb)) LOOP
        v_agent  := NULLIF(btrim(v_cand->>'agent_name'), '');
        v_source := NULLIF(v_cand->>'source_id', '')::bigint;
        v_tk     := v_cand->>'target_kind';
        v_ctx    := NULLIF(btrim(v_cand->>'context_name'), '');
        v_value  := NULLIF(btrim(v_cand->>'value'), '');
        v_rat    := NULLIF(btrim(v_cand->>'rationale'), '');
        v_person := NULLIF(btrim(v_cand->>'person_slug'), '');
        v_field  := NULLIF(btrim(v_cand->>'field'), '');

        IF v_agent IS NULL OR v_source IS NULL OR v_ctx IS NULL OR v_value IS NULL
           OR v_tk NOT IN ('fact', 'note') THEN
            v_malformed := v_malformed + 1; CONTINUE;
        END IF;

        IF v_tk = 'fact' THEN
            IF v_person IS NULL OR v_field IS NULL THEN
                v_malformed := v_malformed + 1; CONTINUE;
            END IF;
            IF NOT core.fn_facts_context_allowed(v_ctx) THEN   -- Install-UX-Phase 6: registry statt Paket-Literal
                v_allowlist := v_allowlist + 1; CONTINUE;
            END IF;
            -- Denylist-Vorfilter (M2): kanonische Derived-Value-Liste wiederverwenden (synthetischer
            -- Nicht-'family'-Name -> NUR die Denylist laeuft, keine Struktur-Pflichtfelder).
            IF agent.fn_validate_household_facts(jsonb_build_object(v_field, v_value), '_learn_denylist_probe') IS NOT NULL THEN
                v_denylist := v_denylist + 1; CONTINUE;
            END IF;
            v_slot := lower(v_ctx || '|' || v_person || '|' || v_field);
            SELECT pp->>v_field INTO v_stored
            FROM agent.core_contexts c
                 CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
            WHERE c.name = v_ctx AND pp->>'person_id' = v_person
            LIMIT 1;
            IF v_stored IS NOT NULL AND btrim(v_stored) = v_value THEN
                v_noop := v_noop + 1; CONTINUE;
            END IF;
            v_kind := CASE WHEN v_stored IS NULL THEN 'new' ELSE 'update' END;
        ELSE  -- note
            IF NOT core.fn_note_context_allowed(v_ctx) THEN
                v_allowlist := v_allowlist + 1; CONTINUE;
            END IF;
            v_norm := lower(regexp_replace(v_value, '\s+', ' ', 'g'));
            v_slot := v_ctx || '|' || md5(v_norm);
            -- NOOP nur gegen die "## Gelernt"-LERN-Notizzeilen (Bullet + Provenienz-Marker 'aus Chat'),
            -- NICHT gegen den gesamten content (sonst wuerde ein zufaelliger Substring in der Prosa/
            -- Instruktion eine echte Notiz dauerhaft als bekannt unterdruecken). Gleiche Identitaet wie
            -- der Append/Remove-Pfad (fn_append/fn_remove_context_note).
            SELECT c.content INTO v_content FROM agent.core_contexts c WHERE c.name = v_ctx;
            IF v_content IS NOT NULL AND EXISTS (
                SELECT 1 FROM unnest(string_to_array(v_content, E'\n')) ln
                WHERE ln LIKE '- %' AND position(v_norm IN lower(ln)) > 0 AND ln ILIKE '%aus Chat%'
            ) THEN
                v_noop := v_noop + 1; CONTINUE;
            END IF;
            v_kind   := 'new';     -- Notizen sind append-only (Wert-Update nur bei facts)
            v_person := NULL;
            v_field  := NULL;
        END IF;

        IF v_slot = ANY(v_seen) THEN
            v_dedup := v_dedup + 1; CONTINUE;
        END IF;
        IF EXISTS (
            SELECT 1 FROM agent.guide_learn_candidates
            WHERE slot_key = v_slot
              AND (status = 'pending'
                   OR (status = 'rejected' AND rejected_at > now() - make_interval(days => v_expiry)))
        ) THEN
            v_dedup := v_dedup + 1; CONTINUE;
        END IF;

        v_seen   := v_seen || v_slot;
        v_accept := v_accept || jsonb_build_object(
            'agent_name', v_agent, 'source_id', v_source, 'target_kind', v_tk,
            'context_name', v_ctx, 'person_slug', v_person, 'field', v_field,
            'proposed_value', v_value, 'kind', v_kind, 'slot_key', v_slot, 'rationale', v_rat,
            'prio', CASE WHEN v_kind = 'update' THEN 0 ELSE 1 END);
    END LOOP;

    -- ===== 2. Cap: pending DES KALENDERTAGS =====
    SELECT count(*) INTO v_today_pending
    FROM agent.guide_learn_candidates
    WHERE status = 'pending' AND created_at::date = current_date;
    v_allow := greatest(v_cap - v_today_pending, 0);

    -- ===== 3. Insert (Prio update>new, gecappt), ON CONFLICT DO NOTHING =====
    FOR v_rec IN
        SELECT e FROM jsonb_array_elements(v_accept) e
        ORDER BY (e->>'prio')::int, (e->>'source_id')::bigint
    LOOP
        IF v_allow <= 0 THEN
            v_capped := v_capped + 1; CONTINUE;
        END IF;
        v_id := NULL;
        INSERT INTO agent.guide_learn_candidates
            (agent_name, source_id, target_kind, context_name, person_slug, field,
             proposed_value, kind, slot_key, rationale, expires_at)
        VALUES (
            v_rec->>'agent_name', (v_rec->>'source_id')::bigint, v_rec->>'target_kind', v_rec->>'context_name',
            v_rec->>'person_slug', v_rec->>'field', v_rec->>'proposed_value', v_rec->>'kind', v_rec->>'slot_key',
            v_rec->>'rationale', now() + make_interval(days => v_expiry))
        ON CONFLICT (agent_name, source_id, slot_key) DO NOTHING
        RETURNING id INTO v_id;
        IF v_id IS NOT NULL THEN
            v_allow     := v_allow - 1;
            v_ins_count := v_ins_count + 1;
            v_inserted  := v_inserted || jsonb_build_object(
                'id', v_id, 'agent_name', v_rec->>'agent_name', 'target_kind', v_rec->>'target_kind',
                'context_name', v_rec->>'context_name', 'person_slug', v_rec->>'person_slug',
                'field', v_rec->>'field', 'proposed_value', v_rec->>'proposed_value',
                'kind', v_rec->>'kind', 'rationale', v_rec->>'rationale');
        ELSE
            v_idem := v_idem + 1;   -- (agent,source,slot) existiert schon -> idempotenter No-op
        END IF;
    END LOOP;

    -- ===== 4. Watermark-Vorschub (GREATEST), selbe Tx =====
    FOR v_wm IN SELECT * FROM jsonb_array_elements(COALESCE(p->'watermarks', '[]'::jsonb)) LOOP
        IF NULLIF(btrim(v_wm->>'agent_name'), '') IS NULL OR NULLIF(v_wm->>'last_seen_id', '') IS NULL THEN
            CONTINUE;
        END IF;
        INSERT INTO agent.guide_learn_watermark (agent_name, last_seen_id)
        VALUES (v_wm->>'agent_name', (v_wm->>'last_seen_id')::bigint)
        ON CONFLICT (agent_name) DO UPDATE
            SET last_seen_id = GREATEST(agent.guide_learn_watermark.last_seen_id, EXCLUDED.last_seen_id),
                updated_at   = now();
        v_wm_adv := v_wm_adv + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', true,
        'new_pending', v_ins_count,
        'inserted', v_inserted,
        'skipped', jsonb_build_object(
            'noop', v_noop, 'dedup', v_dedup, 'denylist', v_denylist, 'allowlist', v_allowlist,
            'malformed', v_malformed, 'capped', v_capped, 'idempotent', v_idem),
        'watermarks_advanced', v_wm_adv,
        'daily_cap', v_cap, 'expiry_days', v_expiry);
END;
$$;
