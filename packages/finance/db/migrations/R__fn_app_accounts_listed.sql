-- ============================================================
-- fn_app_accounts_listed (READ, STABLE) -- die Konten, die der Mini-App-Tab „Konten“ fuer eine Person zeigt
--   Die EINE Regel (UX-Gesamtkonzept 2026-10-31, 5.2/P10): aktive Geld-Konten (cash, fixed_deposit, p2p); wer den
--   Haushalt sieht (core.fn_app_sees_household), sieht alle ohne die Konten der Kinder (die stehen unter „Vermoegen der
--   Kinder“, ihre Sparplan-Frage beantwortet die Ziele-Seite); jede andere Rolle nur eigene (owner_person_id = ich).
--   Ob ein Konto ohne Saldo und ohne Bewegung entfaellt, entscheidet der Bildschirm (Anzeige, nicht Zugehoerigkeit).
--   Konsumenten: finance.fn_app_screen_accounts; finance.fn_app_screen_goals (Konto-Banner nur fuer Konten, die hier
--   NICHT stehen, z. B. Taschengeldkonten der Kinder in der Haushalts-Sicht).
--   RUECKGABE: SETOF account_id
--   Tests: tests/db/finance/test_fn_app_screen_accounts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_accounts_listed(p_person_id text)
RETURNS SETOF int
LANGUAGE sql STABLE AS $$
    SELECT a.id
      FROM finance.accounts a
      LEFT JOIN core.fn_household_persons() hp ON hp.person_id = a.owner_person_id
     WHERE a.status = 'active'
       AND a.account_type::text IN ('cash', 'fixed_deposit', 'p2p')
       AND CASE WHEN core.fn_app_sees_household(p_person_id) THEN hp.role IS DISTINCT FROM 'child'
                ELSE a.owner_person_id IS NOT DISTINCT FROM p_person_id END
       AND p_person_id IS NOT NULL;
$$;
