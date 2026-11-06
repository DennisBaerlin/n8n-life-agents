-- ============================================================
-- fn_merge_fold (INTERNAL HELPER, IMMUTABLE) -- haengt ein Fold-Ergebnis an die Rueckgabe einer Write-fn
--   Die EINE Stelle, an der card_lines zusammengefuegt werden: die Kartenzeilen des Folds kommen HINTER die eigenen
--   der Write-fn (aehnlicher Eintrag, Namenspruefung, Kalender ...), alle uebrigen Fold-Schluessel (z. B.
--   savings_funding) werden angehaengt. Ein blankes `||` wuerde card_lines ersetzen und die eigenen Hinweise still von
--   der Karte nehmen (Plan-Review 2026-10-30). card_lines, die kein Array sind (fehlend, JSON null), zaehlen als leer.
--   Aufrufer: fn_create_savings_plan, fn_set_savings_plan, fn_create_recurring_transfer, fn_create_recurring_payment.
--   RUECKGABE jsonb: p_base || (p_fold ohne card_lines) + card_lines = base.card_lines || fold.card_lines
--   Tests: tests/db/finance/test_fn_savings_funding_fold.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_merge_fold(p_base jsonb, p_fold jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT (COALESCE(p_base, '{}'::jsonb) || (COALESCE(p_fold, '{}'::jsonb) - 'card_lines'))
        || CASE WHEN jsonb_typeof(p_base -> 'card_lines') = 'array' OR jsonb_typeof(p_fold -> 'card_lines') = 'array'
                THEN jsonb_build_object('card_lines',
                         CASE WHEN jsonb_typeof(p_base -> 'card_lines') = 'array' THEN p_base -> 'card_lines' ELSE '[]'::jsonb END
                         || CASE WHEN jsonb_typeof(p_fold -> 'card_lines') = 'array' THEN p_fold -> 'card_lines' ELSE '[]'::jsonb END)
                ELSE '{}'::jsonb END;
$$;
