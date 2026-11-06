-- ============================================================
-- finance.fn_savings_goal_pace(p_goal_id int) — die EINE Ampel-Regel eines Sparziels (2026-10-28)
--   Konsumenten: Mini-App-Bildschirm „Ziele" (finance.fn_app_screen_goals: Pill, Balken, Banner) und der Berater
--   (finance.fn_advisor_review, Pace-Alert). Fakten aus finance.savings_goal_progress (DB rechnet, kein Aufrufer).
--   Zustand eines AKTIVEN Ziels, erste passende Regel gewinnt:
--     1. unmeasurable  NOT progress_measurable (laufende Rate ohne Topf; gilt auch fuer eine Ruecklage)
--     2. NULL          Instandhaltungsruecklage (target_amount NULL, Form-CHECK finance_savings_goals_shape)
--     3. behind        pace_drift_pp > core.config core/advisor/drift_pace_pp (Default 10)
--     4. reached       current_amount >= target_amount
--     5. paused        das Ziel hat eine Spar-Quelle (Raten-Kette recurring_payment_id oder verknuepfter Sparplan) und
--                      keine davon ist aktiv und nicht beendet (Glied der Kette: status active, valid_to offen/kuenftig;
--                      Sparplan: status active). Ein noch laufender Vorgaenger oder eine erst kuenftig startende Rate
--                      ist NICHT pausiert.
--     6. on_track      sonst
--   Nicht aktives oder unbekanntes Ziel -> NULL.
--   Reihenfolge bewusst: behind VOR reached/paused, damit behind <=> (aktiv AND pace_drift_pp > Toleranz) exakt der
--   frueheren Berater-Bedingung entspricht (auch bei negativer Toleranz); unmeasurable <=> NOT progress_measurable.
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
    SELECT p.status, p.progress_measurable, p.target_amount, p.current_amount, p.pace_drift_pp, p.recurring_payment_id
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
        RETURN 'behind';
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
