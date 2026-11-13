-- ============================================================
-- fn_recurring_kind_policy (IMMUTABLE) -- Regel je Kategorie, die das Lese-Modell einer Auszugszeile gibt (recurring_kind)
--   Die eine Adresse, welche Kategorien als Dauerauftrag vorgeschlagen werden (statt einer Wortliste je Bank):
--   card_purchase, cash, fee_interest nie; insurance und loan nicht als Vorschlag, sondern als Hinweis auf ihren Bereich
--   (ein Vierteljahres-Beitrag als freie Zahlung zaehlte sonst falsch); other nur ab 2 Terminen mit gemessenem Rhythmus
--   (confirm_ok false = nie mit angenommenem Rhythmus, fn_get_recurring_candidates); own_transfer wird ein Uebertrag. Unbekannt oder leer = other.
--   Eingabe: p_kind (text).
--   Rueckgabe: {kind (kanonisch), proposable, confirm_ok, min_lines, transfer, hint_area (nur insurance|loan)}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_kind_policy(p_kind text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_strip_nulls(jsonb_build_object(
        'kind', k,
        'proposable', k NOT IN ('card_purchase', 'cash', 'fee_interest', 'insurance', 'loan'),
        'confirm_ok', k NOT IN ('card_purchase', 'cash', 'fee_interest', 'insurance', 'loan', 'other'),
        'min_lines', CASE WHEN k = 'other' THEN 2 ELSE 1 END,
        'transfer', k = 'own_transfer',
        'hint_area', CASE WHEN k IN ('insurance', 'loan') THEN k END))
    FROM (SELECT CASE WHEN lower(btrim(COALESCE(p_kind, ''))) IN
                      ('salary', 'pension', 'benefit', 'rent', 'utility', 'subscription', 'standing_order', 'direct_debit',
                       'insurance', 'loan', 'own_transfer', 'card_purchase', 'cash', 'fee_interest', 'other')
                      THEN lower(btrim(p_kind)) ELSE 'other' END AS k) x;
$$;
