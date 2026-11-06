-- ============================================================
-- V014 (finance) — Vorgaenger-Kette fuer Bestands-Splits nachtragen (Audit Paket 2, A0).
--
--   WARUM: Seit Paket 2 traegt jeder Split / jedes Reopen recurring_payments.predecessor_id. Aeltere Splits (vor
--   diesem Release) haben keinen Link -> fn_close_savings_plan zaehlte deren Historie nicht (Plan mit Buchungen auf
--   der Vorgaenger-rp wuerde hart geloescht), alte Vorkommen wuerden nicht als Sparplan/Kredit erkannt.
--
--   WAS (konservativ, nur das exakte Split-Muster, nur Ketten mit Besitzer):
--     Ziel = rp ohne predecessor_id, die einer Entitaet gehoert (Sparplan/Kredit/Sparziel/Versicherung/Vorsorge)
--            oder schon Vorgaengerin eines verknuepften Glieds ist (-> Ketten > 2 Glieder, iterativ);
--     Vorgaengerin = rp mit valid_to = Ziel.valid_from, gleichem Konto, gleichem Ziel-Konto (IS NOT DISTINCT FROM),
--            gleichem Vorzeichen, gleichem Namen (Splits entitaets-besessener rps uebernehmen den Namen immer),
--            noch ohne Nachfolger und selbst KEIN Kopf einer anderen Entitaet;
--     nur wenn die Zuordnung in BEIDE Richtungen eindeutig ist. Alles andere bleibt unverknuepft (wie bisher).
--   Einmalig (V), weil ein Init-Backfill bei jedem Apply kuenftige Zufallstreffer verknuepfen koennte.
--   Fresh -Reset: keine Daten -> no-op.
-- ============================================================

DO $$
DECLARE
    v_n INT;
BEGIN
    LOOP
        WITH owned AS (
            SELECT recurring_payment_id AS id FROM finance.savings_plans WHERE recurring_payment_id IS NOT NULL
            UNION SELECT recurring_payment_id FROM finance.loans         WHERE recurring_payment_id IS NOT NULL
            UNION SELECT recurring_payment_id FROM finance.savings_goals WHERE recurring_payment_id IS NOT NULL
            UNION SELECT recurring_payment_id FROM finance.insurances    WHERE recurring_payment_id IS NOT NULL
            UNION SELECT recurring_payment_id FROM finance.pension       WHERE recurring_payment_id IS NOT NULL
        ), tgt AS (
            SELECT r.*
            FROM finance.recurring_payments r
            WHERE r.predecessor_id IS NULL
              AND (r.id IN (SELECT id FROM owned)
                   OR EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = r.id))
        ), cand AS (
            SELECT t.id AS new_id, p.id AS old_id
            FROM tgt t
            JOIN finance.recurring_payments p
              ON p.valid_to = t.valid_from
             AND p.account_id = t.account_id
             AND p.target_account_id IS NOT DISTINCT FROM t.target_account_id
             AND sign(p.amount) = sign(t.amount)
             AND p.name = t.name
             AND p.id <> t.id
            WHERE NOT EXISTS (SELECT 1 FROM finance.recurring_payments s WHERE s.predecessor_id = p.id)
              AND p.id NOT IN (SELECT id FROM owned)
        ), uniq AS (
            SELECT c.new_id, c.old_id
            FROM cand c
            WHERE (SELECT count(*) FROM cand x WHERE x.new_id = c.new_id) = 1
              AND (SELECT count(*) FROM cand y WHERE y.old_id = c.old_id) = 1
        )
        UPDATE finance.recurring_payments r
        SET predecessor_id = u.old_id
        FROM uniq u
        WHERE r.id = u.new_id;

        GET DIAGNOSTICS v_n = ROW_COUNT;
        EXIT WHEN v_n = 0;
    END LOOP;
END $$;
