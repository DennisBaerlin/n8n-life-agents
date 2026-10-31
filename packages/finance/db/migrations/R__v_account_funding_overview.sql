-- ============================================================
-- finance.account_funding_overview (Lese-View, Berater-Nachruestung 2026-10-30)
--   „Reicht das Geld fuer meine Sparplaene?" — EINE Zeile je Deckungs-Konto (finance.fn_funding_accounts, dieselbe
--   Regel wie der Konten-Tab der Uebersicht) mit der Spar-Deckung aus finance.fn_account_funding (die eine Rechnung, Horizont
--   finance.funding_horizon_months, Ende = horizon_end). roles = die Rollen des Kontos als Liste (plan = zahlt einen Sparplan, order_source = Absender eines
--   Dauerauftrags): ein Konto mit beiden Rollen steht EINMAL da (sonst lief die Projektion doppelt und der Berater
--   meldete dasselbe Konto zweimal). Haushalts-Sicht ohne Personen-Filter (die Sichtbarkeit je Person macht nur die App).
--   Der Berater liest die Deckung hier und projiziert nie selbst.
--   Bewusst EIGENE Datei (R__v_*, sortiert nach R__fn_*) und nur Tabellen + Funktionen (Muster R__v_savings_plan_overview).
--   Rechte: finance_ro per GRANT SELECT ON ALL TABLES (core.fn_provision_package_roles); die fns sind INVOKER.
--   Kosten: je Konto EINE Projektion (~0,1 s) — fn_account_funding als Funktions-Scan im FROM; eine Unterabfrage ohne FROM
--   zoege der Planer hoch (STABLE) und riefe die Projektion je referenzierter Spalte neu. Nur auf Nachfrage gelesen.
-- ============================================================
DROP VIEW IF EXISTS finance.account_funding_overview CASCADE;
CREATE VIEW finance.account_funding_overview AS
SELECT f.account_id,
       a.name                                   AS account_name,
       f.roles,
       j.fu->>'currency'                        AS currency,
       j.fu->>'state'                           AS state,
       (j.fu->>'balance')::numeric              AS balance,
       (j.fu->>'monthly_in')::numeric           AS monthly_in,
       (j.fu->>'monthly_out')::numeric          AS monthly_out,
       j.fu->>'everyday'                        AS everyday,
       (j.fu->>'min_projected')::numeric        AS min_projected,
       (j.fu->>'min_date')::date                AS min_date,
       (j.fu->>'runs_out_on')::date             AS runs_out_on,
       (j.fu->>'horizon_end')::date             AS horizon_end,
       coalesce((j.fu->>'fx_gap')::boolean, FALSE) AS fx_gap
FROM (SELECT account_id, array_agg(DISTINCT kind ORDER BY kind) AS roles
      FROM finance.fn_funding_accounts()
      GROUP BY account_id) f
JOIN finance.accounts a ON a.id = f.account_id
CROSS JOIN LATERAL finance.fn_account_funding(f.account_id) AS j(fu);
