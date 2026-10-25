-- ============================================================
-- V028 (finance) — Finanzplan-Ziel: von Wunsch-Einkommen, Entnahmerate und Zielportfolio nur zwei speichern.
--
--   WARUM (WP2 "Finanzen schlank", Regel "Keine ableitbaren Spalten"): Zielportfolio = Einkommen x 12 / Entnahmerate --
--   wer alle drei speichert, kann widersprechen. Owner-Entscheid 2026-10-25: Einkommen + Rate bleiben (die Rohwerte des
--   Nutzers), das Zielportfolio leitet finance.fn_plan_goal_resolved ab (Anzeige + Review-Drift). Der Validator lehnt
--   ab jetzt alle drei zusammen ab.
--
--   Muster V007: nur wenn die financial_planning-Zeile Einkommen UND Rate traegt, faellt target_portfolio_eur (Zahl oder
--   [lo, hi]-Spanne) weg. Waehrend dieser V ist noch der ALTE Validator installiert (R__ laeuft danach); er prueft
--   target_portfolio_eur nicht -> das Entfernen passiert ihn. Frische DB = keine Zeile -> No-op. Re-run-sicher.
-- ============================================================

UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts,goal}', (metadata->'facts'->'goal') - 'target_portfolio_eur')
WHERE name = 'financial_planning'
  AND jsonb_typeof(metadata->'facts'->'goal') = 'object'
  AND (metadata->'facts'->'goal') ? 'target_portfolio_eur'
  AND (metadata->'facts'->'goal') ? 'target_income_eur_month'
  AND (metadata->'facts'->'goal') ? 'withdrawal_rate_pct';
