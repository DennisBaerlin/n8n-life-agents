-- ============================================================
-- fn_reset_user_data (Owner-Ops — Werkszustand-Reset; DESTRUKTIV, kein Agent-Tool)
--   Setzt die Instanz auf den Nach-Installations-Stand zurueck (Owner-Entscheid 2026-10-19 „Werkszustand"):
--   ALLE Nutzerdaten weg, nur Config, Stammdaten/Caches, Instruktions-Kontexte, Owner-Identitaet (Name im
--   family-Skelett) und Backup-Key bleiben. VORHER Backup ziehen: `lifeagents backup export`.
--   Aufruf: SELECT core.fn_reset_user_data('RESET');  (Wrapper packages/core/db/util/util_reset_user_data.sql)
--   Falscher/fehlender Bestaetigungs-Token -> {ok:false}, nichts passiert.
--
--   Phase B — Core kennt kein Paket (docs/package-contract.md §6 *Werkszustand-Reset*):
--   (1) Paket-Tabellen DENY-BY-DEFAULT: jede Basistabelle jedes Paket-Schemas (core.package_registry ∪
--       core.schema_version, auch --keep-data-Deinstallierte) wird geleert, AUSSER (a) per
--       COMMENT ON TABLE 'lifecycle:reference ...' markierte Stammdaten/Caches (Muster PG
--       pg_extension_config_dump: Marker am Objekt, faellt mit DROP SCHEMA), (b) extension-eigene Tabellen,
--       (c) <pkg>.onboarding_state (Konvention, Schritt 5). Ein per COMMENT ON SCHEMA 'lifecycle:reset-skip ...'
--       markiertes Schema bleibt ganz unberuehrt (Vertrag fuer ein Paket, das nur einen Fremd-Cache haelt; derzeit von keinem
--       Paket genutzt, Test: test-lokales Schema zzskip in test_fn_reset_user_data).
--       EIN Multi-Table-TRUNCATE ... CONTINUE IDENTITY, NIE CASCADE (ein FK-Bruch scheitert laut statt still
--       Referenzdaten mitzunehmen; CONTINUE statt RESTART: alte Telegram-Knoepfe/HITL-Gates/Latches mit einer
--       alten id duerfen nie eine neue Zeile treffen).
--   (2) Nicht-Owner-Zeilen jeder per-Person-<pkg>.onboarding_state (Spalte person_id).
--   (3) Host-Daten: advisor_plans, user-Monitor-Trigger (DELETE — Deny-Truncate-Trigger), abgeschlossene
--       Update-Auftraege (ein offener bleibt fuer den laufenden root-Runner), Lern-Kandidaten +
--       Watermark, die notification_state-Latches der zurueckgesetzten Pakete + der Advisor-Engine (Knock-
--       Dedup bleibt), alle agent.*_chat_memory; Nicht-Owner-Personen ueber agent.fn_remove_household_person
--       (Kaskade Profil-Eintraege/per-user-Kontexte/Latches; erst jetzt — ihre FK-Referenzierer sind weg);
--       agent-verwaltete Kontexte auf den Nach-Installations-Stand: alle ausser family + den household-Fakten-
--       Skeletten werden GELOESCHT (Plan-Docs inkl. „## Gelernt", per-user-Kontexte, Laufzeit-Docs) — der
--       Loeschschutz core.protected_contexts wird dafuer in DERSELBEN Transaktion kurz gehoben und unveraendert
--       wiederhergestellt (Finalizer-Muster fn_pkg_purge_data); Kontexte eines reset-skip-Pakets bleiben.
--       VERTRAG: managed_by='agent' = Laufzeit-Daten -> der Reset loescht sie (deny-by-default: ein kuenftiger
--       Laufzeit-Kontexttyp faellt automatisch mit). Ein kuenftiger Uebernahme-Pfad fuer GESEEDETE Instruktions-
--       Kontexte (Prompt-Import, Feedback-Tool; Conffile-Guard in seed_data.sh _seed_context_md) MUSS eine eigene
--       Provenienz setzen (z. B. managed_by='owner') und darf eine Seed-Zeile nicht auf 'agent' umschreiben —
--       sonst loescht der Reset sie und bis zum naechsten Seed fehlt die Instruktion. Heute gibt es keinen
--       solchen Pfad (kein Codepfad stellt eine Seed-Zeile auf 'agent' um).
--   (4) household-Fakten-Skelette auf Stub, family auf den Owner (nur Skelett-Pflichtfelder).
--   (5) core.fn_reset_onboarding_state().
--   RUECKGABE: {ok:true, packages, skipped, truncated_tables, advisor_plans, monitor_triggers, persons_removed,
--     contexts_deleted, chat_memory, onboarding} | {ok:false, reason}
--   Tests: tests/db/core/test_fn_reset_user_data.sql, tests/db/core/test_core_only.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_reset_user_data(p_confirm text)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_pkgs     text[];
    v_skipped  text[];
    v_tables   text[];
    v_owner    text;
    v_pkg      text;
    v_pid      text;
    v_tbl      text;
    v_r        jsonb;
    v_pc       jsonb;
    v_n        int;
    v_ap int; v_mt int; v_ctx int; v_mem int := 0; v_persons int := 0;
BEGIN
    IF p_confirm IS DISTINCT FROM 'RESET' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'destructive reset needs the confirmation token: SELECT core.fn_reset_user_data(''RESET'');');
    END IF;

    -- Paket-Menge (Schema muss existieren); reset-skip-Schemas getrennt.
    SELECT COALESCE(array_agg(x.pkg ORDER BY x.pkg) FILTER (WHERE NOT x.skip), ARRAY[]::text[]),
           COALESCE(array_agg(x.pkg ORDER BY x.pkg) FILTER (WHERE x.skip), ARRAY[]::text[])
      INTO v_pkgs, v_skipped
      FROM (SELECT s.pkg,
                   COALESCE(obj_description(to_regnamespace(s.pkg)::oid, 'pg_namespace'), '')
                       LIKE 'lifecycle:reset-skip%' AS skip
              FROM core.fn_package_schemas() AS s(pkg)) x;

    -- (1) Paket-Tabellen deny-by-default leeren.
    SELECT array_agg(format('%I.%I', n.nspname, c.relname) ORDER BY n.nspname, c.relname)
      INTO v_tables
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = ANY (v_pkgs)
       AND c.relkind IN ('r', 'p') AND NOT c.relispartition
       AND COALESCE(obj_description(c.oid, 'pg_class'), '') NOT LIKE 'lifecycle:reference%'
       AND c.relname <> 'onboarding_state'
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e');
    IF v_tables IS NOT NULL THEN
        EXECUTE 'TRUNCATE TABLE ' || array_to_string(v_tables, ', ') || ' CONTINUE IDENTITY';
    END IF;

    -- (2) Nicht-Owner-Zeilen der per-Person-Onboarding-Tabellen (sonst blockte ihr FK den Personen-Abbau).
    v_owner := agent.fn_owner_person_id();
    FOREACH v_pkg IN ARRAY v_pkgs LOOP
        IF EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = to_regclass(format('%I.onboarding_state', v_pkg))
                      AND a.attname = 'person_id' AND NOT a.attisdropped) THEN
            EXECUTE format('DELETE FROM %I.onboarding_state WHERE person_id IS DISTINCT FROM $1', v_pkg) USING v_owner;
        END IF;
    END LOOP;

    -- (3) Host-Daten.
    DELETE FROM agent.advisor_plans;                         GET DIAGNOSTICS v_ap = ROW_COUNT;
    DELETE FROM agent.monitor_triggers WHERE origin = 'user'; GET DIAGNOSTICS v_mt = ROW_COUNT;   -- Observations per CASCADE
    DELETE FROM agent.guide_learn_candidates;
    DELETE FROM agent.guide_learn_watermark;
    DELETE FROM agent.reminder_prefs;                         -- Roter Faden: Erinnerungs-Einstellungen je Person
    -- Update-Protokoll (wer hat wann aktualisiert); ein OFFENER Auftrag bleibt, sonst koennte der laufende root-Runner
    -- ihn nicht mehr abschliessen und melden. Der Release-Latch 'release_update' bleibt (Systemzustand, kein Nutzerdatum).
    DELETE FROM core.update_requests WHERE finished_at IS NOT NULL;
    -- Latch-Quellen-Konvention '<pkg>' / '<pkg>:<sub>' + die Advisor-Engine 'advisor:<domain>[:<pid>]' (Plaene weg);
    -- 'knock' (Pairing-Dedup unbekannter Absender) und reset-skip-Pakete bleiben.
    DELETE FROM core.notification_state
     WHERE split_part(source, ':', 1) = ANY (v_pkgs) OR split_part(source, ':', 1) = 'advisor'
        OR source IN ('onboarding', 'onboarding_nudge');   -- Roter Faden: Einmal-Karten + Nachfass-Stufen (Werkszustand)
    FOR v_tbl IN SELECT tablename FROM pg_tables
                 WHERE schemaname = 'agent' AND tablename LIKE '%\_chat\_memory' ESCAPE '\'
    LOOP
        EXECUTE format('DELETE FROM agent.%I', v_tbl);
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_mem := v_mem + v_n;
    END LOOP;

    FOR v_pid IN
        SELECT pp->>'person_id'
          FROM agent.core_contexts c,
               jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
         WHERE c.name = 'family' AND pp->>'role' IS DISTINCT FROM 'owner'
    LOOP
        v_r := agent.fn_remove_household_person(jsonb_build_object('person_id', v_pid));
        IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN
            RAISE EXCEPTION 'fn_reset_user_data: Person % nicht entfernbar: %', v_pid, v_r->>'reason';
        END IF;
        v_persons := v_persons + 1;
    END LOOP;

    -- Loeschschutz kurz heben (gleiche Transaktion -> nach aussen nie sichtbar), Laufzeit-Kontexte loeschen,
    -- Schutz unveraendert wiederherstellen.
    SELECT COALESCE(jsonb_agg(to_jsonb(pc)), '[]'::jsonb) INTO v_pc FROM core.protected_contexts pc;
    DELETE FROM core.protected_contexts;
    DELETE FROM agent.core_contexts c
     WHERE c.managed_by = 'agent'
       AND c.name <> 'family'
       AND COALESCE(c.package, '') <> ALL (v_skipped)
       AND NOT EXISTS (SELECT 1
                         FROM core.context_validators v
                         LEFT JOIN core.context_scopes s ON s.context_name = v.context_name
                        WHERE v.context_name = c.name AND COALESCE(s.scope, 'household') = 'household');
    GET DIAGNOSTICS v_ctx = ROW_COUNT;
    INSERT INTO core.protected_contexts
    SELECT * FROM jsonb_populate_recordset(NULL::core.protected_contexts, v_pc);

    -- (4) household-Fakten-Skelette auf Stub — die Paket-Fakten-Kontexte ZUERST (bidirektionaler
    --     trg_validate_household_facts: ein family-Write darf keine Profil-Person verwaisen). DB-GESETZ:
    --     family.facts.persons darf nie leer sein + die Zeile ist nie loeschbar -> legales Minimum = der Owner
    --     nur mit den Skelett-Pflichtfeldern (= Stand nach util_seed_owner_skeleton).
    UPDATE agent.core_contexts c
       SET content  = '(noch keine Daten erfasst - Onboarding ausstehend)',
           metadata = jsonb_set(COALESCE(c.metadata, '{}'::jsonb), '{facts}',
                                CASE WHEN c.metadata->'facts' ? 'persons' THEN '{"persons": []}'::jsonb ELSE '{}'::jsonb END)
      FROM core.context_validators v
      LEFT JOIN core.context_scopes s ON s.context_name = v.context_name
     WHERE c.name = v.context_name
       AND v.context_name <> 'family'
       AND COALESCE(s.scope, 'household') = 'household';

    UPDATE agent.core_contexts
       SET content  = '(Inhaber bei der Installation angelegt; weitere Personen folgen im Onboarding)',
           metadata = jsonb_set(COALESCE(metadata, '{}'::jsonb), '{facts}', jsonb_build_object('persons',
               COALESCE(
                   (SELECT jsonb_agg(jsonb_build_object(
                               'person_id',  p->>'person_id',
                               'first_name', p->>'first_name',
                               'last_name',  p->>'last_name',
                               'role',       p->>'role',
                               'birth_date', p->>'birth_date')
                           -- Sprache fester Texte bleibt (sonst faellt nach dem Reset alles auf Englisch zurueck)
                           || CASE WHEN jsonb_typeof(p->'language') = 'string'
                                   THEN jsonb_build_object('language', p->>'language') ELSE '{}'::jsonb END
                           -- Bot-Persona ebenso (Installer-Wahl wie die Sprache, kein Nutzerdatum)
                           || CASE WHEN jsonb_typeof(p->'persona') = 'string'
                                   THEN jsonb_build_object('persona', p->>'persona') ELSE '{}'::jsonb END)
                      FROM jsonb_array_elements(metadata->'facts'->'persons') p
                     WHERE p->>'role' = 'owner'),
                   metadata->'facts'->'persons')))
     WHERE name = 'family';

    -- (5) Onboarding-Fortschritt.
    v_r := core.fn_reset_onboarding_state();

    RETURN jsonb_build_object(
        'ok', true, 'packages', to_jsonb(v_pkgs), 'skipped', to_jsonb(v_skipped),
        'truncated_tables', COALESCE(array_length(v_tables, 1), 0),
        'advisor_plans', v_ap, 'monitor_triggers', v_mt, 'persons_removed', v_persons,
        'contexts_deleted', v_ctx, 'chat_memory', v_mem, 'onboarding', v_r);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_reset_user_data(text) FROM public;
