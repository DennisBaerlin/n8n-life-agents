-- ============================================================
-- fn_goal_depot_risk_fold (INTERNAL HELPER — Event-Fold, nicht tool-facing) — Sparziel im Depot kurz vor dem Termin
--   Die eine Regel aller Sparziel-Write-fns, die den Depot-Anteil erhoehen, ein Datum vorziehen, einen Sparplan
--   verknuepfen oder ein Ziel wieder oeffnen: kein Verbot, sondern eine bewusste, festgehaltene Ausnahme.
--   Eingabe: p_goal (Ziel-id), p_shown (jsonb, siehe Stempel), p_force (Default FALSE).
--   Liest die eine Zeile des Ziels aus fn_savings_goal_derisk_status(p_goal) (Post-State nach dem Write des Aufrufers)
--   und liefert {card_lines, card_approve_key?, effective?, depot_risk?}:
--     * Kurs-Luecke (fx_gap) im Fenster -> nur Hinweis finance.note.goal_depot_risk_fx, nichts festhalten.
--     * needs_acceptance oder (p_force und Ziel im Fenster, nicht bestaetigt) -> Warnzeile finance.note.goal_depot_risk
--       (bzw. _final in den letzten Monaten vor dem Termin), Knopf finance.hitl.accept_depot_risk und
--       effective.depot_risk_shown = {target_date, limit_eur, allowed_eur} = genau die Lage, die die Karte zeigt.
--       limit_eur = Freigabe-Grenze: bei aktivem Sparplan GREATEST(Ziel, Anteil) (er kauft bis zum Ziel weiter),
--       sonst der Anteil; gespeichert, nicht angezeigt (gleicht der Betrag-Zeile).
--     * im Fenster, im Pfad, nicht bestaetigt -> weicher Hinweis finance.note.goal_derisk_window.
--     * sonst [] (auch: bestaetigt und unveraendert -> keine zweite Warnung).
--   Stempel (nur im echten Write): p_shown = p->'depot_risk_shown' des Aufrufers. New-FnWriteGate mischt das effective
--   des Probelaufs fest in den echten Write; das Sprachmodell kann es nicht setzen (kein Tool-Input), interne Aufrufe
--   und der Import bauen ihren Payload selbst und tragen es nie. Eintrag 'accept' nur, wenn p_shown vorliegt und das Ziel
--   im Fenster liegt und der Anteil nach dem Write <= p_shown.limit_eur und das Zieldatum >= p_shown.target_date;
--   gestempelt werden die gezeigten Werte. Sonst bucht der Aufrufer ohne Stempel (die Lage hat sich zwischen Karte und
--   Tipp verschlechtert; die naechste Karte bzw. der Berater fragt neu) — bewusst kein stale_preview-RAISE (Owner-Alarm
--   je Fall fuer ein 10-Minuten-Rennen). Mit Stempel: depot_risk = {reminder_month} (Monat des letzten Checks 'YYYY-MM',
--   NULL bei Bestaetigung im letzten Zeitraum) — Post-State Kategorie 3, der Buchhalter nennt ihn, ohne zu rechnen.
--   Betraege der Karte: "Mein Rat" in der fn abgerundet (floor), der Beispiel-Verlust genau; beide mit
--   core.fn_ui_money(…, p_whole) -> ganze Euro erst im Renderer (card_lines sieht auch das Modell).
--   p_force: "das bleibt so" (fn_set_savings_goal depot_risk_accepted=true) zeigt die Warnung auch im Pfad.
--   plpgsql (late-bound: fn_savings_goal_derisk_status ist alphabetisch spaeter). Schreibt nur mit p_shown.
--   Rueckgabe jsonb: {card_lines: [...], card_approve_key?, effective?: {depot_risk_shown}, depot_risk?: {reminder_month}}
--   Tests: tests/db/finance/test_fn_goal_depot_risk_fold.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_depot_risk_fold(p_goal int, p_shown jsonb, p_force boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    s        record;
    v_limit  numeric;
    v_final  boolean;
    v_held   boolean;
BEGIN
    SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(p_goal) x WHERE x.goal_id = p_goal;
    IF NOT FOUND OR NOT s.in_window THEN
        RETURN jsonb_build_object('card_lines', '[]'::jsonb);
    END IF;
    v_held := s.depot_share_eur > 0 OR s.active_plan;

    -- echter Write nach "Risiko eingehen": genau die gezeigte Lage festhalten
    IF p_shown IS NOT NULL AND jsonb_typeof(p_shown) = 'object' AND NOT s.accepted AND NOT s.fx_gap
       AND s.depot_share_eur <= (p_shown->>'limit_eur')::numeric
       AND s.target_date >= (p_shown->>'target_date')::date THEN
        INSERT INTO finance.savings_goal_risk_decisions (savings_goal_id, event, target_date, limit_eur, allowed_eur)
        VALUES (p_goal, 'accept', (p_shown->>'target_date')::date, (p_shown->>'limit_eur')::numeric,
                (p_shown->>'allowed_eur')::numeric);
        RETURN jsonb_build_object('card_lines', '[]'::jsonb,
            'depot_risk', jsonb_build_object('reminder_month',
                CASE WHEN current_date < s.final_check_date THEN to_char(s.final_check_date, 'YYYY-MM') END));
    END IF;

    IF s.fx_gap THEN
        RETURN jsonb_build_object('card_lines', jsonb_build_array(jsonb_build_object(
            'kind', 'note', 'value', 'finance.note.goal_depot_risk_fx')));
    END IF;

    IF s.needs_acceptance OR (p_force AND v_held AND NOT s.accepted) THEN
        v_limit  := CASE WHEN s.active_plan THEN GREATEST(s.target_amount, s.depot_share_eur) ELSE s.depot_share_eur END;
        v_final  := current_date >= s.final_check_date;
        RETURN jsonb_build_object(
            'card_lines', jsonb_build_array(jsonb_build_object(
                'kind', 'note',
                'value', CASE WHEN v_final THEN 'finance.note.goal_depot_risk_final' ELSE 'finance.note.goal_depot_risk' END,
                'params', jsonb_build_object(
                    'months', core.fn_ui_num(s.months_left),
                    'month', core.fn_ui_month(s.target_date, true),
                    'allowed', core.fn_ui_money(floor(s.allowed_depot_eur), 'EUR', false, true),
                    'stress_pct', core.fn_ui_num(s.stress_pct),
                    'stress_loss', core.fn_ui_money(s.stress_loss_eur, 'EUR', false, true),
                    'reminder', core.fn_ui_month(s.final_check_date, true)))),
            'card_approve_key', 'finance.hitl.accept_depot_risk',
            'effective', jsonb_build_object('depot_risk_shown', jsonb_build_object(
                'target_date', to_char(s.target_date, 'YYYY-MM-DD'),
                'limit_eur', round(v_limit, 2),
                'allowed_eur', s.allowed_depot_eur)));
    END IF;

    IF v_held AND NOT s.accepted THEN
        RETURN jsonb_build_object('card_lines', jsonb_build_array(jsonb_build_object(
            'kind', 'note', 'value', 'finance.note.goal_derisk_window',
            'params', jsonb_build_object('month', core.fn_ui_month(s.target_date, true)))));
    END IF;
    RETURN jsonb_build_object('card_lines', '[]'::jsonb);
END;
$$;
