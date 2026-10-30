-- ============================================================
-- fn_app_payment_occurrences (READ, STABLE) -- die Dauerauftrags-Vorkommen EINES Kontos in [p_from, p_until] als
--   Eingabe-Zeilen fuer finance.fn_app_payment_rows (Mini-App „Zahlungen", UX 2026-10-30). Betraege allein aus
--   finance.fn_account_planned_flows (dieselbe Quelle wie die Tagesreihe: Quell-Seite signiert, Ziel-Seite eines
--   Uebertrags in ZIELwaehrung) -> ein eigener Uebertrag erscheint bei der Quelle als Abgang UND beim Ziel als Eingang.
--   Label: Name der Zahlung (bei einem Sparplan der Plan-Name ueber den Lineage-Kopf, sonst stuende „Sparplan <Plan>"
--   doppelt), nur bei sichtbarer Quelle; sonst neutral „vom Haushalt" (Zero-Trust wie fn_app_screen_payments: p_hh =
--   Haushalts-Sicht, sonst sichtbar = owner_person_id IS NOT DISTINCT FROM p_person). to = Ziel eines Abgangs (Name bei
--   sichtbarem Ziel, sonst „Haushalt"). key = Lineage-Kopf + Seite (Gruppierung wiederholter Vorkommen).
--   RUECKGABE: {rows: [{key, date, amount, cur, label, to}], fx_gap} (Reihenfolge Datum, Name)
--   Tests: tests/db/finance/test_fn_app_payment_occurrences.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_payment_occurrences(p_account_id int, p_from date, p_until date,
                                                              p_hh boolean, p_person text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'rows', COALESCE(jsonb_agg(jsonb_build_object(
                    'key', finance.fn_recurring_lineage_head(r.id)::text || CASE WHEN pf.amount < 0 THEN ':out' ELSE ':in' END,
                    'date', pf.due_date,
                    'amount', pf.amount,
                    'cur', acc.currency,
                    'label', CASE WHEN r.account_id = p_account_id OR p_hh OR sa.owner_person_id IS NOT DISTINCT FROM p_person
                                  THEN to_jsonb(COALESCE(sp.name, r.name))
                                  ELSE core.fn_ui_tpl('finance.app.payments.from_household') END,
                    'to', CASE WHEN r.account_id = p_account_id AND r.target_account_id IS NOT NULL
                               THEN CASE WHEN p_hh OR ta.owner_person_id IS NOT DISTINCT FROM p_person THEN to_jsonb(ta.name)
                                         ELSE core.fn_ui_tpl('finance.app.payments.household') END END)
                    ORDER BY pf.due_date, COALESCE(sp.name, r.name)), '[]'::jsonb),
        'fx_gap', COALESCE(bool_or(pf.fx_gap), false))
      FROM finance.fn_account_planned_flows(p_account_id, p_from, p_until) pf
      JOIN finance.accounts acc ON acc.id = p_account_id
      JOIN finance.recurring_payments r ON r.id = pf.recurring_payment_id
      JOIN finance.accounts sa ON sa.id = r.account_id
      LEFT JOIN finance.accounts ta ON ta.id = r.target_account_id
      LEFT JOIN finance.savings_plans sp ON sp.recurring_payment_id = finance.fn_recurring_lineage_head(r.id);
$$;
