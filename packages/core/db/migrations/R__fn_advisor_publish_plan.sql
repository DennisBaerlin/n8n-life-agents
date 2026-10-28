-- ============================================================
-- fn_advisor_publish_plan (ATOMIC WRITE — Draft publizieren + Context-Doc upserten)
--   In EINER Transaktion: (1) bisheriger active-Plan der Domain -> 'superseded'
--   (Versions-Audit, nie geloescht), (2) Draft -> 'active' + plan_md persistiert,
--   (3) Domaenen-Plan-Doc in agent.core_contexts upserted (finance -> 'financial_planning', WS-B2c)
--   (lazy, agent_name=NULL=global, managed_by='agent' [D14/WS-B2: typisierte Spalte] — der Seeder
--   seed_data.sh fasst managed_by='agent'-Zeilen nie an, sonst wuerde ein Re-Seed den
--   agent-publizierten Plan still ueberschreiben; package=Domain als Uninstall-Purge-Key).
--   Aufgerufen vom HITL-gegateten Tool agent.tool_publish_plan (domain = fixer
--   Binding-Input). Das LLM liefert plan_md als fertiges Markdown — die fn rechnet
--   nichts, sie persistiert und verkettet nur (Status + Versionen = DB-Zustand).
--   P0c PERSON-SCOPE (Paritaet fn_advisor_save_section): Plan-Schluessel = (domain, person_id) + der
--   Context-Name aus core.advisors.plan_context (ersetzt die alte finance->financial_planning-CASE). household
--   (finance/financial_planning) -> person_id NULL, Doc am Basis-Namen; per_user (career/career_planning,
--   core.context_scopes) -> person_id = Sender (own_user_only) aus der chat_id (NIE LLM), Doc suffigiert
--   '<base>__<pid>'; unaufgeloester Sender bei per_user -> {ok:false}. Permission via fn_check_write_permission.
--   Eingabe jsonb: domain (default 'finance'), chat_id (Identitaet), plan_md (Pflicht, Markdown),
--     plan_name (optional, Umbenennung beim Publish),
--     context_description (optional; sonst generischer EN-Default mit Scope-Pointer),
--     change_summary (optional; Aenderungs-Zusammenfassung der Version, gespeichert mit der Owner-Sprache — Plan teilen).
--   WS3 Naht-Backstop: VOR jedem Write komponiert die fn die section_data block-weise und prueft
--     deterministisch, dass jeder Top-Block (goal/risk_profile/target_allocation/glidepath/emergency_reserve)
--     von genau EINER Sektion kommt (der jsonb_each-Merge ist storage-order/nicht-deterministisch -> zwei
--     Sektionen mit demselben Block verloeren still eine Haelfte). Doppelung -> {ok:false, reason}.
--   "## Gelernt" = SYSTEM-VERWALTETER Block (Phase A Bugfix, core.fn_split_learned_block): owner-bestaetigte
--     Lern-Notizen (core.fn_append_context_note) leben im Plan-Doc. Ein Publish ERHAELT den gespeicherten Block
--     unveraendert (angehaengt ans neue plan_md) und VERWIRFT einen im plan_md mitgeschickten (auch im Versions-
--     Audit advisor_plans.plan_md) — vorher ersetzte content = plan_md alles und loeschte still jede Notiz.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, plan_id, version, superseded_plan_id,
--     context_name, section_count} (Post-State der Publish-Kette).
--   Korrigierbar (fehlendes domain, leeres plan_md, kein Draft, Block-Kollision, ungueltige Plan-Fakten laut Core-
--   Form oder Paket-Validator des Basis-Namens) -> {ok:false, reason} OHNE Write.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_advisor_publish_plan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain   TEXT := NULLIF(trim(COALESCE(p->>'domain', '')), '');   -- Pflicht (Phase B: kein 'finance'-Default)
    v_plan_md  TEXT := COALESCE(p->>'plan_md', '');
    v_ctx_name TEXT;                    -- BASIS-Context-Name der Domain (Registry/Fallback); im Result zurueck
    v_physical TEXT;                    -- physischer Speicher: per_user -> '<base>__<pid>', sonst Basis
    v_ctx_desc TEXT;
    v_plan_id  INT;
    v_version  INT;
    v_state    JSONB;
    v_old_id   INT;
    v_sections INT;
    v_new_facts JSONB := '{}'::jsonb;   -- generisch aus interview_state.<section>.data komponiert (P1-D)
    v_old_facts JSONB;                  -- bestehender Sidecar (Migration/frueherer Publish) — bewahren (P1-A/C)
    v_merged    JSONB;
    v_sec       JSONB;
    v_blk_key   TEXT;
    v_seen_blocks TEXT[] := '{}';       -- WS3 Naht-Backstop: schon belegte Top-Block-Keys (Kollisions-Guard)
    -- P0c Person-Scope (Paritaet fn_set_context_facts / fn_advisor_save_section)
    v_scope    TEXT;
    v_perm     TEXT;
    v_pid      TEXT;
    v_err      TEXT;
    v_old_content TEXT;                 -- gespeichertes Plan-Doc (Quelle des verwalteten "## Gelernt"-Blocks)
    v_learned  TEXT;
    v_split    RECORD;
    v_doc_md   TEXT;                    -- content des Plan-Docs = plan_md (ohne Fremd-Block) + gespeicherter Block
BEGIN
    IF v_domain IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'domain is required (the advisor tool binding passes it as a fixed input)');
    END IF;
    -- P0c: Plan-Context der Domain (Domain->Context-Map aus core.advisors; Fallback v_domain||'_planning' fuer
    -- E2E-Sentinel-Domains ohne advisors-Zeile = reproduziert die alte CASE-ELSE). Dessen scope/write_permission
    -- steuert household vs per_user. (Eingeloest: die frueher hartkodierte finance->financial_planning-CASE-Map.)
    v_ctx_name := COALESCE((SELECT plan_context FROM core.advisors WHERE domain = v_domain), v_domain || '_planning');
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm
    FROM core.context_scopes cs WHERE cs.context_name = v_ctx_name;
    v_scope := COALESCE(v_scope, 'household');
    v_perm  := COALESCE(v_perm, 'owner_only');

    -- per_user -> Ziel-Person == Sender (own_user_only), aus der chat_id (Numerik-Guard, NIE LLM).
    IF v_scope = 'per_user' AND p->>'chat_id' ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender((p->>'chat_id')::bigint) ->> 'person_id';
    END IF;
    -- per_user FAIL-CLOSED (das echte Gate fuer unaufgeloeste Sender, VOR Permission & Write).
    IF v_scope = 'per_user' AND v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'cannot resolve person for per-user plan');
    END IF;

    -- WS-5b/P0c: Schreib-Permission generisch aus der Registry (ersetzt den fn_sender_is_member-Hardcode;
    -- financial_planning->owner_only delegiert byte-gleich an fn_sender_is_member, career_planning->own_user_only).
    -- ZUERST (vor plan_md-/Draft-Check), damit ein Mitglied nicht einmal die Existenz eines Drafts erfaehrt.
    v_err := agent.fn_check_write_permission(v_perm, p->>'chat_id', v_pid);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_err);
    END IF;

    -- Verwalteter "## Gelernt"-Block: jeden im neuen plan_md mitgeschickten verwerfen (das Modell sieht den Block
    -- via load_context und koennte ihn wiedergeben) — VOR dem Leer-Check und VOR dem Audit-Write (Schritt 2).
    LOOP
        v_split := core.fn_split_learned_block(v_plan_md);
        EXIT WHEN v_split.block IS NULL;
        v_plan_md := COALESCE(v_split.body, '');
    END LOOP;

    IF trim(v_plan_md) = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'plan_md must be non-empty');
    END IF;

    -- Draft der (Domain, Person) sperren (genau einer moeglich — Partial-UNIQUE (domain, person_id)).
    -- person_id IS NOT DISTINCT FROM v_pid: household (NULL) trifft NULL-Zeilen, per_user die Person.
    SELECT id, version, interview_state INTO v_plan_id, v_version, v_state
    FROM agent.advisor_plans
    WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid AND status = 'draft'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'no draft plan exists for domain ' || v_domain ||
                      ' — save at least one section first');
    END IF;

    -- WS3 Naht-Backstop (VOR jedem Write — "DB ist Gesetz, fn ist Durchsetzung, Prompt driftet"):
    -- Compose-on-Publish + deterministischer Block-Kollisions-Guard. Eine section_data ist ein partielles
    -- facts-Objekt (Top-Block wie goal/target_allocation/glidepath/emergency_reserve); `||` merged auf Block-
    -- Ebene. Der jsonb_each-Merge laeuft in Storage-/Hash-Reihenfolge (NICHT-deterministisch) -> emittieren
    -- zwei VERSCHIEDENE Sektionen denselben Top-Block, verloere `||` still eine Haelfte. Darum: jeden bereits
    -- belegten Top-Block-Key tracken; Doppelung -> {ok:false, reason} OHNE Write (korrigierbar, kein RAISE).
    -- Eine Sektion mit MEHREREN Bloecken (wealth_building -> target_allocation+glidepath) bleibt erlaubt.
    FOR v_sec IN SELECT value FROM jsonb_each(COALESCE(v_state, '{}'::jsonb)) LOOP
        IF jsonb_typeof(v_sec->'data') = 'object' THEN
            FOR v_blk_key IN SELECT jsonb_object_keys(v_sec->'data') LOOP
                IF v_blk_key = ANY (v_seen_blocks) THEN
                    RETURN jsonb_build_object('ok', false,
                        'reason', format('facts block "%s" emitted by multiple sections — '
                          || 'each plan figure block (goal/risk_profile/target_allocation/glidepath/emergency_reserve) '
                          || 'must come from exactly one section', v_blk_key));
                END IF;
                v_seen_blocks := v_seen_blocks || v_blk_key;
            END LOOP;
            v_new_facts := v_new_facts || (v_sec->'data');
        END IF;
    END LOOP;

    -- Compose-on-Publish (WS1a, P1-D/A/C) + Merge auf den BESTEHENDEN Sidecar VOR jedem Write (Backlog-Bugfix-Runde:
    -- die freundliche Vorpruefung unten braucht den Merge-Stand und muss vor Schritt 1 laufen, sonst hinterliesse ein
    -- {ok:false} einen halb umgestellten Plan). v_new_facts traegt bereits den block-weise gemergten, kollisions-
    -- geprueften Sidecar. Facts-Key-Merge auf den BESTEHENDEN Sidecar (Migration-Seed/frueherer Publish bewahren;
    -- P1-A): nur die im aktuellen Interview beruehrten Bloecke ersetzen. P1-C: v_new_facts ist '{}' (nie NULL) ->
    -- leeres Compose laesst geseedete facts unberuehrt + frischt nur den _meta-Stempel. v_merged geht VOR-gemergt in
    -- EXCLUDED, daher bleibt der bestehende Top-Level-`||` (Audit-Keys) korrekt (kein Datenverlust am facts-Key).
    -- P0c PHYSISCHER Name: per_user -> '<base>__<pid>' (Suffix, wie fn_set_context_facts/fn_fetch_context),
    -- sonst der Basis-Name. Speicher-I/O laeuft auf v_physical, das Result meldet den Basis-Namen v_ctx_name.
    -- v_ctx_name (oben aus core.advisors.plan_context, Fallback v_domain||'_planning') = der BASIS-Name:
    -- finance -> 'financial_planning' (loeschgeschuetzt), career -> 'career_planning', Sentinel
    -- '__e2e_finance__' -> '__e2e_finance___planning' (enthaelt 'e2e' -> fn_clear_e2e_data raeumt es).
    -- FOR UPDATE: ein waehrend des Publish bestaetigter Notiz-Append (fn_append_context_note sperrt dieselbe Zeile)
    -- darf nicht zwischen Lesen und Schreiben verloren gehen. Sperr-Reihenfolge seit der Backlog-Bugfix-Runde:
    -- Draft, Plan-Doc, dann der aktive Plan (Schritt 1) — vorher Draft, aktiver Plan, Plan-Doc
    -- (fn_append_context_note sperrt nur das Doc).
    v_physical := CASE WHEN v_scope = 'per_user' THEN v_ctx_name || '__' || v_pid ELSE v_ctx_name END;
    SELECT metadata->'facts', content INTO v_old_facts, v_old_content
    FROM agent.core_contexts WHERE name = v_physical FOR UPDATE;
    v_learned := (core.fn_split_learned_block(v_old_content)).block;
    v_doc_md  := rtrim(v_plan_md, E'\n ') || CASE WHEN v_learned IS NOT NULL THEN E'\n\n' || v_learned ELSE '' END;
    v_merged := COALESCE(v_old_facts, '{}'::jsonb) || v_new_facts;
    v_merged := v_merged || jsonb_build_object('_meta',
        COALESCE(v_merged->'_meta', '{}'::jsonb)
        || jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE, 'YYYY-MM-DD')));

    -- Freundliche Vorpruefung (Paritaet fn_set_context_facts, "Korrigierbare Ablehnung"): Core-Form + der Paket-
    -- Validator des BASIS-Namens. Der Trigger auf agent.core_contexts bleibt das Netz dahinter, wuerde aber RAISEn
    -- (Owner-Alarm, undurchsichtiger Tool-Fehler) — hier bekommt der Advisor {ok:false, reason} zum Korrigieren.
    v_err := agent.fn_validate_context_facts(v_merged, v_physical);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'plan facts invalid: ' || v_err);
    END IF;

    -- 1. Vorgaenger abloesen (vor dem Aktivieren — Partial-UNIQUE erlaubt nur einen active je (domain, person_id))
    UPDATE agent.advisor_plans SET status = 'superseded'
    WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid AND status = 'active'
    RETURNING id INTO v_old_id;

    -- 2. Draft aktivieren + Voll-Plan persistieren
    UPDATE agent.advisor_plans
    SET status    = 'active',
        plan_md   = v_plan_md,
        plan_name = COALESCE(NULLIF(trim(p->>'plan_name'), ''), plan_name),
        -- Plan teilen (2026-10-28): Provenienz der Version — Aenderungs-Zusammenfassung (Originalsprache) + Sprache des
        -- veroeffentlichenden Owners (Plan-Writes sind owner_only); die Mitglieder-Nachricht zeigt sie nur bei gleicher Sprache.
        change_summary      = NULLIF(btrim(COALESCE(p->>'change_summary', '')), ''),
        change_summary_lang = agent.fn_person_lang(agent.fn_owner_person_id())->>'lang'
    WHERE id = v_plan_id;

    -- 3. Context-Doc upserten: das publizierte Plan-Dokument ist das cross-agent Interface
    --    (lazy/global -> Manifest jedes Agenten; Inhalt = plan_md)
    -- WS-B2c (Owner): der Advisor pflegt EIN Domaenen-Plan-Doc, kein separates '<domain>_plan_current'.
    v_ctx_desc := COALESCE(NULLIF(trim(p->>'context_description'), ''),
        'Current published ' || v_domain || ' plan (v' || v_version || ') — the household master plan '
        || 'created and maintained by the advisor agent: situation, goals, recommendations, action items '
        || 'and triggers. Load BEFORE giving any ' || v_domain || ' recommendation. '
        || 'Managed by the agent (managed_by=agent) — never edit via mirror files.');

    -- managed_by/package sind seit D14/WS-B2 typisierte Spalten (vorher metadata.managed_by):
    -- managed_by='agent' (Laufzeit-Schreiber -> Seeder fasst es nie an; der Backup-Filter sichert managed_by='agent');
    -- package = die Domain (das Plan-Doc gehoert dem Domaenen-Paket; finance-Domain -> Paket 'finance').
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
    VALUES (
        v_physical, v_ctx_desc, NULL, 'lazy', v_doc_md, 'agent', v_domain,
        jsonb_build_object(
            'domain', v_domain,
            'plan_id', v_plan_id,
            'version', v_version,
            'published_at', now(),
            'facts', v_merged       -- VOR-gemergt (alt || neu + _meta) -> Top-Level-`||` unten verliert nichts
        )
    )
    ON CONFLICT (name) DO UPDATE SET
        description = EXCLUDED.description,
        content     = EXCLUDED.content,
        managed_by  = EXCLUDED.managed_by,   -- der Advisor ist autoritativ ueber die Provenienz dieses Plan-Docs:
        package     = EXCLUDED.package,      -- ein per Alt-Bundle restauriertes package='core' wuerde sonst stehen bleiben -> Uninstall-Purge verfehlt 'financial_planning'
        metadata    = agent.core_contexts.metadata || EXCLUDED.metadata;

    SELECT count(*)::int INTO v_sections FROM jsonb_object_keys(v_state) AS k;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ok', true,
        'plan_id', v_plan_id,
        'version', v_version,
        'superseded_plan_id', v_old_id,
        'context_name', v_ctx_name,
        'section_count', v_sections
    ));
END;
$$;
