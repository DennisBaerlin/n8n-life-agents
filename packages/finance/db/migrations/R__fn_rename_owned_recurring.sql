-- ============================================================
-- fn_rename_owned_recurring (INTERNAL HELPER — not tool-facing, WP2 "Finanzen schlank")
--   Fuehrt die Namenskopie einer entitaets-besessenen Raten-Kette bei einer Umbenennung mit: jedes Glied der Kette
--   von p_rp_id, dessen Name genau '<Praefix> <alter Name>' lautet, heisst danach '<Praefix> <neuer Name>' (auf 100
--   Zeichen gekuerzt wie die Spalte). Praefixe aus den create-fns: 'Kreditrate' (Kredit), 'Versicherung',
--   'AV-Beitrag' (Vorsorge), 'Sparrate' (Sparziel). Ein abweichender Name bleibt unberuehrt. Vorher blieb die rp nach
--   set_* auf dem alten Namen stehen (Erinnerung, Cashflow-Liste und Kontoauszug-Abgleich sahen ihn weiter).
--   Gerufen von fn_set_loan, fn_set_insurance, fn_set_pension, fn_set_savings_goal. NULL-Kette oder gleicher Name -> 0.
--   RUECKGABE: Anzahl umbenannter Glieder.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_rename_owned_recurring(p_rp_id int, p_prefix text, p_old text, p_new text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_n INT;
BEGIN
    IF p_rp_id IS NULL OR p_new IS NULL OR p_old IS NOT DISTINCT FROM p_new THEN
        RETURN 0;
    END IF;
    UPDATE finance.recurring_payments
       SET name = left(p_prefix || ' ' || p_new, 100)
     WHERE id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
       AND name = p_prefix || ' ' || p_old;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;
