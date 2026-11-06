-- ============================================================
-- V033 (finance) — Notreserve: Plan-Block emergency_reserve aus gespeicherten Plaenen entfernen.
--
--   WARUM (Transparenz 2026-10-30, ein Fakt eine Adresse): die Notreserve ist jetzt eine Ruecklage (Sparziel kind
--   emergency_reserve; Ziel, Basis und Deckung in finance.fn_emergency_reserve_status). Der Validator
--   fn_validate_financial_planning weist den alten Block ab. fn_advisor_publish_plan merged den Draft auf den
--   BESTEHENDEN Sidecar — stuende der Block dort noch, scheiterte jeder spaetere Publish am Validator.
--
--   Muster V007/V028: waehrend dieser V ist noch der ALTE Validator installiert (R__ laeuft danach) -> das Entfernen
--   passiert ihn. Entfernt (1) den Block aus dem Sidecar financial_planning.metadata.facts und (2) aus den Sektions-
--   Daten offener Drafts (interview_state.<section>.data). Veroeffentlichte Versionen bleiben Historie (sie werden nie
--   neu komponiert). Ein frueheres Monats-Ziel geht damit verloren — der Berater fragt es im Read-back der Sektion neu
--   ab und der Buchhalter legt die Ruecklage an. Frische DB = keine Zeile -> No-op. Re-run-sicher.
-- ============================================================

UPDATE agent.core_contexts
SET metadata = jsonb_set(metadata, '{facts}', (metadata->'facts') - 'emergency_reserve')
WHERE name = 'financial_planning'
  AND jsonb_typeof(metadata->'facts') = 'object'
  AND (metadata->'facts') ? 'emergency_reserve';

UPDATE agent.advisor_plans ap
SET interview_state = (
    SELECT jsonb_object_agg(s.key,
               CASE WHEN jsonb_typeof(s.value->'data') = 'object' AND (s.value->'data') ? 'emergency_reserve'
                    THEN jsonb_set(s.value, '{data}', (s.value->'data') - 'emergency_reserve')
                    ELSE s.value END)
    FROM jsonb_each(ap.interview_state) s)
WHERE ap.domain = 'finance' AND ap.status = 'draft'
  AND jsonb_typeof(ap.interview_state) = 'object'
  AND EXISTS (SELECT 1 FROM jsonb_each(ap.interview_state) s
               WHERE jsonb_typeof(s.value->'data') = 'object' AND (s.value->'data') ? 'emergency_reserve');
