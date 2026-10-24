-- ============================================================
-- V022 (finance) — Altbestand fuer den CHECK finance_transactions_transfer_grouped nachtragen + validieren.
--
--   Das Init legt den CHECK (category 'transfer' => group_id NOT NULL) beim ersten Mal NOT VALID an. Eine Instanz
--   mit einbeinigen transfer-Zeilen aus der Zeit vor group_id wuerde sonst beim Einspielen eines Backups (COPY
--   prueft jeden CHECK, auch NOT VALID) scheitern. Darum hier einmalig:
--     (1) transfer-Zeilen ohne Kredit: je Zeile eine EIGENE group_id (= der heutige Void-Einzelfall von
--         fn_void_transaction: ohne group_id wird genau diese Zeile storniert -> Verhalten unveraendert);
--     (2) Kredit-Ereignisse mit einem transfer-Bein: ALLE Zeilen ohne group_id desselben (loan_id, transaction_date)
--         bekommen EINE gemeinsame group_id (auch principal/loan_payment-Beine) = der heutige Void-Fallback
--         "Altdaten ohne group_id" ueber loan_id + Datum -> die Paarung bleibt erhalten, egal welches Bein storniert wird;
--     (3) VALIDATE CONSTRAINT.
--   Fresh-DB: keine Zeilen -> (1)/(2) No-Op, (3) validiert sofort. Re-run-sicher (nur group_id IS NULL).
--   APPLY-ORDER: finance-Init (legt den CHECK an) laeuft VOR den V-Migrationen.
-- ============================================================

UPDATE finance.transactions
SET group_id = gen_random_uuid()
WHERE category::text = 'transfer' AND group_id IS NULL AND loan_id IS NULL;

-- MATERIALIZED: die UUID je (loan_id, Datum) genau EINMAL erzeugen. Eine Unterabfrage im FROM darf der Planer je
-- Zielzeile neu auswerten (Nested Loop) -> jedes Bein bekaeme still eine eigene gen_random_uuid().
WITH g AS MATERIALIZED (
    SELECT loan_id, transaction_date, gen_random_uuid() AS gid
    FROM finance.transactions
    WHERE category::text = 'transfer' AND group_id IS NULL AND loan_id IS NOT NULL
    GROUP BY loan_id, transaction_date
)
UPDATE finance.transactions t
SET group_id = g.gid
FROM g
WHERE t.group_id IS NULL
  AND t.loan_id = g.loan_id AND t.transaction_date = g.transaction_date;

ALTER TABLE finance.transactions VALIDATE CONSTRAINT finance_transactions_transfer_grouped;
