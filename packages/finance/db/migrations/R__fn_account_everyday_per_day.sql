-- ============================================================
-- fn_account_everyday_per_day (READ, STABLE) -- geschaetzte Alltagsausgaben je Tag eines Kontos aus seinen Auszuegen
--   Einzelumsaetze werden nicht gespeichert -> Schaetzung aus den GEZAEHLTEN Auszuegen von finance.fn_account_everyday_basis
--   (die eine Adresse der Auswahl: juengste 3, der frueheste Auszug zaehlt nicht, sobald ein spaeterer existiert —
--   Transparenz 2026-10-30), je neu abgeglichenem Tag, gerundet auf 2 Stellen; ohne Auszug 0.
--   per_day     = Summe (unmatched_out - oneoff_out) / Tage (nur Abgaenge ohne einmalige Grossausgaben, Owner-Entscheid
--                 2026-10-30; Kontovorschau bis zum naechsten Geldeingang)
--   per_day_net = (unmatched_out + unmatched_in) / Tage, hoechstens 0 (Spar-Deckung ueber 24 Monate: ohne die nicht
--                 zugeordneten Eingaenge faerbte die lineare Hochrechnung jedes Konto rot); einmalige Grossausgaben
--                 zaehlen hier bewusst MIT (ueber 24 Monate kommen sie wieder -> vorsichtig)
--   provisional = nur EIN Auszug vorhanden (der frueheste zaehlt mangels spaeterer) -> Schaetzung vorlaeufig, eher zu hoch.
--   Konsumenten: fn_account_outlook (per_day), fn_account_funding (per_day_net), View account_everyday_spending.
--   RUECKGABE: (per_day <= 0, per_day_net <= 0, has_history, provisional)
--   Rueckgabetyp geaendert 2026-10-30: das einmalige DROP (reisst die View account_everyday_spending mit) macht
--   finance:V034 — NIE hier (jede spaetere Aenderung nur dieser Datei verloere sonst die View still). Eine weitere
--   Signatur-Aenderung braucht wieder eine V-Migration + Aenderung der View-Datei.
--   Tests: tests/db/finance/test_fn_account_everyday_per_day.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_everyday_per_day(p_account_id int)
RETURNS TABLE(per_day numeric, per_day_net numeric, has_history boolean, provisional boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_out  NUMERIC;
    v_in   NUMERIC;
    v_oo   NUMERIC;
    v_days NUMERIC;
    v_n    INT;
BEGIN
    SELECT sum(b.unmatched_out) FILTER (WHERE b.counted), sum(b.unmatched_in) FILTER (WHERE b.counted),
           sum(b.oneoff_out) FILTER (WHERE b.counted), sum(b.days) FILTER (WHERE b.counted), count(*)
    INTO v_out, v_in, v_oo, v_days, v_n
    FROM finance.fn_account_everyday_basis(p_account_id) b;
    per_day     := round(COALESCE((v_out - v_oo) / NULLIF(v_days, 0), 0), 2);
    per_day_net := LEAST(round(COALESCE((COALESCE(v_out, 0) + COALESCE(v_in, 0)) / NULLIF(v_days, 0), 0), 2), 0);
    has_history := v_n > 0;
    provisional := v_n = 1;
    RETURN NEXT;
END;
$$;
