-- ============================================================
-- V037 (finance) — Mini-App Konten: die Config-Zeile app_payments_days HART entfernen.
--
--   WARUM eine V-Migration (Muster V016): Seeds sind additiv und loeschen nie. Seit der Owner-Abnahme 2026-10-31 zeigen
--   „Gehen ab“ / „Kommen rein“ auf dem Konten-Tab den naechsten vollen Kalendermonat (jede Monatszahlung genau einmal);
--   ein Fenster „heute + N Tage“ gibt es nicht mehr, die Einstellung waere tot.
--   CHIRURGISCH: nur diese Zeile; IDEMPOTENT (ledger-gegated, Fresh DB = no-op).
-- ============================================================

DELETE FROM core.config
WHERE package = 'finance'
  AND category = 'finance'
  AND key = 'app_payments_days';
