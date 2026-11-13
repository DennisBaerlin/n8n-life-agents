-- ============================================================
-- fn_plan_readiness (READ, STABLE — Daten-Reife des Finanzplans fuer den Onboarding-Plan-Schritt)
--   Registry-Feld core.advisors.readiness_fn der Domain 'finance': sind die harten Mindestdaten fuer einen sinnvollen
--   Haushalts-Finanzplan erfasst? Der Plan-Knopf erscheint erst, wenn genug Finanzdaten da sind, sonst
--   eine Erlaeuterung, was zuerst fehlt (und ein Knopf auf genau diesen Onboarding-Abschnitt).
--   Pflicht (in dieser Reihenfolge, je Punkt der Abschnitt, in dem er erfasst wird):
--     accounts -> mindestens ein aktives Geld-Konto (account_type 'cash', status 'active')       [Abschnitt accounts]
--     income   -> mindestens eine laufende Einnahme   (recurring_cashflow_classified 'income')   [Abschnitt liabilities]
--     expenses -> mindestens eine laufende Ausgabe    (Klasse 'consumption' oder 'loan')         [Abschnitt liabilities]
--   "Laufend" + Klasse kommen allein aus finance.recurring_cashflow_classified (auch eine Zahlung, deren erster Termin
--   innerhalb eines Rhythmus aussteht; Transfers, Sparraten, pausierte, beendete und erst spaeter startende Zahlungen
--   zaehlen nicht). Versicherungen, Rente, Depots und Ziele sind bewusst keine Pflicht: ihre Luecken findet gerade
--   das Plan-Interview (risk_protection, retirement_pension).
--   Eingabe: p_domain/p_person_id = die einheitliche Registry-Signatur (wie gaps_fn); der Finanzplan ist haushaltsweit,
--   beide werden nicht ausgewertet.
--   Rueckgabe: jsonb { ready: bool, missing: [{key, section}, ...] } (missing leer gdw ready).
--   STABLE/INVOKER: Aufrufer sind core.fn_advisor_plan_status (SECURITY DEFINER, Menue/Knopf) und der Berater-Knoten
--   'Onboarding gate read' (agent.finance_advisor, Haupt-Cred wie der Rest dieses Knotens: liest core.config).
--   Tests: tests/db/finance/test_fn_plan_readiness.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_readiness(p_domain text, p_person_id text)
RETURNS jsonb
LANGUAGE sql STABLE
AS $$
    WITH chk AS (
        SELECT 1 AS ord, 'accounts' AS key, 'accounts' AS section,
               EXISTS (SELECT 1 FROM finance.accounts a WHERE a.account_type = 'cash' AND a.status = 'active') AS ok
        UNION ALL
        SELECT 2, 'income', 'liabilities',
               EXISTS (SELECT 1 FROM finance.recurring_cashflow_classified r WHERE r.cashflow_class = 'income')
        UNION ALL
        SELECT 3, 'expenses', 'liabilities',
               EXISTS (SELECT 1 FROM finance.recurring_cashflow_classified r WHERE r.cashflow_class IN ('consumption', 'loan'))
    )
    SELECT jsonb_build_object(
        'ready',   bool_and(ok),
        'missing', COALESCE(jsonb_agg(jsonb_build_object('key', key, 'section', section) ORDER BY ord) FILTER (WHERE NOT ok), '[]'::jsonb))
    FROM chk;
$$;
