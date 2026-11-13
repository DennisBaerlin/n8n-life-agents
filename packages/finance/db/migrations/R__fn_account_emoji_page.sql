-- ============================================================
-- fn_account_emoji_page (READ, STABLE) -- eine Seite der Knopf-Liste fuer das Konto-Zeichen
--   Die eine Stelle fuer Reihenfolge und Seiten: erst die sechs der Kontoart (erstes = Ersatz-Zeichen), dann die uebrigen
--   in Listen-Reihenfolge; 24 Zeichen = vier Seiten zu je sechs (n8n-Tastaturen sind statisch, Telegram lehnt leere Knoepfe ab).
--   Eingabe: p_account_id, p_page (0-3), p_lang. Rueckgabe core-neutrale choice_card {text, options:[6 x {text, data}], more:{text, data}}, more zeigt nach Seite 3 auf 0.
--   data = acem:<id>:<zeichen> bzw. acem:<id>:more:<seite> (finance.fn_handle_account_emoji_cb). NULL: Konto unbekannt oder Seite ausserhalb 0-3.
--   Tests: tests/db/finance/test_fn_account_emoji_page.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_emoji_page(p_account_id int, p_page int, p_lang text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_a     finance.accounts%ROWTYPE;
    v_head  text[];
    v_order text[];
    v_opts  jsonb;
BEGIN
    IF p_page IS NULL OR p_page NOT BETWEEN 0 AND 3 THEN RETURN NULL; END IF;
    SELECT * INTO v_a FROM finance.accounts WHERE id = p_account_id;
    IF NOT FOUND THEN RETURN NULL; END IF;

    v_head := CASE v_a.account_type
        WHEN 'cash'          THEN ARRAY['🏦','💳','👛','🐷','💰','🏠']
        WHEN 'p2p'           THEN ARRAY['🤝','💶','🌱','📈','💰','🎯']
        WHEN 'stocks_depot'  THEN ARRAY['📈','🌱','🎯','🎓','👶','🏠']
        WHEN 'crypto_depot'  THEN ARRAY['💎','📈','🌱','🎯','🌟','🍀']
        WHEN 'fixed_deposit' THEN ARRAY['🔒','🐷','💰','🎯','🌱','🏠']
        WHEN 'loan'          THEN ARRAY['🧾','🚗','🏠','🎓','🛒','🔧']
    END;
    v_order := v_head || ARRAY(SELECT e FROM unnest(finance.fn_account_emoji_choices()) WITH ORDINALITY AS t(e, n)
                                WHERE NOT e = ANY(v_head) ORDER BY n);

    SELECT jsonb_agg(jsonb_build_object(
               'text', e || ' ' || core.fn_ui_text('finance.emoji.' || to_hex(ascii(e)), p_lang),
               'data', 'acem:' || p_account_id || ':' || e) ORDER BY n)
      INTO v_opts
      FROM unnest(v_order[(p_page * 6 + 1):(p_page * 6 + 6)]) WITH ORDINALITY AS t(e, n);

    RETURN jsonb_build_object(
        'text', core.fn_ui_text('finance.dialog.emoji_pick', p_lang,
                    jsonb_build_object('account', finance.fn_account_label(v_a.emoji, v_a.account_type, v_a.name))),
        'options', v_opts,
        'more', jsonb_build_object('text', core.fn_ui_text('finance.dialog.emoji_more', p_lang),
                                   'data', 'acem:' || p_account_id || ':more:' || ((p_page + 1) % 4)));
END;
$$;
