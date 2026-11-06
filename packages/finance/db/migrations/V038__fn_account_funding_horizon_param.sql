-- V038__fn_account_funding_horizon_param.sql
-- Versionierte Einmal-Migration (Flyway-V__): finance.fn_account_funding bekommt den optionalen Parameter
-- p_horizon_months (2026-11-01, Enddatum "bis das freie Geld aufgebraucht ist" ueber laengere Zeitraeume). Ein neuer
-- Parameter ist in PostgreSQL eine neue Signatur -> die alte (int, boolean) muss weg, sonst gaebe es zwei Ueberladungen
-- und jeder 2-arg-Aufruf waere mehrdeutig. Die View finance.account_funding_overview haengt an der alten Signatur und
-- wird mitgedroppt; ihr R__ (in derselben Aenderung neu gefasst) legt sie danach wieder an, die neue fn legt ihr R__ an.
-- KEINE BEGIN/COMMIT (der Treiber wrapt). IF EXISTS -> frische DB: No-op.

DROP VIEW IF EXISTS finance.account_funding_overview;
DROP FUNCTION IF EXISTS finance.fn_account_funding(int, boolean);
