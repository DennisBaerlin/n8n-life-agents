-- ============================================================
-- estate.fn_advisor_review (WS-4 — Review-fn der Nachlass-/Vorsorge-Domaene, Jahres-Review)
--   Erfuellt den generischen Engine-Vertrag fn(text,text,jsonb)->jsonb { alerts:[…], digest:{…} } (WS2):
--   der Core-Wrapper core.fn_advisor_review_evaluate dispatcht hierher (Registry core.advisors, domain
--   'estate'), latcht je alert ueber metric_key (geteilte core.notification_state, source='advisor:estate')
--   und reicht den digest ungelatcht durch. Jeder alert traegt 'msg' = [tpl…], der digest 'lines' = [tpl|null…]
--   (Textkatalog Phase C, Form wie finance: estate.advisor.*-Keys + typisierte Werte) — die generischen Core-Crons
--   (UND der estate-eigene cron_review_register) kennen KEINE estate-Felder, sie rendern nur die Struktur.
--
--   estate ist HAUSHALT (KEIN per_user wie career): p_person_id wird IGNORIERT (NULL byte-gleich; die
--   Signatur ist nur die uniforme Plugin-Schnittstelle, Praezedenz finance). estate_overview traegt KEINE
--   core.context_scopes-Zeile -> agent.fn_context_persons('estate_overview') ist leer -> der Eval-Cron
--   faechert household (person_id NULL). Muster/Delta zu career: STATT eines Plan-Sidecars sind die Register-
--   Tabellen die Wahrheit; die Luecken rechnet die WS-2-Quelle estate.fn_gap_report() (doppel-guardet).
--
--   Metriken (alle latch-faehig ueber metric_key):
--     (A) STALENESS je Erwachsenem: person_records.last_reviewed_at aelter als advisor.estate_review_days
--         (Config, Default 365) -> ein Alert je ueberfaelligem Erwachsenen (metric_key
--         review_staleness:<pid>). fn_confirm_review re-armt (stempelt last_reviewed_at -> Alert
--         faellt aus dem Set -> Reconcile-GC loescht den Latch). GRENZE: NULL last_reviewed_at (nie
--         bestaetigt) feuert NICHT — es gibt keine gerissene Frist-Basis; die Register-Luecke (missing
--         person_record) deckt Unvollstaendigkeit ab. Erst-Confirm startet die jaehrliche Re-Arm-Schleife.
--     (B) FEHLENDE Vorsorge-Dokumente je Erwachsenem (estate.v_directive_gaps, essential+recommended;
--         Haushalts-Urkunde deckt beide Partner) -> ein Alert je Erwachsenem mit ≥1 Luecke (metric_key
--         directive_gaps:<pid>), Owner-Wahl "ruhig": feuert beim Auftauchen, re-armt per Person
--         bei 0 Luecken. Kind + situational NIE (die View filtert).
--     (C) finance-Nachlass-Feld-Gaps GUARDED: estate.fn_gap_report().finance.gaps (policy_number/beneficiary/
--         claim_deadline_hours je Police, ownership/has_transmortal_poa je Konto) -> EIN Singleton-Alert
--         finance_gaps. DOPPEL-GUARDET in fn_gap_report (fn_package_active('finance') + to_regprocedure
--         je Call-Site) -> finance absent/nicht lesbar => gaps=[] => KEIN Alert (graceful, kein Crash).
--   DIGEST (ungelatcht): strukturierte Zaehler (adults_total/reviews_recorded/stale_review_count/
--     directive_gap_count/register_gap_count/finance_gap_count/finance_status) + 'lines' (Zeilen-Struktur).
--
--   ⚠️ DARF NIE RAISEn: der geteilte Drift-Cron wertet ALLE Advisor in EINER materialisierten CTE aus ->
--   eine Exception hier kippt auch den finance-/career-Lauf. Alle Datums-/Cast-Pfade defensiv geguarded.
--   Der Core-Wrapper faengt nur eine FEHLENDE fn ab, NICHT ein RAISE INNERHALB.
--
--   ROLLEN-PFAD: aufgerufen vom Core-Wrapper unter dem Haupt-RW-Credential (Owner/DDL) -> erreicht estate.*
--   + core.fn_household_persons()/fn_config_get() (DEFINER-Fenster) + finance.* (via fn_gap_report, guarded).
--   estate.-qualifiziert (der Wrapper pinnt nur pg_catalog -> ALLES schema-qualifiziert). STABLE/INVOKER.
--   RUECKGABE jsonb: { ok, alerts:[{metric_key,kind,label,value,target?,msg}], digest:{…,lines} }.
--   ROTER FADEN: alerts nur, wenn mind. ein estate.onboarding_state-Abschnitt completed ist ("erst einladen, dann mahnen").
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_advisor_review.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_advisor_review(p_domain text, p_person_id text DEFAULT NULL, p_observations jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_alerts       jsonb := '[]'::jsonb;
    v_stale_days   numeric;
    v_report       jsonb;
    v_fin_status   text;
    v_fin_gaps     jsonb;
    v_fin_count    int;
    v_fin_items    text;
    v_stale_count  int := 0;
    v_dir_count    int := 0;
    v_adults       int;
    v_reviewed     int;
    v_dir_gap_ct   int;
    v_reg_gap_ct   int;
    v_lines        jsonb;
    r              record;
BEGIN
    -- Tuning-Schwelle (estate-eigener Config-Key; Default 365, defensiv gegen fehlende/leere Zeile).
    BEGIN
        v_stale_days := COALESCE(NULLIF(core.fn_config_get('estate', 'advisor', 'estate_review_days'), '')::numeric, 365);
    EXCEPTION WHEN OTHERS THEN
        v_stale_days := 365;
    END;

    -- EINE Gap-Quelle (doppel-guardet): Vorsorge-Dokumente, Register-Feld-Luecken, finance-Nachlass-Felder.
    v_report     := estate.fn_gap_report();
    v_fin_status := v_report->'finance'->>'status';
    v_fin_gaps   := COALESCE(v_report->'finance'->'gaps', '[]'::jsonb);
    v_fin_count  := jsonb_array_length(v_fin_gaps);
    v_dir_gap_ct := jsonb_array_length(COALESCE(v_report->'directive_gaps', '[]'::jsonb));
    v_reg_gap_ct := jsonb_array_length(COALESCE(v_report->'register_gaps', '[]'::jsonb));

    -- ---------- (A) Staleness je Erwachsenem (Register jaehrlich bestaetigen) ----------
    -- Nur NOT NULL last_reviewed_at, das die Frist reisst; NULL = nie bestaetigt -> keine Staleness (die
    -- Register-Luecke deckt Unvollstaendigkeit). Erwachsene ueber das DEFINER-Fenster core.fn_household_persons().
    FOR r IN
        SELECT hp.person_id, hp.full_name,
               (current_date - pr.last_reviewed_at::date) AS age_days
        FROM core.fn_household_persons() hp
        JOIN estate.person_records pr ON pr.person_id = hp.person_id
        WHERE hp.role IN ('owner', 'partner')
          AND pr.last_reviewed_at IS NOT NULL
          AND (current_date - pr.last_reviewed_at::date) > v_stale_days
    LOOP
        v_stale_count := v_stale_count + 1;
        v_alerts := v_alerts || core.fn_staleness_alert(
            'review_staleness:' || r.person_id, 'review_staleness', r.age_days, v_stale_days,
            jsonb_build_array(core.fn_ui_tpl('estate.advisor.review_stale', jsonb_build_object(
                'name', COALESCE(r.full_name, r.person_id), 'days', core.fn_ui_num(r.age_days),
                'threshold', core.fn_ui_num(v_stale_days)))));
    END LOOP;

    -- ---------- (B) Fehlende Vorsorge-Dokumente je Erwachsenem (aus v_directive_gaps) ----------
    -- Ein singleton-Alert JE ERWACHSENEM (Owner-Wahl "ruhig": feuert beim Auftauchen, re-armt per Person bei
    -- 0 Luecken). Der Text nennt die essenziellen Fehlstellen zuerst. Kind + situational filtert die View.
    FOR r IN
        SELECT g.person_id,
               max(g.full_name) AS full_name,
               count(*) AS gap_count,
               count(*) FILTER (WHERE g.recommendation = 'essential') AS essential_count,
               string_agg(g.label, ', ' ORDER BY g.label) FILTER (WHERE g.recommendation = 'essential') AS essential_labels
        FROM estate.v_directive_gaps g
        GROUP BY g.person_id
    LOOP
        v_dir_count := v_dir_count + 1;
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'directive_gaps:' || r.person_id,
            'kind',       'directive_gap',
            'label',      'directive_gaps',
            'value',      r.gap_count,
            -- essential_labels = directive_types.label (gespeicherte Daten, deutsche Rechtsbegriffe bleiben deutsch)
            'msg',        jsonb_build_array(core.fn_ui_tpl(
                              CASE WHEN r.essential_count > 0 THEN 'estate.advisor.directive_gaps_essential'
                                   ELSE 'estate.advisor.directive_gaps' END,
                              jsonb_build_object('name', COALESCE(r.full_name, r.person_id),
                                                 'count', core.fn_ui_num(r.gap_count), 'labels', r.essential_labels))));
    END LOOP;

    -- ---------- (C) finance-Nachlass-Feld-Gaps (GUARDED via fn_gap_report) ----------
    -- Singleton-Alert: die konkreten Felder leben bei finance (Grenzregel) und werden dort nachgetragen ->
    -- ein Sammel-Nudge statt per-Feld-Laerm. Guard sitzt in fn_gap_report (Paket absent/nicht lesbar -> []).
    IF v_fin_count > 0 THEN
        SELECT string_agg(g->>'item', ', ') INTO v_fin_items
        FROM jsonb_array_elements(v_fin_gaps) g;
        v_alerts := v_alerts || jsonb_build_object(
            'metric_key', 'finance_gaps',
            'kind',       'finance_gap',
            'label',      'finance_gaps',
            'value',      v_fin_count,
            'msg',        jsonb_build_array(core.fn_ui_tpl('estate.advisor.finance_gaps', jsonb_build_object(
                              'count', core.fn_ui_num(v_fin_count), 'items', v_fin_items))));
    END IF;

    -- ---------- Digest (Jahres-Voll-Report, ungelatcht durchgereicht) ----------
    SELECT count(*) FILTER (WHERE hp.role IN ('owner', 'partner')),
           count(*) FILTER (WHERE hp.role IN ('owner', 'partner') AND pr.last_reviewed_at IS NOT NULL)
      INTO v_adults, v_reviewed
    FROM core.fn_household_persons() hp
    LEFT JOIN estate.person_records pr ON pr.person_id = hp.person_id;

    -- Digest als Zeilen-STRUKTUR (Textkatalog Phase C, Form wie finance: tpl | null = Leerzeile).
    v_lines := jsonb_build_array(
        core.fn_ui_tpl('estate.advisor.digest_title'),
        core.fn_ui_tpl('estate.advisor.digest_adults', jsonb_build_object(
            'adults', core.fn_ui_num(v_adults), 'reviewed', core.fn_ui_num(v_reviewed), 'stale', core.fn_ui_num(v_stale_count))),
        core.fn_ui_tpl('estate.advisor.digest_directive_gaps', jsonb_build_object('n', core.fn_ui_num(v_dir_gap_ct))),
        core.fn_ui_tpl('estate.advisor.digest_register_gaps', jsonb_build_object('n', core.fn_ui_num(v_reg_gap_ct))),
        CASE WHEN v_fin_status = 'ok'
             THEN core.fn_ui_tpl('estate.advisor.digest_finance_gaps', jsonb_build_object('n', core.fn_ui_num(v_fin_count)))
             ELSE core.fn_ui_tpl('estate.advisor.digest_finance_unavailable',
                      jsonb_build_object('status', COALESCE(v_fin_status, 'unknown'))) END,
        NULL,
        -- "vollstaendig" nur wenn ALLE Gap-Kategorien 0 sind — inkl. der register_gaps, die (anders als
        -- Staleness/Dokument-/finance-Gaps) KEINEN Alert emittieren und nur hier im Digest zaehlen. Ohne den
        -- reg-Term widerspraeche der Schluss-Satz der Zeile "Offene Register-Luecken: N" (Cold-Eyes WS-4).
        CASE WHEN v_stale_count = 0 AND v_dir_count = 0 AND v_fin_count = 0 AND v_reg_gap_ct = 0
             THEN core.fn_ui_tpl('estate.advisor.digest_all_done')
             ELSE core.fn_ui_tpl('estate.advisor.digest_next') END);

    -- Roter Faden "erst einladen, dann mahnen" (Owner-Entscheid 2026-10-23): solange KEIN estate-Onboarding-Abschnitt
    -- 'completed' ist, mahnt der Review nicht (die Nachfass-Karte core.fn_onboarding_nudges_due laedt zum Einrichten
    -- ein). Nur 'skipped' = "nicht jetzt" -> ebenfalls still. Leere alerts -> der Engine-Reconcile raeumt alte Latches,
    -- nach dem Start feuern die Luecken einmal als NEU. Der Digest bleibt (Inhalt auf Abruf).
    IF NOT EXISTS (SELECT 1 FROM estate.onboarding_state WHERE status = 'completed') THEN
        v_alerts := '[]'::jsonb;
    END IF;

    RETURN jsonb_build_object(
        'ok',     true,
        'alerts', v_alerts,
        'digest', jsonb_build_object(
            'adults_total',        v_adults,
            'reviews_recorded',    v_reviewed,
            'stale_review_count',  v_stale_count,
            'directive_gap_count', v_dir_gap_ct,
            'register_gap_count',  v_reg_gap_ct,
            'finance_gap_count',   v_fin_count,
            'finance_status',      v_fin_status,
            'lines',               v_lines));
END;
$$;
