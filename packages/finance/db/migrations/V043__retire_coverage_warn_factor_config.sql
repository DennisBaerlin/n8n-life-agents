-- ============================================================
-- V043 (finance) — die Config-Zeile coverage_warn_factor entfernen (Muster V037).
--
--   WARUM eine V-Migration: Seeds sind additiv und loeschen nie. Das Puffer-Urteil von fn_account_low_state kennt nur
--   noch ok (ab dem Puffer) und alert (darunter); die gelbe Stufe „knapp ueber dem Puffer" und ihr Faktor sind weg.
--   Nur diese Zeile; idempotent (Fresh DB = no-op).
-- ============================================================

DELETE FROM core.config
WHERE package = 'finance'
  AND category = 'finance'
  AND key = 'coverage_warn_factor';
