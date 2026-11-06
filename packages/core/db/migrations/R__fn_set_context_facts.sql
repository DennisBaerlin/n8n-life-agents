-- ============================================================
-- fn_set_context_facts (ATOMIC WRITE — der EINE Schreibweg fuer facts-Sidecars, Phase A Fakten-Konsolidierung)
--   Schreibt metadata.facts eines Kontexts in der HOST-Tabelle agent.core_contexts. Loest die zwei frueheren
--   Pfade ab (das fruehere Haushalts-Fakten-Schreibfenster fuer family/finance_profile und das Profil-Fakten-Schreibfenster fuer career) — core:V019 droppt
--   sie. D10 verbietet Paket-Rollen jeden Write auf agent.* -> jeder Fakten-Write ist core-vermittelt.
--   Aufrufer: HITL-Tool agent.tool_set_context_facts (Guide bindet es als tool_set_household_facts, career als
--   tool_set_profile_facts/tool_set_career_preferences), fn_add_household_person + fn_merge_member_identity
--   (bewusst OHNE chat_id: CLI/Pairing sind nicht chat-autorisiert), fn_approve_learn_candidate.
--
--   Eingabe jsonb: context_name (Pflicht), facts (Objekt, partielle Roh-Fakten), content (optional, Prosa-
--     Replace; der system-verwaltete "## Gelernt"-Block bleibt erhalten, ein mitgeschickter wird verworfen —
--     core.fn_split_learned_block, Paritaet fn_advisor_publish_plan), description (optional, nur per_user-Erstanlage), chat_id (Identitaet, NIE LLM), scope (optional,
--     FEST aus der Tool-Bindung, nie $fromAI: 'household' Guide / 'per_user' career -> Abweichung = {ok:false}).
--
--   RESERVIERTE CORE-FORM-KEYS (gelten fuer JEDES Sidecar; Merge-Key = Core-Konstante, kein Registry-Feld):
--     persons   = Liste von Personen-Objekten, Merge-Key person_id (vorhanden: Key-Merge, neu: anhaengen),
--                 as_of-Stempel je beruehrter Person; NUR household-Kontexte (per_user -> {ok:false}).
--     household = Objekt, flacher Merge + as_of-Stempel.
--     Alle anderen Top-Level-Keys: ersetzen. null loescht den Key (Top-Level, in einer Person, im household) —
--     nur die Keys des Patches, nie das Gesamtdokument (gespeicherte JSON-nulls bleiben gueltig).
--     Abgewiesen ({ok:false}): persons:null / household:null (Massen-Loeschung — Person entfernen ist
--     fn_remove_household_person), person_id:null/fehlt, ein _meta-Key (System-Stempel), falsche Typen.
--   CHAT-PFAD (chat_id gesetzt = das LLM-Tool schreibt; WP3 "Slugs und Stempel vergibt die fn"):
--     * as_of je Person/household stempelt IMMER die fn (ein mitgeschicktes as_of wird ueberschrieben).
--     * family: person_id darf fehlen. Treffer per Vor- + Nachname auf GENAU eine Person -> Merge in diese (ein
--       abweichendes Geburtsdatum -> {ok:false}: Korrektur oder Namensvetter wird nicht geraten, person_id noetig);
--       kein Treffer + vollstaendiger Neu-Datensatz (first/last/birth_date/role) -> neue Person mit Slug von
--       agent.fn_person_slug; mehrdeutig/unvollstaendig -> {ok:false}. Eine unbekannte person_id -> {ok:false}
--       (keine vom LLM erfundenen Slugs).
--     Ohne chat_id (CLI, Pairing, interne Aufrufer) gilt das bisherige Verhalten (as_of nur, wenn es fehlt).
--   Relative Zeitangaben in *_date / since ("-12 years", "last monday") loest core.fn_resolve_fact_dates auf.
--
--   ZWEI ZWEIGE (Scope aus core.context_scopes; fehlt die Zeile -> household/owner_only):
--     household (inkl. family): Gate core.fn_facts_context_allowed (family ODER registriert ∧ Paket aktiv ∧
--       household). Die Zeile MUSS existieren (Installer-Skelett: family via util_seed_owner_skeleton, Paket-
--       Kontexte via Manifest-context_skeletons) -> fehlt sie: {ok:false}, KEIN Insert — sonst entstuende sie mit
--       agent_name=NULL und waere still fuer jeden Agenten sichtbar. family = hart owner_only als ERSTE Pruefung
--       (family traegt role/telegram_user_id = die Identitaets-Quelle von fn_resolve_sender -> Eskalationspfad).
--     per_user: person_id DETERMINISTISCH aus fn_resolve_sender(chat_id); unaufgeloest -> {ok:false} (fail-closed,
--       das echte Gate); physischer Speicher '<base>__<pid>' (Suffix fuer I/O, Basis fuer Registry-Lookups);
--       Registry-Zeile core.context_validators ∧ Paket aktiv; INSERT-on-first-write (managed_by='agent', lazy,
--       agent_name=NULL, package aus der Registry) — Muster fn_ensure_onboarding_person (Personen-Zeilen lazy).
--   Permission: agent.fn_check_write_permission(write_permission, chat_id, target_pid) — ohne chat_id
--     Pass-Through (CLI/Pairing, Paritaet fn_sender_is_member).
--   Plan-Dokumente (core.advisors.plan_context, z. B. financial_planning/career_planning) sind fuer ALLE
--     Absender gesperrt -> {ok:false}; sie schreibt nur fn_advisor_publish_plan (owner_only, versioniert).
--   Mitglieder-Selbstpflege: agent.fn_set_own_context_facts setzt scope='per_user' fest (Stufe self).
--   Freundliche Pre-Validation (gleiche Quellen wie der Trigger-Backstop): Core-Validator
--     agent.fn_validate_household_facts + registrierter Paket-Validator -> {ok:false, reason} OHNE Write.
--   Sprache: language einer Person wird vorab normiert (agent.fn_normalize_language: "Koreanisch" -> ko); ein nicht
--     abbildbarer Wert bleibt roh und scheitert am Validator (Wertevorrat core.ui_languages) mit Grund.
--   Persona: persona einer Person wird lower(trim()) normiert; 'neutral' loescht den Key (neutral wird nie gespeichert,
--     Validator-Gesetz).
--   RUECKGABE (Post-State): {ok:true, context_name, created, last_confirmed_at} + persons_count/updated_persons,
--     wenn der Post-State persons[] traegt; bei family zusaetzlich language_missing = die in DIESEM Write neu
--     angehaengten Personen ohne Sprache (Handles -> das Tool schickt dem Owner je Person den Sprach-Picker)
--     | {ok:false, reason} ohne Write.
--   Tests: tests/db/core/test_fn_set_context_facts.sql (+ test_fn_household_facts.sql Trigger-Teil)
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_context_facts(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name       TEXT  := NULLIF(trim(p->>'context_name'), '');
    v_in         JSONB := p->'facts';
    v_want_scope TEXT  := NULLIF(trim(p->>'scope'), '');
    v_content    TEXT  := NULLIF(p->>'content', '');
    v_scope      TEXT;
    v_perm       TEXT;
    v_fn         TEXT;
    v_pkg        TEXT;
    v_target_pid TEXT;
    v_physical   TEXT;
    v_desc       TEXT;
    v_old        JSONB;
    v_exists     BOOLEAN := false;
    v_merged     JSONB;
    v_persons    JSONB;
    v_e          JSONB;
    v_nulls      TEXT[];
    v_hh         JSONB;
    v_kv         RECORD;
    v_idx        INT;
    v_i          INT;
    v_updated    TEXT[] := '{}';
    v_appended   TEXT[] := '{}';
    v_err        TEXT;
    v_today      TEXT  := to_char(CURRENT_DATE, 'YYYY-MM-DD');
    v_old_content TEXT;
    v_learned    TEXT;
    v_split      RECORD;
    -- Chat-Pfad = das LLM-Tool schreibt (chat_id gesetzt). Nur dort: as_of stempelt immer die fn, neue family-
    -- Personen bekommen den Slug von der fn (CLI/Pairing/Tests ohne chat_id bleiben unveraendert).
    v_chat_path  BOOLEAN := NULLIF(trim(COALESCE(p->>'chat_id', '')), '') IS NOT NULL;
    v_match      TEXT;
    v_cnt        INT;
BEGIN
    IF v_name IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'context_name is required');
    END IF;

    -- family = hart owner_only, ZUERST (ein Mitglied erfaehrt nichts ueber Existenz/Form; kein Registry-Lookup davor).
    IF v_name = 'family' AND agent.fn_sender_is_member(p->>'chat_id') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only');
    END IF;

    -- Plan-Dokumente (core.advisors.plan_context) schreibt NUR fn_advisor_publish_plan (owner_only, versioniert) —
    -- fuer ALLE Absender, sonst umginge ein per_user-Plan (career_planning) ueber diesen Weg das Publish-Gate.
    IF EXISTS (SELECT 1 FROM core.advisors a WHERE a.plan_context = v_name) THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            format('context "%s" is a plan document; it is written only by publishing the plan', v_name));
    END IF;

    -- ---- Eingabe-Form (E3) ----
    IF v_in IS NULL OR jsonb_typeof(v_in) = 'null' THEN
        IF v_content IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'nothing to write (facts or content required)');
        END IF;
        v_in := '{}'::jsonb;
    ELSIF jsonb_typeof(v_in) <> 'object' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'facts must be a JSON object of raw facts');
    END IF;
    IF v_in ? '_meta' THEN
        RETURN jsonb_build_object('ok', false, 'reason', '_meta is system-maintained and cannot be written');
    END IF;
    IF v_in ? 'persons' THEN
        IF jsonb_typeof(v_in->'persons') = 'null' THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'persons cannot be cleared here (remove a person via the household person removal instead)');
        END IF;
        IF jsonb_typeof(v_in->'persons') <> 'array' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'persons must be an array of partial person objects');
        END IF;
        FOR v_e IN SELECT * FROM jsonb_array_elements(v_in->'persons') LOOP
            -- Ausnahme: family auf dem Chat-Pfad darf person_id WEGLASSEN (neue Person -> Slug von der fn, bekannte
            -- Person -> Treffer per Name); ein explizites person_id:null bleibt abgelehnt.
            IF jsonb_typeof(v_e) <> 'object'
               OR (jsonb_typeof(v_e->'person_id') IS DISTINCT FROM 'string'
                   AND NOT (v_name = 'family' AND v_chat_path AND NOT (v_e ? 'person_id'))) THEN
                RETURN jsonb_build_object('ok', false, 'reason', 'each persons entry must be an object with a person_id');
            END IF;
        END LOOP;
    END IF;
    IF v_in ? 'household' THEN
        IF jsonb_typeof(v_in->'household') = 'null' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'household cannot be cleared as a whole (null single keys instead)');
        END IF;
        IF jsonb_typeof(v_in->'household') <> 'object' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'household must be a JSON object');
        END IF;
    END IF;
    -- Relative Zeitangaben (*_date / since: "-12 years", "last monday") rechnet die DB, Genauigkeit folgt der Angabe.
    v_in := core.fn_resolve_fact_dates(v_in);

    -- ---- Scope + Permission (registry-getrieben; family fest household/owner_only) ----
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm
    FROM core.context_scopes cs WHERE cs.context_name = v_name;
    v_scope := COALESCE(v_scope, 'household');
    v_perm  := COALESCE(v_perm, 'owner_only');
    IF v_name = 'family' THEN
        v_scope := 'household';
        v_perm  := 'owner_only';
    END IF;
    IF v_want_scope IS NOT NULL AND v_want_scope <> v_scope THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            format('context "%s" is %s-scoped; this binding writes only %s contexts', v_name, v_scope, v_want_scope));
    END IF;

    IF v_scope = 'per_user' THEN
        -- =========================== per_user-Zweig ===========================
        IF v_in ? 'persons' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'persons is a household-only shape key');
        END IF;
        IF p->>'chat_id' ~ '^[0-9]+$' THEN
            v_target_pid := agent.fn_resolve_sender((p->>'chat_id')::bigint) ->> 'person_id';
        END IF;
        IF v_target_pid IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve person for per-user context');
        END IF;
        v_err := agent.fn_check_write_permission(v_perm, p->>'chat_id', v_target_pid);
        IF v_err IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_err);
        END IF;
        SELECT cv.validate_fn, cv.package INTO v_fn, v_pkg
        FROM core.context_validators cv WHERE cv.context_name = v_name;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                format('context "%s" is not a registered facts context (declare a context_validators entry for it first)', v_name));
        END IF;
        IF NOT EXISTS (SELECT 1 FROM core.package_registry r WHERE r.package = v_pkg AND r.status = 'active') THEN
            RETURN jsonb_build_object('ok', false, 'reason', format('package "%s" is not active', v_pkg));
        END IF;
        v_physical := v_name || '__' || v_target_pid;
    ELSE
        -- =========================== household-Zweig ===========================
        IF NOT core.fn_facts_context_allowed(v_name) THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                format('context "%s" is not a writable household facts context (family, or a registered facts context of an active package)', v_name));
        END IF;
        v_err := agent.fn_check_write_permission(v_perm, p->>'chat_id', NULL);
        IF v_err IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_err);
        END IF;
        v_physical := v_name;
    END IF;

    -- ---- Bestand sperren + lesen ----
    SELECT metadata->'facts', content, true INTO v_old, v_old_content, v_exists
    FROM agent.core_contexts WHERE name = v_physical FOR UPDATE;
    v_exists := COALESCE(v_exists, false);
    IF NOT v_exists AND v_scope = 'household' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            format('context row missing for "%s" (package skeleton not seeded — reinstall/update the package)', v_name));
    END IF;
    v_merged := COALESCE(v_old, '{}'::jsonb);

    -- ---- Merge: persons (Merge-Key person_id) ----
    IF v_in ? 'persons' THEN
        v_persons := CASE WHEN jsonb_typeof(v_merged->'persons') = 'array' THEN v_merged->'persons' ELSE '[]'::jsonb END;
        FOR v_e IN SELECT * FROM jsonb_array_elements(v_in->'persons') LOOP
            IF jsonb_typeof(v_e->'persona') = 'string' THEN  -- Persona-Code normieren ("Butler " -> butler) ...
                v_e := v_e || jsonb_build_object('persona', lower(trim(v_e->>'persona')));
            END IF;
            IF v_e->>'persona' = 'neutral' THEN             -- ... neutral = keine Persona = Key loeschen (eine Darstellung)
                v_e := v_e || jsonb_build_object('persona', NULL);
            END IF;
            SELECT COALESCE(array_agg(k), '{}') INTO v_nulls
            FROM jsonb_each(v_e) AS x(k, v) WHERE jsonb_typeof(v) = 'null';
            v_e := v_e - v_nulls;                         -- erst null-Keys auswerten ...
            IF v_e ? 'language' AND agent.fn_normalize_language(v_e->>'language') IS NOT NULL THEN
                v_e := v_e || jsonb_build_object('language', agent.fn_normalize_language(v_e->>'language'));
            END IF;
            -- family/Chat-Pfad: die person_id vergibt bzw. findet die fn, nie das LLM.
            IF NOT (v_e ? 'person_id') THEN
                SELECT count(*), min(pp->>'person_id') INTO v_cnt, v_match
                  FROM jsonb_array_elements(v_persons) pp
                 WHERE lower(trim(pp->>'first_name')) = lower(trim(v_e->>'first_name'))
                   AND lower(trim(pp->>'last_name'))  = lower(trim(v_e->>'last_name'));
                -- Gleicher Name, anderes Geburtsdatum: Korrektur ODER Namensvetter — nicht raten (eine stille Dublette
                -- oder ein ueberschriebenes Geburtsdatum waeren beide falsch) -> die Person per person_id ansprechen.
                IF v_cnt = 1 AND v_e ? 'birth_date' AND EXISTS (
                       SELECT 1 FROM jsonb_array_elements(v_persons) pp
                        WHERE pp->>'person_id' = v_match AND pp->>'birth_date' IS DISTINCT FROM v_e->>'birth_date') THEN
                    RETURN jsonb_build_object('ok', false, 'reason', format(
                        'a household member "%s %s" already exists (person_id %s) with a different birth date — pass '
                        || 'person_id %s to correct their data; a second person with the same full name can only be '
                        || 'added via the household CLI', v_e->>'first_name', v_e->>'last_name', v_match, v_match));
                END IF;
                IF v_cnt = 1 THEN
                    v_e := v_e || jsonb_build_object('person_id', v_match);       -- bekannte Person (Vor- + Nachname)
                ELSIF v_cnt > 1 THEN
                    RETURN jsonb_build_object('ok', false, 'reason', format(
                        'several household members are called "%s %s" — pass the person_id of the one you mean',
                        v_e->>'first_name', v_e->>'last_name'));
                ELSIF COALESCE(trim(v_e->>'first_name'), '') <> '' AND COALESCE(trim(v_e->>'last_name'), '') <> ''
                      AND v_e ? 'birth_date' AND v_e ? 'role' THEN
                    v_e := v_e || jsonb_build_object('person_id', agent.fn_person_slug(v_e->>'first_name',
                        ARRAY(SELECT pp->>'person_id' FROM jsonb_array_elements(v_persons) pp)));
                ELSE
                    RETURN jsonb_build_object('ok', false, 'reason', format(
                        'household member "%s %s" not found — pass their person_id to update them, or first_name, '
                        || 'last_name, birth_date and role to add a new member',
                        COALESCE(v_e->>'first_name', '?'), COALESCE(v_e->>'last_name', '?')));
                END IF;
            ELSIF v_name = 'family' AND v_chat_path
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_persons) pp
                                   WHERE pp->>'person_id' = v_e->>'person_id') THEN
                RETURN jsonb_build_object('ok', false, 'reason', format(
                    'unknown person_id "%s" — omit person_id to add a new household member (the system assigns it)',
                    v_e->>'person_id'));
            END IF;
            IF v_chat_path OR NOT (v_e ? 'as_of') THEN    -- ... dann stempeln (Chat-Pfad immer; as_of:null -> frisch)
                v_e := v_e || jsonb_build_object('as_of', v_today);
            END IF;
            v_nulls := array_remove(v_nulls, 'as_of');    -- der frische Stempel darf nicht wieder fallen
            v_idx := NULL;
            FOR v_i IN 0 .. jsonb_array_length(v_persons) - 1 LOOP
                IF v_persons->v_i->>'person_id' = v_e->>'person_id' THEN v_idx := v_i; EXIT; END IF;
            END LOOP;
            IF v_idx IS NULL THEN
                v_persons := v_persons || jsonb_build_array(v_e);
                v_appended := v_appended || (v_e->>'person_id');
            ELSE
                v_persons := jsonb_set(v_persons, ARRAY[v_idx::text], ((v_persons->v_idx) || v_e) - v_nulls);
            END IF;
            v_updated := v_updated || (v_e->>'person_id');
        END LOOP;
        v_merged := jsonb_set(v_merged, '{persons}', v_persons);
    END IF;

    -- ---- Merge: household (flach) ----
    IF v_in ? 'household' THEN
        v_hh := v_in->'household';
        SELECT COALESCE(array_agg(k), '{}') INTO v_nulls
        FROM jsonb_each(v_hh) AS x(k, v) WHERE jsonb_typeof(v) = 'null';
        v_hh := v_hh - v_nulls;
        IF v_chat_path OR NOT (v_hh ? 'as_of') THEN
            v_hh := v_hh || jsonb_build_object('as_of', v_today);
        END IF;
        v_nulls := array_remove(v_nulls, 'as_of');
        v_merged := jsonb_set(v_merged, '{household}',
            ((CASE WHEN jsonb_typeof(v_merged->'household') = 'object' THEN v_merged->'household' ELSE '{}'::jsonb END)
             || v_hh) - v_nulls);
    END IF;

    -- ---- Merge: sonstige Top-Level-Keys (Replace; null loescht) ----
    FOR v_kv IN SELECT k, v FROM jsonb_each(v_in) AS x(k, v) WHERE k NOT IN ('persons', 'household') LOOP
        IF jsonb_typeof(v_kv.v) = 'null' THEN
            v_merged := v_merged - v_kv.k;
        ELSE
            v_merged := v_merged || jsonb_build_object(v_kv.k, v_kv.v);
        END IF;
    END LOOP;

    v_merged := jsonb_set(v_merged, '{_meta}',
        COALESCE(v_merged->'_meta', '{}'::jsonb) || jsonb_build_object('last_confirmed_at', v_today));

    -- ---- Freundliche Pre-Validation (dieselbe Pruefung wie der Trigger: agent.fn_validate_context_facts) ----
    v_err := agent.fn_validate_context_facts(v_merged, v_physical);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_err);
    END IF;

    -- ---- Prosa-Replace: "## Gelernt" ist system-verwaltet (core.fn_split_learned_block, Paritaet
    --      fn_advisor_publish_plan): einen im neuen content mitgeschickten Block verwerfen, den gespeicherten
    --      (owner-bestaetigte Lern-Notizen, family ist Notiz-Ziel) unveraendert anhaengen. ----
    IF v_content IS NOT NULL THEN
        LOOP
            v_split := core.fn_split_learned_block(v_content);
            EXIT WHEN v_split.block IS NULL;
            v_content := COALESCE(v_split.body, '');
        END LOOP;
        v_learned := (core.fn_split_learned_block(v_old_content)).block;
        IF v_learned IS NOT NULL THEN
            v_content := rtrim(v_content, E'\n ') || E'\n\n' || v_learned;
        END IF;
        v_content := NULLIF(v_content, '');
    END IF;

    -- ---- Write ----
    IF v_scope = 'household' THEN
        UPDATE agent.core_contexts
        SET metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{facts}', v_merged),
            content  = COALESCE(v_content, content)
        WHERE name = v_physical;
    ELSE
        v_desc := COALESCE(NULLIF(trim(p->>'description'), ''),
            format('Runtime facts profile "%s" (PII, maintained by the agent via per-entry HITL; '
                || 'load to ground recommendations).', v_name));
        INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
        VALUES (v_physical, v_desc, NULL, 'lazy', COALESCE(v_content, ''), 'agent', v_pkg,
                jsonb_build_object('facts', v_merged))
        ON CONFLICT (name) DO UPDATE SET
            content  = COALESCE(v_content, agent.core_contexts.content),
            metadata = jsonb_set(COALESCE(agent.core_contexts.metadata, '{}'::jsonb), '{facts}', v_merged);
    END IF;

    -- Post-State-Vertrag: kein Input-Echo der Fakten, nur was der Aufrufer nicht weiss.
    RETURN jsonb_build_object(
        'ok', true,
        'context_name', v_name,
        'created', NOT v_exists,
        'last_confirmed_at', v_today)
        || CASE WHEN jsonb_typeof(v_merged->'persons') = 'array'
                THEN jsonb_build_object('persons_count', jsonb_array_length(v_merged->'persons'),
                                        'updated_persons', to_jsonb(v_updated))
                ELSE '{}'::jsonb END
        || CASE WHEN v_physical = 'family'
                THEN jsonb_build_object('language_missing', COALESCE((
                         SELECT jsonb_agg(pp->>'person_id')
                           FROM jsonb_array_elements(v_merged->'persons') pp
                          WHERE pp->>'person_id' = ANY (v_appended)
                            AND jsonb_typeof(pp->'language') IS DISTINCT FROM 'string'), '[]'::jsonb))
                ELSE '{}'::jsonb END;
END;
$$;
