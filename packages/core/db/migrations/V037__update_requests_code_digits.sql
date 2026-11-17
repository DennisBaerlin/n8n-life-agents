-- ============================================================
-- V037 — Schritt- und Grund-Codes in core.update_requests duerfen Ziffern tragen.
--   Der Schritt "n8n" (provision.sh ui_step) und der Grund "n8n_start" verstiessen gegen '^[a-z_]{1,40}$':
--   fn_update_request_finish machte sie zu NULL, der Bericht sagte "Schritt unbekannt". Neue Form wie im Init:
--   Kleinbuchstabe vorn, dann Kleinbuchstaben, Ziffern, Unterstrich (bleibt eng; die Codes stehen in Katalog-Keys).
--   Nur erweitert: jede Bestands-Zeile erfuellt die neue Form schon. Re-run-sicher (DROP CONSTRAINT IF EXISTS + ADD).
--   squawk ban-drop-constraint je Zeile ausgenommen: Drop und Neu-Anlage unter demselben Namen in derselben Transaktion,
--   keine Garantie geht verloren (eine Ausnahme je Datei in config/.squawk.toml scheitert bei einer einzeln gestagten V-Datei).
-- ============================================================
-- squawk-ignore ban-drop-constraint
ALTER TABLE core.update_requests DROP CONSTRAINT IF EXISTS update_requests_stage_check;
ALTER TABLE core.update_requests ADD CONSTRAINT update_requests_stage_check
    CHECK (stage IS NULL OR stage ~ '^[a-z][a-z0-9_]{0,39}$');
-- squawk-ignore ban-drop-constraint
ALTER TABLE core.update_requests DROP CONSTRAINT IF EXISTS update_requests_reason_code_check;
ALTER TABLE core.update_requests ADD CONSTRAINT update_requests_reason_code_check
    CHECK (reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{0,39}$');
