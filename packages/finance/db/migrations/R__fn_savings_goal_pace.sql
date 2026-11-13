-- ============================================================
-- fn_savings_goal_pace (READ, STABLE) — die eine Ampel-Regel eines Sparziels
--   Konsumenten: Mini-App-Bildschirm „Ziele" (finance.fn_app_screen_goals: Pill, Balken, Banner), der Berater
--   (finance.fn_advisor_review, Pace-Alert) und sein Schnappschuss (finance.fn_advisor_snapshot, goal_status).
--   Fakten aus finance.savings_goal_progress (DB rechnet, kein Aufrufer).
--   Eingabe: p_goal_id int (Pflicht). Rueckgabe: text (unmeasurable | behind | unknown | reached | paused | on_track)
--   oder NULL; keine ok-Huelle, keine Seiteneffekte.
--   Zustand eines aktiven Ziels, erste passende Regel gewinnt:
--     1. unmeasurable  NOT progress_measurable (laufende Rate ohne Topf; gilt auch fuer eine Ruecklage)
--     2. NULL          Instandhaltungsruecklage (target_amount NULL, Form-CHECK finance_savings_goals_shape)
--     3. behind        pace_drift_pp > core.config core/advisor/drift_pace_pp (Default 10), ohne Kurs-Luecke
--        unknown       dieselbe Bedingung mit has_fx_gap: ein Anteil liegt auf einem Konto in einer Waehrung
--                      ohne jeden Wechselkurs. Der gemessene Stand ist dann nur eine Untergrenze; eine Aussage bleibt
--                      nur gueltig, wenn sie nicht vom Fehlenden abhaengt (SQL-Dreiwertlogik). reached/paused/on_track
--                      haengen nicht davon ab (mehr Geld aendert sie nicht), behind schon -> nicht beurteilbar.
--                      Annahme: Summe der Luecken-Anteile je Ziel >= 0. Kein Constraint, die Write-fns sichern sie
--                      (fn_book_savings_reservation Betrag >= 0, fn_book_savings_goal_transfer Entnahme <= Anteil,
--                      fn_book_savings_goal_reassign fx_missing-Guard, fn_book_stock_buy). Vorbild-Name:
--                      finance.fn_depot_cover_state ('unknown' = nicht ermittelbar statt Fehldiagnose).
--     4. reached       current_amount >= target_amount
--     5. paused        das Ziel hat eine Spar-Quelle (Raten-Kette recurring_payment_id oder verknuepfter Sparplan) und
--                      keine davon ist aktiv und nicht beendet (Glied der Kette: status active, valid_to offen/kuenftig;
--                      Sparplan: status active). Ein noch laufender Vorgaenger oder eine erst kuenftig startende Rate
--                      ist nicht pausiert.
--     6. on_track      sonst
--   Nicht aktives oder unbekanntes Ziel -> NULL.
--   Reihenfolge bewusst: behind/unknown vor reached/paused, damit (behind OR unknown) <=> (aktiv AND pace_drift_pp >
--   Toleranz) exakt gilt (auch bei negativer Toleranz), unknown <=> zusaetzlich has_fx_gap;
--   unmeasurable <=> NOT progress_measurable. unknown meldet nie einen Alert (die Luecke meldet data_quality).
--   plpgsql (late-bound wie finance.fn_price_status): core.fn_config_get ist eine core-R__.
--   INVOKER, reiner Lese-Helfer (finance_ro bekommt ihn wie jede INVOKER-fn).
--   Tests: tests/db/finance/test_fn_savings_goal_pace.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_goal_pace(p_goal_id int)
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    r     record;
    v_tol numeric;
BEGIN
    SELECT p.status, p.progress_measurable, p.target_amount, p.current_amount, p.pace_drift_pp, p.recurring_payment_id,
           p.has_fx_gap
      INTO r
      FROM finance.savings_goal_progress p
     WHERE p.id = p_goal_id;
    IF NOT FOUND OR r.status <> 'active' THEN
        RETURN NULL;
    END IF;
    IF NOT r.progress_measurable THEN
        RETURN 'unmeasurable';
    END IF;
    IF r.target_amount IS NULL THEN
        RETURN NULL;
    END IF;
    v_tol := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'drift_pace_pp'), '')::numeric, 10);
    IF r.pace_drift_pp > v_tol THEN
        RETURN CASE WHEN r.has_fx_gap THEN 'unknown' ELSE 'behind' END;
    END IF;
    IF r.current_amount >= r.target_amount THEN
        RETURN 'reached';
    END IF;
    IF (r.recurring_payment_id IS NOT NULL
        OR EXISTS (SELECT 1 FROM finance.savings_plans sp WHERE sp.savings_goal_id = p_goal_id))
       AND NOT EXISTS (SELECT 1
                         FROM finance.fn_recurring_lineage(r.recurring_payment_id) lid
                         JOIN finance.recurring_payments rp ON rp.id = lid
                        WHERE rp.status = 'active'
                          AND (rp.valid_to IS NULL OR rp.valid_to > current_date))
       AND NOT EXISTS (SELECT 1 FROM finance.savings_plans sp
                        WHERE sp.savings_goal_id = p_goal_id AND sp.status = 'active') THEN
        RETURN 'paused';
    END IF;
    RETURN 'on_track';
END;
$$;
