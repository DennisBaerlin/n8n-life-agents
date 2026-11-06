-- ============================================================
-- V033 (core) — core.fn_resolve_person bekommt die chat_id des Absenders: die 1-Arg-Signatur droppen.
--
--   WARUM (Renteninformation-Plan 2026-10-26, Owner-Befund "ich" als Person scheiterte): ein Personenfeld, das GENAU
--   ein Selbstbezug ist (ich/mir/mein/me/나 ...), meint die Person, die gerade chattet. R__fn_resolve_person legt
--   jetzt (text, text DEFAULT NULL) an; CREATE OR REPLACE kann die Aritaet nicht aendern -> die alte (text)-Form muss
--   EINMALIG weg (sonst "function is not unique" beim 1-Arg-Call, Muster V013/V014). Die 1-Arg-Aufrufe der Tools
--   und fns bleiben gueltig (DEFAULT NULL = wie bisher).
--
-- APPLY-ORDER: Inits -> V (hier) -> R (R__fn_resolve_person legt die 2-Arg-Form an; R__fn_provision_package_roles
--   grantet sie den Paket-Rollen) -> util. Kein DB-Objekt haengt an der Funktion (nur plpgsql-Aufrufer, late-bound).
--   Fresh DB: die 1-Arg-Form entstand nie -> DROP no-op. Re-run-sicher.
-- ============================================================

DROP FUNCTION IF EXISTS core.fn_resolve_person(text);
