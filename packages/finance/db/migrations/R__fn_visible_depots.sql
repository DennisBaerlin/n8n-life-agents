-- ============================================================
-- finance.fn_visible_depots(p_household boolean, p_person_id text) — die sichtbaren Depots einer Sicht (READ)
--   EINE Adresse fuer „welche Depots zeigt eine Sicht, welche davon sind Kinder-Depots": aktive stocks_depot/crypto_depot;
--   p_household = true (Haushalts-Sicht, core.fn_app_sees_household) -> alle, kid = Inhaber hat role 'child'
--   (core.fn_household_persons); sonst nur Depots mit owner_person_id = p_person_id, kid immer false (der Betrachter
--   sieht seine eigene Summe). Konsumenten: finance.fn_app_screen_depot (Hero, Abschnitte, probe) und
--   finance.fn_depot_performance (Rendite je Depot, „Alle Depots" ohne Kinder) — dieselbe Auswahl, damit „Alle Depots"
--   und der Depotwert-Hero nie auseinanderlaufen.
--   INVOKER, PUBLIC-EXECUTE (liest finance.accounts + das publizierte Fenster core.fn_household_persons).
--   Tests: tests/db/finance/test_fn_app_screen_depot.sql, tests/db/finance/test_fn_depot_performance.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_visible_depots(p_household boolean, p_person_id text)
RETURNS TABLE (id int, name text, owner_person_id text, kid boolean)
LANGUAGE sql STABLE
AS $$
    SELECT a.id, a.name::text, a.owner_person_id::text, (p_household AND hp.role IS NOT DISTINCT FROM 'child') AS kid
      FROM finance.accounts a
      LEFT JOIN core.fn_household_persons() hp ON hp.person_id = a.owner_person_id
     WHERE a.status = 'active' AND a.account_type IN ('stocks_depot', 'crypto_depot')
       AND (p_household OR a.owner_person_id = p_person_id);
$$;
