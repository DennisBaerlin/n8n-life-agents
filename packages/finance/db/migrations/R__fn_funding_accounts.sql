-- ============================================================
-- fn_funding_accounts (READ, STABLE) -- die EINE Regel, welche Konten eine Spar-Deckungs-Ampel haben
--   Deckungs-Konto = aktives Nicht-Kredit-Konto, das (kind 'plan') einen aktiven Sparplan bezahlt (Konto des Glieds
--   fn_recurring_current) oder (kind 'order_source') ABSENDER eines Dauerauftrags ist (fn_standing_orders kind transfer
--   = Uebertrag auf ein eigenes Konto, debit = Spar-Abfluss ohne Ziel-Konto). UX-Gesamtkonzept 2026-10-31 (P12, Bug B2):
--   die Warnung gehoert an das Konto, das ausfuehrt; das Empfaengerkonto eines Uebertrags ist kein Deckungs-Konto (es ist
--   es nur, wenn es selbst einen Sparplan bezahlt oder weiterueberweist). Ein Gehaltskonto ohne diese Rolle bekommt keine
--   Ampel (seine Alltagsausgaben sind unbekannt).
--   Je Rolle eine Zeile (ein Konto kann mehrfach vorkommen); beneficiary_person_id + depot_owner_person_id nur bei
--   kind 'plan' -- die Regel selbst kennt keine Person.
--   Konsumenten: fn_account_low_state (Konten-Tab, Spiegel-Pille am Sparplan), fn_savings_funding_fold (Karten-Hinweis
--   + Frage), finance.account_funding_overview (Berater).
--   RUECKGABE: (account_id, kind, beneficiary_person_id, depot_owner_person_id)
--   Tests: tests/db/finance/test_fn_funding_accounts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_funding_accounts()
RETURNS TABLE(account_id int, kind text, beneficiary_person_id text, depot_owner_person_id text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT x.account_id, x.kind, x.beneficiary_person_id, x.depot_owner_person_id
      FROM (SELECT c.account_id, 'plan'::text AS kind, sp.beneficiary_person_id, d.owner_person_id AS depot_owner_person_id
              FROM finance.savings_plans sp
              JOIN finance.accounts d ON d.id = sp.depot_id
              JOIN finance.recurring_payments c ON c.id = finance.fn_recurring_current(sp.recurring_payment_id, current_date)
             WHERE sp.status = 'active'
            UNION ALL
            SELECT r.account_id, 'order_source', NULL::text, NULL::text
              FROM finance.fn_standing_orders() so
              JOIN finance.recurring_payments r ON r.id = so.rp_id
             WHERE so.kind IN ('transfer', 'debit')) x
      JOIN finance.accounts a ON a.id = x.account_id
     WHERE a.status = 'active' AND a.account_type <> 'loan';
END;
$$;
