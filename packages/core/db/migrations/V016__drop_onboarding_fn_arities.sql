-- ============================================================
-- V016 (core) — die alten Aritaeten der geteilten Onboarding-Lese-fns droppen (P2b-1 person-aware).
--
--   P2b-1 macht career.onboarding_state pro Person. Die GETEILTEN Core-Onboarding-Lese-fns bekommen eine
--   chat_id-Dimension (Person aus dem Sender, nie LLM): core.fn_onboarding_status(text) -> (text, text DEFAULT NULL)
--   und core.fn_onboarding_overview() -> (text DEFAULT NULL). CREATE OR REPLACE kann die ARITAET einer Function
--   nicht aendern; die alten Formen mit DEFAULT-Arg-Ueberladung wuerden beim 1-/0-arg-Call "function is not unique"
--   werfen -> die alten Formen muessen EINMALIG weg (Muster fn_fetch_context core:V013, fn_advisor_review_evaluate
--   core:V015). fn_set_onboarding_section(jsonb) bleibt unveraendert (chat_id reitet im jsonb -> keine Arity-Aenderung).
--
--   KEIN DB-Objekt haengt statisch an den alten Formen (die Aufrufer sind n8n-Postgres-Nodes/EXECUTE) -> reiner DROP.
--   Die EXECUTE-Grants auf die NEUE Arity setzt util_create_core_ro.sql (core_ro) + R__fn_provision_package_roles
--   (<pkg>_rw/_ro) im selben Apply NACH den R__ neu (sonst verwaisen sie still -> Laufzeit-permission-denied,
--   db_test/test_role_permissions deckt das ab).
--
--   APPLY-ORDER: core-V (hier) laeuft VOR den core-R__ (die die neue Arity anlegen) und VOR career. Fresh-DB:
--   die alte Form existiert nie (erst R legt fns an) -> DROP IF EXISTS = No-Op; Upgrade: droppt die alte Form
--   vor dem R__-Re-Create. Re-run-sicher.
-- ============================================================

DROP FUNCTION IF EXISTS core.fn_onboarding_status(text);
DROP FUNCTION IF EXISTS core.fn_onboarding_overview();
