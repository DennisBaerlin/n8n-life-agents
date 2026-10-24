-- ============================================================
-- estate.fn_confirm_review (ATOMIC WRITE — WS-2, Fortschritts-Flag-Klasse)
--   Stempelt estate.person_records.last_reviewed_at = now() fuer EINE Person — die Bestaetigung
--   "Register durchgesehen, Stand aktuell". Re-armt damit den WS-4-Jahres-Review (Staleness-
--   Vergleich advisor.estate_review_days). UPSERT: existiert noch keine Stammdaten-Zeile,
--   entsteht sie mit dem Stempel (die Review-Bestaetigung soll nie an einer fehlenden Zeile
--   scheitern). person_id loest das TOOL via core.fn_resolve_person auf (Pflicht-Input).
--   KEIN HITL am Tool (Fortschritts-Flag wie set_onboarding_section/set_case_task — kein
--   Domaenen-/PII-Write, nur ein Zeitstempel); der adults_only-DB-Backstop bleibt trotzdem:
--   core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, person_id (Slug, Pflicht).
--   RUECKGABE: {ok:true, person_id, last_reviewed_at} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_confirm_review.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_confirm_review(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm   TEXT;
    v_person TEXT := NULLIF(trim(COALESCE(p->>'person_id', '')), '');
    v_at     TIMESTAMPTZ;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may confirm the register review.');
    END IF;

    IF v_person IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'person_id is required (resolve the household member first).');
    END IF;
    -- KEIN expliziter agent.persons-Read (SECURITY INVOKER unter estate_rw ohne agent-USAGE, D10):
    -- die FK person_id -> agent.persons(person_id) ist der Backstop (RI-Check intern, kein Grant noetig),
    -- der Tool-Resolve ist der Guard. Siehe fn_set_person_record fuer die volle Begruendung.

    INSERT INTO estate.person_records (person_id, last_reviewed_at)
    VALUES (v_person, now())
    ON CONFLICT (person_id) DO UPDATE SET last_reviewed_at = now()
    RETURNING last_reviewed_at INTO v_at;

    RETURN jsonb_build_object('ok', true, 'person_id', v_person, 'last_reviewed_at', v_at);
END;
$$;
