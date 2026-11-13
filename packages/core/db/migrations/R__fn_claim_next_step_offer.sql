-- ============================================================
-- core.fn_claim_next_step_offer(p) — darf dieser Vorschlag mit Knopf jetzt raus? (WRITE, zaehlt ihn)
--   Am Sendepunkt des Orchestrators gerufen, erst wenn der Knopf feststeht; das Gegenstueck zum lesenden Feld offer von
--   core.fn_get_next_step (gleiche Keys ueber core.fn_next_step_offer_keys).
--   Eingabe p: { chat_id, callback, state, generation, smalltalk }.
--     smalltalk nicht greeting/ping (eine ausdrueckliche Frage wie "und jetzt?") -> true, ohne Pruefung und ohne Zaehlen.
--   Ablauf: Advisory-Lock je Person; dann beide Grenzen nur lesen (core.fn_notify_told); nur wenn beide einen freien Key
--     haben, beide per core.fn_should_notify setzen. So wird nie ein Latch verbraucht, ohne dass ein Knopf rausgeht.
--   Aufraeumen im selben Lauf (core.fn_notify_forget_before): Tag-Keys aelter als 2 Tage (der Kalendertag im Key macht
--     sie bedeutungslos), Wiederholungs-Keys aelter als 90 Tage (alte Generationen; eine Lage, die so lange still
--     unveraendert liegt, darf wieder angeboten werden).
--   Rueckgabe boolean. Wirft nie; jeder Fehler und ein unbekannter Absender -> false (der Knopf ist Komfort, eine kaputte
--     Latch-Schicht darf keine Knopf-Flut ausloesen).
--   Bewusst hingenommen: zwei fast gleichzeitige Gruesse lesen beide offer=true, der zweite Claim verliert -> sein Satz
--     geht ohne Knopf raus.
--   SECURITY DEFINER (schreibt core.notification_state), search_path gepinnt; Aufrufer: Orchestrator unter der Host-Cred.
--   Tests: tests/db/core/test_fn_claim_next_step_offer.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_claim_next_step_offer(p jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_sender jsonb;
    v_pid    text;
    v_keys   jsonb;
    v_day    text;
    v_rep    text;
BEGIN
    IF COALESCE(p->>'smalltalk', '') NOT IN ('greeting', 'ping') THEN
        RETURN v_chat ~ '^[0-9]{1,18}$' AND COALESCE(p->>'callback', '') <> '';
    END IF;
    IF v_chat !~ '^[0-9]{1,18}$' OR COALESCE(p->>'callback', '') = '' THEN
        RETURN false;
    END IF;
    v_sender := agent.fn_resolve_sender(v_chat::bigint);
    IF COALESCE((v_sender->>'found')::boolean, false) IS NOT TRUE THEN
        RETURN false;
    END IF;
    v_pid := v_sender->>'person_id';
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('next_step:' || v_pid));

    PERFORM core.fn_notify_forget_before('next_step_day', now() - interval '2 days');
    PERFORM core.fn_notify_forget_before('next_step_offer', now() - interval '90 days');

    v_keys := core.fn_next_step_offer_keys(v_pid, p->>'callback', p->>'state', NULLIF(p->>'generation', '')::bigint);
    IF jsonb_array_length(v_keys->'day') > 0 THEN
        SELECT k INTO v_day FROM jsonb_array_elements_text(v_keys->'day') WITH ORDINALITY AS t(k, i)
        WHERE NOT core.fn_notify_told('next_step_day', k) ORDER BY i LIMIT 1;
        IF v_day IS NULL THEN RETURN false; END IF;
    END IF;
    IF jsonb_array_length(v_keys->'repeat') > 0 THEN
        SELECT k INTO v_rep FROM jsonb_array_elements_text(v_keys->'repeat') WITH ORDINALITY AS t(k, i)
        WHERE NOT core.fn_notify_told('next_step_offer', k) ORDER BY i LIMIT 1;
        IF v_rep IS NULL THEN RETURN false; END IF;
    END IF;
    IF v_day IS NOT NULL THEN PERFORM core.fn_should_notify('next_step_day', v_day, NULL); END IF;
    IF v_rep IS NOT NULL THEN PERFORM core.fn_should_notify('next_step_offer', v_rep, NULL); END IF;
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_claim_next_step_offer(jsonb) FROM public;
