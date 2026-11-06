-- ============================================================
-- V030 (core) — die alte Text-Signatur von core.fn_staleness_alert droppen (Folge Textkatalog Phase C).
--
--   Seit Phase C (Release v0.10.0) rufen alle Paket-Reviewer (finance/career/estate fn_advisor_review) die
--   jsonb-Ueberladung (Struktur statt deutschem Text). Die Text-Form (text,text,numeric,numeric,text) blieb nur als
--   Uebergang fuer ein Paket-Update, das hinter dem Core-Update zurueckliegt; der Uebergang ist abgelaufen.
--
--   KEIN DB-Objekt haengt statisch an der alten Form (Aufrufer sind PL/pgSQL-Bodies, die per jsonb binden) -> reiner DROP.
--
--   APPLY-ORDER: core-V (hier) laeuft VOR den core-R__ (R__fn_staleness_alert legt nur noch die jsonb-Form an).
--   Fresh-DB: die alte Form existiert nie -> DROP IF EXISTS = No-Op; Upgrade: droppt sie einmalig. Re-run-sicher.
-- ============================================================

DROP FUNCTION IF EXISTS core.fn_staleness_alert(text, text, numeric, numeric, text);
