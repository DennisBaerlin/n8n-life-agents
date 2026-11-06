-- ============================================================
-- fn_emergency_reserve_covered (READ, STABLE) -- gedecktes Notreserve-Geld je Konto in EUR (2026-10-30)
--   Die EINE Adresse fuer „wie viel der Notreserve ist wirklich da“: je zulaessigem Konto
--   (fn_emergency_reserve_account_ok: aktiv, Geld-Konto, kein Kinderkonto) der Anteil der aktiven Notreserve
--   (savings_goal_account_share), hoechstens der positive Saldo NACH den Anteilen der anderen aktiven Ziele auf demselben
--   Konto. Die Notreserve steht im Rang nach den normalen Zielen (konservativ, kein Saldo zaehlt doppelt); fliesst Geld
--   ab, schrumpft die Deckung von selbst (Monarch „Allocated vs. Available“, arch-challenge 2026-10-30).
--   Konsumenten: fn_emergency_reserve_status (Deckung, Konten), fn_liquidity_snapshot (emergency_eur; Runway zaehlt sie
--   als verfuegbar).
--   RUECKGABE: (account_id, account_name, share_eur, covered_eur, fx_gap) je Konto mit Notreserve-Anteil > 0
--   Tests: tests/db/finance/test_fn_emergency_reserve_status.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_emergency_reserve_covered()
RETURNS TABLE(account_id int, account_name text, share_eur numeric, covered_eur numeric, fx_gap boolean)
LANGUAGE sql STABLE AS $$
    WITH s AS (
        SELECT sh.account_id, sh.account_name, g.kind, sh.share_eur
          FROM finance.savings_goal_account_share sh
          JOIN finance.savings_goals g ON g.id = sh.goal_id
         WHERE sh.goal_status = 'active'
           AND finance.fn_emergency_reserve_account_ok(sh.account_id)
    ), a AS (
        SELECT s.account_id, max(s.account_name) AS account_name,
               COALESCE(sum(s.share_eur) FILTER (WHERE s.kind = 'emergency_reserve'), 0) AS em,
               COALESCE(sum(GREATEST(s.share_eur, 0)) FILTER (WHERE s.kind <> 'emergency_reserve'), 0) AS other
          FROM s GROUP BY s.account_id
    )
    SELECT a.account_id, a.account_name::text, round(a.em, 2),
           round(LEAST(a.em, GREATEST(COALESCE(o.balance_eur, 0) - a.other, 0)), 2),
           (o.balance_eur IS NULL AND COALESCE(o.balance, 0) <> 0)
      FROM a
      JOIN finance.account_overview o ON o.id = a.account_id
     WHERE a.em > 0;
$$;
