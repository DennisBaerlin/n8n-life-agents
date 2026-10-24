-- ============================================================
-- util_reset_user_data.sql — Werkszustand-Reset (Owner-Ops, DESTRUKTIV)
--   Duenner Wrapper um core.fn_reset_user_data (Logik + Vertrag dort, Phase B): ALLE Nutzerdaten weg
--   (Paket-Tabellen deny-by-default, Berater-Plaene, gelernte Notizen, Chat-Memory, weitere Personen,
--   Onboarding-Fortschritt), es bleiben Config, Stammdaten/Caches, Instruktions-Kontexte, die Owner-Identitaet
--   im family-Skelett und der Backup-Key. Paperless bleibt ganz unberuehrt (reset-skip, Owner-Entscheid).
--   PFLICHT VORHER: Backup ziehen — `lifeagents backup export` (Restore via `lifeagents backup restore`).
--   Usage:   db_apply.ps1 -File packages\core\db\util\util_reset_user_data.sql
-- ============================================================
SELECT core.fn_reset_user_data('RESET');
