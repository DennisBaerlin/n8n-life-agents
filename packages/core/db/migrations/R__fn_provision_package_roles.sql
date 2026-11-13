-- ============================================================
-- fn_provision_package_roles (ATOMIC, privilegiert — per-Paket-Rollen anlegen)
--   Legt fuer ein installiertes Paket die zwei Login-Rollen <pkg>_rw / <pkg>_ro an und
--   verdrahtet die strukturelle DB-Isolation. Idempotent (Re-Install darf nicht scheitern).
--   Aufgerufen vom CLI-Lifecycle (pkg_lifecycle.sh) nach der Schema-/Tabellen-Migration des
--   Pakets (die Tabellen muessen existieren, damit GRANT ON ALL TABLES greift; kuenftige
--   deckt ALTER DEFAULT PRIVILEGES).
--
--   Isolation (die Grenze ist physisch, nicht nur Lint):
--     * <pkg>_rw: SELECT/INSERT/UPDATE/DELETE + Sequenzen + EXECUTE nur im Schema <pkg>.
--       Kein CREATE/DDL (ein Paket darf kein Schema-/Core-DDL) — die Tabellen legt
--       der Installer als Superuser an, die Rolle bucht nur Daten.
--     * <pkg>_ro: nur SELECT im Schema <pkg> + default_transaction_read_only.
--     * Beide: USAGE auf core (um die publizierten SECURITY-DEFINER-Read-fns aufzurufen)
--       + EXECUTE auf genau diese Read-fns — aber kein SELECT/USAGE auf core-Tabellen,
--       agent.* oder Nachbar-Paket-Schemas. Ein `JOIN <pkg>.x agent.y` scheitert mit
--       "permission denied for schema agent"; `SELECT core.config` mit "permission denied
--       for table config". Core-Daten erreicht das Paket nur ueber die Read-fns.
--
--   Diese fn ist privilegiert (CREATE/ALTER/GRANT ROLE = Superuser noetig); sie laeuft
--   als der aufrufende Superuser (postgres, via apply_schema/CLI). Bewusst SECURITY
--   INVOKER (kein DEFINER) — kein Privileg-Eskalations-Fenster fuer Nicht-Superuser.
--   ALTER DEFAULT PRIVILEGES haengt an current_user = der Rolle, die die Paket-Tabellen
--   anlegt (postgres) -> deckt kuenftige Tabellen.
--
--   Eingabe jsonb: package (Pflicht; Schema-/Paketname, muss ^[a-z][a-z0-9_]*$ matchen
--     und als Schema existieren); per_user (optional bool: Paket deklariert per_user-Kontexte -> person-private
--     Tabellen sperren, s. unten).
--   Rueckgabe: {ok:true, package, rw_role, ro_role}. Leerer/ungueltiger Name oder
--     fehlendes Schema -> {ok:false, reason} ohne Write (korrigierbar, kein RAISE).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_provision_package_roles(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pkg TEXT := trim(COALESCE(p->>'package', ''));
    v_rw  TEXT;
    v_ro  TEXT;
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;
    -- Paketname = Schema- und Rollen-Praefix: streng validieren (Identifier-Injection-Schutz,
    -- selbst wenn alle Caller per format(%I) quoten — defense in depth).
    IF v_pkg !~ '^[a-z][a-z0-9_]*$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid package name (expect ^[a-z][a-z0-9_]*$): ' || v_pkg);
    END IF;
    IF to_regnamespace(v_pkg) IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'schema does not exist: ' || v_pkg);
    END IF;

    v_rw := v_pkg || '_rw';
    v_ro := v_pkg || '_ro';

    -- Rollen idempotent anlegen (LOGIN; Passwort setzt der Installer out-of-band, nie hier/im Repo).
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_rw) THEN
        EXECUTE format('CREATE ROLE %I LOGIN', v_rw);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_ro) THEN
        EXECUTE format('CREATE ROLE %I LOGIN', v_ro);
    END IF;

    -- Sicherheits-Defaults (greifen beim Connect; SET ROLE re-appliziert Rollen-GUCs nicht).
    EXECUTE format('ALTER ROLE %I SET default_transaction_read_only = on', v_ro);
    EXECUTE format('ALTER ROLE %I SET statement_timeout = %L', v_ro, '15s');
    EXECUTE format('ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', v_ro, '30s');
    -- search_path nur das eigene Schema (+ pg_catalog), kein agent/core im Default-Pfad.
    EXECUTE format('ALTER ROLE %I SET search_path = pg_catalog, %I', v_ro, v_pkg);
    EXECUTE format('ALTER ROLE %I SET search_path = pg_catalog, %I', v_rw, v_pkg);

    -- USAGE auf das eigene Schema + auf core (nur fuer die Read-fns; keine core-Tabellen-Grants).
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I, %I', v_pkg, v_rw, v_ro);
    EXECUTE format('GRANT USAGE ON SCHEMA core TO %I, %I', v_rw, v_ro);

    -- RW: CRUD + Sequenzen + EXECUTE im Paket-Schema (kein CREATE/DDL).
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', v_pkg, v_rw);
    EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', v_pkg, v_rw);
    EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', v_pkg, v_rw);
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I',
        current_user, v_pkg, v_rw);
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT USAGE, SELECT ON SEQUENCES TO %I',
        current_user, v_pkg, v_rw);

    -- RO: nur SELECT im Paket-Schema.
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', v_pkg, v_ro);
    EXECUTE format(
        'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
        current_user, v_pkg, v_ro);
    -- RO: + EXECUTE auf die INVOKER-fns des eigenen Schemas (generisch): kanonische
    -- Read-fns eines Pakets laufen unter <pkg>_ro und duerfen
    -- ihr PUBLIC-Default-EXECUTE per REVOKE in der R__-Datei haerten — der Grant hier stellt den
    -- Zugriff nach dem Apply wieder her (Reihenfolge: migrate vor roles, ein Grant in der R__-Datei
    -- faende die Rolle auf frischen Installs nie). Nur SECURITY INVOKER (NOT prosecdef): die echte
    -- Schranke bleiben Tabellen-Grants + read_only-GUC (Write-fns scheitern am Write, kein
    -- Eskalations-Fenster); DEFINER-fns bleiben bewusst aussen vor (explizite Einzel-Grants).
    -- Fuer Pakete ohne REVOKE ist der Grant ein No-op-Aequivalent (PUBLIC deckt sie schon).
    DECLARE v_fn record;
    BEGIN
        FOR v_fn IN
            SELECT p.oid::regprocedure AS sig
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = v_pkg AND NOT p.prosecdef AND p.prokind = 'f'
        LOOP
            -- Dynamischer Bulk-Grant, per NOT prosecdef strikt auf INVOKER-fns begrenzt: kein
            -- DEFINER-Fenster -> ausserhalb des role_test_lint-Scopes; Perspektiv-Abdeckung
            -- liegt in den Paket-Isolationstests (tests/db/<pkg>/test_<pkg>_isolation.sql).
            EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', v_fn.sig, v_ro);  -- lint-ignore: role-test-lint (INVOKER-only bulk grant)
        END LOOP;
    END;

    -- Core-Lesefenster (Paket-Lese-Vertrag): das Paket oeffnet sein Lese-Schema fuer die
    -- privilegierte Core-Host-Leserolle `core_ro` (genutzt vom Frei-SQL-Pfad der Core-Agenten
    -- agent.monitor/agent.guide). Unbedingt: Core ist der isolations-ausgenommene Host und darf jedes
    -- Paket read-only sehen (kein Paket-Opt-in, ein Paket soll sich der Host-Aufsicht nicht entziehen
    -- koennen). Own-schema-scoped ueber den validierten v_pkg -> ein Paket kann hierueber nie ein fremdes
    -- Ziel granten. Einzige Ausnahme: person-private Tabellen (Host-abgeleitet, Block unten — Privatsphaere
    -- der Person, kein Paket-Opt-out). Views bleiben der empfohlene erste Anlaufpunkt (Tool-Beschreibung);
    -- der Grant deckt Tabellen+Views. Faellt bei Deinstall mit dem Schema weg. No-op, falls core_ro (noch) fehlt.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO core_ro', v_pkg);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO core_ro', v_pkg);
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO core_ro',
            current_user, v_pkg);
        -- Desired-State: core_ro traegt einen search_path-Tail je installiertem Paket-Schema (Frei-SQL-
        -- Convenience fuer agent.monitor/agent.guide, trigger_design.md). Generisch aus core.package_registry
        -- recomputen (Full-Replace). Das gerade installierende Paket ist hier registriert (Stage 1) und das
        -- Schema existiert (Stage 2) -> inkludiert.
        -- Late-binding-Guard: fn_sync_role_search_paths ist ein eigenes R__ (zum Laufzeit-Aufruf appliziert).
        IF to_regprocedure('core.fn_sync_role_search_paths(text)') IS NOT NULL THEN
            PERFORM core.fn_sync_role_search_paths('core_ro');
        END IF;
    END IF;

    -- Person-private Tabellen (strikt privat): der Host leitet ab, kein Paket-Schalter, ein Paket kann sich
    -- so nicht der Aufsicht entziehen. In einem Paket mit per_user-Kontexten (core.fn_package_is_per_user)
    -- gehoert jede Tabelle mit person_id NOT NULL genau einer Person; sie und jede (auch verschachtelt) davon
    -- abhaengige View sind fuer die Frei-SQL-Rollen <pkg>_ro + core_ro unsichtbar (Views lesen mit
    -- Owner-Rechten -> explizit mit). Die Person liest ihre Zeilen nur ueber gebundene DEFINER-Fenster
    -- (z. B. career.fn_read_job_matches). Laeuft nach dem Schema-Grant oben -> jedes Re-Provisioning setzt es erneut.
    -- per_user-Quelle: das Manifest (p.per_user, vom Install-Lifecycle aus context_scopes gelesen — core.context_scopes
    -- fuellt erst der Seed nach dieser fn) oder die Registry (Aufrufer ohne Flag, z. B. ein spaeteres Re-Provisioning).
    IF COALESCE((p->>'per_user')::boolean, false)
       OR (to_regprocedure('core.fn_package_is_per_user(text)') IS NOT NULL AND core.fn_package_is_per_user(v_pkg)) THEN
        DECLARE v_rel record;
        BEGIN
            FOR v_rel IN
                WITH RECURSIVE priv(oid) AS (
                    SELECT c.oid
                      FROM pg_class c
                      JOIN pg_namespace n ON n.oid = c.relnamespace
                      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'person_id'
                                         AND a.attnotnull AND NOT a.attisdropped
                     WHERE n.nspname = v_pkg AND c.relkind IN ('r', 'p')
                    UNION
                    SELECT r.ev_class
                      FROM priv p
                      JOIN pg_depend d ON d.refobjid = p.oid AND d.classid = 'pg_rewrite'::regclass
                      JOIN pg_rewrite r ON r.oid = d.objid
                     WHERE r.ev_class <> p.oid
                )
                SELECT oid::regclass AS rel FROM priv
            LOOP
                EXECUTE format('REVOKE ALL ON %s FROM %I', v_rel.rel, v_ro);
                IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
                    EXECUTE format('REVOKE ALL ON %s FROM core_ro', v_rel.rel);
                END IF;
            END LOOP;
        END;
    END IF;

    -- Publizierte SECURITY-DEFINER-Read-fns = das einzige Core-Lesefenster der engen Paket-Rollen.
    -- Neue Read-fns hier ergaenzen, wenn sie zur publizierten Contract-Oberflaeche kommen.
    -- core.fn_advisor_read_plan: advisor_plans bleibt in `agent`, die engen finance_ro/career_ro erreichen es nur
    -- ueber dieses Fenster. Signatur (text, text) (chat_id-Arg fuer den Person-Scope): Guard und Grant muessen auf
    -- sie ziehen, sonst wird nach dem core:V014-DROP der 1-Arg-Form still uebersprungen -> Laufzeit-"permission denied".
    EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_core_api_version() TO %I, %I', v_rw, v_ro);
    IF to_regprocedure('core.fn_advisor_read_plan(text, text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_advisor_read_plan(text, text) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Uebergabe Berater -> Buchhalter: der Paket-Agent liest die Aufgaben seines Auftrags (beide Rollen); die Write-fns
    -- des Pakets pruefen und schliessen sie in derselben Transaktion ab (nur _rw, finance.fn_with_handoff).
    IF to_regprocedure('core.fn_handoff_tasks_read(integer[])') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_handoff_tasks_read(integer[]) TO %I, %I', v_rw, v_ro);
    END IF;
    IF to_regprocedure('core.fn_handoff_task_check(jsonb)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_handoff_task_check(jsonb) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_complete_handoff_task(jsonb)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_complete_handoff_task(jsonb) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_cancel_handoff_task(jsonb)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_cancel_handoff_task(jsonb) TO %I', v_rw);
    END IF;
    -- Onboarding-Schnittstelle: Read (kombiniert core+package) an beide Rollen; der
    -- INVOKER-Write nur an _rw (das _ro-Profil ist default_transaction_read_only -> kann ohnehin nicht schreiben).
    IF to_regprocedure('core.fn_onboarding_status(text, text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_onboarding_status(text, text) TO %I, %I', v_rw, v_ro);   -- (text, text): p_chat_id, core:V016 droppt die 1-Arg-Form
    END IF;
    IF to_regprocedure('core.fn_set_onboarding_section(jsonb)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_set_onboarding_section(jsonb) TO %I', v_rw);
        IF to_regprocedure('core.fn_menu_refresh_request()') IS NOT NULL THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_menu_refresh_request() TO %I', v_rw);
        END IF;
    END IF;
    -- fn_set_onboarding_section ist SECURITY INVOKER und leitet den per_user-Scope aus der Registry
    -- core.context_scopes ab -> die enge Paket-RW-Rolle braucht SELECT darauf, sonst crasht der
    -- Onboarding-Marker unter <pkg>_rw ('permission denied for table context_scopes'; unter dem
    -- Superuser-db_test unsichtbar -> Perspektiv-Test in tests/db/cross/test_role_permissions.sql).
    -- Nur die no-PII-Scope-Registry (Praezedenz direkter SELECT-Grants an enge Rollen:
    -- agent.monitor_triggers -> finance_ro); RO braucht es nicht (nur der RW-Write-Pfad ruft die fn;
    -- fn_onboarding_status/-_overview sind DEFINER).
    EXECUTE format('GRANT SELECT ON core.context_scopes TO %I', v_rw);
    -- Routing-Status-Gate: das Paket-Agent-Eingangs-Gate liest core.fn_package_active(<pkg>)
    -- unter <pkg>_ro (kein direktes SELECT auf core.package_registry). Read an beide Rollen.
    IF to_regprocedure('core.fn_package_active(text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_package_active(text) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Generisches Config-Lesefenster (read-all). Paket-Crons laufen unter Paket-Rollen
    -- und lesen ihren cron_enable-Flag ueber dieses Fenster (kein direktes SELECT core.config).
    IF to_regprocedure('core.fn_config_get(text, text, text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_config_get(text, text, text) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Monitor-Trigger-Summary-Fenster: der Advisor-Cron (finance_ro) liest die
    -- armed/fired-Zaehler aus agent.monitor_triggers (fuer enge Rollen gesperrt) ueber dieses Fenster.
    IF to_regprocedure('core.fn_monitor_trigger_summary(text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_monitor_trigger_summary(text) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Monitor-Trigger-LIST-Fenster: der Advisor (finance_ro) liest beim Plan-Publish die bestehenden
    -- Trigger seiner Domain (Labels) ueber dieses Fenster -> Dubletten-Bewusstsein vor dem Vorschlagen.
    -- Read an beide Rollen.
    IF to_regprocedure('core.fn_list_monitor_triggers(text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_list_monitor_triggers(text) TO %I, %I', v_rw, v_ro);
    END IF;
    IF to_regprocedure('core.fn_period_reminder_date(text,date)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_period_reminder_date(text,date) TO %I', v_ro);
    END IF;
    -- Personen-Rollen-Fenster: finance.fn_advisor_review (FIRE-Pool-Ausschluss role='child') +
    -- finance.parent_cashflow_overview (Eltern->Kind-Transfer-Erkennung) joinen core.fn_household_persons()
    -- statt agent.persons direkt (fuer enge Rollen gesperrt). Read an beide Rollen.
    -- Die no-arg-Signatur guarden (nicht (text)), sonst greift der to_regprocedure-Guard nie.
    IF to_regprocedure('core.fn_household_persons()') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_household_persons() TO %I, %I', v_rw, v_ro);
    END IF;
    -- Personen-Resolver-Fenster: die finance create_*/set_*-Write-Tools loesen einen Personen-Namen
    -- (Vorname/voll/Alias) gegen die family-Facts zu einem person_id-Slug auf (fuer den *_person_id-FK
    -- und die HITL-Summary), bevor sie schreiben. Die engen Paket-Rollen erreichen agent.core_contexts
    -- nicht direkt -> ueber dieses core-Fenster. Read an beide Rollen (finance_ro nutzt es auch lesend).
    -- (text, text): zweites Argument = chat_id des Absenders fuer Selbstbezuege (core:V033).
    IF to_regprocedure('core.fn_resolve_person(text, text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_resolve_person(text, text) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Empfaenger-Text-Fenster: Paket-Crons (finance_rw/_ro, estate_rw) und die Agent-Eingangs-Gates (<pkg>_ro)
    -- laden Sprache/Locale/Texte des Empfaengers; agent.* + core.ui_texts sind fuer enge Rollen unerreichbar.
    -- Read an beide Rollen (generisch, jedes Paket).
    IF to_regprocedure('core.fn_ui_texts_for(jsonb)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_ui_texts_for(jsonb) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Schreib-Permission-Fenster: die Paket-Write-fns (z. B. estate.fn_record_* unter estate_rw) pruefen
    -- den deklarativen write_permission-Backstop (adults_only/owner_only) ueber dieses DEFINER-Fenster,
    -- das agent-Primitiv agent.fn_check_write_permission ist fuer enge Rollen unerreichbar.
    -- Nur an _rw (reiner Write-Pfad-Guard; _ro ist default_transaction_read_only + schreibt nie).
    IF to_regprocedure('core.fn_check_write_permission(text, text, text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_check_write_permission(text, text, text) TO %I', v_rw);
    END IF;
    -- Personen-chat_id-Fenster (Umkehrung von fn_resolve_sender): estate.fn_create_case (unter estate_rw)
    -- vergleicht die chat_id des Subjekts mit der Sender-chat_id fuer den Guard "subject == Sender selbst";
    -- agent.fn_person_chat_id liest Schema agent (fuer enge Rollen gesperrt). Nur an _rw (reiner
    -- Write-Pfad-Guard, Muster fn_check_write_permission).
    IF to_regprocedure('core.fn_person_chat_id(text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_person_chat_id(text) TO %I', v_rw);
    END IF;
    -- Geteilte Owner-Benachrichtigungs-Dedup-Schicht: die Paket-Write-fns (Echtzeit-Folds) + der
    -- Saldo-Trigger (Re-Arm) erreichen core.notification_state nur ueber diese DEFINER-Schreibfenster
    -- -> EXECUTE nur an _rw (das _ro-Profil ist default_transaction_read_only + latcht nie).
    -- fn_notify_reconcile ist advisor-only (laeuft unter dem breiten Haupt-Credential) -> kein Paket-Grant.
    IF to_regprocedure('core.fn_should_notify(text,text,interval)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_should_notify(text,text,interval) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_notify_resolve(text,text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_notify_resolve(text,text) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_notify_told(text,text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_notify_told(text,text) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_proactive_claim(text,text,text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_proactive_claim(text,text,text) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_handoff_done_stamps(text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_handoff_done_stamps(text) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_mark_told(text,text,text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_mark_told(text,text,text) TO %I', v_rw);
    END IF;
    -- Crons mit Einmal-Latch ohne TTL raeumen ihre eigenen alten Merker; Person-Erinnerungen fragen die eine Pruef-Adresse.
    IF to_regprocedure('core.fn_notify_forget_before(text,timestamptz)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_notify_forget_before(text,timestamptz) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_reminder_allowed(text,text)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_reminder_allowed(text,text) TO %I', v_rw);
    END IF;
    -- Probelauf der Write-fn vor der HITL-Karte (Build-Helper New-FnWriteGate). INVOKER, fuehrt
    -- nur die eigene Paket-fn aus und rollt immer zurueck -> nur an _rw. "Heute" (Haushalts-Zeitzone) an beide Rollen.
    IF to_regprocedure('core.fn_dry_run(regprocedure, jsonb)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_dry_run(regprocedure, jsonb) TO %I', v_rw);
    END IF;
    IF to_regprocedure('core.fn_today(timestamptz)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_today(timestamptz) TO %I, %I', v_rw, v_ro);
    END IF;
    -- Relative Zeitangabe -> Datum ("-3 days", "in 3 weeks"): die Paket-Write-fns rechnen sie selbst (LLM rechnet nie).
    IF to_regprocedure('core.fn_resolve_date(text, date)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_resolve_date(text, date) TO %I, %I', v_rw, v_ro);
    END IF;
    -- ... und der Payload-Einstieg darauf (alle Datums-Keys eines Tool-Aufrufs einmal, {ok:false} statt Cast-Fehler).
    IF to_regprocedure('core.fn_resolve_input_dates(jsonb, text[], date)') IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION core.fn_resolve_input_dates(jsonb, text[], date) TO %I, %I', v_rw, v_ro);
    END IF;

    RETURN jsonb_build_object('ok', true, 'package', v_pkg, 'rw_role', v_rw, 'ro_role', v_ro);
END;
$$;
