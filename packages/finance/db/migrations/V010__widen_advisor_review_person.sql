-- ============================================================
-- V010 (finance) — die alte 2-Arg-Signatur finance.fn_advisor_review(text, jsonb) droppen.
--
--   WARUM eine V-Migration: CREATE OR REPLACE kann die ARITAET einer Function NICHT aendern. P2a faechert den
--   geteilten Advisor-Drift-Wrapper core.fn_advisor_review_evaluate pro Person und dispatcht uniform 3-arg an
--   ALLE registrierten <pkg>.fn_advisor_review (domain, person_id, observations). finance bleibt HAUSHALT und
--   IGNORIERT den person_id-Parameter (0 Verhaltensaenderung), muss aber die uniforme 3-Arg-Signatur tragen
--   (Rule of Three / 2. Dispatcher-Konsument = jetzt vereinheitlichen; der Wrapper kann nicht je Scope eine andere
--   Aritaet rufen). R__fn_advisor_review.sql legt jetzt finance.fn_advisor_review(text, text DEFAULT NULL, jsonb
--   DEFAULT) an; die alte (text, jsonb)-Form muss EINMALIG weg (sonst "function is not unique" — Muster V013/V014).
--
--   SICHER: kein DB-Objekt haengt an finance.fn_advisor_review (nur der Core-Wrapper ruft sie dynamisch via
--   EXECUTE). IDEMPOTENT (IF EXISTS); Fresh DB = no-op (R__ legt direkt die 3-Arg-Form an). finance hat keinen
--   REVOKE-PUBLIC-Tail auf dieser fn -> kein M3-Thema.
--
-- APPLY-ORDER: Inits -> V (hier, droppt 2-Arg) -> R (legt 3-Arg an). Re-run-sicher.
-- ============================================================

DROP FUNCTION IF EXISTS finance.fn_advisor_review(text, jsonb);
