-- ============================================================
-- fn_savings_goal_derisk_status (READ, STABLE) — Glide Path + bewusste Risiko-Entscheidung je Sparziel
--   Umschicht-Hilfe vor dem Zieldatum (Sparziel-Zweckbindung 2026-10-27; Muster Zieldatum-Fonds "Glide Path" bzw.
--   Ablaufmanagement von Rentenvertraegen): je AKTIVEM Sparziel (kind='goal'; Ruecklagen haben eigene, harte
--   Konto-Regeln) mit Depot-Anteil (savings_goal_account_share, Depot-Typen, EUR) ODER aktivem Sparplan darf im Fenster
--   vor dem Zieldatum linear immer weniger im Depot liegen, am Zieldatum 0:
--     months_left       = Kalendermonate von heute bis zum Zieldatum (>= 0)
--     allowed_depot_eur = Ziel * min(months_left / Fenster, 1)
--     excess_eur        = max(Depot-Anteil - erlaubt, 0)   (= Vorschlagsbetrag zum Umschichten)
--     in_window         = Zieldatum in der Zukunft und fn_goal_in_derisk_window (die eine Adresse der Fenster-Regel)
--     breach            = in_window und Depot-Anteil > erlaubt + Toleranz (pp des Ziels)
--     active_plan       = ein aktiver Sparplan finanziert das Ziel (kauft weiter ins Depot)
--   BEWUSSTE AUSNAHME (2026-11-06, Tabelle finance.savings_goal_risk_decisions, letzter Eintrag zaehlt):
--     final_check_date   = Zieldatum - advisor.derisk_accepted_final_months (12): Ablauf einer Entscheidung = der
--                          letzte Check (eine Erinnerung im letzten Jahr, kein zweiter Mechanismus)
--     accepted           = letzter Eintrag 'accept' UND Zieldatum >= Snapshot-Datum UND Depot-Anteil <= limit_eur
--                          (eingezahlte EUR, nie Marktwert: Kurse heben die Entscheidung nie auf) UND (heute vor dem
--                          Ablauf ODER entschieden erst nach dem Ablauf-Stichtag -> gilt bis zum Termin)
--     acceptance_expired = letzter Eintrag 'accept', Lage nicht schlechter, nur der Ablauf greift
--     accepted_on/limit_eur = Datum bzw. Grenze des letzten 'accept' (NULL sonst)
--     needs_acceptance   = breach UND NOT accepted UND NOT fx_gap (die Schwelle des Beraters, Leitung 2026-11-06)
--     headroom_eur       = max(erlaubt - Anteil, 0), Cent-genau; headroom_eur_whole = floor(headroom_eur): der EINE
--                          Betrag, den der Buchhalter nach "Abbrechen" anbietet (abgerundet landet ein befolgter Rat
--                          nie ueber dem Rat; Rundung nur hier bewusst, Leitung 2026-11-06)
--     stress_loss_eur    = Anteil * stress_pct / 100 (Beispiel-Verlust, Cent wie jede _eur-Groesse); stress_pct =
--                          advisor.derisk_stress_pct (die eine Adresse des Prozentsatzes fuer Karte und Text)
--     fx_gap             = ein Depot-Bein des Ziels ohne Wechselkurs (der Anteil waere zu niedrig) -> keine
--                          Entscheidung festhalten (needs_acceptance false, der Fold zeigt nur einen Hinweis)
--   p_goal (opt): nur dieses Ziel (Fold-Bedingung "billig": eine Zeile im Schreib-Pfad); NULL = alle.
--   Fenster/Toleranz/Ablauf/Stress aus core.config advisor.derisk_window_months / derisk_tolerance_pp /
--   derisk_accepted_final_months / derisk_stress_pct (COALESCE 60 / 10 / 12 / 30). Bewusst eine fn, keine View
--   (Config zur Laufzeit); INVOKER genuegt: finance_ro darf core.fn_config_get (test_role_permissions).
--   Konsumenten: fn_advisor_review (2b'), fn_goal_depot_risk_fold, fn_advisor_snapshot (depot_risk), Buchhalter
--   (headroom_eur_whole nach "Abbrechen", postgres_select).
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_savings_goal_derisk_status();
DROP FUNCTION IF EXISTS finance.fn_savings_goal_derisk_status(int);
CREATE FUNCTION finance.fn_savings_goal_derisk_status(p_goal int DEFAULT NULL)
RETURNS TABLE (goal_id int, name text, target_date date, target_amount numeric, months_left int, window_months int,
               depot_share_eur numeric, allowed_depot_eur numeric, excess_eur numeric, in_window boolean, breach boolean,
               active_plan boolean, accepted boolean, accepted_on date, limit_eur numeric, acceptance_expired boolean,
               needs_acceptance boolean, final_check_date date, headroom_eur numeric, headroom_eur_whole numeric,
               stress_loss_eur numeric, fx_gap boolean, stress_pct numeric)
LANGUAGE plpgsql   -- late-bound: core.fn_config_get (anderes Paket) muss beim CREATE noch nicht existieren
STABLE
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH cfg AS (
        SELECT GREATEST(COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_window_months'), '')::int, 60), 1) AS win,
               COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_tolerance_pp'), '')::numeric, 10)      AS tol,
               GREATEST(COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_accepted_final_months'), '')::int, 12), 0) AS fin,
               GREATEST(COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_stress_pct'), '')::numeric, 30), 0) AS stress
    ), dep AS (
        SELECT s.goal_id, sum(s.share_eur) AS share, bool_or(s.has_fx_gap) AS fx_gap
        FROM finance.savings_goal_account_share s
        WHERE s.goal_status = 'active' AND s.account_type IN ('stocks_depot', 'crypto_depot')
          AND (p_goal IS NULL OR s.goal_id = p_goal)
        GROUP BY s.goal_id
    ), plan AS (
        SELECT DISTINCT sp.savings_goal_id AS goal_id
        FROM finance.savings_plans sp   -- "laeuft gerade" = active_recurring_payments (nie Status roh)
        JOIN finance.active_recurring_payments a ON a.id = sp.recurring_payment_id
        WHERE sp.savings_goal_id IS NOT NULL AND (p_goal IS NULL OR sp.savings_goal_id = p_goal)
    ), base AS (
        SELECT g.id, g.name::text AS name, g.target_date, g.target_amount, COALESCE(d.share, 0) AS share,
               COALESCE(d.fx_gap, false) AS fx_gap, (pl.goal_id IS NOT NULL) AS has_plan, c.win, c.tol, c.fin, c.stress,
               GREATEST((EXTRACT(YEAR FROM g.target_date)::int * 12 + EXTRACT(MONTH FROM g.target_date)::int)
                        - (EXTRACT(YEAR FROM current_date)::int * 12 + EXTRACT(MONTH FROM current_date)::int), 0) AS months_left,
               (g.target_date - make_interval(months => c.fin))::date AS final_check
        FROM finance.savings_goals g
        LEFT JOIN dep d ON d.goal_id = g.id
        LEFT JOIN plan pl ON pl.goal_id = g.id
        CROSS JOIN cfg c
        WHERE g.status = 'active' AND g.kind = 'goal'
          AND (p_goal IS NULL OR g.id = p_goal)
          AND (COALESCE(d.share, 0) > 0 OR pl.goal_id IS NOT NULL OR COALESCE(d.fx_gap, false))   -- Kurs-Luecke: Zeile fuer den Hinweis
    ), calc AS (
        SELECT b.*, round(b.target_amount * LEAST(b.months_left::numeric / b.win, 1), 2) AS allowed,
               COALESCE(b.target_date > current_date AND finance.fn_goal_in_derisk_window(b.id), false) AS in_win,
               dec.event AS last_event, dec.decided_at, dec.target_date AS dec_date, dec.limit_eur AS dec_limit
        FROM base b
        LEFT JOIN LATERAL (
            SELECT d.event, d.decided_at, d.target_date, d.limit_eur
            FROM finance.savings_goal_risk_decisions d
            WHERE d.savings_goal_id = b.id
            ORDER BY d.decided_at DESC, d.id DESC
            LIMIT 1) dec ON true
    ), judged AS (
        SELECT c.*,
               COALESCE(c.in_win AND c.share > c.allowed + c.target_amount * c.tol / 100, false) AS brch,
               -- Lage nicht schlechter als bestaetigt (Datum nicht frueher, Anteil nicht ueber der Grenze)
               COALESCE(c.last_event = 'accept' AND c.target_date >= c.dec_date AND round(c.share, 2) <= c.dec_limit, false) AS holds,
               -- Zeit: vor dem Ablauf-Stichtag, oder erst danach entschieden (gilt dann bis zum Termin)
               COALESCE(current_date < c.final_check OR c.decided_at::date >= c.final_check, false) AS in_time
        FROM calc c
    )
    SELECT j.id, j.name, j.target_date, j.target_amount, j.months_left, j.win,
           round(j.share, 2), j.allowed, round(GREATEST(j.share - j.allowed, 0), 2), j.in_win,
           j.brch,
           j.has_plan,
           (j.holds AND j.in_time),
           CASE WHEN j.last_event = 'accept' THEN j.decided_at::date END,
           CASE WHEN j.last_event = 'accept' THEN j.dec_limit END,
           (j.holds AND NOT j.in_time),
           (j.brch AND NOT (j.holds AND j.in_time) AND NOT j.fx_gap),
           j.final_check,
           round(GREATEST(j.allowed - j.share, 0), 2),
           floor(GREATEST(j.allowed - j.share, 0)),
           round(j.share * j.stress / 100, 2),
           j.fx_gap,
           j.stress
    FROM judged j;
END;
$$;
