-- ============================================================
-- fn_interest_accrued_preview (READ — aufgelaufener, noch nicht gebuchter Zins; Schaetzwert, kein Write)
--   Liefert den seit der LETZTEN Gutschrift bis p_as_of aufgelaufenen, noch nicht gebuchten Zins eines
--   Kontos: basis x (annual_rate/100) x fn_interest_day_fraction(aufzins_start, as_of, conv).
--     aufzins_start = juengstes gebuchtes Scheduler-Perioden-Ende (MAX interest_period_end <= as_of),
--                     sonst der Zins-Start MIN(valid_from).
--     basis = Saldo zum as_of (nur Habensaldo). Satz + Konvention = am as_of gueltige Rate-Zeile.
--   NUR fuer Anzeige/Advisor/HITL-Preview (kein Write, keine Tabelle). SCHAETZWERT: kann von der Summe der
--   tatsaechlich (gerundet) gebuchten Tagesgutschriften um Rundungscents abweichen (m3). Mischt zudem die
--   Saetze NICHT (ein Satz am as_of fuers ganze Aufzins-Fenster) -> bei unterjaehrigem Satzwechsel kann der
--   Preview von der segmentierten Gutschrift (fn_interest_amount_due, Phase Z WS-Z3) abweichen — bewusst:
--   Preview != Gutschrift, der gebuchte Betrag kommt aus fn_interest_amount_due, nicht aus dem Preview.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_accrued_preview(p_account_id int, p_as_of date)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_rate       NUMERIC;
    v_conv       TEXT;
    v_int_start  DATE;
    v_accr_start DATE;
    v_basis      NUMERIC;
BEGIN
    SELECT annual_rate, day_count_convention INTO v_rate, v_conv
      FROM finance.account_interest_rates
     WHERE account_id = p_account_id
       AND valid_from <= p_as_of AND (valid_to IS NULL OR p_as_of < valid_to)
     ORDER BY valid_from DESC LIMIT 1;
    IF v_rate IS NULL THEN RETURN 0; END IF;

    SELECT MIN(valid_from) INTO v_int_start
      FROM finance.account_interest_rates WHERE account_id = p_account_id;

    -- Aufzins-Start = juengstes gebuchtes Scheduler-Perioden-Ende <= as_of, sonst Zins-Start.
    SELECT COALESCE(MAX(interest_period_end), v_int_start) INTO v_accr_start
      FROM finance.transactions
     WHERE account_id = p_account_id AND category = 'interest'
       AND interest_period_end IS NOT NULL AND interest_period_end <= p_as_of;

    IF v_accr_start >= p_as_of THEN RETURN 0; END IF;   -- seit der letzten Gutschrift nichts aufgelaufen

    SELECT COALESCE(SUM(amount), 0) INTO v_basis
      FROM finance.transactions
     WHERE account_id = p_account_id AND transaction_date <= p_as_of;
    IF v_basis <= 0 THEN RETURN 0; END IF;

    RETURN ROUND(v_basis * (v_rate / 100.0) * finance.fn_interest_day_fraction(v_accr_start, p_as_of, v_conv), 2);
END;
$$;
