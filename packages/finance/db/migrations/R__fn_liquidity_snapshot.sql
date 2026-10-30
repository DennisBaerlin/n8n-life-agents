-- ============================================================
-- finance.fn_liquidity_snapshot (WS-5 — Provider-Lesefenster fuer die career-Runway-Bruecke)
--   Publizierte, provider-eigene Lese-fn (docs/package-contract.md "Cross-package reads / provides.reads"):
--   liefert das FREIE Cash + die monatlichen Pflichtausgaben/Einnahmen, aus denen der career-Renderer die
--   Runway ("kann ich mir den Jobwechsel leisten?") rechnet. finance besitzt die BERECHNUNG (Domaene),
--   career besitzt die Runway-Mathe (career.fn_runway). Audit Paket 3: auch fn_advisor_review liest
--   Notreserve-Cash + Monatsbasis HIER (eine Adresse statt zwei Summen).
--
--   PLAIN STABLE, KEIN SECURITY DEFINER, KEIN Grant: career liest sie NICHT unter career_ro, sondern der
--   career-Renderer (career.fn_render_career_planning -> career.fn_runway) ruft sie render-at-fetch IM
--   core.fn_fetch_context-DEFINER-Kontext (Owner=Superuser) auf -> Schema-Read OHNE neuen Grant (Oberflaeche A
--   der WS-5-arch-challenge). Eine spaetere interaktive Variante C (Tool unter career_ro) wuerde dieselbe fn
--   als SECURITY DEFINER + Grant exponieren.
--
--   RAISE-FREI + alles COALESCE'd: die fn laeuft IM Render-Fetch -> ein RAISE braeche den ganzen
--   load_context-Abruf ab. Die Summary-Views sind bare Aggregate (immer 1 Zeile).
--
--   FREIES CASH (Audit Paket 3; Verbraucherzentrale/Finanztip: Notreserve aufs Tagesgeld, nicht in Aktien):
--   aktive account_type='cash'-Konten OHNE kind-besessene (core.fn_household_persons(), publiziertes Fenster),
--   je Konto abzueglich der fuer aktive Sparziele reservierten Summe (account_reserve_status.reserved), hoechstens
--   bis zum positiven Saldo: balance - LEAST(GREATEST(reserved,0), GREATEST(balance,0)). reserved = Ziel-Anteile
--   (getaggt + zugeordnet, savings_goal_account_share); ein negativer Anteil zaehlt 0 -> blaeht das freie Cash nie auf.
--   earmarked_eur = Summe des Abgezogenen. Ein als Sparziel gefuehrter Notgroschen zaehlt damit bewusst NICHT
--   als freie Reserve (goal_type ist Freitext; der Notgroschen gehoert in den Planfakt emergency_reserve).
--
--   PFLICHT-BASIS: monthly_expenses_eur (Key consumer-stabil fuer career.fn_runway) = fixed_expenses_eur +
--   everyday_eur. fixed = |monthly_obligations| aus parent_cashflow_summary = Konsum + Kreditrate (inkl. Tilgung;
--   laeuft im Notfall weiter), OHNE Sparraten (ruhend stellbar). everyday = geschaetzte Alltagsausgaben je Monat aus
--   den Kontoauszuegen (finance.fn_household_everyday_month; seit 2026-10-30 eingerechnet, Owner-Entscheid — vorher
--   fehlten Einkauf/Karte und Notreserve-Ziel/Runway wirkten zu rosig; 0 ohne Kontoauszug). Eltern-Blick = derselbe
--   Scope wie das freie Cash ohne Kinderkonten.
--
--   RUECKGABE jsonb: { cash_eur, earmarked_eur, monthly_expenses_eur (>=0, ABS), fixed_expenses_eur, everyday_eur,
--   everyday_accounts, everyday_provisional, monthly_income_eur, has_data, has_fx_gap }. has_fx_gap = true, wenn ein
--   AKTIVES Cash-Konto mit Guthaben in einer Fremdwaehrung OHNE FX-Kurs liegt (balance_eur IS NULL -> still 0) ODER ein
--   laufender Dauerauftrag bzw. eine Alltags-Schaetzung ohne Kurs in der Pflicht-Basis fehlt. career.fn_runway reicht
--   das Flag durch, der Renderer warnt.
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_liquidity_snapshot.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_liquidity_snapshot()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'cash_eur',             c.cash_eur,
        'earmarked_eur',        c.earmarked_eur,
        'monthly_expenses_eur', m.monthly_expenses_eur + abs(e.monthly_everyday),
        'fixed_expenses_eur',   m.monthly_expenses_eur,
        'everyday_eur',         abs(e.monthly_everyday),
        'everyday_accounts',    e.accounts,
        'everyday_provisional', e.provisional,
        'monthly_income_eur',   m.monthly_income_eur,
        'has_data',             (c.cash_eur > 0 OR m.monthly_income_eur > 0 OR m.monthly_expenses_eur > 0),
        'has_fx_gap',           (c.has_fx_gap OR m.has_fx_gap OR e.has_fx_gap)
    )
    FROM (
        SELECT COALESCE(sum(finance.fn_to_eur(x.balance - x.held, x.currency)), 0) AS cash_eur,
               COALESCE(sum(finance.fn_to_eur(x.held, x.currency)), 0)             AS earmarked_eur,
               COALESCE(bool_or(x.currency <> 'EUR' AND x.balance <> 0 AND x.balance_eur IS NULL), false) AS has_fx_gap
        FROM (
            SELECT a.currency,
                   COALESCE(a.balance, 0) AS balance,
                   a.balance_eur,
                   LEAST(GREATEST(COALESCE(r.reserved, 0), 0), GREATEST(COALESCE(a.balance, 0), 0)) AS held
            FROM finance.account_overview a
            LEFT JOIN finance.account_reserve_status r ON r.account_id = a.id
            LEFT JOIN core.fn_household_persons() hp ON hp.person_id = a.owner_person_id
            WHERE a.status = 'active' AND a.account_type = 'cash'
              AND hp.role IS DISTINCT FROM 'child'
        ) x
    ) c
    CROSS JOIN (
        -- bares Aggregat -> immer genau 1 Zeile (Summen COALESCE'd in der View); Pflichtausgaben ABS (>=0)
        SELECT ABS(monthly_obligations) AS monthly_expenses_eur,
               monthly_income           AS monthly_income_eur,
               has_fx_gap
        FROM finance.parent_cashflow_summary
    ) m
    CROSS JOIN finance.fn_household_everyday_month() e;
$$;
