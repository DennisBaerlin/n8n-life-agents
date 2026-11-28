-- ============================================================
-- core.fn_nudge_stage(p) — gemeinsamer Stufen-Helfer der Nachfass-Erinnerungen (WRITE)
--   Zwei Stufen, dann Ruhe: entscheidet fuer eine Person und eine Lage, ob jetzt Stufe 1 oder 2 rausgeht, und setzt
--   dann Budget und Merker. Aufrufer: core.fn_onboarding_nudges_due (Einrichten), core.fn_advisor_resume_due (Beratung).
--   Ein dritter Nachfass-Typ ruft diesen Helfer und erbt alle Regeln.
--   p: { source, key_prefix, person_id, slot, idle_since, rearm_since, first_days, last_days, gap_days, rearm_days,
--        exclusive_sources:[source, ...] } — alle Pflicht ausser exclusive_sources (Default leer).
--     key_prefix ist die person_id oder beginnt mit '<person_id>:' (Merker '<key_prefix>:1' / ':2', source in core.notification_state, NULL-TTL);
--     daran erkennt die Quellen-Grenze die Person ueber alle Nachfass-Quellen.
--   Reihenfolge (wie der Bestand des Einrichtungs-Nachfassens):
--     1. ausserhalb core.fn_in_reminder_window() -> NULL (Schutz gegen Nachhol-Laeufe nach einem Neustart).
--     2. Re-Arm: rearm_since juenger als die letzte gesendete Stufe UND die letzte Stufe vor >= rearm_days Tagen ->
--        beide Stufen wieder scharf (core.fn_notify_resolve). rearm_days 0 = sofort.
--     3. Stufe 1: Stillstand (now - idle_since) >= first_days, Stufe 1 frei. Stufe 2: Stillstand >= last_days, Stufe 1
--        vor >= gap_days gesendet, Stufe 2 frei.
--     4. told-Pruefung zuerst (Stufe 2 bliebe sonst taeglich wahr und belegte einen Slot ohne Nachricht).
--     5. Quellen-Grenze: hat eine der exclusive_sources der Person heute (core.fn_today) schon geschrieben -> NULL,
--        Stufe unverbraucht. Hoechstens eine Nachfass-Nachricht je Person und Tag; das Tagesbudget bleibt aussen.
--     6. core.fn_proactive_claim(person, slot, 'normal') (voll/Pause -> NULL, unverbraucht), dann core.fn_should_notify.
--   Rueckgabe int 1 | 2 | NULL. Fehlender Pflichtwert -> NULL; ein echter Fehler wirft (der Cron-Lauf meldet ihn ueber
--   core.sub_error_notify, statt still nie mehr zu erinnern).
--   INVOKER (laeuft unter der Host-Cred der Crons), search_path gepinnt, Body schema-qualifiziert. EXECUTE nur Host.
--   Tests: tests/db/core/test_fn_nudge_stage.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_nudge_stage(p jsonb)
RETURNS int
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_src    text := p->>'source';
    v_prefix text := p->>'key_prefix';
    v_pid    text := p->>'person_id';
    v_slot   text := p->>'slot';
    v_idle   interval;
    v_rearm  timestamptz;
    v_first  int := NULLIF(p->>'first_days', '')::int;
    v_last   int := NULLIF(p->>'last_days', '')::int;
    v_gap    int := NULLIF(p->>'gap_days', '')::int;
    v_redays int := NULLIF(p->>'rearm_days', '')::int;
    v_excl   text[] := ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'exclusive_sources') = 'array'
                                                                  THEN p->'exclusive_sources' ELSE '[]'::jsonb END));
    v_fired  timestamptz;
    v_s1     text;
    v_s1_at  timestamptz;
    v_want   int;
BEGIN
    v_idle  := now() - (p->>'idle_since')::timestamptz;
    v_rearm := (p->>'rearm_since')::timestamptz;
    IF v_src IS NULL OR v_prefix IS NULL OR v_pid IS NULL OR v_slot IS NULL OR v_idle IS NULL
       OR v_first IS NULL OR v_last IS NULL OR v_gap IS NULL OR v_redays IS NULL THEN
        RETURN NULL;
    END IF;
    IF NOT core.fn_in_reminder_window() THEN
        RETURN NULL;
    END IF;

    SELECT max(ns.last_fired_at) INTO v_fired FROM core.notification_state ns
     WHERE ns.source = v_src AND ns.key IN (v_prefix || ':1', v_prefix || ':2') AND ns.state = 'fired';
    IF v_fired IS NOT NULL AND v_rearm > v_fired AND v_fired <= now() - make_interval(days => v_redays) THEN
        PERFORM core.fn_notify_resolve(v_src, v_prefix || ':1');
        PERFORM core.fn_notify_resolve(v_src, v_prefix || ':2');
    END IF;

    SELECT ns.state, ns.last_fired_at INTO v_s1, v_s1_at FROM core.notification_state ns
     WHERE ns.source = v_src AND ns.key = v_prefix || ':1';
    v_want := CASE WHEN v_idle >= make_interval(days => v_first) AND COALESCE(v_s1, 'ok') = 'ok' THEN 1
                   WHEN v_idle >= make_interval(days => v_last) AND v_s1 = 'fired'
                        AND v_s1_at <= now() - make_interval(days => v_gap) THEN 2 END;
    IF v_want IS NULL OR core.fn_notify_told(v_src, v_prefix || ':' || v_want) THEN
        RETURN NULL;
    END IF;

    IF EXISTS (SELECT 1 FROM core.notification_state ns
                WHERE ns.source = ANY (v_excl)
                  AND left(ns.key, length(v_pid) + 1) = v_pid || ':'
                  AND core.fn_today(ns.last_fired_at) = core.fn_today()) THEN
        RETURN NULL;
    END IF;

    IF core.fn_proactive_claim(v_pid, v_slot, 'normal') AND core.fn_should_notify(v_src, v_prefix || ':' || v_want) THEN
        RETURN v_want;
    END IF;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_nudge_stage(jsonb) FROM public;
