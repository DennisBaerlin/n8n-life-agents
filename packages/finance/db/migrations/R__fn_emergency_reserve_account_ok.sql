-- ============================================================
-- fn_emergency_reserve_account_ok (READ, STABLE) -- darf dieses Konto Notreserve-Geld halten? (2026-10-30)
--   Die EINE Adresse der Konto-Regel der Notreserve: aktiv, Kontotyp aus fn_emergency_reserve_account_types (Geld-Konto:
--   sofort verfuegbar, einlagengesichert) und KEIN Kinderkonto (Haushalts-Notreserve, Eltern-Blick wie
--   fn_liquidity_snapshot). Live-Befund 2026-10-30: der Buchhalter bot Kinderkonten an — der Prompt ist nur Komfort,
--   das Gesetz steht hier und in jeder Write-fn, die es fragt.
--   Konsumenten: fn_emergency_reserve_covered (Deckung), fn_emergency_reserve_status (candidates),
--   fn_create_savings_goal / fn_set_savings_goal / fn_book_savings_reservation (Ablehnung als {ok:false}).
--   Tests: tests/db/finance/test_fn_emergency_reserve_status.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_emergency_reserve_account_ok(p_account_id int)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT a.status = 'active'
               AND a.account_type = ANY (finance.fn_emergency_reserve_account_types())
               AND NOT EXISTS (SELECT 1 FROM core.fn_household_persons() hp
                                WHERE hp.person_id = a.owner_person_id AND hp.role = 'child')
          FROM finance.accounts a WHERE a.id = p_account_id), false);
$$;
