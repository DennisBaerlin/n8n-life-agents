-- ============================================================
-- core.fn_advisor_review_evaluate (generischer Eval-/Latch-Wrapper der Core-Advisor-Engine)
--   Der eine Eintrittspunkt des Drift-Checks: Registry-Lookup domain -> review_fn, dyn. EXECUTE der
--   paket-besessenen Review-fn, dann generischer Latch gegen die geteilte core.notification_state
--   (person-suffigierte v_source = 'advisor:'||domain||COALESCE(':'||person_id,''))
--   ueber core.fn_should_notify/fn_notify_reconcile + Reconcile-GC.
--   Eingaben: p_domain (Pflicht), p_person_id (optional), p_observations (optional, an die review_fn durchgereicht).
--
--   Rollenmodell (wie fn_monitor_evaluate): SECURITY INVOKER. Der schreibende Cron laeuft unter
--   dem Haupt-RW-Credential (wie cron_monitor_check_triggers); die Cron-SQL ist entwickler-geschrieben
--   und deterministisch (kein LLM-formuliertes SELECT), darum braucht der Latch-Write kein core_ro/DEFINER-
--   Eskalationsfenster. SET search_path=pg_catalog (CVE-2018-1058) + to_regprocedure-Guard auf
--   die installer-geschriebene review_fn aus der Registry (nie $fromAI).
--
--   Latch (geteilte Schicht, Muster fn_monitor_evaluate): je alert aus review_fn.alerts ruft
--   core.fn_should_notify(v_source, metric_key) (NULL-TTL = reiner Edge-Latch) -> true gdw der
--   Latch ok->fired kippt = neuer Breach = senden (send=true); bereits 'fired' = still. Reconcile-GC:
--   core.fn_notify_reconcile loescht jede Latch-Zeile dieser source, deren metric_key nicht mehr im
--   aktuellen Set ist (wieder im Band oder Ziel/Block umbenannt/geloescht) -> Re-Arm + kein Leak.
--
--   Mengen-Alarm: traegt ein alert ein nicht-leeres Array 'latch_keys' (z. B. die ids der
--   Positionen ohne Anlageklasse), latcht die Engine je Element unter 'metric_key#k' statt unter metric_key -> ein
--   neu hinzukommendes Element meldet den Alarm erneut, dieselbe Menge bleibt still, ein verschwundenes Element
--   re-armt per Reconcile.
--
--   Person-Faecherung: p_person_id faechert den Latch und den Dispatch pro Person.
--   v_source = 'advisor:'||domain||COALESCE(':'||person_id,'') -> person_id NULL ergibt 'advisor:'||domain
--   (finance, Haushalt); mit person_id latcht jede Person getrennt ('advisor:career:<pid>'). Die person_id geht
--   uniform an alle registrierten <pkg>.fn_advisor_review(text,text,jsonb) (finance ignoriert sie = Haushalt,
--   career nutzt sie); keine scope-konditionale Dispatch-Aritaet.
--
--   told_keys: ein alert darf told_keys:[{source,key,latch_key?}] tragen. Ist einer laut core.fn_notify_told gemeldet,
--   wird der Merker gesetzt, der alert (bzw. mit latch_key das Element) aber nicht neu (Alertmanager inhibit_rules).
--
--   Budget: Ist etwas neu, belegt die fn vor dem ersten Merker den Slot des Owners (die Nachricht geht in den Owner-Chat):
--   Waechter 'advisor_drift' normal (mehrere Domains = eine Nachricht), eigener Review-Cron 'advisor:<domain>' priority.
--   Kein Platz -> { ok, send:false, deferred:true, alerts:[], first_run:false, digest }, keine Merker.
--   Rueckgabe jsonb: { ok, send:boolean, alerts:[…neue Breaches, je _latched:[{source,key}]…], first_run:boolean, digest:{…} }
--     send=true gdw mindestens ein Breach neu ist (Latch-Uebergang) -> der Drift-Cron schickt nur dann.
--     first_run=true beim ersten Lauf je (domain, person) mit neuen Alarmen. _latched braucht core.fn_advisor_alerts_cap.
--     digest reicht die fn unveraendert durch (der Quartals-Cron nutzt ihn ungelatcht).
--     ok:false, error = 'unknown_advisor_domain' | 'review_fn_missing' (send:false, alerts:[]).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_review_evaluate(p_domain text, p_person_id text DEFAULT NULL, p_observations jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_fn         text;
    v_result     jsonb;
    v_alerts     jsonb;
    v_digest     jsonb;
    v_new        jsonb := '[]'::jsonb;   -- nur die NEU gebreachten (Latch-Uebergang) -> Versand
    v_keys       text[] := '{}';         -- alle aktuell breachenden metric_keys (Reconcile-Anker)
    v_alert      jsonb;
    v_key        text;
    v_sub        text;
    v_told       boolean;
    v_latched    jsonb;
    v_first_run  boolean := false;
    v_needs      boolean;
    v_own_cron   boolean;
    -- Person-suffigierte Latch-source (NULL = Haushalt). Eine Variable, an beiden Call-Sites
    -- (fn_should_notify + fn_notify_reconcile) genutzt, sonst latcht der eine person-aware und der
    -- Reconcile raeumt person-blind -> Dauer-Stummschaltung/Leak.
    v_source     text := 'advisor:' || p_domain || COALESCE(':' || p_person_id, '');
BEGIN
    SELECT review_fn, own_review_cron INTO v_fn, v_own_cron FROM core.advisors WHERE domain = p_domain;
    IF v_fn IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'send', false, 'error', 'unknown_advisor_domain', 'alerts', '[]'::jsonb);
    END IF;
    IF to_regprocedure(v_fn || '(text,text,jsonb)') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'send', false, 'error', 'review_fn_missing', 'alerts', '[]'::jsonb);
    END IF;

    -- review_fn ist installer-kontrolliert und schema-qualifiziert; uniform 3-arg (person_id durchgereicht).
    EXECUTE format('SELECT %s($1, $2, $3)', v_fn) INTO v_result USING p_domain, p_person_id, p_observations;
    v_alerts := COALESCE(v_result->'alerts', '[]'::jsonb);
    v_digest := COALESCE(v_result->'digest', '{}'::jsonb);

    -- Vorab-Blick ohne Schreiben: Nur eine wirklich neue Meldung belegt einen Tages-Slot. Kein Platz -> nichts gemerkt,
    -- auch nicht der Erst-Merker; der naechste Lauf meldet. v_keys vollstaendig, sonst raeumte der Reconcile gesetzte Merker.
    SELECT COALESCE(bool_or(NOT core.fn_notify_told(v_source, e.k)
                            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(a->'told_keys', '[]'::jsonb)) t
                                             WHERE (e.sub IS NULL OR t->>'latch_key' IS NULL OR t->>'latch_key' = e.sub)
                                               AND core.fn_notify_told(t->>'source', t->>'key'))), false),
           COALESCE(array_agg(e.k), '{}')
      INTO v_needs, v_keys
      FROM jsonb_array_elements(v_alerts) a
     CROSS JOIN LATERAL (
         SELECT (a->>'metric_key') || '#' || s AS k, s AS sub
           FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(a->'latch_keys') = 'array' THEN a->'latch_keys' ELSE '[]'::jsonb END) s
         UNION ALL
         SELECT a->>'metric_key', NULL
          WHERE CASE WHEN jsonb_typeof(a->'latch_keys') = 'array' THEN jsonb_array_length(a->'latch_keys') = 0 ELSE true END
     ) e
     WHERE a->>'metric_key' IS NOT NULL;

    IF v_needs AND NOT core.fn_proactive_claim(NULL,
           CASE WHEN v_own_cron THEN 'advisor:' || p_domain ELSE 'advisor_drift' END,
           CASE WHEN v_own_cron THEN 'priority' ELSE 'normal' END) THEN
        PERFORM core.fn_notify_reconcile(v_source, v_keys || '__first_run__'::text);
        RETURN jsonb_build_object('ok', true, 'send', false, 'deferred', true, 'alerts', '[]'::jsonb, 'first_run', false, 'digest', v_digest);
    END IF;

    -- Latch je aktuellem Alert ueber die geteilte core.notification_state (source='advisor:'||domain, key=metric_key):
    -- core.fn_should_notify gatet (NULL-TTL = reiner Edge-Latch, kein auto-Re-Arm) -> true gdw der Latch jetzt
    -- ok->fired kippt (Erst-Breach oder nach Re-Arm) -> neuer Breach -> senden.
    FOR v_alert IN SELECT * FROM jsonb_array_elements(v_alerts) LOOP
        v_key  := v_alert->>'metric_key';
        CONTINUE WHEN v_key IS NULL;   -- ein alert ohne metric_key wuerde sonst die NOT-NULL-key-
                                       -- Constraint von core.notification_state verletzen + den Cron-Lauf killen
        -- Der Merker wird immer zuerst gesetzt, erst dann told geprueft: Eine gesagte Lage gilt so als gemeldet.
        -- Mengen-Alarm mit latch_keys -> je Element 'metric_key#k' latchen (Alertmanager-Gruppe: ein neues Mitglied
        -- meldet erneut); jedes Element wird gelatcht (kein Kurzschluss), verschwundene raeumt der Reconcile unten.
        v_latched := '[]'::jsonb;
        IF jsonb_typeof(v_alert->'latch_keys') = 'array' AND jsonb_array_length(v_alert->'latch_keys') > 0 THEN
            FOR v_sub IN SELECT jsonb_array_elements_text(v_alert->'latch_keys') LOOP
                IF core.fn_should_notify(v_source, v_key || '#' || v_sub) THEN
                    SELECT EXISTS (
                        SELECT 1 FROM jsonb_array_elements(COALESCE(v_alert->'told_keys', '[]'::jsonb)) t
                        WHERE (t->>'latch_key' IS NULL OR t->>'latch_key' = v_sub)
                          AND core.fn_notify_told(t->>'source', t->>'key')) INTO v_told;
                    IF NOT v_told THEN
                        v_latched := v_latched || jsonb_build_object('source', v_source, 'key', v_key || '#' || v_sub);
                    END IF;
                END IF;
            END LOOP;
        ELSE
            IF core.fn_should_notify(v_source, v_key) THEN
                SELECT EXISTS (
                    SELECT 1 FROM jsonb_array_elements(COALESCE(v_alert->'told_keys', '[]'::jsonb)) t
                    WHERE core.fn_notify_told(t->>'source', t->>'key')) INTO v_told;
                IF NOT v_told THEN
                    v_latched := v_latched || jsonb_build_object('source', v_source, 'key', v_key);
                END IF;
            END IF;
        END IF;
        IF jsonb_array_length(v_latched) > 0 THEN
            v_new := v_new || (v_alert || jsonb_build_object('_latched', v_latched));
        END IF;
    END LOOP;

    -- Erst-Merker in derselben Quelle: Reset, Personen-Purge und Restore wirken ohne weitere Stelle. Nur ein Lauf mit
    -- neuen Alarmen verbraucht ihn; "keine Merker vorhanden" taugt nicht, das gilt auch nach einer Phase ohne Abweichung.
    v_keys := v_keys || '__first_run__'::text;
    IF jsonb_array_length(v_new) > 0 THEN
        v_first_run := core.fn_should_notify(v_source, '__first_run__');
    END IF;

    -- Reconcile-GC (level-triggered): der Review-Lauf liefert das volle aktuelle Alert-Set. Jede gelatchte
    -- Metrik dieser Domain, die nicht (mehr) im Set ist (wieder im Band oder Ziel/Block umbenannt/geloescht),
    -- wird ueber das Reconcile-Fenster geloescht -> re-armt sauber (naechster Breach feuert wieder), kein Leak.
    PERFORM core.fn_notify_reconcile(v_source, v_keys);

    RETURN jsonb_build_object(
        'ok',     true,
        'send',   jsonb_array_length(v_new) > 0,
        'alerts', v_new,
        'first_run', v_first_run,
        'digest', v_digest);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_advisor_review_evaluate(text, text, jsonb) FROM public;
