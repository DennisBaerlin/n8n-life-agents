-- ============================================================
-- V028 (core) — die alte Null-Argument-Form von core.fn_render_welcome droppen (Textkatalog Phase B).
--
--   Die Begruessung kommt jetzt in der Sprache des Empfaengers: core.fn_render_welcome() -> (p_lang text DEFAULT NULL).
--   CREATE OR REPLACE kann die ARITAET nicht aendern; die alte 0-arg-Form neben der DEFAULT-Form wuerde beim 0-arg-Call
--   "function is not unique" werfen -> die alte Form muss EINMALIG weg (Muster core:V013/V015/V016).
--
--   KEIN DB-Objekt haengt statisch an der alten Form (Aufrufer: n8n-Postgres-Node + owner_connect.sh) -> reiner DROP.
--   Der core_ro-EXECUTE-Grant auf die neue Arity setzt util_create_core_ro.sql im selben Apply nach den R__ neu.
--
--   APPLY-ORDER: core-V (hier) laeuft VOR den core-R__ (die die neue Arity anlegen). Fresh-DB: die alte Form existiert
--   nie -> DROP IF EXISTS = No-Op; Upgrade: droppt die alte Form vor dem R__-Re-Create. Re-run-sicher.
-- ============================================================

DROP FUNCTION IF EXISTS core.fn_render_welcome();
