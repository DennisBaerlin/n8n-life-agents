-- ============================================================
-- V032 (finance) — Verrechnungskonto nur fuer Depots und P2P-Konten scharf schalten (Bank-Import-Modul Paket 2).
--
--   WARUM eine V-Migration: das Init legt finance_accounts_settlement_kind nur NOT VALID an (fn_create_account nahm
--   frueher bei jeder Kontoart ein Verrechnungskonto an; ein solcher Altwert hatte nie eine Bedeutung). Hier wird er
--   EINMALIG geleert, dann validiert. FRISCHE DB: kein Bestand -> No-op + VALIDATE. Re-run-sicher.
-- ============================================================

UPDATE finance.accounts
   SET settlement_account_id = NULL
 WHERE settlement_account_id IS NOT NULL
   AND account_type NOT IN ('stocks_depot', 'crypto_depot', 'p2p');

ALTER TABLE finance.accounts VALIDATE CONSTRAINT finance_accounts_settlement_kind;
