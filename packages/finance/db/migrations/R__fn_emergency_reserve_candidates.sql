-- ============================================================
-- fn_emergency_reserve_candidates (READ, STABLE) -- Konten, die Notreserve-Geld aufnehmen koennen, mit freiem Betrag
--   Fuer das Onboarding/Zuordnen im Buchhalter (Live-Befund 2026-10-30: er bot Kinderkonten an und merkte das ganze
--   Guthaben eines Kontos vor, ueber das ein Sparplan laeuft — der Stand sank danach jeden Monat unter die Vormerkung).
--   Konten = fn_emergency_reserve_account_ok (aktiv, Geld-Konto, kein Kinderkonto), nach Name.
--   free_eur = das Kleinere aus
--     (a) heute frei: fn_account_free_balance (derselbe Guard wie fn_book_savings_reservation) und
--     (b) frei am tiefsten vorausgesagten Stand: fn_account_outlook.min_projected minus die schon vorgemerkten Anteile
--         (Saldo - freier Saldo) — Sparplan-/Dauerauftrags-Abgaenge bis zum naechsten Geldeingang sind kein Notgroschen;
--   nie unter 0, in EUR (fn_to_eur, heute); ohne Kurs NULL. low_date = Tag des tiefsten Stands, nur wenn (b) begrenzt.
--   Eigene fn (nicht in fn_emergency_reserve_status): die Vorschau je Konto braucht nur der Buchhalter.
--   RUECKGABE jsonb: [{name, free_eur, low_date}]
--   Tests: tests/db/finance/test_fn_emergency_reserve_status.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_emergency_reserve_candidates()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_out  JSONB := '[]'::jsonb;
    r      RECORD;
    v_free NUMERIC;
    v_bal  NUMERIC;
    v_o    JSONB;
    v_low  NUMERIC;
    v_date DATE;
BEGIN
    FOR r IN SELECT a.id, a.name, a.currency FROM finance.accounts a
              WHERE finance.fn_emergency_reserve_account_ok(a.id) ORDER BY a.name, a.id LOOP
        v_free := finance.fn_account_free_balance(r.id);
        SELECT b.balance INTO v_bal FROM finance.account_balances b WHERE b.account_id = r.id;
        v_o := finance.fn_account_outlook(r.id);
        v_low := NULL; v_date := NULL;
        IF (v_o->>'ok')::boolean AND v_o->>'min_projected' IS NOT NULL THEN
            v_low := (v_o->>'min_projected')::numeric - (COALESCE(v_bal, 0) - COALESCE(v_free, 0));
            IF v_low < COALESCE(v_free, 0) THEN
                v_date := (v_o->>'min_date')::date;
            END IF;
        END IF;
        v_out := v_out || jsonb_build_object('name', r.name,
            'free_eur', finance.fn_to_eur(GREATEST(LEAST(COALESCE(v_free, 0), COALESCE(v_low, v_free, 0)), 0), r.currency),
            'low_date', v_date);
    END LOOP;
    RETURN v_out;
END;
$$;
