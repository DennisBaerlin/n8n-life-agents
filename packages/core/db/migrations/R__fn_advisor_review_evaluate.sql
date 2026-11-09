-- ============================================================
-- core.fn_advisor_review_evaluate (WS2 — generischer Eval-/Latch-Wrapper der Core-Advisor-Engine)
--   Der EINE Eintrittspunkt des Drift-Checks: Registry-Lookup domain -> review_fn, dyn. EXECUTE der
--   paket-besessenen Review-fn, dann generischer LATCH gegen die GETEILTE core.notification_state
--   (Phase Notify; person-suffigierte v_source = 'advisor:'||domain||COALESCE(':'||person_id,''), P2a)
--   ueber core.fn_should_notify/fn_notify_reconcile + Reconcile-GC.
--
--   ROLLENMODELL (Praezedenz fn_monitor_evaluate): SECURITY INVOKER. Der schreibende Cron laeuft unter
--   dem Haupt-RW-Credential (wie cron_monitor_check_triggers) — die Cron-SQL ist entwickler-geschrieben
--   + deterministisch (kein LLM-formuliertes SELECT), darum KEIN core_ro/DEFINER-Eskalationsfenster
--   noetig fuer den Latch-Write. SET search_path=pg_catalog (CVE-2018-1058) + to_regprocedure-Guard auf
--   die installer-geschriebene review_fn aus der Registry (nie $fromAI).
--
--   LATCH (geteilte Schicht, Muster fn_monitor_evaluate): je alert aus review_fn.alerts ruft
--   core.fn_should_notify(v_source, metric_key) (NULL-TTL = reiner Edge-Latch) -> true GDW der
--   Latch ok->fired kippt = NEUER Breach = senden (send=true); bereits 'fired' = still. RECONCILE-GC:
--   core.fn_notify_reconcile loescht jede Latch-Zeile dieser source, deren metric_key NICHT mehr im
--   aktuellen Set ist (wieder im Band ODER Ziel/Block umbenannt/geloescht) -> Re-Arm + kein Leak.
--
--   MENGEN-ALARM (Roter Faden 2026-10-23): traegt ein alert ein nicht-leeres Array 'latch_keys' (z. B. die ids der
--   Positionen ohne Anlageklasse), latcht die Engine je Element unter 'metric_key#k' statt unter metric_key -> ein
--   NEU hinzukommendes Element meldet den Alarm erneut, dieselbe Menge bleibt still, ein verschwundenes Element
--   re-armt per Reconcile. Einmaleffekt beim ersten Lauf nach Einfuehrung: der bisherige metric_key-Latch wird
--   reconciled und der bestehende Alarm meldet sich EINMAL neu (gewollt: er nennt jetzt die konkreten Namen).
--
--   PERSON-FAECHERUNG (P2a, uniform 3-arg): p_person_id faechert den Latch + den Dispatch pro Person.
--   v_source = 'advisor:'||domain||COALESCE(':'||person_id,'') -> person_id NULL ist BYTE-GLEICH heute
--   ('advisor:'||domain) -> finance (Haushalt) + die heutigen 1-Arg-Cron-Aufrufe sind 0-Verhaltensaenderung;
--   mit person_id (P2b-Cron-Schleife) latcht jede Person getrennt ('advisor:career:<pid>'). Der person_id geht
--   UNIFORM an ALLE registrierten <pkg>.fn_advisor_review(text,text,jsonb) (finance ignoriert ihn = Haushalt,
--   career nutzt ihn) — keine scope-konditionale Dispatch-Aritaet (Rule of Three, 2. Dispatcher-Konsument).
--
--   TOLD_KEYS: ein alert darf told_keys:[{source,key,latch_key?}] tragen. Ist einer laut core.fn_notify_told gemeldet,
--   wird der Merker gesetzt, der alert (bzw. mit latch_key das Element) aber nicht neu (Alertmanager inhibit_rules).
--
--   BUDGET: Ist etwas neu, belegt die fn VOR dem ersten Merker den Slot des Owners (die Nachricht geht in den Owner-Chat):
--   Waechter 'advisor_drift' normal (mehrere Domains = eine Nachricht), eigener Review-Cron 'advisor:<domain>' priority.
--   Kein Platz -> { ok, send:false, deferred:true, alerts:[], first_run:false, digest }, keine Merker.
--   RUECKGABE jsonb: { ok, send:boolean, alerts:[…neue Breaches, je _latched:[{source,key}]…], first_run:boolean, digest:{…} }
--     send=true gdw mindestens EIN Breach NEU ist (Latch-Uebergang) -> der Drift-Cron schickt nur dann.
--     first_run=true beim ersten Lauf je (domain, person) mit neuen Alarmen. _latched braucht core.fn_advisor_alerts_cap.
--     digest reicht die fn unveraendert durch (der Quartals-Cron nutzt ihn ungelatcht).
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_advisor_review_evaluate.sql
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
    -- P2a: person-suffigierte Latch-source (NULL=Haushalt -> byte-gleich heute). EINE Variable, an BEIDEN
    -- Call-Sites (fn_should_notify + fn_notify_reconcile) genutzt -> sonst latcht der eine person-aware und der
    -- Reconcile raeumt person-blind -> Dauer-Stummschaltung/Leak (Opus-Review M2).
    v_source     text := 'advisor:' || p_domain || COALESCE(':' || p_person_id, '');
BEGIN
    -- Registry-Lookup + Guard
    SELECT review_fn, own_review_cron INTO v_fn, v_own_cron FROM core.advisors WHERE domain = p_domain;
    IF v_fn IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'send', false, 'error', 'unknown_advisor_domain', 'alerts', '[]'::jsonb);
    END IF;
    IF to_regprocedure(v_fn || '(text,text,jsonb)') IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'send', false, 'error', 'review_fn_missing', 'alerts', '[]'::jsonb);
    END IF;

    -- Paket-Review-fn dynamisch ausfuehren (review_fn ist installer-kontrolliert + schema-qualifiziert).
    -- UNIFORM 3-arg: person_id durchgereicht (finance ignoriert ihn = Haushalt; career nutzt ihn).
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

    -- ---------- Latch je aktuellem Alert (Phase Notify: ueber die GETEILTE core.notification_state) ----------
    -- Der frueher advisor-eigene Edge-Latch (core.advisor_review_state) lebt jetzt in der geteilten Dedup-
    -- Schicht (source='advisor:'||domain, key=metric_key). Pro aktuellem Alert ueber das Edge-Latch-Fenster
    -- core.fn_should_notify gaten (NULL-TTL = reiner Edge-Latch, KEIN auto-Re-Arm) -> true GDW der Latch jetzt
    -- ok->fired kippt (Erst-Breach oder nach Re-Arm) -> NEUER Breach -> senden. Race-Safety (INSERT ON CONFLICT
    -- -> FOR UPDATE) + send-once/Re-Arm-Semantik byte-gleich; die frueheren Audit-Spalten (last_value/target/drift)
    -- entfallen (write-only, kein Leser).
    FOR v_alert IN SELECT * FROM jsonb_array_elements(v_alerts) LOOP
        v_key  := v_alert->>'metric_key';
        CONTINUE WHEN v_key IS NULL;   -- defensiv: ein alert ohne metric_key wuerde sonst die NOT-NULL-key-
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

    -- ---------- Reconcile-GC: Re-Arm wieder-im-Band + Loeschen stale Keys ----------
    -- Level-triggered: der Review-Lauf liefert das VOLLE aktuelle Alert-Set. Jede gelatchte Metrik dieser
    -- Domain, die NICHT (mehr) im Set ist (wieder im Band ODER Ziel/Block umbenannt/geloescht), wird ueber
    -- das Reconcile-Fenster geloescht -> re-armt sauber (naechster Breach feuert wieder) + kein Leak.
    -- (Desired-State treibt die Tabelle, k8s-Reconcile.)
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
