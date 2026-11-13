-- ============================================================
-- fn_transfer_executed_by (READ HELPER)
--   Wer fuehrt einen wiederkehrenden Uebertrag aus? Eine Adresse der Regel; Karte (create/set_recurring_payment),
--   Berater-Alarm (fn_advisor_review standing_order_ending) und Uebersicht (standing_order_overview.executed_by) lesen sie.
--   Eingabe: p_rp_id (recurring_payments.id). Rueckgabe: 'bank' (Dauerauftrag bei der Bank des Nutzers) | 'manual' (der Nutzer ueberweist selbst) | 'unknown'.
--   Regel: ein gespeicherter Wert (recurring_payments.executed_by, Nutzerangabe) gewinnt; sonst richtet sich die Antwort nach
--   der Kontoart der Quelle: Geld-Konto (cash) -> 'unknown' (ein Dauerauftrag ist moeglich, aber nirgends belegt); jede andere
--   Kontoart (P2P, Depot, Festgeld, Kredit) -> 'manual' (dort kann keine Dauerauftrags-Regel liegen, der Nutzer loest die
--   Auszahlung selbst aus). Zeile ohne Ziel-Konto (kein Uebertrag) oder unbekannte id -> 'unknown'.
--   Keine Schreib-Seiteneffekte; STABLE, INVOKER (liest nur finance.*, laeuft unter finance_rw und finance_ro).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_transfer_executed_by(p_rp_id int)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT CASE
                    WHEN rp.target_account_id IS NULL THEN 'unknown'
                    WHEN rp.executed_by IS NOT NULL THEN rp.executed_by
                    WHEN a.account_type = 'cash' THEN 'unknown'
                    ELSE 'manual'
                END
           FROM finance.recurring_payments rp
           JOIN finance.accounts a ON a.id = rp.account_id
          WHERE rp.id = p_rp_id),
        'unknown');
$$;
