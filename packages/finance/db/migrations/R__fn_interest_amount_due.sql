-- ============================================================
-- fn_interest_amount_due (READ — Zins-Betrag am Perioden-Ende, DB rechnet, NIE das LLM)
--   Liefert den vorgeschlagenen Zinsbetrag fuer (Konto, period_end):
--     SUMME ueber alle Satz-Segmente: basis x (annual_rate/100) x fn_interest_day_fraction(seg_start, seg_end,
--     day_count_convention) — EINMAL um die Summe gerundet (nie Σ ROUND -> kein Cent-Drift).
--
--   period_start liefert finance.fn_interest_effective_period_start (EINE Regel mit fn_interest_due_open): Raster-Beginn
--     im Regime des letzten Periodentags (fn_interest_period_start, groesste Rastergrenze < period_end, nie
--     period_end MINUS Kadenz-Schritt -- das doppelt-zaehlte den dom=-1-Monatsletzten-Tail); die erste Periode nach einem
--     Rhythmuswechsel reicht bis zum letzten Rasterpunkt des alten Regimes zurueck (keine Gutschrift am Wechseltag,
--     Live-Befund 2026-10-24); nie vor der juengsten erledigten Periode (Schutz vor Doppelverzinsung).
--
--   Taggenaue Satz-Mischung (Phase Z WS-Z3): bei unterjaehrigem Satzwechsel wird die Periode an jedem
--     account_interest_rates.valid_from zerschnitten und jeder Satz nur auf SEINE Tage gerechnet (deutsche
--     Banken-Norm / Zinsstaffel; vorher galt der period_end-Satz fuer die ganze Periode). Segmentierung +
--     Satz-/Konvention-Zuordnung liefert fn_interest_rate_segments (Containment-Join auf die EXCLUDE-gist-
--     Tiling-Semantik). FAIL-CLOSED: die Segment-Tage muessen [period_start, period_end) lueckenlos decken
--     (Tiling-Garantie EXCLUDE-gist + Close-then-Insert) — eine Luecke = Datenkorruption -> RAISE statt
--     stiller Unterverzinsung. Jedes Segment nutzt SEINE eigene day_count_convention.
--
--   basis (B2, re-eval-robust): Saldo zum period_end (Summe aller Tx mit transaction_date <= period_end)
--     OHNE jede SCHEDULER-Zins-Tx mit interest_period_end >= period_end -> die eigene + jede spaetere
--     Gutschrift zaehlt nie in die eigene Basis (Re-Eval nach dem Buchen liefert denselben Betrag);
--     FRUEHERE Gutschriften zaehlen -> emergenter Zinseszins ueber den Saldo. Generische Zinseinnahmen
--     (interest_period_end IS NULL, z. B. via fn_book_transaction) zaehlen normal in die Basis.
--     basis ist KONSTANT ueber alle Segmente (Z3 segmentiert die SATZ-, nicht die Saldo-Dimension; intra-
--     period Ein-/Auszahlungen = bewusst out-of-scope, kein daily-balance-Staffelzins).
--     Nur Habensaldo (<=0 -> 0; Negativ-/Kreditzins = Gebuehr (category='fee'), bewusst NICHT auf dem
--     Zins-Pfad -> BGH 04.02.2025, s. packages/finance/CLAUDE.md Zins-Block).
-- ============================================================
-- Param-Umbenennung gegenueber WS-5c (p_due_date -> p_period_end): CREATE OR REPLACE kann Parameter nicht
-- umbenennen -> alte Signatur zuerst droppen. Idempotent (IF EXISTS); plpgsql-Caller (fn_book_interest_
-- occurrence) resolven den Namen zur Laufzeit neu, kein harter Abhaengigkeits-Bruch.
DROP FUNCTION IF EXISTS finance.fn_interest_amount_due(integer, date);
CREATE OR REPLACE FUNCTION finance.fn_interest_amount_due(p_account_id int, p_period_end date)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_reg          RECORD;
    v_period_start DATE;
    v_basis        NUMERIC;
    v_covered_days INT;
    v_interest     NUMERIC;
BEGIN
    -- Gibt es ein Regime am LETZTEN Periodentag (period_end - 1)? Sonst kein Zins. Der SATZ kommt je Segment
    -- (taggenaue Satz-Mischung, fn_interest_rate_segments), der Beginn aus fn_interest_effective_period_start.
    SELECT * INTO v_reg
      FROM finance.fn_interest_regimes(p_account_id) r
     WHERE r.regime_start <= p_period_end - 1
       AND (r.regime_end IS NULL OR p_period_end - 1 < r.regime_end)
     ORDER BY r.regime_start DESC
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN 0;   -- kein gueltiger Satz in der Periode
    END IF;

    -- Wirksamer Periodenbeginn, dieselbe Regel wie fn_interest_due_open (Raster; erste Periode nach einem Rhythmuswechsel
    -- ab dem letzten Rasterpunkt des alten Regimes; nie vor der juengsten erledigten Periode).
    v_period_start := finance.fn_interest_effective_period_start(p_account_id, p_period_end);

    -- basis (re-eval-robust): Saldo zum period_end ohne Scheduler-Zins-Tx mit interest_period_end >= period_end.
    SELECT COALESCE(SUM(amount), 0) INTO v_basis
      FROM finance.transactions
     WHERE account_id = p_account_id
       AND transaction_date <= p_period_end
       AND NOT (category = 'interest'
                AND interest_period_end IS NOT NULL
                AND interest_period_end >= p_period_end);

    IF v_basis <= 0 THEN
        RETURN 0;   -- nur Habensaldo verzinst
    END IF;

    -- Taggenaue Satz-Mischung: basis KONSTANT, Satz + Konvention je Segment; EINMAL um die Summe runden.
    -- Zugleich die Roh-Tage je Segment summieren -> Fail-closed-Deckungspruefung (Luecke -> RAISE).
    SELECT COALESCE(SUM(s.seg_end - s.seg_start), 0),
           ROUND(SUM(v_basis * (s.annual_rate / 100.0)
                     * finance.fn_interest_day_fraction(s.seg_start, s.seg_end, s.day_count_convention)), 2)
      INTO v_covered_days, v_interest
      FROM finance.fn_interest_rate_segments(p_account_id, v_period_start, p_period_end) s;

    IF v_covered_days <> (p_period_end - v_period_start) THEN
        RAISE EXCEPTION 'Interest period % .. % for account % is not fully covered by rate rows (gap in rate history).',
            v_period_start, p_period_end, p_account_id;
    END IF;

    RETURN COALESCE(v_interest, 0);
END;
$$;
