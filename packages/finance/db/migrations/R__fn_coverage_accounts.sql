-- ============================================================
-- fn_coverage_accounts (READ, STABLE) -- die Konten, fuer die eine Deckungs-Vorschau (fn_account_outlook) bewertet wird
--   Regel an EINER Stelle: aktives cash-Konto mit mindestens einem eingespielten Kontoauszug. Ohne Auszug fehlt die
--   Schaetzung der Alltagsausgaben -> keine Ampel auf Halbwissen (ein Kinderkonto mit 50 stuende sonst dauerhaft rot).
--   Konsumenten: fn_advisor_review (Warnung account_coverage), fn_app_screen_payments (Kontovorschau der Mini-App).
--   RUECKGABE: SETOF account_id
--   Tests: tests/db/finance/test_fn_account_outlook.sql (Berater), tests/db/finance/test_fn_app_screen_payments.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_coverage_accounts()
RETURNS SETOF int
LANGUAGE sql STABLE AS $$
    SELECT a.id
    FROM finance.accounts a
    WHERE a.status = 'active' AND a.account_type = 'cash'
      AND EXISTS (SELECT 1 FROM finance.bank_statements b WHERE b.account_id = a.id)
    ORDER BY a.id;
$$;
