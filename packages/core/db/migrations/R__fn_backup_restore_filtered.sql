-- ============================================================
-- core.fn_backup_restore_filtered (Phase 4b — NUR-Restore-Helfer der gefilterten geteilten Tabellen)
--   KEIN Backup, KEIN ganzer Restore: der Bulk (finance.* + advisor_plans + guide_onboarding_state)
--   laeuft via pg_restore in der CLI; diese fn macht NUR die ZWEI zeilen-gefilterten gemischten
--   agent-Tabellen, die pg_restore nicht zeilengenau behandeln kann (Code+Nutzerdaten in EINER Tabelle):
--     * agent.core_contexts (managed_by='agent' = PII: family + Paket-Fakten-/Plan-Kontexte):
--       UPDATE-statt-DELETE (trg_core_contexts_protect blockt DELETE protected Zeilen), family VOR den
--       Kontexten, die family-Personen referenzieren (bidirektionaler trg_validate_household_facts), Phase-0
--       (deren LIVE-persons[] leeren — NUR fuer Kontexte, die das Bundle mitbringt; sonst verloere ein Bundle
--       ohne sie die Live-Facts / der Orphan-Check blockte den family-Write). Phase A: form-getrieben ueber den
--       reservierten Core-Key persons[] statt des Literals finance_profile (bewusst nicht registry-getrieben:
--       das Bundle ist Daten, die Registry kann zum Restore-Zeitpunkt abweichen — arch-challenge D3c).
--     * agent.monitor_triggers (origin='user'): DELETE origin='user' (observations CASCADE) + Fresh-id-
--       Insert (kein UNIQUE(domain,lower(label))-Bruch gegen bestehende user-Zeilen; nichts referenziert
--       Trigger-ids ausser den ausgeschlossenen observations).
--   = schlanke Uebernahme der bewaehrten Shared-Choreografie der frueheren agent.fn_import_restore (Phase 3,
--   via V004 entfernt), ohne den finance-Bulk (den uebernimmt jetzt pg_dump/pg_restore). filtered_tables ist STRUKTURELL Core-Sache:
--   das Schema agent ist geteilter Host-Raum; Domaenen-Pakete besitzen ihr eigenes Schema voll (Voll-Wipe).
--
--   Phase B: bringt das Bundle einen Trigger mit, dessen acquisition_method auf der Ziel-Instanz NICHT in
--     core.monitor_acquisition_methods steht (z. B. fx_rate, aber finance nicht installiert), bricht der Restore
--     VORHER mit einer verstaendlichen Meldung ab (welche Methoden, Paket zuerst installieren) — statt eines
--     kryptischen FK-Fehlers. Ueberspringen scheidet aus: der Count-Verify der CLI (verify_counts) fiele dann
--     ohnehin; die alte Welt bleibt durch die eine Restore-TX intakt.
--   EINGABE p (jsonb, Schluessel = qualifizierte Tabellennamen wie im core-Manifest backup.filtered_tables):
--     { "agent.core_contexts": [ {row}, ... ], "agent.monitor_triggers": [ {row}, ... ] }   (Keys optional)
--   RUECKGABE: { ok:true, core_contexts:n, monitor_triggers:n }
--   ATOMAR via die AUFRUFENDE TX (SECURITY INVOKER): jeder Fehler -> RAISE -> der CLI-`psql -1`-Restore
--   rollt alles (inkl. pg_restore-Bulk + TRUNCATE) zurueck. Laeuft als postgres-Superuser (CLI).
--   search_path=pg_catalog gepinnt (alle Objekte schema-qualifiziert, CVE-2018-1058).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_backup_restore_filtered(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_cc      JSONB := p->'agent.core_contexts';
    v_mt      JSONB := p->'agent.monitor_triggers';
    v_row     JSONB;
    v_cc_n    INT := 0;
    v_mt_n    INT := 0;
    v_cols    TEXT;
    v_missing TEXT;
BEGIN
    -- ---------- agent.monitor_triggers: user-Zeilen wipen + Fresh-id-Insert ----------
    IF jsonb_typeof(v_mt) = 'array' THEN
        SELECT string_agg(DISTINCT r->>'acquisition_method', ', ') INTO v_missing
          FROM jsonb_array_elements(v_mt) r
         WHERE NOT EXISTS (SELECT 1 FROM core.monitor_acquisition_methods m
                            WHERE m.method = r->>'acquisition_method');
        IF v_missing IS NOT NULL THEN
            RAISE EXCEPTION 'restore aborted: the bundle contains monitor triggers for acquisition methods not available on this instance (%) — install the package that provides them first (lifeagents package install <pkg>), then restore again', v_missing;
        END IF;
        -- nur user-Trigger (core-Seeds bleiben; observations CASCADE)
        DELETE FROM agent.monitor_triggers WHERE origin = 'user';
        IF jsonb_array_length(v_mt) > 0 THEN
            -- Spaltenliste aus dem Katalog (NUR is_generated='NEVER', OHNE id = frisch gemintet) ->
            -- schema-evolutionsfest, keine handgepflegte Spaltenliste.
            SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
            INTO v_cols
            FROM information_schema.columns
            WHERE table_schema = 'agent' AND table_name = 'monitor_triggers'
              AND is_generated = 'NEVER' AND column_name <> 'id';
            EXECUTE format(
                'INSERT INTO agent.monitor_triggers (%s) SELECT %s FROM jsonb_populate_recordset(NULL::agent.monitor_triggers, $1)',
                v_cols, v_cols)
            USING v_mt;
            GET DIAGNOSTICS v_mt_n = ROW_COUNT;
        END IF;
    END IF;

    -- ---------- agent.core_contexts: managed_by='agent' (PII) per UPDATE/INSERT ----------
    IF jsonb_typeof(v_cc) = 'array' THEN
        -- Phase 0: die LIVE-Personen jedes Nicht-family-Kontexts mit persons[] leeren — NUR wenn das Bundle
        -- diesen Kontext selbst mitbringt (sonst verloere ein Bundle ohne ihn die Live-Facts). Bedingung auf der
        -- LIVE-Zeile (persons[] vorhanden), nicht auf der Bundle-Zeile: auch ein aelteres Bundle-Exemplar ohne
        -- persons ersetzt die Zeile, die Live-Referenzen muessen also vor dem family-Write weg. Der bidirektionale
        -- Facts-Check prueft ein family-UPDATE gegen ALLE Live-persons[]-Referenzen; ohne dieses Leeren blockte eine
        -- Live-Person, die das (aeltere) Bundle nicht kennt, den Restore. (Ein Live-Kontext mit persons[], den das
        -- Bundle NICHT mitbringt, bleibt — referenziert er eine Person, die das Bundle-family nicht kennt, rollt der
        -- Restore laut zurueck: dasselbe Limit wie vorher.)
        UPDATE agent.core_contexts lc
        SET metadata = jsonb_set(lc.metadata, '{facts,persons}', '[]'::jsonb)
        WHERE lc.name <> 'family'
          AND jsonb_typeof(lc.metadata->'facts'->'persons') = 'array'
          AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_cc) c WHERE c->>'name' = lc.name);

        -- Phase 1+2: family ZUERST (ORDER BY name <> 'family'), dann die uebrigen Kontexte. Protected/
        -- managed Contexts werden per UPDATE ERSETZT (nie DELETE -> Protect-Trigger blockte). managed_by/
        -- package aus dem Bundle (COALESCE haelt den Bestandswert bzw. defaultet agent/Paket beim INSERT).
        FOR v_row IN SELECT * FROM jsonb_array_elements(v_cc) c
                     ORDER BY (c->>'name' <> 'family'), c->>'name' LOOP
            -- Backups von VOR dem Textkatalog (core:V027) tragen Freitext-Sprachen ("Deutsch") -> vor dem Write
            -- normieren, sonst lehnte der Validator (Wertevorrat core.ui_languages) den family-Restore ab.
            IF v_row->>'name' = 'family' AND jsonb_typeof(v_row->'metadata'->'facts'->'persons') = 'array' THEN
                v_row := jsonb_set(v_row, '{metadata,facts,persons}',
                                   agent.fn_normalize_person_languages(v_row->'metadata'->'facts'->'persons'));
                -- Persona aus einem aelteren/neueren Bundle, die diese Instanz nicht kennt (oder 'neutral'): nur
                -- den Key verwerfen, statt den ganzen family-Restore am Validator scheitern zu lassen.
                v_row := jsonb_set(v_row, '{metadata,facts,persons}', (
                    SELECT COALESCE(jsonb_agg(
                             CASE WHEN jsonb_typeof(e.pp) = 'object' AND e.pp ? 'persona'
                                       AND (e.pp->>'persona' IS NULL OR e.pp->>'persona' = 'neutral'
                                            OR NOT EXISTS (SELECT 1 FROM core.ui_personas x WHERE x.code = e.pp->>'persona'))
                                  THEN e.pp - 'persona' ELSE e.pp END ORDER BY e.ord), '[]'::jsonb)
                      FROM jsonb_array_elements(v_row->'metadata'->'facts'->'persons') WITH ORDINALITY AS e(pp, ord)));
            END IF;
            UPDATE agent.core_contexts
            SET description   = v_row->>'description',
                agent_name    = NULLIF(v_row->>'agent_name',''),
                load_strategy = v_row->>'load_strategy',
                content       = v_row->>'content',
                managed_by    = COALESCE(NULLIF(v_row->>'managed_by',''), managed_by),
                package       = COALESCE(NULLIF(v_row->>'package',''),    package),
                metadata      = COALESCE(v_row->'metadata', '{}'::jsonb)
            WHERE name = v_row->>'name';
            IF NOT FOUND THEN
                INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
                VALUES (v_row->>'name', v_row->>'description', NULLIF(v_row->>'agent_name',''),
                        v_row->>'load_strategy', v_row->>'content',
                        COALESCE(NULLIF(v_row->>'managed_by',''), 'agent'),
                        COALESCE(NULLIF(v_row->>'package',''), 'core'),
                        COALESCE(v_row->'metadata', '{}'::jsonb));
            END IF;
            v_cc_n := v_cc_n + 1;
        END LOOP;
    END IF;

    RETURN jsonb_build_object('ok', true, 'core_contexts', v_cc_n, 'monitor_triggers', v_mt_n);
END;
$$;

-- Restore-Primitive: nie fuer die Paket-Leserollen (laeuft nur ueber den CLI-Superuser).
REVOKE ALL ON FUNCTION core.fn_backup_restore_filtered(jsonb) FROM public;
