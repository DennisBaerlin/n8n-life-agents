-- ============================================================
-- finance.account_everyday_spending (Lese-View)
--   Geschaetzte Alltagsausgaben (Einkauf, Karte, Bargeld) je aktivem Geld-Konto aus den eingespielten Kontoauszuegen
--   (finance.fn_account_everyday_per_day.per_day = nur Abgaenge, dieselbe Zahl wie die Konto-Vorschau fn_account_outlook),
--   je Tag und je Monat (x fn_days_per_month aus dem ungerundeten Tageswert per_day_raw, einmal gerundet). Diese Ausgaben
--   stehen nicht in monthly_cashflow_* (die kennen nur regelmaessige Zahlungen) -> der Berater nennt sie bei
--   Leistbarkeits-Fragen, statt monthly_free als „bleibt uebrig" zu lesen, und rechnet die Monatszahl nie selbst.
--   Die Spar-Deckung (fn_account_funding) nutzt bewusst die Netto-Schaetzung per_day_net (24-Monats-Hochrechnung),
--   daher kann ihre Zahl abweichen.
--   Ohne Auszug (has_history false) sind beide Werte NULL: unbekannt, nicht 0. provisional = nur ein Auszug (der
--   frueheste, meist vor den Dauerauftraegen eingelesen) -> Schaetzung vorlaeufig, eher zu hoch.
--   Eine Signatur-Aenderung der fn braucht DROP ... CASCADE dieser View (Neuanlage steht hier).
--   Bewusst eigene Datei (R__v_*, sortiert nach R__fn_*) und nur Tabellen + Funktionen (Muster R__v_savings_plan_overview).
--   Rechte: finance_ro per GRANT SELECT ON ALL TABLES (core.fn_provision_package_roles).
-- ============================================================
DROP VIEW IF EXISTS finance.account_everyday_spending CASCADE;
CREATE VIEW finance.account_everyday_spending AS
SELECT a.id                                     AS account_id,
       a.name                                   AS account_name,
       a.owner_person_id,
       a.currency,
       e.has_history,
       CASE WHEN e.has_history THEN e.per_day END AS everyday_per_day,
       CASE WHEN e.has_history THEN round(e.per_day_raw * finance.fn_days_per_month(), 2) END AS everyday_per_month,
       e.provisional
FROM finance.accounts a
CROSS JOIN LATERAL finance.fn_account_everyday_per_day(a.id) e
WHERE a.status = 'active' AND a.account_type = 'cash';
