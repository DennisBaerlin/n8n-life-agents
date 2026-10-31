-- V036__drop_fn_app_screen_payments.sql
-- Versionierte Einmal-Migration (Flyway-V__): der Mini-App-Bildschirm „Zahlungen“ ist durch „Konten“ ersetzt
-- (finance.fn_app_screen_accounts, UX-Gesamtkonzept 2026-10-31). Die Registry-Zeile raeumt der Seeder
-- (_seed_app_screens: DELETE + INSERT je Paket) ab; die alte Function bliebe ohne diesen Drop verwaist in der DB stehen
-- (Muster V031). KEINE BEGIN/COMMIT (der Treiber wrapt). IF EXISTS -> frische DB: No-op.

DROP FUNCTION IF EXISTS finance.fn_app_screen_payments(jsonb);
