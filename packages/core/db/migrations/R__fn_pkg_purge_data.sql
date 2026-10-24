-- ============================================================
-- fn_pkg_purge_data (ATOMIC — Cross-Schema-Host-Daten eines Pakets purgen, WS-2 / --purge)
--   Loescht die paket-BESESSENEN Zeilen, die AUSSERHALB des Paket-Schemas liegen und daher von
--   `DROP SCHEMA <pkg> CASCADE` NICHT erfasst werden (Host-Registries in core/agent). Alles
--   `WHERE package=<pkg>`. Aufgerufen vom CLI-Uninstall (`pkg_cmd_uninstall --purge`) innerhalb
--   EINER psql-Transaktion zusammen mit DROP SCHEMA/ROLE/Registry-Dereg (PG-DDL ist transaktional
--   -> all-or-nothing; Atomaritaet-ist-Gesetz). Paket-eigene Tabellen (z. B. finance.onboarding_state)
--   fallen mit DROP SCHEMA <pkg> CASCADE — NICHT hier.
--
--   FINALIZER-REIHENFOLGE (Kubernetes-ownerReference/Finalizer-Muster, docs/package-contract.md §6):
--     1. core.protected_contexts  — Schutz-Registry ZUERST: hebt den BEFORE-DELETE-Trigger
--        agent.trg_core_contexts_protect fuer Schritt 2 (der un-committete DELETE ist der eigenen
--        Transaktion sichtbar -> der Trigger findet kein EXISTS mehr).
--     2. agent.core_contexts      — Instructions + facts-Sidecars (finance_profile) + agent-Plan-Docs.
--     3. core.context_validators + core.context_scopes + core.context_renderers + core.advisors +
--        core.cron_labels + core.callback_handlers — VOR dem (CLI-seitigen) DROP SCHEMA, sonst zeigen validate_fn/render_fn/
--        review_fn/handler_fn auf eine gedroppte fn (Orphan-Dispatch-Ziel in den generischen Core-Wrappern).
--        renderers + advisors kamen mit WS1/WS2 dazu, core.cron_labels (Toggle-/Label-Registry) +
--        core.callback_handlers (Callback-Dispatch-Registry) mit Phase 0 WS-0c (sonst leakt ein Paket-
--        Uninstall einen Orphan-render_fn/-review_fn/-handler_fn bzw. eine tote Toggle-/Label-Zeile).
--        NICHT core.ui_texts: der Textkatalog bildet die GEBUENDELTEN Dateien ab, unabhaengig vom Installationsstand
--        (Onboarding-Menue und Vermittler nennen auch nicht installierte Pakete beim Namen); Pakete, die das Release
--        verlassen, raeumt der Seed (seed_data.sh _seed_ui_texts).
--     3b. agent.monitor_triggers WHERE package=<pkg> AND origin='user' — paket-erzeugte Monitor-Trigger
--        (z. B. advisor-Plan-Trigger). Host-Tabelle, von DROP SCHEMA <pkg> nicht erreicht. `origin='user'`-
--        Guard: ein origin='core'-Trigger blockt sonst den Protect-Trigger -> Abbruch der Purge-Transaktion.
--     3c. (Phase B) Trigger, die eine MONITOR-METHODE des Pakets benutzen (acquisition_method in
--        core.monitor_acquisition_methods WHERE package=<pkg>, origin='user') — auch die vom Core-Monitor-
--        Agenten angelegten (package='core', daher von 3b NICHT erfasst) — explizit + gezaehlt; DANACH die
--        Methoden-Zeilen selbst (der FK auf method ist NO ACTION -> Reihenfolge tragend). Ein origin='core'-
--        Trigger auf einer Paket-Methode bricht die Purge LAUT ab (Protect-Trigger) — bewusst, kein stilles Loeschen.
--     4. core.services + core.config — Alias-Map + Config-Zeilen des Pakets.
--     5. core.schema_version       — Migrations-Ledger des Pakets (Phase 5, Flyway-`clean`-Muster):
--        ohne diese Raeumung ueberspringt ein Re-Install die versionierten Paket-Migrationen, deren
--        Effekt aber mit `DROP SCHEMA <pkg>` verschwunden ist (heutige finance-V sind zwar idempotent/
--        no-op auf frischer DB -> Inits bauen den Endzustand; das ist Hygiene/Future-Proofing fuer eine
--        kuenftige nicht-idempotente Paket-V-Migration).
--
--   GUARDS: leerer/ungueltiger package -> {ok:false, reason}; package='core' -> {ok:false} (der
--     privilegierte Host ist nie purgebar — Backstop zusaetzlich zum CLI-Reject).
--   SECURITY INVOKER: laeuft mit den Rechten des aufrufenden Superuser-CLI; KEIN DEFINER-Eskalations-
--     Fenster (es loescht in core UND agent, beide gehoeren dem Host). search_path=pg_catalog gepinnt
--     (alle Objekte schema-qualifiziert, CVE-2018-1058-Hygiene).
--   RUECKGABE: {ok:true, package, protected, contexts, validators, scopes, renderers, advisors, cron_labels,
--     callback_handlers, monitor_triggers, method_triggers, acquisition_methods, services, config,
--     schema_version} (Lösch-Counts).
--   ATOMAR: RAISE -> Rollback (Trigger laufen in derselben Transaktion).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_purge_data(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_pkg        TEXT := trim(COALESCE(p->>'package', ''));
    v_protected  INT;
    v_contexts   INT;
    v_validators INT;
    v_scopes     INT;
    v_renderers  INT;
    v_advisors   INT;
    v_cronlabels INT;
    v_cbhandlers INT;
    v_triggers   INT;
    v_mtriggers  INT;
    v_methods    INT;
    v_services   INT;
    v_config     INT;
    v_ledger     INT;
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;
    IF v_pkg !~ '^[a-z][a-z0-9_]*$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid package name (expect ^[a-z][a-z0-9_]*$): ' || v_pkg);
    END IF;
    IF v_pkg = 'core' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'the privileged core host cannot be purged');
    END IF;

    -- 1. Schutz-Registry zuerst (Finalizer loesen).
    DELETE FROM core.protected_contexts WHERE package = v_pkg;
    GET DIAGNOSTICS v_protected = ROW_COUNT;

    -- 2. paket-besessene Context-Zeilen.
    DELETE FROM agent.core_contexts WHERE package = v_pkg;
    GET DIAGNOSTICS v_contexts = ROW_COUNT;

    -- 3. Validator-/Renderer-/Advisor-Registries (vor DROP SCHEMA, sonst Orphan-validate_fn/render_fn/review_fn).
    DELETE FROM core.context_validators WHERE package = v_pkg;
    GET DIAGNOSTICS v_validators = ROW_COUNT;
    -- core.context_scopes (P0a): Scope-/Permission-Registry; package-besessen, von DROP SCHEMA <pkg> nicht
    -- erreicht (Core-Tabelle). Keine fn-Bezeichner -> kein Orphan-Dispatch-Risiko, aber Hygiene-Pflicht wie
    -- die anderen Core-Registries (sonst bliebe eine tote Scope-Zeile zurueck).
    DELETE FROM core.context_scopes WHERE package = v_pkg;
    GET DIAGNOSTICS v_scopes = ROW_COUNT;
    DELETE FROM core.context_renderers WHERE package = v_pkg;
    GET DIAGNOSTICS v_renderers = ROW_COUNT;
    DELETE FROM core.advisors WHERE package = v_pkg;
    GET DIAGNOSTICS v_advisors = ROW_COUNT;
    -- core.cron_labels (Phase 0 WS-0c): Chat-Toggle-Registry der opt-in Crons; package-besessen, von
    -- DROP SCHEMA <pkg> nicht erreicht (Core-Tabelle). Keine fn-Bezeichner -> kein Orphan-Dispatch-Risiko,
    -- aber Hygiene-Pflicht wie die anderen Core-Registries (sonst bliebe eine tote Toggle-/Label-Zeile).
    -- Roter Faden: Personen-Einstellungen der Reminder dieses Pakets (kein FK auf cron_labels, s. agent.reminder_prefs_init).
    DELETE FROM agent.reminder_prefs rp USING core.cron_labels l WHERE l.cron_key = rp.cron_key AND l.package = v_pkg;
    DELETE FROM core.cron_labels WHERE package = v_pkg;
    GET DIAGNOSTICS v_cronlabels = ROW_COUNT;
    -- core.callback_handlers (Phase 0 WS-0c CB): Callback-Dispatch-Registry; package-besessen, VOR DROP SCHEMA,
    -- sonst zeigt handler_fn auf eine gedroppte Paket-fn (Orphan-Dispatch-Ziel im generischen Dispatcher).
    DELETE FROM core.callback_handlers WHERE package = v_pkg;
    GET DIAGNOSTICS v_cbhandlers = ROW_COUNT;

    -- 3b. Paket-besessene Monitor-Trigger (Host-Tabelle agent.monitor_triggers, von DROP SCHEMA <pkg>
    --     NICHT erreicht — Advisor<->Monitor-Integration). `AND origin='user'` ist Invarianten-Pflicht:
    --     ein origin='core'-Trigger triggert den BEFORE-DELETE-Block (agent.trg_monitor_triggers_protect)
    --     und wuerde die GESAMTE atomare Purge-Transaktion abbrechen. Paket-Trigger sind immer 'user'.
    DELETE FROM agent.monitor_triggers WHERE package = v_pkg AND origin = 'user';
    GET DIAGNOSTICS v_triggers = ROW_COUNT;

    -- 3c. Trigger auf den Monitor-Methoden des Pakets (auch package='core'), dann die Methoden (FK NO ACTION).
    DELETE FROM agent.monitor_triggers t
     USING core.monitor_acquisition_methods m
     WHERE m.method = t.acquisition_method AND m.package = v_pkg AND t.origin = 'user';
    GET DIAGNOSTICS v_mtriggers = ROW_COUNT;
    DELETE FROM core.monitor_acquisition_methods WHERE package = v_pkg;
    GET DIAGNOSTICS v_methods = ROW_COUNT;

    -- 4. Service-Alias-Map + Config-Zeilen.
    DELETE FROM core.services WHERE package = v_pkg;
    GET DIAGNOSTICS v_services = ROW_COUNT;
    DELETE FROM core.config WHERE package = v_pkg;
    GET DIAGNOSTICS v_config = ROW_COUNT;

    -- 5. Migrations-Ledger (Flyway-clean): damit der Re-Install die Paket-V-Migrationen erneut sieht.
    DELETE FROM core.schema_version WHERE package = v_pkg;
    GET DIAGNOSTICS v_ledger = ROW_COUNT;

    RETURN jsonb_build_object(
        'ok',               true,
        'package',          v_pkg,
        'protected',        v_protected,
        'contexts',         v_contexts,
        'validators',       v_validators,
        'scopes',           v_scopes,
        'renderers',        v_renderers,
        'advisors',         v_advisors,
        'cron_labels',      v_cronlabels,
        'callback_handlers', v_cbhandlers,
        'monitor_triggers', v_triggers,
        'method_triggers',  v_mtriggers,
        'acquisition_methods', v_methods,
        'services',         v_services,
        'config',           v_config,
        'schema_version',   v_ledger
    );
END;
$$;
