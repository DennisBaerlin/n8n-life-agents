-- ============================================================
-- util_seed_owner_skeleton.sql — Erst-Seed der Haushalts-Kontexte beim Owner-Bootstrap (Phase 4)
--
-- ZWECK: Auf einer FRISCHEN Instanz existiert die Kontextzeile 'family' noch nicht (PII -> kein
--   Tarball-Inhalt, kein SQL-Seed). fn_consume_pairing_challenge mergt aber nur in
--   eine BESTEHENDE, vollstaendige family-Person (birth_date-Validator = Backstop-Gesetz). Dieser Seed
--   legt daher das Owner-Person-SKELETT an, BEVOR der Owner seinen Pairing-Code eintippt — die
--   Telegram-Identitaet (telegram_user_id) bindet erst der spaetere Consume-Merge.
--
-- STRUKTUR ist hier getrackt + reviewbar; die PII kommt als psql-Variable zur Laufzeit (nie ins Repo):
--   bootstrap_owner.sh ruft:  psql -v owner_first=... -v owner_last=... -v owner_birth=YYYY-MM-DD \
--                                  [-v owner_person_id=owner] -f packages/core/db/util/util_seed_owner_skeleton.sql
--
-- IDEMPOTENT + sicher: ON CONFLICT (name) DO NOTHING — ein vorhandener Haushalt (Re-Run, Restore)
--   wird NIE ueberschrieben. role ist fix 'owner'; telegram_user_id bleibt absichtlich NULL (Skelett).
--   Render-at-fetch dispatcht seit WS1b die Registry core.context_renderers (family ->
--   agent.fn_household_context, aus packages/core/manifest.json geseedet) — KEIN metadata.render_fn-Flag mehr.
--   managed_by='agent' (Sync-Guard: Seeder fasst die PII-Zeile nie an) + package='core' sind seit D14/WS-B2
--   TYPISIERTE Spalten; load_strategy='lazy', agent_name=NULL.
--   Install-UX-Phase 6: das leere 'finance_profile'-Skelett legt NICHT mehr der Core an (Core-Single-Paket-
--   Naht), sondern das finance-Paket selbst bei jeder Installation (Manifest-Block `context_skeletons`,
--   seed_data.sh _seed_context_skeletons) — sonst fehlte es nach `finance --purge` + Neuinstallation.
-- ============================================================

-- Default fuer die Person-ID, falls der Aufrufer keine uebergibt (matcht ^[a-z0-9_]+$).
\if :{?owner_person_id}
\else
  \set owner_person_id owner
\endif
-- Sprache der festen Bot-Texte (Textkatalog; Installer-Auswahl OWNER_LANGUAGE). Fehlt sie -> 'de'. Ein nicht
-- unterstuetzter Code faellt ebenfalls auf 'de' (agent.fn_normalize_language), statt am Validator zu scheitern.
\if :{?owner_language}
\else
  \set owner_language de
\endif

BEGIN;

-- family mit dem Owner-Skelett (vollstaendige Pflichtfelder; der Validator erzwingt sie als Backstop).
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('family',
        'Household members and shared household facts (people, roles, relationships).',
        NULL, 'lazy',
        '(Inhaber bei der Installation angelegt; weitere Personen folgen im Onboarding)',   -- = util_reset_user_data.sql
        'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object(
                             '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date,'YYYY-MM-DD')),
                             'persons', jsonb_build_array(jsonb_build_object(
                               'person_id',  :'owner_person_id',
                               'first_name', :'owner_first',
                               'last_name',  :'owner_last',
                               'role',       'owner',
                               'birth_date', :'owner_birth',
                               'language',   coalesce(agent.fn_normalize_language(:'owner_language'), 'de'),
                               'as_of',      to_char(current_date,'YYYY-MM-DD'))))))
ON CONFLICT (name) DO NOTHING;

-- Summary (Post-State): existiert der Owner als unverknuepftes Skelett?
DO $$
DECLARE v_owner JSONB;
BEGIN
  SELECT pp INTO v_owner
  FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) pp
  WHERE c.name = 'family' AND pp->>'role' = 'owner' LIMIT 1;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'SEED FAIL: kein Owner in family nach dem Seed';
  END IF;
  RAISE NOTICE 'SEED OK: family-Owner "%" (% %), gepairt=%',
    v_owner->>'person_id', v_owner->>'first_name', v_owner->>'last_name',
    (v_owner ? 'telegram_user_id' AND jsonb_typeof(v_owner->'telegram_user_id') <> 'null');
END $$;

COMMIT;
